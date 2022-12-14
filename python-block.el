;;; python-block.el --- smart block indentation in Python -*- lexical-binding: t -*-

;; Copyright (C) 2022 Benjamin Moody

;; Author: Benjamin Moody <bmoody@mit.edu>
;; Keywords: languages

;; This file is not part of Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `python-block-mode' provides a mechanism for somewhat-intelligently
;; indenting Python code, by automatically detecting the "block" of
;; statements associated with the current line, and re-indenting all
;; of the lines at once.
;;
;; In other words, this mode lets you use the TAB key in Python mode
;; the same way that you would use TAB in any other programming
;; language - to interactively re-indent code as you edit it - without
;; screwing up the program's structure.
;;
;; Using the default settings:
;;
;;    aaaa()            # <---  pressing TAB on this line...
;;    if 1 < 2:         #
;;        bbbb()        #
;;    else:             #
;;        cccc()        #
;;                      #
;;        dddd()        #
;;    eeee()            #  ... re-indents up to here
;;
;;    ffff()            # <---  pressing TAB on this line...
;;    while True:       #
;;        gggg()        #  ... re-indents up to here
;;
;;
;;        if 2 > 3:     # <---  pressing TAB on this line...
;;                      #
;;            hhhh()    #  ... re-indents up to here
;;    iiii()
;;
;; These defaults can be tweaked via `python-block-max-blank-lines'
;; and `python-block-max-sibling-blank-lines'.  They can be
;; overridden by a prefix argument (C-u 5 TAB to indent exactly 5
;; lines, or C-u - TAB to ignore blank lines and extend the block as
;; far as possible.)
;;
;; To enable this mode by default in .emacs:
;;
;;   (autoload 'python-block-mode "python-block" nil t)
;;   (add-hook 'python-mode-hook (lambda () (python-block-mode 1)))

;;; Code:

(require 'python)

(defcustom python-block-highlight t
  "If non-nil, highlight a block after indenting it."
  :type 'boolean
  :group 'python)

(defface python-block-highlight
  '((((class color) (min-colors 88) (background light))
     :background "honeydew2"
     :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "darkslategray"
     :extend t)
    (t
     :inverse-video t
     :extend t))
  "Face used to highlight the block that was indented."
  :group 'python)

(defcustom python-block-max-blank-lines 1
  "Number of consecutive blank lines allowed within a block.

When indenting a block using `python-block-indent-lines', this
determines how many blank lines can appear in a row, regardless
of indentation or syntactic context.  If more than this number of
blank lines appear in a row, the indentation block ends there,
even if the blank lines occur in the middle of a subordinate
block or a multi-line expression.

If set to nil, there is no limit.  If set to 0,
`python-block-indent-lines' behaves just like
`python-indent-line'."
  :type '(choice (integer :tag "Number of lines")
                 (const :tag "Unlimited" nil))
  :safe 'integerp
  :group 'python)

(defcustom python-block-max-sibling-blank-lines 0
  "Number of consecutive blank lines allowed between sibling statements.

When indenting a block using `python-block-indent-lines', this
determines how many blank lines can appear between statements at
the original indentation level.

If set to nil, there is no limit.  If set to -1, sibling
statements are never considered to be part of the indentation
block."
  :type '(choice (integer :tag "Number of lines")
                 (const :tag "Unlimited" nil))
  :safe 'integerp
  :group 'python)

(defun python-block--indentable-p ()
  "Check whether point is at the start of an indentable block.

This is true if the current line is not empty, and is the start
of a Python statement or block (i.e., not in the middle of a
multi-line expression or a multi-line string constant.)"
  (and (not (eolp))
       (memq (car (python-indent-context))
             '(:after-comment
               ;; :inside-string
               :no-indent
               ;; :inside-paren
               ;; :inside-paren-at-closing-nested-paren
               ;; :inside-paren-at-closing-paren
               ;; :inside-paren-newline-start
               ;; :inside-paren-newline-start-from-block
               ;; :after-backslash
               ;; :after-backslash-assignment-continuation
               ;; :after-backslash-dotted-continuation
               ;; :after-backslash-first-line
               :after-block-end
               :after-block-start
               :after-line
               :at-dedenter-block-start))))

(defun python-block--independent-p ()
  "Check whether point is at the start of an independent block.

This is true if the current line is not empty, and is the start
of an independent Python statement or block (i.e., not in the
middle of a multi-line expression or multi-line string constant,
or a dedenter block such as `else' or `except'.)"
  (and (not (eolp))
       (memq (car (python-indent-context))
             '(:after-comment
               ;; :inside-string
               :no-indent
               ;; :inside-paren
               ;; :inside-paren-at-closing-nested-paren
               ;; :inside-paren-at-closing-paren
               ;; :inside-paren-newline-start
               ;; :inside-paren-newline-start-from-block
               ;; :after-backslash
               ;; :after-backslash-assignment-continuation
               ;; :after-backslash-dotted-continuation
               ;; :after-backslash-first-line
               :after-block-end
               :after-block-start
               :after-line
               ;; :at-dedenter-block-start
               ))))

