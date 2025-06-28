(in-package :py4cl2-cffi)

(defun optimize-speed-p ()
  (and +disable-pystop+
       (eq :initialized *python-state*)
       (member :sbcl *features*)))

(define-compiler-macro pycall (&whole form python-callable &rest args)
  #+sbcl (declare (sb-ext:muffle-conditions sb-ext:compiler-note))
  (if (not (optimize-speed-p))
      form
      (cond ((and (typep python-callable 'cffi:foreign-pointer)
                  (every (lambda (arg) (typep arg 'cffi:foreign-pointer)) args))
             (let ((pos-args (pythonize-list args)))
               `(with-pygc
                  (%pycall-return-value
                   ;; PyObject_Call returns a new reference
                   (pyforeign-funcall "PyObject_Call"
                                      :pointer ,python-callable
                                      :pointer ,pos-args
                                      :pointer ,(null-pointer)
                                      :pointer)))))
            ((constantp python-callable)
             (let ((python-callable
                     (typecase python-callable
                       (python-name
                        (pyvalue* python-callable))
                       (string
                        (with-remote-objects (raw-pyeval python-callable)))
                       (symbol
                        (pyvalue* (pythonize-symbol python-callable)))
                       (pyobject-wrapper
                        (pyobject-wrapper-pointer python-callable))
                       (t
                        (pythonize python-callable)))))
               (if (and (every #'constantp args)
                        (not (some #'python-keyword-p args)))
                   `(%pycall ,python-callable ,@args)
                   `(apply #'%pycall
                           ,python-callable
                           (list ,@args)))))
            (t
             form))))
