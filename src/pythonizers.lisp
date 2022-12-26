(in-package :py4cl2-cffi)

;;; Object Handles - for not really translated lisp objects

(defvar *handle-counter* 0)
(defvar *lisp-objects* (make-hash-table :test #'eql))

(defun clear-lisp-objects ()
  "Clear the *lisp-objects* object store, allowing them to be GC'd"
  (setf *lisp-objects* (make-hash-table :test #'eql)
        *handle-counter* 0))

(defun free-handle (handle)
  "Remove an object with HANDLE from the hash table"
  (remhash handle *lisp-objects*))

(defun lisp-object (handle)
  "Get the lisp object corresponding to HANDLE"
  (or (gethash handle *lisp-objects*)
      (error "Invalid Handle.")))

(defun object-handle (object)
  "Store OBJECT and return a handle"
  (let ((handle (incf *handle-counter*)))
    (setf (gethash handle *lisp-objects*) object)
    handle))

;;; Reference counting utilities

(defvar *python-new-references* (make-hash-table)
  "A foreign object returned as a result of python C API function that
returns a new reference should call PYTRACK.

PYGC will then decrement the references when called.")

(defvar *top-level-p* t
  "Used inside PYGC and WITH-PYGC to avoid calling PYGC at non-top levels.
This avoids inadvertent calls to DecRef during recursions.")

(defun pygc ()
  (when *top-level-p*
    (maphash-keys (lambda (key)
                    (cffi:foreign-funcall "Py_DecRef" :pointer (make-pointer key))
                    (remhash key *python-new-references*))
                  *python-new-references*))
  nil)

(defmacro with-pygc (&body body)
  `(unwind-protect
     (let ((*top-level-p* nil))
       ,@body)
     ;; FIXME: When to call CLEAR-LISP-OBJECTS
     (pygc)))

(defun pytrack (python-object-pointer)
  "Call this function when the foreign function of the Python C-API returns
a New Reference"
  (declare (type foreign-pointer python-object-pointer)
           (optimize speed))
  (unless (null-pointer-p python-object-pointer)
    (setf (gethash (pointer-address python-object-pointer) *python-new-references*) t))
  python-object-pointer)

(defun pyuntrack (python-object-pointer)
  "Call this function when the foreign function of the Python C-API steals
a New Reference"
  (declare (type foreign-pointer python-object-pointer)
           (optimize speed))
  (let ((ht   *python-new-references*)
        (addr (pointer-address python-object-pointer)))
    (remhash addr ht))
  nil)

;;; Unknown python objects
(defstruct python-object
  "A pointer to a python object which couldn't be translated into a Lisp value.
TYPE slot is the python type string
POINTER slot points to the object"
  type
  pointer)

(defvar *print-python-object* t
  "If non-NIL, python's 'str' is called on the python-object before printing.")

(defun python-object-eq (o1 o2)
  (declare (type python-object o1 o2))
  (pointer-eq (python-object-pointer o1)
              (python-object-pointer o2)))

(defmethod print-object ((o python-object) s)
  (print-unreadable-object (o s :type t :identity t)
    (with-slots (type pointer) o
      (if *print-python-object*
          (progn
            (format s ":type ~A~%"
                    (lispify (foreign-funcall "PyObject_Str" :pointer type :pointer)))
            (pprint-logical-block (s nil :per-line-prefix "  ")
              ()
              (write-string (lispify (foreign-funcall "PyObject_Str"
                                                      :pointer pointer :pointer))
                            s))
            (terpri s))
          (format s ":POINTER ~A :TYPE ~A" pointer
                  (lispify (foreign-funcall "PyObject_Str" :pointer type :pointer)))))))

(declaim (type (function (t) foreign-pointer) pythonize))
(defgeneric pythonize (lisp-value-or-object))

(deftype c-long ()
  (let ((num-bits (* 8 (cffi:foreign-type-size :long))))
    `(signed-byte ,num-bits)))

(defmethod pythonize ((o #+sbcl sb-sys:system-area-pointer
                         #-sbcl foreign-pointer))
  o)
(defmethod pythonize ((o python-object)) (python-object-pointer o))

(defmethod pythonize ((o integer))
  (unless (typep o 'c-long)
    ;; TODO: Proper warning class
    (warn "Given integer ~S is too bit to be interpreted as a C long" o))
  (pytrack (foreign-funcall "PyLong_FromLong" :long o :pointer)))

(defmethod pythonize ((o float))
  ;; TODO: Different numpy float types: float32 and float64
  (pytrack (foreign-funcall "PyFloat_FromDouble"
                            :double (coerce o 'double-float)
                            :pointer)))

(defmethod pythonize ((o string))
  (pytrack (foreign-funcall "PyUnicode_FromString" :string o :pointer)))

(defmethod pythonize ((o list))
  (pythonize-list o))

(defmethod pythonize ((o vector))
  (if (typep o '(vector t))
      (pytrack
       (let ((list (foreign-funcall "PyList_New" :int (length o) :pointer)))
         (loop :for elt :across o
               :for pyelt := (pythonize elt)
               :for pos :from 0
               :do (if (zerop (foreign-funcall "PyList_SetItem"
                                               :pointer list
                                               :int pos
                                               :pointer pyelt
                                               :int))
                       (pyuntrack pyelt)
                       (python-may-be-error)))
         list))
      (pythonize-array o)))

(defmethod pythonize ((o hash-table))
  (pytrack
   (let ((dict (foreign-funcall "PyDict_New" :pointer)))
     (maphash (lambda (key value)
                (let ((key   (pythonize key))
                      (value (pythonize value)))
                  (if (zerop (foreign-funcall "PyDict_SetItem"
                                              :pointer dict
                                              :pointer key
                                              :pointer value
                                              :int))
                      nil ;; No reference stealing
                      (python-may-be-error))))
              o)
     dict)))

(defmethod pythonize ((o array))
  (pythonize-array o))

(defcallback lisp-callback-fn :pointer ((handle :int) (args :pointer) (kwargs :pointer))
  (handler-case
      (let ((lisp-callback (lisp-object handle)))
        (pythonize (apply lisp-callback
                          (nconc (unless (null-pointer-p args)
                                   (lispify args))
                                 (unless (null-pointer-p kwargs)
                                   (loop :for i :from 0
                                         :for elt
                                           :in (hash-table-plist
                                                (lispify kwargs))
                                         :collect (if (evenp i)
                                                      (intern (lispify-name elt) :keyword)
                                                      elt)))))))
    (error (c)
      (foreign-funcall "PyErr_SetString"
                       :pointer (pytype "Exception")
                       :string (format nil "~A" c))
      (pythonize 0))))

(defmethod pythonize ((o function))
  (let ((lisp-callback-object
          (pycall "_py4cl_LispCallbackObject" (object-handle o))))
    (pytrack (python-object-pointer lisp-callback-object))))

(defun pythonize-array (array)
  (pytrack
   (let* ((descr        (foreign-funcall "PyArray_Descr_from_element_type_code"
                                         :string (array-element-typecode array)
                                         :pointer))
          (ndarray-type (foreign-funcall "PyDict_GetItemString"
                                         :pointer (py-module-dict "numpy")
                                         :string "ndarray"
                                         :pointer))
          (ndims        (array-rank array)))
     (with-foreign-objects ((dims    :long ndims))
       (dotimes (i ndims)
         (setf (mem-aref dims :long i) (array-dimension array i)))
       (with-pointer-to-vector-data (array-data (sb-ext:array-storage-vector array))
         (numpy-funcall "PyArray_NewFromDescr"
                        :pointer ndarray-type
                        :pointer descr
                        :int ndims
                        :pointer dims
                        :pointer (null-pointer)
                        :pointer array-data
                        :int (logior +npy-array-c-contiguous+ +npy-array-writeable+) ; flags
                        :pointer (null-pointer)
                        :pointer))))))

(defun array-element-typecode (array)
  ;; This is necessary, because not all lisps using these specific names as the
  ;; element-types. Element-types returned by different lisps (eg: SBCL vs ECL)
  ;; would only be TYPE= to each other, and not STRING=
  (declare (optimize speed))
  (eswitch ((array-element-type array) :test #'type=)
    ('single-float "f32")
    ('double-float "f64")
    ('(signed-byte 64) "sb64")
    ('(signed-byte 32) "sb32")
    ('(signed-byte 16) "sb16")
    ('(signed-byte 08) "sb8")
    ('(unsigned-byte 64) "ub64")
    ('(unsigned-byte 32) "ub32")
    ('(unsigned-byte 16) "ub16")
    ('(unsigned-byte 08) "ub8")))

(defun pythonize-list (list)
  (pytrack
   (let ((tuple (foreign-funcall "PyTuple_New" :int (length list) :pointer)))
     (loop :for elt :in list
           :for pyelt := (pythonize elt)
           :for pos :from 0
           :do (assert (zerop (foreign-funcall "PyTuple_SetItem"
                                               :pointer tuple
                                               :int pos
                                               :pointer pyelt
                                               :int)))
               (pyuntrack pyelt))
     tuple)))

(defmethod pythonize ((o symbol))
  (if (null o)
      (pyvalue* "None")
      (let* ((symbol-name (symbol-name o))
             (name (cond ((and (char= (char symbol-name 0) #\*)
                               ;; *global-variable* == PYTHON_CONSTANT
                               (char= (char symbol-name (1- (length symbol-name)))))
                          (subseq symbol-name 1 (1- (length symbol-name))))
                         ((string= "T" symbol-name)
                          "True")
                         ((every #'(lambda (char) ; = every character is either upper-case
                                     (not (lower-case-p char))) ; or is not an alphabet
                                 symbol-name)
                          (format nil "~(~a~)" symbol-name))
                         (t
                          symbol-name))))
        ;; Replace - by _
        (iter (for char in-string name)
          (collect (if (char= char #\-)
                       #\_
                       char)
            into python-name
            result-type string)
          ;; Use keywords as if to indicate keyword python argument name
          (finally (return (pythonize python-name)))))))

(defun pythonize-plist (plist)
  (pytrack
   (if (null plist)
       (null-pointer)
       (let ((dict (foreign-funcall "PyDict_New" :pointer)))
         (doplist (key val plist)
                  (assert (zerop (foreign-funcall "PyDict_SetItem"
                                                  :pointer dict
                                                  :pointer (pythonize key)
                                                  :pointer (pythonize val)
                                                  :int))))
         dict))))

(defvar *pythonizers*
  ()
  "Each entry in the alist *PYTHONIZERS* maps from a lisp-type to
a single-argument PYTHON-FUNCTION-DESIGNATOR. This python function takes as input the
\"default\" python objects and is expected to appropriately convert it to the corresponding
python object.

NOTE: This is a new feature and hence unstable; recommended to avoid in production code.")

(defmacro with-pythonizers ((&rest overriding-pythonizers) &body body)
  "Each entry of OVERRIDING-PYTHONIZERS is a two-element list of the form
  (TYPE PYTHONIZER)
Here, TYPE is unevaluated, while PYTHONIZER will be evaluated; the PYTHONIZER is expected
to take a default-pythonized object (see lisp-python types translation table in docs)
and return the appropriate object user expects.

For example,

  (raw-pyeval \"[1, 2, 3]\") ;=> #(1 2 3) ; the default object
  (with-pythonizers ((vector \"tuple\"))
    (print (pycall #'identity #(1 2 3)))
    (print (pycall #'identity 5)))
  ; (1 2 3)  ; coerced to tuple by the pythonizer, which then translates to list
  ; 5        ; pythonizer uncalled for non-VECTOR
  5

NOTE: This is a new feature and hence unstable; recommended to avoid in production code."
  `(let ((*pythonizers* (list* ,@(loop :for (type pythonizer) :in overriding-pythonizers
                                       :collect `(cons ',type ,pythonizer))
                               *pythonizers*)))
     ,@body))

(defun %pythonize (object)
  "A wrapper around PYTHONIZE to take custom *PYTHONIZERS* into account."
  (let ((default-pythonized-object (pythonize object)))
    (loop :for (type . pythonizer) :in *pythonizers*
          :if (typep object type)
            :do (return-from %pythonize (pycall* pythonizer default-pythonized-object)))
    default-pythonized-object))
