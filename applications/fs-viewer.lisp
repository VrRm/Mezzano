;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

(defpackage :mezzano.gui.fs-viewer
  (:use :cl)
  (:export #:spawn))

(in-package :mezzano.gui.fs-viewer)

(defvar *up-icon* (mezzano.gui.desktop::load-image "LOCAL:>Icons>16x16 Up.png"))
(defvar *file-icon* (mezzano.gui.desktop::load-image "LOCAL:>Icons>16x16 File.png"))
(defvar *folder-icon* (mezzano.gui.desktop::load-image "LOCAL:>Icons>16x16 Folder.png"))

(defclass fs-viewer ()
  ((%fifo :initarg :fifo :reader fifo)
   (%window :initarg :window :reader window)
   (%thread :initarg :thread :reader thread)
   (%font :initarg :font :reader font)
   (%frame :initarg :frame :reader frame)
   (%path :initarg :path :accessor path)
   (%clickables :initarg :clickables :accessor clickables))
  (:default-initargs :clickables '()))

(defgeneric dispatch-event (viewer event))

(defmethod dispatch-event (window (event mezzano.gui.compositor:window-activation-event))
  (setf (mezzano.gui.widgets:activep (frame window)) (mezzano.gui.compositor:state event))
  (mezzano.gui.widgets:draw-frame (frame window)))

(defvar *type-registry*
  '((:lisp-source-code "lisp" "lsp" "asd")
    (:compiled-lisp-code "llf")
    (:text "text" "txt")
    (:font "ttf")
    (:image "png" "jpeg" "jpg")))

(defun canonical-type-from-pathname-type (type-string)
  (when (not type-string)
    (return-from canonical-type-from-pathname-type :unknown))
  (when (eql type-string :wild)
    (return-from canonical-type-from-pathname-type :wild))
  (dolist (type *type-registry* :unknown)
    (when (member type-string (rest type) :test #'string-equal)
      (return (first type)))))

(defgeneric view (type path)
  (:method (type path)
    (declare (ignore path))
    (error "No way to view files of type ~A." type)))

(defun view-in-editor (path)
  ;; Ech, the terrible groveling.
  (let ((existing (mezzano.gui.compositor:get-window-by-kind :editor)))
    (cond (existing
           (mezzano.supervisor:fifo-push (make-instance (read-from-string "mezzano.editor:open-file-request") :path path)
                                           (mezzano.gui.compositor::fifo existing)
                                           nil))
          (t (funcall (read-from-string "mezzano.editor:spawn") :initial-file path)))))

(defmethod view ((type (eql :lisp-source-code)) path)
  (view-in-editor path))

(defmethod view ((type (eql :text)) path)
  (view-in-editor path))

(defmethod view ((type (eql :image)) path)
  (funcall (read-from-string "mezzano.gui.image-viewer:spawn") path))

(defun click (viewer thing)
  (cond ((functionp thing)
         (funcall thing viewer))
        ((not (pathnamep thing)))
        ((pathname-name thing)
         (view (canonical-type-from-pathname-type (pathname-type thing)) thing))
        (t ;; Directory
         (change-path viewer thing))))

(defmethod dispatch-event (window (event mezzano.gui.compositor:mouse-event))
  (mezzano.gui.widgets:frame-mouse-event (frame window) event)
  (when (and (not (logbitp 0 (mezzano.gui.compositor:mouse-button-state event)))
             (logbitp 0 (mezzano.gui.compositor:mouse-button-change event)))
    (let ((mx (mezzano.gui.compositor:mouse-x-position event))
          (my (mezzano.gui.compositor:mouse-y-position event)))
      (loop for (x1 y1 x2 y2 thing) in (clickables window) do
           (when (and (<= x1 mx) (< mx x2)
                      (<= y1 my) (< my y2))
             (return (click window thing)))))))

(defmethod dispatch-event (window (event mezzano.gui.compositor:window-close-event))
  (declare (ignore window event))
  (throw 'mezzano.supervisor::terminate-thread nil))

(defmethod dispatch-event (window (event mezzano.gui.compositor:key-event))
  (declare (ignore window event)))

(defun draw-string (string font framebuffer x y colour)
  (loop
     with pen = x
     for ch across string
     for glyph = (mezzano.gui.font:character-to-glyph font ch)
     for mask = (mezzano.gui.font:glyph-mask glyph)
     do
       (mezzano.gui:bitset-argb-xrgb-mask-8 (array-dimension mask 0) (array-dimension mask 1) colour
                                            mask 0 0
                                            framebuffer
                                            (- y (mezzano.gui.font:glyph-yoff glyph))
                                            (+ pen (mezzano.gui.font:glyph-xoff glyph)))
       (incf pen (mezzano.gui.font:glyph-advance glyph))
     finally (return pen)))

(defun change-path (viewer new-path)
  (setf (path viewer) new-path
        ;; Grumble
        (mezzano.gui.widgets:frame-title (frame viewer)) (concatenate 'string
                                                                      (string (mezzano.file-system:host-name (pathname-host new-path)))
                                                                      ":"
                                                                      (mezzano.file-system:unparse-pathname new-path (pathname-host new-path))))
  (let* ((window (window viewer))
         (framebuffer (mezzano.gui.compositor:window-buffer window))
         (font (font viewer))
         (width (mezzano.gui.compositor:width window))
         (height (mezzano.gui.compositor:height window))
         (stuff (directory (make-pathname :name :wild
                                          :type :wild
                                          :defaults new-path)))
         (files (sort (remove-if-not (lambda (x) (pathname-name x)) stuff)
                      #'string-lessp
                      :key #'pathname-name))
         (dirs (sort (set-difference stuff files)
                     #'string-lessp
                     :key (lambda (x) (first (last (pathname-directory x)))))))
    (multiple-value-bind (left right top bottom)
        (mezzano.gui.widgets:frame-size (frame viewer))
      (mezzano.gui:bitset (- height top bottom)
                          (- width left right)
                          mezzano.gui:*default-background-colour*
                          framebuffer
                          top left)
      (let ((y top))
        (flet ((wr (string &optional (offset 0) (min-line-height 0))
                 (draw-string string
                              font
                              framebuffer
                              (+ left offset) (+ y (mezzano.gui.font:ascender font))
                              mezzano.gui:*default-foreground-colour*)
                 (incf y (max min-line-height (mezzano.gui.font:line-height font))))
               (seperator ()
                 (mezzano.gui:bitset 1
                                     (- width left right)
                                     mezzano.gui:*default-foreground-colour*
                                     framebuffer
                                     y left)
                 (incf y))
               (clickable (icon name thing)
                 (mezzano.gui:bitblt-argb-xrgb 16 16
                                               icon 0 0
                                               framebuffer
                                               y (1+ left))
                 (let ((end (draw-string name
                                         font
                                         framebuffer
                                         (+ left 16 2) (+ y 2 (mezzano.gui.font:ascender font))
                                         mezzano.gui:*default-foreground-colour*)))
                   (push (list left y end (+ y (max 16 (mezzano.gui.font:line-height font)))
                               thing)
                         (clickables viewer)))
                 (incf y (max 16 (mezzano.gui.font:line-height font)))))
          (setf (clickables viewer) '())
          (let ((pen left))
            (dolist (host (mezzano.file-system:list-all-hosts))
              (let ((before pen))
                (incf pen 10)
                (cond ((eql host (pathname-host new-path))
                       (let ((text-width (draw-string (mezzano.file-system:host-name host)
                                                      font
                                                      framebuffer
                                                      0 0
                                                      #x00000000)))
                         (mezzano.gui:bitset (mezzano.gui.font:line-height font)
                                             (+ 10 text-width 10)
                                             mezzano.gui:*default-foreground-colour*
                                             framebuffer
                                             y (- pen 10))
                         (setf pen (draw-string (mezzano.file-system:host-name host)
                                                font
                                                framebuffer
                                                pen (+ y (mezzano.gui.font:ascender font))
                                                mezzano.gui:*default-background-colour*))))
                      (t (setf pen (draw-string (mezzano.file-system:host-name host)
                                                font
                                                framebuffer
                                                pen (+ y (mezzano.gui.font:ascender font))
                                                mezzano.gui:*default-foreground-colour*))))
                (incf pen 10)
                (push (list before y pen (+ y (mezzano.gui.font:line-height font))
                            (make-pathname :host host
                                           :directory '(:absolute)
                                           :name nil
                                           :type nil
                                           :version :newest))
                      (clickables viewer))))
            (incf y (mezzano.gui.font:line-height font)))
          (seperator)
          (wr (namestring new-path))
          (seperator)
          (when (not (= (length (pathname-directory new-path)) 1))
            (clickable *up-icon*
                       "Parent"
                       (make-pathname :directory (butlast (pathname-directory new-path))
                                      :defaults new-path)))
          (dolist (d dirs)
            (clickable *folder-icon*
                       (format nil "~A" (first (last (pathname-directory d))))
                       d))
          (dolist (f files)
            (clickable *file-icon*
                       (file-namestring f)
                       f))))
      (mezzano.gui.widgets:draw-frame (frame viewer))
      (mezzano.gui.compositor:damage-window window
                                            0 0
                                            width height))))

(defun main (default-path width height)
  (let ((font (mezzano.gui.font:open-font
               mezzano.gui.font:*default-monospace-font*
               mezzano.gui.font:*default-monospace-font-size*))
        (fifo (mezzano.supervisor:make-fifo 50)))
    (mezzano.gui.compositor:with-window (window fifo (or width 640) (or height 480))
      (let* ((framebuffer (mezzano.gui.compositor:window-buffer window))
             (frame (make-instance 'mezzano.gui.widgets:frame
                                   :framebuffer framebuffer
                                   :title (namestring default-path)
                                   :close-button-p t
                                   :damage-function (mezzano.gui.widgets:default-damage-function window)))
             (fs-viewer (make-instance 'fs-viewer
                                       :fifo fifo
                                       :window window
                                       :thread (mezzano.supervisor:current-thread)
                                       :font font
                                       :frame frame
                                       :path default-path)))
        (change-path fs-viewer default-path)
        (loop
           (handler-case
               (dispatch-event fs-viewer (mezzano.supervisor:fifo-pop fifo))
             (error (c)
               (ignore-errors
                 (format t "Error: ~A~%" c)))
             ;; Exit when the close button is clicked.
             (mezzano.gui.widgets:close-button-clicked ()
               (return-from main))))))))

(defun spawn (&key (initial-path *default-pathname-defaults*) width height)
  (setf initial-path (merge-pathnames initial-path))
  (mezzano.supervisor:make-thread (lambda () (main initial-path width height))
                                  :name "FS Viewer"
                                  :initial-bindings `((*terminal-io* ,(make-instance 'mezzano.gui.popup-io-stream:popup-io-stream
                                                                                     :title "FS Viewer console"))
                                                      (*standard-input* ,(make-synonym-stream '*terminal-io*))
                                                      (*standard-output* ,(make-synonym-stream '*terminal-io*))
                                                      (*error-output* ,(make-synonym-stream '*terminal-io*))
                                                      (*trace-output* ,(make-synonym-stream '*terminal-io*))
                                                      (*debug-io* ,(make-synonym-stream '*terminal-io*))
                                                      (*query-io* ,(make-synonym-stream '*terminal-io*)))))
