;;; macro-rules.el --- Macros by Example

;; Copyright (C) 2014  Ian Price

;; Author: Ian Price <ianprice90@googlemail.com>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Supports r5rs patterns, except for vector patterns i.e.
;;
;;   (<pattern> ...)
;;   (<pattern> <pattern> ... . <pattern>)
;;   (<pattern> ... <pattern> <ellipsis>)

;;; Code:
(require 'cl-lib)
(require 'pcase)

(defun mbe-self-evaluating-p (object)
  (or (numberp object)
      (stringp object)
      (booleanp object)
      (keywordp object)))

(defvar mbe-ellipsis-object '...)

(defun mbe-ellipsis-p (object)
  (eql object mbe-ellipsis-object))

(defun mbe-pattern-p (sexp)
  (pcase sexp
    (`(,p ,(pred mbe-ellipsis-p))
     (mbe-pattern-p p))
    (`(,a . ,d)
     (and (mbe-pattern-p a) (mbe-pattern-p d)))
    ((pred symbolp) t)
    ((pred mbe-self-evaluating-p) t)
    (_ nil)))

(defun mbe-pattern-variables (sexp)
  ;; TODO: duplicate checking
  (pcase sexp
    (`(,p ,(pred mbe-ellipsis-p) . ,rest)
     (append (mbe-pattern-variables p)
             (mbe-pattern-variables rest)))
    (`(,a . ,d)
     (append (mbe-pattern-variables a) (mbe-pattern-variables d)))
    (`() nil)
    ((pred symbolp) (list sexp))
    (_ nil)))

(defun mbe-levels (pattern)
  (mbe-levels* pattern 0))

(defun mbe-levels* (pattern level)
  (pcase pattern
    (`(,p ,(pred mbe-ellipsis-p) . ,rest)
     (append (mbe-levels* p (+ level 1))
             (mbe-levels* rest level)))
    (`(,a . ,d)
     (append (mbe-levels* a level)
             (mbe-levels* d level)))
    (`() nil)
    ((pred symbolp) `((,pattern . ,level)))
    (_ nil)))

(defun mbe-compile-pattern-match (pattern match-var body)
  `(let ,(mbe-pattern-variables pattern)
     ,(mbe-compile-pattern-match* pattern match-var)
     ,@body))

(defun mbe-compile-pattern-match* (pattern match-var)
  (pcase pattern
    (`(,p ,(pred mbe-ellipsis-p))
     `(progn
        (unless (listp ,match-var) (throw 'bad-match nil))
        (while ,match-var
          ,(let* ((mvar  (gensym match-var))
                  (pvars (mbe-pattern-variables p))
                  (gensyms (mapcar #'gensym pvars)))
             `(let ,gensyms
                (let ((,mvar (car ,match-var)) ,@pvars)
                  ,(mbe-compile-pattern-match* p mvar)
                  ,@(cl-map 'list (lambda (x y) `(setq ,x ,y)) gensyms pvars))
                ;; TODO: build in reverse, then reverse
                ,@(cl-map 'list (lambda (x y) `(setq ,x (append ,x (list ,y))))
                          pvars gensyms)
                (setq ,match-var (cdr ,match-var)))))))
    (`(,a . ,d)
     `(progn
        (unless (consp ,match-var) (throw 'bad-match nil))
        ,(let ((m1 (gensym match-var))
               (m2 (gensym match-var)))
           `(let ((,m1 (car ,match-var))
                  (,m2 (cdr ,match-var)))
              ,(mbe-compile-pattern-match* a m1)
              ,(mbe-compile-pattern-match* d m2)))))
    (`()
     `(when ,match-var (throw 'bad-match nil)))
    ((pred symbolp)
     `(setq ,pattern ,match-var))
    ((pred mbe-self-evaluating-p)
     ;; TODO: make equality configurable?
     `(unless (equal ,match-var ,pattern) (throw 'bad-match nil)))
    (_ (throw 'bad-pattern pattern))))


(defmacro mbe-destructuring-let (pattern val &rest body)
  (let ((value (gensym)))
    `(let ((,value ,val))
       (catch 'bad-match
         ,(mbe-compile-pattern-match pattern value body)))))


(defun mbe-constrain-levels (levels form)
  (let ((vars (mbe-pattern-variables form)))
    (mapcar #'mbe-adjust-level
            (cl-remove-if-not (lambda (pair) (member (car pair) vars))
                              levels))))
(defun mbe-adjust-level (pair)
  (cons (car pair) (- (cdr pair) 1)))

(defun mbe-compile-template (pattern levels)
  (pcase pattern
    (`(,p ,(pred mbe-ellipsis-p) . ,rest)
     (let* ((levels*  (mbe-constrain-levels levels p))
            (ids      (mapcar #'car levels*)))
       ;; TODO: check lengths
       (unless ids (throw 'bad-ellipsis))
       `(append (cl-mapcar (lambda ,ids
                             ,(mbe-compile-template p levels*))
                           ,@ids)
                ,(mbe-compile-template rest levels))))
    (`(,a . ,d)
     `(cons ,(mbe-compile-template a levels)
            ,(mbe-compile-template d levels)))
    (`() nil)
    ((pred symbolp)
     (let ((level (cdr (assoc pattern levels))))
       (cond ((not level) (list 'quote pattern))
             ((and level (= level 0)) pattern)
             (else (throw 'not-enough-ellipsis)))))
    ((pred mbe-self-evaluating-p) pattern)
    (_ (throw 'bad-pattern pattern))))

(defun mbe-make-defrule (var pattern template on-success)
  (let ((levels (mbe-levels pattern)))
    `(catch 'bad-match
       ,(mbe-compile-pattern-match
         pattern
         var
         (list `(throw ',on-success
                       (cons 'progn ,(mbe-compile-template template levels))))))))

(defmacro defrule (name pattern template)
  `(defrules ,name (,pattern ,template)))

(defmacro defrules (name &rest rest)
  (let ((rest*   (gensym 'rest))
        (success (gensym 'success)))
    `(defmacro ,name (&rest ,rest*)
       (catch ',success
         ,@(mapcar (lambda (clause)
                     (let ((pattern  (car clause))
                           (template (cdr clause)))
                       (mbe-make-defrule rest*
                                         pattern
                                         template
                                         success)))
                   rest)
         (error "No matching pattern for defrule" name rest)))))

(provide 'macro-rules)
;;; macro-rules.el ends here
