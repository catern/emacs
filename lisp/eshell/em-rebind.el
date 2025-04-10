;;; em-rebind.el --- rebind keys when point is at current input  -*- lexical-binding:t -*-

;; Copyright (C) 1999-2025 Free Software Foundation, Inc.

;; Author: John Wiegley <johnw@gnu.org>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'esh-mode)

;;;###esh-module-autoload
(progn
(defgroup eshell-rebind nil
  "This module allows for special keybindings that only take effect
while the point is in a region of input text.  The default
keybindings mimic the bindings used in other shells when the user
is editing new input text.

For example, it binds C-u to kill the current input text and C-w
to `backward-kill-word'.  If the history module is enabled, it
also binds C-p and C-n to move through the input history, etc.

If `eshell-confine-point-to-input' is non-nil, this module prevents
certain commands from causing the point to leave the input area, such
as `backward-word', `previous-line', etc."
  :tag "Rebind keys at input"
  :group 'eshell-module))

;;; User Variables:

(defcustom eshell-rebind-load-hook nil
  "A list of functions to call when loading `eshell-rebind'."
  :version "24.1"			; removed eshell-rebind-initialize
  :type 'hook
  :group 'eshell-rebind)

(defcustom eshell-rebind-keys-alist
  '(([(control ?d)] . eshell-delchar-or-maybe-eof)
    ([backspace]    . eshell-delete-backward-char)
    ([delete]       . eshell-delete-backward-char)
    ([(control ?w)] . backward-kill-word)
    ([(control ?u)] . eshell-kill-input))
  "Bind some keys differently if point is in input text."
  :type '(repeat (cons (vector :tag "Keys to bind"
			       (repeat :inline t sexp))
		       (function :tag "Command")))
  :group 'eshell-rebind)

