(defpackage :py4cl2-cffi
  (:use :cl :cffi :alexandria :py4cl2-cffi/config :iterate)
  (:import-from #:py4cl2-cffi/config
                #:%shared-library-from-ldflag)
  (:export #:*internal-features*

           #:+disable-pystop+
           #:with-python-gil
           #:*pygc-threshold*
           #:with-pygc
           #:enable-pygc
           #:disable-pygc

           #:pystart
           #:*additional-init-codes*
           #:python-alive-p
           #:python-start-if-not-alive
           #:with-python-output
           #:with-python-error-output
           #:pystop
           #:raw-pyeval
           #:pyeval
           #:raw-pyexec
           #:pyexec
           #:pyerror
           #:simple-pyerror
           #:pyvalue

           #:pythonize
           #:pyobject-wrapper
           #:pyobject-wrapper-eq
           #:pyobject-wrapper-eq*
           #:define-lispifier

           #:*pythonizers*
           #:with-pythonizers
           #:*lispifiers*
           #:with-lispifiers

           #:pycall
           #:pymethod
           #:pygenerator
           #:pyslot-value
           #:pyhelp
           #:pyref
           #:chain*
           #:chain
           #:pyversion-info
           #:with-remote-objects
           #:with-remote-objects*

           #:import-module
           #:import-function
           #:pymethod-list
           #:pyslot-list
           #:defpyfun
           #:defpymodule
           #:*defpymodule-silent-p*
           #:*print-pyobject*
           #:*print-pyobject-wrapper-identity*
           #:export-function

           #:+py-empty-tuple+
           #:+py-empty-tuple-pointer+
           #:+py-none+
           #:+py-none-pointer+

           #:python-getattr
           #:python-setattr

           #:pyfor))

(in-package :py4cl2-cffi)