(defun python-block--get-indentation ()
  "Move to the start of the line, and return the initial whitespace."
  (let ((end (progn (back-to-indentation) (point)))
        (start (progn (forward-line 0) (point))))
    (buffer-substring-no-properties start end)))

(defun python-block--change-indentation (old new)
  "Replace indentation OLD with NEW.

If the current line is part of the indentation block defined by
OLD (i.e., the line begins with the string OLD, possibly followed
by additional whitespace), replace OLD with NEW.

One or more blank lines may be skipped before the re-indented
line, depending on `python-block-max-blank-lines' and
`python-block-max-sibling-blank-lines'.

If a replacement is performed, return the number of lines
affected; otherwise, return nil."
  (let* ((n-blank-lines (skip-chars-forward "\n"))
         (ind (python-block--get-indentation)))
    (when (and (string-prefix-p old ind)
               (or (not python-block-max-blank-lines)
                   (<= n-blank-lines python-block-max-blank-lines))
               (or (not python-block-max-sibling-blank-lines)
                   (<= n-blank-lines python-block-max-sibling-blank-lines)
                   (not (equal old ind))
                   (not (python-block--independent-p))))
      (delete-region (point) (+ (point) (length old)))
      (insert new)
      (1+ n-blank-lines))))

(defvar python-block--indent-count 0
  "Number of lines indented by `bm-python-indent-block'.")

(defun python-block-indent-lines (&optional arg)
  "Indent one or more lines in Python mode.

With no prefix argument, if the current line is the start of a
Python statement, re-indent subsequent lines within the same
logical block of code.  The end of the block is defined by a
de-indented line, or by one or more blank lines (depending on the
values of of `python-block-max-blank-lines' and
`python-block-max-sibling-blank-lines'.)  Each line within the
block is indented or de-indented by the same amount.

If prefix argument ARG is an integer, re-indent the specified
number of lines (including the current line.)

If ARG is `-' (\\[universal-argument] -), re-indent all subsequent lines until the
next de-indented line (regardless of intervening blank lines.)

When an indentation command is invoked interactively multiple
times in a row (see `python-indent-trigger-commands'), it cycles
possible indentation levels from right to left."
  (interactive "P")

  (let* ((trigger-commands (cons 'python-block-indent-lines
                                 python-indent-trigger-commands))
         (cycling (and (memq this-command trigger-commands)
                       (eq last-command this-command)))
         (old (save-excursion (python-block--get-indentation)))
         (indentable (save-excursion
                       (forward-line 0)
                       (python-block--indentable-p)))
         (limit (cond
                 (arg (and (integerp arg) arg))
                 (cycling python-block--indent-count)))
         (python-block-max-blank-lines
          (if (eq arg '-) nil
            python-block-max-blank-lines))
         (python-block-max-sibling-blank-lines
          (if (eq arg '-) nil
            python-block-max-sibling-blank-lines))
         (start (line-beginning-position))
         (end start))
    (python-indent-line cycling)
    (when (or limit indentable)
      (save-excursion
        (let ((new (python-block--get-indentation)))
          (if limit
              ;; Limit specified: re-indent next N lines (or up to end
              ;; of buffer).  Lines that cannot be re-indented are
              ;; left alone.
              (save-restriction
                (save-excursion
                  (forward-line (max limit 0))
                  (narrow-to-region (point-min) (point)))
                (while (and (= (forward-line 1) 0)
                            (not (eobp)))
                  (python-block--change-indentation old new)))

            ;; No limit: detect end of block automatically.
            (while (and
                    ;; Stop if we have reached the end of the buffer
                    (= (forward-line 1) 0)
                    (not (eobp))
                    ;; Stop if this line is not re-indentable
                    (python-block--change-indentation old new)))))

        ;; Don't highlight blank lines at end of block
        (skip-chars-backward "\n")
        (skip-chars-forward "\n" (1+ (point)))
        (setq end (point))))

    (setq-local python-block--indent-count (count-lines start end))

    ;; Highlight the indented block
    (and indentable
         python-block-highlight
         (not noninteractive)
         (eq (current-buffer) (window-buffer (selected-window)))
         (let ((overlay (make-overlay start end)))
           (overlay-put overlay 'face 'python-block-highlight)
           (unwind-protect
               (sit-for 10)
             (delete-overlay overlay))))))

(defvar python-block-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\t" 'python-block-indent-lines)
    map))

;;;###autoload
(define-minor-mode python-block-mode
  "Minor mode to perform indentation on a block at a time in Python."
  :keymap python-block-mode-map
  :lighter " PyBlk"
  (when (derived-mode-p 'python-mode)
    (if python-block-mode
        (setq-local indent-line-function 'python-block-indent-lines)
      (setq-local indent-line-function 'python-indent-line-function))))

;;;###autoload (add-hook 'python-mode-hook (lambda () (python-block-mode 1)))

(provide 'python-block)

;;; python-block.el ends here
