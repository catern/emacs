;;; hl-line.el --- highlight the current line  -*- lexical-binding:t -*-

;; Copyright (C) 1998, 2000-2025 Free Software Foundation, Inc.

;; Author: Dave Love <fx@gnu.org>
;; Maintainer: emacs-devel@gnu.org
;; Created: 1998-09-13
;; Keywords: faces, frames, emulations

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

;; Provides a local minor mode (toggled by M-x hl-line-mode) and
;; a global minor mode (toggled by M-x global-hl-line-mode) to
;; highlight, on a suitable terminal, the line on which point is.  The
;; global mode highlights the current line in the selected window only
;; (except when the minibuffer window is selected).  This was
;; implemented to satisfy a request for a feature of Lesser Editors.
;; The local mode is sticky: it highlights the line about the buffer's
;; point even if the buffer's window is not selected.  Caveat: the
;; buffer's point might be different from the point of a non-selected
;; window.  Set the variable `hl-line-sticky-flag' to nil to make the
;; local mode behave like the global mode.

;; You probably don't really want to use the global mode; if the
;; cursor is difficult to spot, try changing its color, relying on
;; `blink-cursor-mode' or both.  The hookery used might affect
;; response noticeably on a slow machine.  The local mode may be
;; useful in non-editing buffers such as Gnus or PCL-CVS though.

;; An overlay is used.  In the non-sticky cases, this overlay is
;; active only on the selected window.  A hook is added to
;; `post-command-hook' to activate the overlay and move it to the line
;; about point.

;; You could make variable `global-hl-line-mode' buffer-local and set
;; it to nil to avoid highlighting specific buffers, when the global
;; mode is used.

;; By default the whole line is highlighted.  The range of highlighting
;; can be changed by defining an appropriate function as the
;; buffer-local value of `hl-line-range-function'.

;;; Code:

(defvar-local hl-line-overlay nil
  "Overlay used by Hl-Line mode to highlight the current line.")

(defvar-local global-hl-line-overlay nil
  "Overlay used by Global-Hl-Line mode to highlight the current line.")

(defvar global-hl-line-overlays nil
  "Overlays used by Global-Hl-Line mode in various buffers.
Global-Hl-Line keeps displaying one overlay in each buffer
when `global-hl-line-sticky-flag' is non-nil.")