(defcustom eshell-confine-point-to-input t
  "If non-nil, do not allow the point to leave the current input.
This is more difficult to do nicely in Emacs than one might think.
Basically, the `point-left' attribute is added to the input text, and
a function is placed on that hook to take the point back to
`eshell-last-output-end' every time the user tries to move away.  But
since there are many cases in which the point _ought_ to move away
\(for programmatic reasons), the variable
`eshell-cannot-leave-input-list' defines commands which are affected
from this rule.  However, this list is by no means as complete as it
probably should be, so basically all one can hope for is that other
people will left the point alone in the Eshell buffer.  Sigh."
  :type 'boolean
  :group 'eshell-rebind)

(defcustom eshell-error-if-move-away t
  "If non-nil, consider it an error to try to move outside current input.
This is default behavior of shells like bash."
  :type 'boolean
  :group 'eshell-rebind)

(defcustom eshell-remap-previous-input t
  "If non-nil, remap input keybindings on previous prompts as well."
  :type 'boolean
  :group 'eshell-rebind)

(defcustom eshell-cannot-leave-input-list
  '(beginning-of-line-text
    beginning-of-line
    move-to-column
    move-to-left-margin
    move-to-tab-stop
    forward-char
    backward-char
    delete-char
    delete-backward-char
    backward-delete-char
    backward-delete-char-untabify
    kill-paragraph
    backward-kill-paragraph
    kill-sentence
    backward-kill-sentence
    kill-sexp
    backward-kill-sexp
    kill-word
    backward-kill-word
    kill-region
    forward-list
    backward-list
    forward-page
    backward-page
    forward-paragraph
    backward-paragraph
    backward-prefix-chars
    forward-sentence
    backward-sentence
    forward-sexp
    backward-sexp
    forward-to-indentation
    backward-to-indentation
    backward-up-list
    forward-word
    backward-word
    forward-line
    previous-line
    next-line
    forward-visible-line
    forward-comment
    forward-thing)
  "A list of commands that cannot leave the input area."
  :type '(repeat function)
  :group 'eshell-rebind)

(defvar-keymap eshell-rebind-mode-map
  "C-c M-l" #'eshell-lock-local-map)

;; Internal Variables:

(defvar eshell-input-keymap)
(defvar eshell-previous-point)
(defvar eshell-lock-keymap)

;;; Functions:

(define-minor-mode eshell-rebind-mode
  "Minor mode for the eshell-rebind module.

\\{eshell-rebind-mode-map}"
  :keymap eshell-rebind-mode-map)

(defun eshell-rebind-initialize ()  ;Called from `eshell-mode' via intern-soft!
  "Initialize the inputting code."
  (unless eshell-non-interactive-p
    (add-hook 'eshell-mode-hook 'eshell-setup-input-keymap nil t)
    (make-local-variable 'eshell-previous-point)
    (add-hook 'pre-command-hook 'eshell-save-previous-point nil t)
    (make-local-variable 'overriding-local-map)
    (add-hook 'post-command-hook 'eshell-rebind-input-map nil t)
    (setq-local eshell-lock-keymap nil)
    (eshell-rebind-mode)))

(defun eshell-lock-local-map (&optional arg)
  "Lock or unlock the current local keymap.
With prefix ARG, set the local keymap to its normal value, and
lock it at that."
  (interactive "P")
  (if (or arg (not eshell-lock-keymap))
      (progn
	(use-local-map eshell-mode-map)
	(setq eshell-lock-keymap t)
	(message "Local keymap locked in normal mode"))
    (use-local-map eshell-input-keymap)
    (setq eshell-lock-keymap nil)
    (message "Local keymap unlocked: obey context")))

(defun eshell-save-previous-point ()
  "Save the location of point before the next command is run."
  (setq eshell-previous-point (point)))

(defsubst eshell-point-within-input-p (pos)
  "Test whether POS is within an input range."
  (let (begin)
    (or (and (>= pos eshell-last-output-end)
	     eshell-last-output-end)
	(and eshell-remap-previous-input
	     (setq begin
		   (save-excursion
		     (beginning-of-line)
		     (and (not (bolp)) (point))))
	     (>= pos begin)
	     (<= pos (line-end-position))
	     begin))))

(defun eshell-rebind-input-map ()
  "Rebind the input keymap based on the location of the cursor."
  (ignore-errors
    (unless eshell-lock-keymap
      (if (eshell-point-within-input-p (point))
	  (use-local-map eshell-input-keymap)
	(let (begin)
	  (if (and eshell-confine-point-to-input
		   (setq begin
			 (eshell-point-within-input-p eshell-previous-point))
		   (memq this-command eshell-cannot-leave-input-list))
	      (progn
		(use-local-map eshell-input-keymap)
		(goto-char begin)
		(if (and eshell-error-if-move-away
			 (not (eq this-command 'kill-region)))
		    (beep)))
	    (use-local-map eshell-mode-map)))))))

(defun eshell-setup-input-keymap ()
  "Setup the input keymap to be used during input editing."
  (setq-local eshell-input-keymap (make-sparse-keymap))
  (set-keymap-parent eshell-input-keymap eshell-mode-map)
  (let ((bindings eshell-rebind-keys-alist))
    (while bindings
      (define-key eshell-input-keymap (caar bindings)
	(cdar bindings))
      (setq bindings (cdr bindings)))))

(defun eshell-delete-backward-char (n)
  "Delete the last character, unless it's part of the output."
  (interactive "P")
  (let ((count (prefix-numeric-value n)))
    (if (eshell-point-within-input-p (- (point) count))
	(delete-char (- count) n)
      (beep))))

(defun eshell-delchar-or-maybe-eof (arg)
  "Delete ARG characters forward or send an EOF to subprocess.
Sends an EOF only if point is at the end of the buffer and there is no
input."
  (interactive "p")
  (let ((proc (eshell-head-process)))
    (if (eobp)
	(cond
	 ((/= (point) eshell-last-output-end)
	  (beep))
	 (proc
	  (process-send-eof))
	 (t
	  (eshell-life-is-too-much)))
      (eshell-delete-backward-char (- arg)))))

(provide 'em-rebind)
;;; em-rebind.el ends here