(defgroup hl-line nil
  "Highlight the current line."
  :version "21.1"
  :group 'convenience)

(defface hl-line
  '((t :inherit highlight :extend t))
  "Default face for highlighting the current line in Hl-Line mode."
  :version "22.1"
  :group 'hl-line)

(defcustom hl-line-face 'hl-line
  "Face with which to highlight the current line in Hl-Line mode."
  :type 'face
  :group 'hl-line
  :set (lambda (symbol value)
	 (set symbol value)
	 (dolist (buffer (buffer-list))
	   (with-current-buffer buffer
	     (when (overlayp hl-line-overlay)
	       (overlay-put hl-line-overlay 'face hl-line-face))))
	 (when (overlayp global-hl-line-overlay)
	   (overlay-put global-hl-line-overlay 'face hl-line-face))))

(defcustom hl-line-sticky-flag t
  "Non-nil means the HL-Line mode highlight appears in all windows.
Otherwise Hl-Line mode will highlight only in the selected
window.  Setting this variable takes effect the next time you use
the command `hl-line-mode' to turn Hl-Line mode on.

This variable has no effect in Global Highlight Line mode.
For that, use `global-hl-line-sticky-flag'."
  :type 'boolean
  :version "22.1"
  :group 'hl-line
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (featurep 'hl-line)
           (unless value
             (let ((selected (window-buffer (selected-window))))
               (dolist (buffer (buffer-list))
                 (unless (eq buffer selected)
                   (with-current-buffer buffer
                     (hl-line-unhighlight)))))))))

(defcustom global-hl-line-sticky-flag nil
  "Non-nil means the Global HL-Line mode highlight appears in all windows.
Otherwise Global Hl-Line mode will highlight only in the selected
window.  Setting this variable takes effect the next time you use
the command `global-hl-line-mode' to turn Global Hl-Line mode on."
  :type 'boolean
  :version "24.1"
  :group 'hl-line)

(defcustom global-hl-line-modes t
  "Which major modes `hl-line-mode' is switched on in.
This variable can be either t (all major modes), nil (no major modes),
or a list of modes and (not modes) to switch use this minor mode or
not.  For instance

  (c-mode (not message-mode mail-mode) text-mode)

means \"use this mode in all modes derived from `c-mode', don't use in
modes derived from `message-mode' or `mail-mode', but do use in other
modes derived from `text-mode'\".  An element with value t means \"use\"
and nil means \"don't use\".  There's an implicit nil at the end of the
list."
  :type
  '(choice (const :tag "Enable in all major modes" t)
           (repeat :tag "Rules (earlier takes precedence)..."
                   (choice
                    (const :tag "Enable in all (other) modes" t)
                    (symbol :value fundamental-mode :tag
                            "Enable in major mode")
                    (cons :tag "Don't enable in major modes"
                          (const :tag "Don't enable in..." not)
                          (repeat
                           (symbol :value fundamental-mode :tag
                                   "Major mode"))))))
  :version "31.1")

(defvar hl-line-range-function nil
  "If non-nil, function to call to return highlight range.
The function of no args should return a cons cell; its car value
is the beginning position of highlight and its cdr value is the
end position of highlight in the buffer.
It should return nil if there's no region to be highlighted.

This variable is expected to be made buffer-local by modes.")

(defvar hl-line-overlay-buffer nil
  "Most recently visited buffer in which Hl-Line mode is enabled.")

(defcustom hl-line-overlay-priority -50
  "Priority used on the overlay used by hl-line."
  :type 'integer
  :version "28.1"
  :group 'hl-line)

;;;###autoload
(define-minor-mode hl-line-mode
  "Toggle highlighting of the current line (Hl-Line mode).

Hl-Line mode is a buffer-local minor mode.  If
`hl-line-sticky-flag' is non-nil, Hl-Line mode highlights the
line about the buffer's point in all windows.  Caveat: the
buffer's point might be different from the point of a
non-selected window.  Hl-Line mode uses the function
`hl-line-highlight' on `post-command-hook' in this case.

When `hl-line-sticky-flag' is nil, Hl-Line mode highlights the
line about point in the selected window only."
  :group 'hl-line
  ;; If the global mode is switched on, then `M-x hl-line-mode' should
  ;; switch the mode off in this buffer.
  (when (and global-hl-line-mode
             (eq arg 'toggle))
    (setq hl-line-mode nil)
    (setq-local global-hl-line-mode nil)
    (global-hl-line-unhighlight))
  (if hl-line-mode
      (progn
        ;; In case `kill-all-local-variables' is called.
        (add-hook 'change-major-mode-hook #'hl-line-unhighlight nil t)
        (hl-line-highlight)
        (setq hl-line-overlay-buffer (current-buffer))
	(add-hook 'post-command-hook #'hl-line-highlight nil t))
    (remove-hook 'post-command-hook #'hl-line-highlight t)
    (hl-line-unhighlight)
    (remove-hook 'change-major-mode-hook #'hl-line-unhighlight t)))

(defun hl-line-make-overlay ()
  (let ((ol (make-overlay (point) (point))))
    (overlay-put ol 'priority hl-line-overlay-priority) ;(bug#16192)
    (overlay-put ol 'face hl-line-face)
    ol))

(defun hl-line-highlight ()
  "Activate the Hl-Line overlay on the current line."
  (if hl-line-mode	; Might be changed outside the mode function.
      (progn
        (unless (overlayp hl-line-overlay)
          (setq hl-line-overlay (hl-line-make-overlay))) ; To be moved.
        (overlay-put hl-line-overlay
                     'window (unless hl-line-sticky-flag (selected-window)))
	(hl-line-move hl-line-overlay)
        (hl-line-maybe-unhighlight))
    (hl-line-unhighlight)))

(defun hl-line-unhighlight ()
  "Deactivate the Hl-Line overlay on the current line."
  (when (overlayp hl-line-overlay)
    (delete-overlay hl-line-overlay)
    (setq hl-line-overlay nil)))

(defun hl-line-maybe-unhighlight ()
  "Maybe deactivate the Hl-Line overlay on the current line.
Specifically, when `hl-line-sticky-flag' is nil deactivate all
such overlays in all buffers except the current one."
  (let ((hlob hl-line-overlay-buffer)
        (curbuf (current-buffer)))
    (when (and (buffer-live-p hlob)
               (not hl-line-sticky-flag)
               (not (eq curbuf hlob))
               (not (minibufferp)))
      (with-current-buffer hlob
        (hl-line-unhighlight)))
    (when (and (overlayp hl-line-overlay)
               (eq (overlay-buffer hl-line-overlay) curbuf))
      (setq hl-line-overlay-buffer curbuf))))

;;;###autoload
(define-minor-mode global-hl-line-mode
  "Toggle line highlighting in all buffers (Global Hl-Line mode).

If `global-hl-line-sticky-flag' is non-nil, Global Hl-Line mode
highlights the line about the current buffer's point in all live
windows.

Global-Hl-Line mode uses the function `global-hl-line-highlight'
on `post-command-hook'."
  :global t
  :group 'hl-line
  (if global-hl-line-mode
      (progn
        ;; In case `kill-all-local-variables' is called.
        (add-hook 'change-major-mode-hook #'global-hl-line-unhighlight)
        (global-hl-line-highlight-all)
	(add-hook 'post-command-hook #'global-hl-line-highlight))
    (global-hl-line-unhighlight-all)
    (remove-hook 'post-command-hook #'global-hl-line-highlight)
    (remove-hook 'change-major-mode-hook #'global-hl-line-unhighlight)))

(defun global-hl-line-highlight ()
  "Highlight the current line in the current window."
  (require 'easy-mmode)
  (when (and global-hl-line-mode ; Might be changed outside the mode function.
             (easy-mmode--globalized-predicate-p global-hl-line-modes))
    (unless (window-minibuffer-p)
      (unless (overlayp global-hl-line-overlay)
        (setq global-hl-line-overlay (hl-line-make-overlay))) ; To be moved.
      (unless (member global-hl-line-overlay global-hl-line-overlays)
	(push global-hl-line-overlay global-hl-line-overlays))
      (overlay-put global-hl-line-overlay 'window
		   (unless global-hl-line-sticky-flag
		     (selected-window)))
      (hl-line-move global-hl-line-overlay)
      (global-hl-line-maybe-unhighlight))))

(defun global-hl-line-highlight-all ()
  "Highlight the current line in all live windows."
  (walk-windows (lambda (w)
                  (with-current-buffer (window-buffer w)
                    (global-hl-line-highlight)))
                nil t))

(defun global-hl-line-unhighlight ()
  "Deactivate the Global-Hl-Line overlay on the current line."
  (when (overlayp global-hl-line-overlay)
    (delete-overlay global-hl-line-overlay)
    (setq global-hl-line-overlay nil)))

(defun global-hl-line-maybe-unhighlight ()
  "Maybe deactivate the Global-Hl-Line overlay on the current line.
Specifically, when `global-hl-line-sticky-flag' is nil deactivate
all such overlays in all buffers except the current one."
  (mapc (lambda (ov)
	  (let ((ovb (overlay-buffer ov)))
            (when (and (not global-hl-line-sticky-flag)
                       (bufferp ovb)
                       (not (eq ovb (current-buffer)))
                       (not (minibufferp)))
	      (with-current-buffer ovb
                (global-hl-line-unhighlight)))))
        global-hl-line-overlays))

(defun global-hl-line-unhighlight-all ()
  "Deactivate all Global-Hl-Line overlays."
  (mapc (lambda (ov)
	  (let ((ovb (overlay-buffer ov)))
	    (when (bufferp ovb)
		(with-current-buffer ovb
		  (global-hl-line-unhighlight)))))
	global-hl-line-overlays)
  (setq global-hl-line-overlays nil))

(defun hl-line-move (overlay)
  "Move the Hl-Line overlay.
If `hl-line-range-function' is non-nil, move the OVERLAY to the position
where the function returns.  If `hl-line-range-function' is nil, fill
the line including the point by OVERLAY."
  (let (tmp b e)
    (if hl-line-range-function
	(setq tmp (funcall hl-line-range-function)
	      b   (car tmp)
	      e   (cdr tmp))
      (setq tmp t
	    b (line-beginning-position)
	    e (line-beginning-position 2)))
    (if tmp
	(move-overlay overlay b e)
      (move-overlay overlay 1 1))))

(defun hl-line-unload-function ()
  "Unload the Hl-Line library."
  (global-hl-line-mode -1)
  (save-current-buffer
    (dolist (buffer (buffer-list))
      (set-buffer buffer)
      (when hl-line-mode (hl-line-mode -1))))
  ;; continue standard unloading
  nil)

(provide 'hl-line)

;;; hl-line.el ends here
