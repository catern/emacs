;;; mh-e.el --- GNU Emacs interface to the MH mail system  -*- lexical-binding: t; -*-

;; Copyright (C) 1985-1988, 1990, 1992-1995, 1997, 1999-2025 Free
;; Software Foundation, Inc.

;; Author: Bill Wohler <wohler@newt.com>
;; Version: 8.6+git
;; Keywords: mail

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

;; MH-E is an Emacs interface to the MH mail system.

;; To learn about MH-E, read The MH-E Manual at info node '(mh-e)'.

;; MH-E is compatible with MH versions 6.8.4 and higher, all versions
;; of nmh, and GNU mailutils 1.0 and higher.

;; MH (Message Handler) is a powerful mail reader. See
;; https://rand-mh.sourceforge.io/.

;; N.B. MH must have been compiled with the MHE compiler flag or several
;; features necessary for MH-E will be missing from MH commands, specifically
;; the -build switch to repl and forw.

;; How to use:
;;   M-x mh-rmail to read mail.  Type C-h m there for a list of commands.
;;   C-u M-x mh-rmail to visit any folder.
;;   M-x mh-smail to send mail.  From within the mail reader, "s" works, too.

;; Your .emacs might benefit from these bindings:
;;   (keymap-global-set "C-c r" #'mh-rmail)
;;   (keymap-global-set "C-x m" #'mh-smail)
;;   (keymap-global-set "C-x 4 m" #'mh-smail-other-window)

;; Mailing Lists:
;;   mh-e-users@lists.sourceforge.net
;;   mh-e-announce@lists.sourceforge.net
;;   mh-e-devel@lists.sourceforge.net

;;   Subscribe by sending a "subscribe" message to
;;   <list>-request@lists.sourceforge.net, or by using the web interface at
;;   https://sourceforge.net/mail/?group_id=13357

;; Bug Reports:
;;   https://sourceforge.net/tracker/?group_id=13357&atid=113357
;;   Include the output of M-x mh-version in the bug report unless
;;   you're 110% sure we won't ask for it.

;; Feature Requests:
;;   https://sourceforge.net/tracker/?group_id=13357&atid=363357

;; Support:
;;   https://sourceforge.net/tracker/?group_id=13357&atid=213357

;;; Change Log:

;; Original version for Gosling emacs by Brian Reid, Stanford, 1982.
;; Modified by James Larus, BBN, July 1984 and UCB, 1984 & 1985.
;; Rewritten for GNU Emacs, James Larus, 1985.
;; Modified by Stephen Gildea, 1988.
;; Maintenance picked up by Bill Wohler and the
;;   SourceForge Crew <https://mh-e.sourceforge.io/>, 2001.
;; Since 2016, MH-E development occurs within the Emacs repository.

;;; Code:

;; Provide functions to the rest of MH-E. However, mh-e.el must not
;; use any definitions in files that require mh-e from mh-loaddefs,
;; for if it does it will introduce a require loop.
(require 'mh-loaddefs)

(require 'cl-lib)

(require 'mh-buffers)



;;; Global Variables

;; Try to keep variables local to a single file. Provide accessors if
;; variables are shared. Use this section as a last resort.

(defconst mh-version "8.6+git" "Version number of MH-E.")

;; Variants

(defvar mh-sys-path
  '("/usr/local/nmh/bin"                ; nmh default
    "/usr/local/bin/mh/"
    "/usr/local/mh/"
    "/usr/bin/mh/"                      ; Ultrix 4.2, Linux
    "/usr/new/mh/"                      ; Ultrix < 4.2
    "/usr/contrib/mh/bin/"              ; BSDI
    "/usr/pkg/bin/"                     ; NetBSD
    "/usr/local/bin/"
    "/usr/local/bin/mu-mh/"             ; GNU mailutils MH - default
    "/usr/bin/mu-mh/")                  ; GNU mailutils MH - packaged
  "List of directories to search for variants of the MH variant.
The list `exec-path' is searched in addition to this list.
There's no need for users to modify this list. Instead add extra
directories to the customizable variable `mh-path'.")

(defvar mh-variants nil
  "List describing known MH variants.
Do not access this variable directly as it may not have yet been initialized.
Use the function `mh-variants' instead.")

(defvar mh-variant-in-use nil
  "The MH variant currently in use; a string with variant and version number.
This differs from `mh-variant' when the latter is set to
\"autodetect\".")

(defvar mh-progs nil
  "Directory containing MH commands, such as inc, repl, and rmm.")

;;;###autoload
(put 'mh-progs 'risky-local-variable t)

(defvar mh-lib nil
  "Directory containing the MH library.
This directory contains, among other things, the components file.")

;;;###autoload
(put 'mh-lib 'risky-local-variable t)

(defvar mh-lib-progs nil
  "Directory containing MH helper programs.
This directory contains, among other things, the mhl program.")

;;;###autoload
(put 'mh-lib-progs 'risky-local-variable t)

(defvar mh-default-directory "~/"
  "Default directory for MH-E folder buffers.
Set to nil to have MH-E buffers inherit default-directory.")

;; Profile Components

(defvar mh-draft-folder nil
  "Cached value of the \"Draft-Folder:\" MH profile component.
Name of folder containing draft messages.
Do not use a draft folder if nil.")

(defvar mh-inbox nil
  "Cached value of the \"Inbox:\" MH profile component.
Set to \"+inbox\" if no such component.
Name of the Inbox folder.")

(defvar mh-user-path nil
  "Cached value of the \"Path:\" MH profile component.
User's mail folder directory.")

;; Maps declared here so that they can be used in docstrings.

(defvar-keymap mh-folder-mode-map
  :doc "Keymap for MH-Folder mode."
  :full t)

(defvar mh-folder-seq-tool-bar-map nil
  "Keymap for MH-Folder tool bar.")

(defvar mh-folder-tool-bar-map nil
  "Keymap for MH-Folder tool bar.")

(defvar-keymap mh-inc-spool-map
  :doc "Keymap for MH-E's mh-inc-spool commands.")

(defvar mh-letter-mode-map (copy-keymap text-mode-map)
  "Keymap for MH-Letter mode.")

(defvar mh-letter-tool-bar-map nil
  "Keymap for MH-Letter tool bar.")

(defvar-keymap mh-search-mode-map
  :doc "Keymap for MH-Search mode.")

(defvar-keymap mh-show-mode-map
  :doc "Keymap for MH-Show mode.")

(defvar mh-show-seq-tool-bar-map nil
  "Keymap for MH-Show tool bar.")

(defvar mh-show-tool-bar-map nil
  "Keymap for MH-Show tool bar.")

;; MH-Folder Locals (alphabetical)

(defvar mh-arrow-marker nil
  "Marker for arrow display in fringe.")

(defvar mh-blocklist nil
  "List of messages to use to train the junk filter.
This variable can be used by
`mh-before-commands-processed-hook'.")

(defvar mh-colors-available-flag nil
  "Non-nil means colors are available.")

(defvar mh-current-folder nil
  "Name of current folder, a string.")

(defvar mh-delete-list nil
  "List of message numbers to delete.
This variable can be used by
`mh-before-commands-processed-hook'.")

(defvar mh-folder-view-stack nil
  "Stack of previous folder views.")

(defvar mh-index-data nil
  "Info about index search results.")

(defvar mh-index-previous-search nil)

(defvar mh-index-msg-checksum-map nil)

(defvar mh-index-checksum-origin-map nil)

(defvar mh-index-sequence-search-flag nil)

(defvar mh-mode-line-annotation nil
  "Message range displayed in buffer.")

(defvar mh-next-direction 'forward
  "Direction to move to next message.")

(defvar mh-previous-window-config nil
  "Window configuration before MH-E command.")

(defvar mh-refile-list nil
  "List of folder names in `mh-seq-list'.
This variable can be used by
`mh-before-commands-processed-hook'.")

(defvar mh-seen-list nil
  "List of displayed messages to be removed from the \"Unseen\" sequence.")

(defvar mh-seq-list nil
  "Alist of this folder's sequences.
Elements have the form (SEQUENCE . MESSAGES).")

(defvar mh-sequence-notation-history nil
  "Remember original notation that is overwritten by `mh-note-seq'.")

(defvar mh-show-buffer nil
  "Buffer that displays message for this folder.")

(define-minor-mode mh-showing-mode
  "Minor mode to show the message in a separate window."
  ;; FIXME: maybe this should be moved to mh-show.el.
  :lighter " Show")

(defvar mh-view-ops nil
  "Stack of operations that change the folder view.
These operations include narrowing or threading.")

(defvar mh-allowlist nil
  "List of messages to use to train the junk filter.
This variable can be used by
`mh-before-commands-processed-hook'.")

;; MH-Show Locals (alphabetical)

(defvar mh-globals-hash (make-hash-table)
  "Keeps track of MIME data on a per buffer basis.")

(defvar mh-show-folder-buffer nil
  "Keeps track of folder whose message is being displayed.")

;; MH-Letter Locals

(defvar mh-folders-changed nil
  "Lists which folders were affected by deletes and refiles.
This list will always include the current folder
`mh-current-folder'. This variable can be used by
`mh-after-commands-processed-hook'.")

(defcustom mh-mail-header-separator "--------"
  "Line used by MH to separate headers from text in messages being composed.

This variable should not be used directly in programs. Programs
should use `mail-header-separator' instead.
`mail-header-separator' is initialized to
`mh-mail-header-separator' in `mh-letter-mode'; in other
contexts, you may have to perform this initialization yourself.

Do not make this a regular expression as it may be the argument
to `insert' and it is passed through `regexp-quote' before being
used by functions like `re-search-forward'."
  :group 'mh-e                          ; FIXME?
  :type 'string)

(defvar mh-sent-from-folder nil
  "Folder of msg assoc with this letter.")

(defvar mh-sent-from-msg nil
  "Number of msg assoc with this letter.")

;; Sequences

(defvar mh-unseen-seq nil
  "Cached value of the \"Unseen-Sequence:\" MH profile component.
Name of the Unseen sequence.")

(defvar mh-previous-seq nil
  "Cached value of the \"Previous-Sequence:\" MH profile component.
Name of the Previous sequence.")

;; Etc. (alphabetical)

(defvar mh-flists-present-flag nil
  "Non-nil means that we have \"flists\".")

(defvar mh-index-data-file ".mhe_index"
  "MH-E specific file where index search info is stored.")

(defvar mh-letter-header-field-regexp "^\\([A-Za-z][A-Za-z0-9-]*\\):")

(defvar mh-page-to-next-msg-flag nil
  "Non-nil means next SPC or whatever goes to next undeleted message.")

(defvar mh-pgp-support-flag (not (not (locate-library "mml2015")))
  "Non-nil means PGP support is available.")

(defvar mh-signature-separator "-- \n"
  "Text of a signature separator.

A signature separator is used to separate the body of a message
from the signature. This can be used by user agents such as MH-E
to render the signature differently or to suppress the inclusion
of the signature in a reply. Use `mh-signature-separator-regexp'
when searching for a separator.")

(defvar mh-signature-separator-regexp "^-- $"
  "This regular expression matches the signature separator.
See `mh-signature-separator'.")

(defvar-local mh-thread-scan-line-map nil
  "Map of message index to various parts of the scan line.")

(defvar-local mh-thread-scan-line-map-stack nil
  "Old map of message index to various parts of the scan line.
This is the original map that is stored when the folder is
narrowed.")

(defcustom mh-x-mailer-string nil
  "String containing the contents of the X-Mailer header field.
If nil, this variable is initialized to show the version of MH-E,
Emacs, and MH the first time a message is composed."
  :group 'mh-e                          ; FIXME?
  :type '(choice (const :tag "Default" nil) string))


;;; MH-E Entry Points

(eval-when-compile (require 'gnus))

(defmacro mh-macro-expansion-time-gnus-version ()
  "Return Gnus version available at macro expansion time.
The macro evaluates the Gnus version at macro expansion time. If
MH-E was compiled then macro expansion happens at compile time."
gnus-version)

(defun mh-run-time-gnus-version ()
  "Return Gnus version available at run time."
  (require 'gnus)
  gnus-version)

(defvar mh-variant)

;;;###autoload
(defun mh-version ()
  "Display version information about MH-E and the MH mail handling system."
  (interactive)
  (set-buffer (get-buffer-create mh-info-buffer))
  (erase-buffer)
  ;; MH-E version.
  (insert "MH-E " mh-version "\n\n")
  ;; MH-E compilation details.
  (insert "MH-E compilation details:\n")
  (let* ((compiled-mhe (compiled-function-p (symbol-function 'mh-version)))
         (gnus-compiled-version (if compiled-mhe
                                    (mh-macro-expansion-time-gnus-version)
                                  "N/A")))
    (insert " Compiled:\t\t" (if compiled-mhe "yes" "no") "\n"
            " Gnus (compile-time):\t" gnus-compiled-version "\n"
            " Gnus (run-time):\t" (mh-run-time-gnus-version) "\n\n"))
  ;; Emacs version.
  (insert (emacs-version) "\n\n")
  ;; MH version.
  (or mh-variant-in-use (mh-variant-set mh-variant))
  (if mh-variant-in-use
      (insert mh-variant-in-use "\n"
              " mh-progs:\t" mh-progs "\n"
              " mh-lib:\t" mh-lib "\n"
              " mh-lib-progs:\t" mh-lib-progs "\n\n")
    (insert "No MH variant detected\n"))
  ;; Linux version.
  (condition-case ()
      (call-process "uname" nil t nil "-a")
    (file-error))
  (goto-char (point-min))
  (display-buffer mh-info-buffer))



;;; Support Routines

(defun mh-list-to-string (l)
  "Flatten the list L and make every element of the new list into a string."
  (nreverse (mh-list-to-string-1 l)))

(defun mh-list-to-string-1 (l)
  "Flatten the list L and make every element of the new list into a string."
  (let (new-list)
    (dolist (element l)
      (cond ((null element))
            ((symbolp element)
             (push (symbol-name element) new-list))
            ((numberp element)
             (push (int-to-string element) new-list))
            ((equal element ""))
            ((stringp element)
             (push element new-list))
            ((listp element)
             (setq new-list (nconc (mh-list-to-string-1 element) new-list)))
            (t
             (error "Bad element: %s" element))))
    new-list))

(defun mh-set-default-directory ()
  "Set `default-directory' to `mh-default-directory' unless it is nil."
  (when (stringp mh-default-directory)
    (setq default-directory (file-name-as-directory
                             (expand-file-name mh-default-directory)))))



;;; MH-E Process Support

(defvar mh-index-max-cmdline-args 500
  "Maximum number of command line args.")

(defun mh-xargs (cmd &rest args)
  "Partial imitation of xargs.
The current buffer contains a list of strings, one on each line.
The function will execute CMD with ARGS and pass the first
`mh-index-max-cmdline-args' strings to it. This is repeated till
all the strings have been used."
  (goto-char (point-min))
  (let ((current-buffer (current-buffer)))
    (with-temp-buffer
      (let ((out (current-buffer)))
        (set-buffer current-buffer)
        (while (not (eobp))
          (let ((arg-list (reverse args))
                (count 0))
            (while (and (not (eobp)) (< count mh-index-max-cmdline-args))
              (push (buffer-substring-no-properties (point)
                                                    (line-end-position))
                    arg-list)
              (incf count)
              (forward-line))
            (apply #'call-process cmd nil (list out nil) nil
                   (nreverse arg-list))))
        (erase-buffer)
        (insert-buffer-substring out)))))

;; XXX This should be applied anywhere MH-E calls out to /bin/sh.
(defun mh-quote-for-shell (string)
  "Quote STRING for /bin/sh.
Adds double-quotes around entire string and quotes the characters
\\, `, and $ with a backslash."
  (concat "\""
          (cl-loop for x across string
                   concat (format (if (memq x '(?\\ ?` ?$)) "\\%c" "%c") x))
          "\""))

(defun mh-exec-cmd (command &rest args)
  "Execute mh-command COMMAND with ARGS.
The side effects are what is desired. Any output is assumed to be
an error and is shown to the user. The output is not read or
parsed by MH-E."
  (with-current-buffer (get-buffer-create mh-log-buffer)
    (let* ((initial-size (mh-truncate-log-buffer))
           (start (point))
           (args (mh-list-to-string args)))
      (apply #'call-process (expand-file-name command mh-progs) nil t nil args)
      (when (> (buffer-size) initial-size)
        (save-excursion
          (goto-char start)
          (insert "Errors when executing: " command)
          (cl-loop for arg in args do (insert " " arg))
          (insert "\n"))
        (save-window-excursion
          (switch-to-buffer-other-window mh-log-buffer)
          (sit-for 5))))))

(defun mh-exec-cmd-error (env command &rest args)
  "In environment ENV, execute mh-command COMMAND with ARGS.
ENV is nil or a string of space-separated \"var=value\" elements.
Signals an error if process does not complete successfully."
  (with-current-buffer (get-buffer-create mh-temp-buffer)
    (erase-buffer)
    (let ((process-environment process-environment))
      ;; XXX: We should purge the list that split-string returns of empty
      ;;  strings. This can happen in XEmacs if leading or trailing spaces
      ;;  are present.
      (dolist (elem (if (stringp env) (split-string env " ") ()))
        (push elem process-environment))
      (mh-handle-process-error
       command (apply #'call-process (expand-file-name command mh-progs)
                      nil t nil (mh-list-to-string args))))))

(defun mh-exec-cmd-daemon (command filter &rest args)
  "Execute MH command COMMAND in the background.

If FILTER is non-nil then it is used to process the output
otherwise the default filter `mh-process-daemon' is used. See
`set-process-filter' for more details of FILTER.

ARGS are passed to COMMAND as command line arguments."
  (with-current-buffer (get-buffer-create mh-log-buffer)
    (mh-truncate-log-buffer))
  (let* ((process-connection-type nil)
         (process (apply #'start-process
                         command nil
                         (expand-file-name command mh-progs)
                         (mh-list-to-string args))))
    (set-process-filter process (or filter 'mh-process-daemon))
    process))

(defun mh-exec-cmd-env-daemon (env command filter &rest args)
  "In environment ENV, execute mh-command COMMAND in the background.

ENV is nil or a string of space-separated \"var=value\" elements.
Signals an error if process does not complete successfully.

If FILTER is non-nil then it is used to process the output
otherwise the default filter `mh-process-daemon' is used. See
`set-process-filter' for more details of FILTER.

ARGS are passed to COMMAND as command line arguments."
  (let ((process-environment process-environment))
    (dolist (elem (if (stringp env) (split-string env " ") ()))
      (push elem process-environment))
    (apply #'mh-exec-cmd-daemon command filter args)))

(defun mh-process-daemon (_process output)
  "PROCESS daemon that puts OUTPUT into a temporary buffer.
Any output from the process is displayed in an asynchronous
pop-up window."
  (with-current-buffer (get-buffer-create mh-log-buffer)
    (insert-before-markers output)
    (display-buffer mh-log-buffer)))

(defun mh-exec-cmd-quiet (raise-error command &rest args)
  "Signal RAISE-ERROR if COMMAND with ARGS fails.
Execute MH command COMMAND with ARGS. ARGS is a list of strings.
Return at start of mh-temp buffer, where output can be parsed and
used.
Returns value of `call-process', which is 0 for success, unless
RAISE-ERROR is non-nil, in which case an error is signaled if
`call-process' returns non-0."
  (set-buffer (get-buffer-create mh-temp-buffer))
  (erase-buffer)
  (let ((value
         (apply #'call-process
                (expand-file-name command mh-progs) nil t nil
                args)))
    (goto-char (point-min))
    (if raise-error
        (mh-handle-process-error command value)
      value)))

(defun mh-exec-cmd-output (command display &rest args)
  "Execute MH command COMMAND with DISPLAY flag and ARGS.
Put the output into buffer after point.
Set mark after inserted text.
Output is expected to be shown to user, not parsed by MH-E."
  (push-mark (point) t)
  (apply #'call-process
         (expand-file-name command mh-progs) nil t display
         (mh-list-to-string args))

  ;; The following is used instead of 'exchange-point-and-mark because the
  ;; latter activates the current region (between point and mark), which
  ;; turns on highlighting.  So prior to this bug fix, doing "inc" would
  ;; highlight a region containing the new messages, which is undesirable.
  ;; The bug wasn't seen in emacs21 but still occurred in XEmacs21.4.
  (mh-exchange-point-and-mark-preserving-active-mark))

(defun mh-exchange-point-and-mark-preserving-active-mark ()
  "Put the mark where point is now, and point where the mark is now.
This command works even when the mark is not active, and
preserves whether the mark is active or not."
  (interactive nil)
  (let ((is-active mark-active))
    (let ((omark (mark t)))
      (if (null omark)
          (error "No mark set in this buffer"))
      (set-mark (point))
      (goto-char omark)
      (setq mark-active is-active)
      nil)))

(defun mh-exec-lib-cmd-output (command &rest args)
  "Execute MH library command COMMAND with ARGS.
Put the output into buffer after point.
Set mark after inserted text."
  (apply #'mh-exec-cmd-output (expand-file-name command mh-lib-progs) nil args))

(defun mh-handle-process-error (command status)
  "Raise error if COMMAND returned non-zero STATUS, otherwise return STATUS."
  (if (equal status 0)
      status
    (goto-char (point-min))
    (insert (if (integerp status)
                (format "%s: exit code %d\n" command status)
              (format "%s: %s\n" command status)))
    (let ((error-message (buffer-substring (point-min) (point-max))))
      (with-current-buffer (get-buffer-create mh-log-buffer)
        (mh-truncate-log-buffer)
        (insert error-message)))
    (error "%s failed, check buffer %s for error message"
           command mh-log-buffer)))



;;; MH-E Customization Support Routines

;; Temporary function and data structure used customization.
;; These will be unbound after the options are defined.
(defmacro mh-strip-package-version (args)
  "ARGS is returned unchanged."
  (declare (obsolete identity "29.1"))
  args)

(defmacro defgroup-mh (symbol members doc &rest args)
  "Declare SYMBOL as a customization group containing MEMBERS.
See documentation for `defgroup' for a description of the arguments
SYMBOL, MEMBERS, DOC and ARGS."
  (declare (obsolete defgroup "29.1") (doc-string 3) (indent defun))
  `(defgroup ,symbol ,members ,doc ,args))

(defmacro defcustom-mh (symbol value doc &rest args)
  "Declare SYMBOL as a customizable variable that defaults to VALUE.
See documentation for `defcustom' for a description of the arguments
SYMBOL, VALUE, DOC and ARGS."
  (declare (obsolete defcustom "29.1") (doc-string 3) (indent defun))
  `(defcustom ,symbol ,value ,doc ,args))

(defmacro defface-mh (face spec doc &rest args)
  "Declare FACE as a customizable face that defaults to SPEC.
See documentation for `defface' for a description of the arguments
FACE, SPEC, DOC and ARGS."
  (declare (obsolete defface "29.1") (doc-string 3) (indent defun))
  `(defface ,face ,spec ,doc ,args))



;;; Variant Support

(defcustom mh-path nil
  "Additional list of directories to search for MH.
See `mh-variant'."
  :group 'mh-e
  :type '(repeat (directory))
  :package-version '(MH-E . "8.0"))

(defun mh-variants ()
  "Return a list of installed variants of MH on the system.
This function looks for MH in `mh-sys-path', `mh-path' and
`exec-path'. The format of the list of variants that is returned
is described by the variable `mh-variants'."
  (if mh-variants
      mh-variants
    (let ((list-unique))
      ;; Make a unique list of directories, keeping the given order.
      ;; We don't want the same MH variant to be listed multiple times.
      (cl-loop for dir in (append mh-path mh-sys-path exec-path) do
               ;; skip relative dirs, typically "."
               (if (file-name-absolute-p dir)
                   (progn
                     (setq dir (file-chase-links (directory-file-name dir)))
                     (cl-pushnew dir list-unique :test #'equal))))
      (cl-loop for dir in (nreverse list-unique) do
               (when (and dir (file-accessible-directory-p dir))
                 (let ((variant (mh-variant-info dir)))
                   (if variant
                       (add-to-list 'mh-variants variant)))))
      mh-variants)))

(defun mh-variant-info (dir)
  "Return MH variant found in DIR, or nil if none present."
  (let ((tmp-buffer (get-buffer-create mh-temp-buffer)))
    (with-current-buffer tmp-buffer
      (cond
       ((mh-variant-mh-info dir))
       ((mh-variant-nmh-info dir))
       ((mh-variant-gnu-mh-info dir))))))

(defun mh-variant-mh-info (dir)
  "Return info for MH variant in DIR assuming a temporary buffer is set up."
  ;; MH does not have the -version option.
  ;; Its version number is included in the output of "-help" as:
  ;;
  ;; version: MH 6.8.4 #2[UCI] (burrito) of Fri Jan 15 20:01:39 EST 1999
  ;; options: [ATHENA] [BIND] [DUMB] [LIBLOCKFILE] [LOCALE] [MAILGROUP] [MHE]
  ;;          [MHRC] [MIME] [MORE='"/usr/bin/sensible-pager"'] [NLINK_HACK]
  ;;          [NORUSERPASS] [OVERHEAD] [POP] [POPSERVICE='"pop-3"'] [RENAME]
  ;;          [RFC1342] [RPATHS] [RPOP] [SENDMTS] [SMTP] [SOCKETS]
  ;;          [SPRINTFTYPE=int] [SVR4] [SYS5] [SYS5DIR] [TERMINFO]
  ;;          [TYPESIG=void] [UNISTD] [UTK] [VSPRINTF]
  (let ((mhparam (expand-file-name "mhparam" dir)))
    (when (mh-file-command-p mhparam)
      (erase-buffer)
      (call-process mhparam nil '(t nil) nil "-help")
      (goto-char (point-min))
      (when (search-forward-regexp "version: MH \\(\\S +\\)" nil t)
        (let ((version (format "MH %s" (match-string 1))))
          (erase-buffer)
          (call-process mhparam nil '(t nil) nil "libdir")
          (goto-char (point-min))
          (when (search-forward-regexp "^.*$" nil t)
            (let ((libdir (match-string 0)))
              `(,version
                (variant        mh)
                (mh-lib-progs   ,libdir)
                (mh-lib         ,libdir)
                (mh-progs       ,dir)
                (flists         nil)))))))))

(defun mh-variant-gnu-mh-info (dir)
  "Return info for GNU mailutils MH variant in DIR.
This assumes that a temporary buffer is set up."
  ;; Sample '-version' outputs:
  ;; mhparam (GNU mailutils 0.3.2)
  ;; install-mh (GNU Mailutils 2.2)
  ;; install-mh (GNU Mailutils 3.7)
  (let ((install-mh (expand-file-name "install-mh" dir)))
    (when (mh-file-command-p install-mh)
      (erase-buffer)
      (call-process install-mh nil '(t nil) nil "-version")
      (goto-char (point-min))
      (when (search-forward-regexp "install-mh (\\(GNU [Mm]ailutils \\S +\\))"
                                   nil t)
        (let ((version (match-string 1))
              (mh-progs dir))
          `(,version
            (variant        gnu-mh)
            (mh-lib-progs   ,(mh-profile-component "libdir"))
            (mh-lib         ,(mh-profile-component "etcdir"))
            (mh-progs       ,dir)
            (flists         ,(file-exists-p
                              (expand-file-name "flists" dir)))))))))

(defun mh-variant-nmh-info (dir)
  "Return info for nmh variant in DIR assuming a temporary buffer is set up."
  ;; Sample '-version' outputs:
  ;; mhparam -- nmh-1.1-RC1 [compiled on chaak at Fri Jun 20 11:03:28 PDT 2003]
  ;; install-mh -- nmh-1.7.1 built October 26, 2019 on build-server-000
  ;; "libdir" was deprecated in nmh-1.7 in favor of "libexecdir", and
  ;; removed completely in nmh-1.8.
  (let ((install-mh (expand-file-name "install-mh" dir)))
    (when (mh-file-command-p install-mh)
      (erase-buffer)
      (call-process install-mh nil '(t nil) nil "-version")
      (goto-char (point-min))
      (when (search-forward-regexp "install-mh -- nmh-\\(\\S +\\)" nil t)
        (let ((version (format "nmh %s" (match-string 1)))
              (mh-progs dir))
          `(,version
            (variant        nmh)
            (mh-lib-progs   ,(or (mh-profile-component "libdir")
                                 (mh-profile-component "libexecdir")))
            (mh-lib         ,(mh-profile-component "etcdir"))
            (mh-progs       ,dir)
            (flists         ,(file-exists-p
                              (expand-file-name "flists" dir)))))))))

(defun mh-file-command-p (file)
  "Return t if file FILE is the name of an executable regular file."
  (and (file-regular-p file) (file-executable-p file)))

(defun mh-variant-set-variant (variant)
  "Set up the system variables for the MH variant named VARIANT.
If VARIANT is a string, use that key in the alist returned by the
function `mh-variants'.
If VARIANT is a symbol, select the first entry that matches that
variant."
  (cond
   ((stringp variant)                   ;e.g. "nmh 1.1-RC1"
    (when (assoc variant (mh-variants))
      (let* ((alist (cdr (assoc variant (mh-variants))))
             (lib-progs (cadr (assoc 'mh-lib-progs alist)))
             (lib       (cadr (assoc 'mh-lib       alist)))
             (progs     (cadr (assoc 'mh-progs     alist)))
             (flists    (cadr (assoc 'flists       alist))))
        ;;(set-default mh-variant variant)
        (setq mh-x-mailer-string     nil
              mh-flists-present-flag flists
              mh-lib-progs           lib-progs
              mh-lib                 lib
              mh-progs               progs
              mh-variant-in-use      variant))))
   ((symbolp variant)                   ;e.g. 'nmh (pick the first match)
    (cl-loop for variant-list in (mh-variants)
             when (eq variant (cadr (assoc 'variant (cdr variant-list))))
             return (let* ((version   (car variant-list))
                           (alist (cdr variant-list))
                           (lib-progs (cadr (assoc 'mh-lib-progs alist)))
                           (lib       (cadr (assoc 'mh-lib       alist)))
                           (progs     (cadr (assoc 'mh-progs     alist)))
                           (flists    (cadr (assoc 'flists       alist))))
                      ;;(set-default mh-variant flavor)
                      (setq mh-x-mailer-string     nil
                            mh-flists-present-flag flists
                            mh-lib-progs           lib-progs
                            mh-lib                 lib
                            mh-progs               progs
                            mh-variant-in-use      version)
                      t)))))

(defun mh-variant-p (&rest variants)
  "Return t if variant is any of VARIANTS.
Currently known variants are `MH', `nmh', and `gnu-mh'."
  (or mh-variant-in-use (mh-variant-set mh-variant))
  (let ((variant-in-use
         (cadr (assoc 'variant (assoc mh-variant-in-use (mh-variants))))))
    (not (null (member variant-in-use variants)))))

(defun mh-profile-component (component)
  "Return COMPONENT value from mhparam, or nil if unset."
  (save-excursion
    ;; MH and nmh use -components, GNU mailutils MH uses -component.
    ;; Since MH and nmh work with an unambiguous prefix, the `s' is
    ;; dropped here.
    (mh-exec-cmd-quiet nil "mhparam" "-component" component)
    (mh-profile-component-value component)))

(defun mh-profile-component-value (component)
  "Find and return the value of COMPONENT in the current buffer.
Returns nil if the component is not in the buffer."
  (let ((case-fold-search t))
    (goto-char (point-min))
    (cond ((not (re-search-forward (format "^%s:" component) nil t)) nil)
          ((looking-at "[\t ]*$") nil)
          (t
           (re-search-forward "[\t ]*\\([^\t \n].*\\)$" nil t)
           (let ((start (match-beginning 1)))
             (end-of-line)
             (buffer-substring start (point)))))))

(defun mh-variant-set (variant)
  "Set the MH variant to VARIANT.
Sets `mh-progs', `mh-lib', `mh-lib-progs' and
`mh-flists-present-flag'.
If the VARIANT is \"autodetect\", then first try nmh, then MH and
finally GNU mailutils MH."
  (interactive
   (list (completing-read
          "MH variant: "
          (mapcar (lambda (x) (list (car x))) (mh-variants))
          nil t)))

  ;; TODO Remove mu-mh backwards compatibility in 9.0.
  (when (and (stringp variant)
             (string-match "^mu-mh"  variant))
    (message
     (format "%s\n%s; %s" "The variant name mu-mh has been renamed to gnu-mh"
             "and will be removed in MH-E 9.0"
             "try M-x customize-option mh-variant"))
    (sit-for 5)
    (setq variant (concat "gnu-mh" (substring variant (match-end 0)))))

  (let ((valid-list (mapcar #'car (mh-variants))))
    (cond
     ((eq variant 'none))
     ((eq variant 'autodetect)
      (cond
       ((mh-variant-set-variant 'nmh)
        (message "%s installed as MH variant" mh-variant-in-use))
       ((mh-variant-set-variant 'mh)
        (message "%s installed as MH variant" mh-variant-in-use))
       ((mh-variant-set-variant 'gnu-mh)
        (message "%s installed as MH variant" mh-variant-in-use))
       (t
        (message "No MH variant found on the system"))))
     ((member variant valid-list)
      (when (not (mh-variant-set-variant variant))
        (message "Warning: %s variant not found. Autodetecting..." variant)
        (mh-variant-set 'autodetect)))
     ((null valid-list)
      (message "Unknown variant %s; can't find MH anywhere" variant))
     (t
      (message "Unknown variant %s; use %s"
               variant
               (mapconcat (lambda (x) (format "%s" (car x)))
                          (mh-variants) " or "))))))

(defcustom mh-variant 'autodetect
  "Specifies the variant used by MH-E.

The default setting of this option is \"Auto-detect\" which means
that MH-E will automatically choose the first of nmh, MH, or GNU
mailutils MH that it finds in the directories listed in
`mh-path' (which you can customize), `mh-sys-path', and
`exec-path'. If MH-E can't find MH at all, you may have to
customize `mh-path' and add the directory in which the command
\"mhparam\" is located. If, on the other hand, you have both nmh
and GNU mailutils MH installed (for example) and
`mh-variant-in-use' was initialized to nmh but you want to use
GNU mailutils MH, then you can set this option to \"gnu-mh\".

When this variable is changed, MH-E resets `mh-progs', `mh-lib',
`mh-lib-progs', `mh-flists-present-flag', and `mh-variant-in-use'
accordingly. Prior to version 8, it was often necessary to set
some of these variables in \"~/.emacs\"; now it is no longer
necessary and can actually cause problems."
  :type `(radio
          (const :tag "Auto-detect" autodetect)
          ,@(mapcar (lambda (x) `(const ,(car x))) (mh-variants)))
  :set (lambda (symbol value)
         (set-default symbol value)     ;Done in mh-variant-set-variant!
         (mh-variant-set value))
  :initialize #'custom-initialize-default
  :group 'mh-e
  :package-version '(MH-E . "8.0"))



;;; MH-E Customization

;; All of the defgroups, defcustoms, and deffaces in MH-E are found
;; here. This makes it possible to customize modules that aren't
;; loaded yet. It also makes it easier to organize the customization
;; groups.

;; This section contains the following sub-sections:

;; 1. MH-E Customization Groups

;;    These are the customization group definitions. Every group has a
;;    associated manual node. The ordering is alphabetical, except for
;;    the groups mh-faces and mh-hooks which are last .

;; 2. MH-E Customization

;;    These are the actual customization variables. There is a
;;    sub-section for each group in the MH-E Customization Groups
;;    section, in the same order, separated by page breaks. Within
;;    each section, variables are sorted alphabetically.

;; 3. Hooks

;;    All hooks must be placed in the mh-hook group; in addition, add
;;    the group associated with the manual node in which the hook is
;;    described. Since the mh-hook group appears near the end of this
;;    section, the hooks will appear at the end of these other groups.

;; 4. Faces

;;    All faces must be placed in the mh-faces group; in addition, add
;;    the group associated with the manual node in which the face is
;;    described. Since the mh-faces group appears near the end of this
;;    section, the faces will appear at the end of these other groups.

(defun mh-customize (&optional delete-other-windows-flag)
  "Customize MH-E variables.
If optional argument DELETE-OTHER-WINDOWS-FLAG is non-nil, other
windows in the frame are removed."
  (interactive "P")
  (customize-group 'mh-e)
  (when delete-other-windows-flag
    (delete-other-windows)))

(add-to-list 'customize-package-emacs-version-alist
             '(MH-E ("6.0" . "22.1") ("6.1" . "22.1") ("7.0" . "22.1")
                    ("7.1" . "22.1") ("7.2" . "22.1") ("7.3" . "22.1")
                    ("7.4" . "22.1") ("8.0" . "22.1") ("8.1" . "23.1")
                    ("8.2" . "23.1") ("8.3" . "24.1") ("8.4" . "24.4")
                    ("8.5" . "24.4") ("8.6" . "24.4")))



;;; MH-E Customization Groups

(defgroup mh-e nil
  "Emacs interface to the MH mail system.
MH is the Rand Mail Handler. Other implementations include nmh
and GNU mailutils."
  :link '(custom-manual "(mh-e)Top")
  :group 'mail
  :package-version '(MH-E . "8.0"))

(defgroup mh-alias nil
  "Aliases."
  :link '(custom-manual "(mh-e)Aliases")
  :prefix "mh-alias-"
  :group 'mh-e
  :package-version '(MH-E . "7.1"))

(defgroup mh-folder nil
  "Organizing your mail with folders."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Folders")
  :group 'mh-e
  :package-version '(MH-E . "7.1"))

(defgroup mh-folder-selection nil
  "Folder selection."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Folder Selection")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-identity nil
  "Identities."
  :link '(custom-manual "(mh-e)Identities")
  :prefix "mh-identity-"
  :group 'mh-e
  :package-version '(MH-E . "7.1"))

(defgroup mh-inc nil
  "Incorporating your mail."
  :prefix "mh-inc-"
  :link '(custom-manual "(mh-e)Incorporating Mail")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-junk nil
  "Dealing with junk mail."
  :link '(custom-manual "(mh-e)Junk")
  :prefix "mh-junk-"
  :group 'mh-e
  :package-version '(MH-E . "7.3"))

(defgroup mh-letter nil
  "Editing a draft."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Editing Drafts")
  :group 'mh-e
  :package-version '(MH-E . "7.1"))

(defgroup mh-ranges nil
  "Ranges."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Ranges")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-scan-line-formats nil
  "Scan line formats."
  :link '(custom-manual "(mh-e)Scan Line Formats")
  :prefix "mh-"
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-search nil
  "Searching."
  :link '(custom-manual "(mh-e)Searching")
  :prefix "mh-search-"
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-sending-mail nil
  "Sending mail."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Sending Mail")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-sequences nil
  "Sequences."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Sequences")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-show nil
  "Reading your mail."
  :prefix "mh-"
  :link '(custom-manual "(mh-e)Reading Mail")
  :group 'mh-e
  :package-version '(MH-E . "7.1"))

(defgroup mh-speedbar nil
  "The speedbar."
  :prefix "mh-speed-"
  :link '(custom-manual "(mh-e)Speedbar")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-thread nil
  "Threading."
  :prefix "mh-thread-"
  :link '(custom-manual "(mh-e)Threading")
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-tool-bar nil
  "The tool bar."
  :link '(custom-manual "(mh-e)Tool Bar")
  :prefix "mh-"
  :group 'mh-e
  :package-version '(MH-E . "8.0"))

(defgroup mh-hooks nil
  "MH-E hooks."
  :link '(custom-manual "(mh-e)Top")
  :prefix "mh-"
  :group 'mh-e
  :package-version '(MH-E . "7.1"))

(defgroup mh-faces nil
  "Faces used in MH-E."
  :link '(custom-manual "(mh-e)Top")
  :prefix "mh-"
  :group 'faces
  :group 'mh-e
  :package-version '(MH-E . "7.1"))



;;; MH-E Customization

;; See Variant Support, above, for mh-e group.

;;; Aliases (:group 'mh-alias)

(defcustom mh-alias-completion-ignore-case-flag t
  "Non-nil means don't consider case significant in MH alias completion.

As MH ignores case in the aliases, so too does MH-E. However, you
may turn off this option to make case significant which can be
used to segregate completion of your aliases. You might use
lowercase for mailing lists and uppercase for people."
  :type 'boolean
  :group 'mh-alias
  :package-version '(MH-E . "7.1"))

(defcustom mh-alias-expand-aliases-flag nil
  "Non-nil means to expand aliases entered in the minibuffer.

In other words, aliases entered in the minibuffer will be
expanded to the full address in the message draft.  By default,
this expansion is not performed."
  :type 'boolean
  :group 'mh-alias
  :package-version '(MH-E . "7.1"))

(defcustom mh-alias-flash-on-comma t
  "Specify whether to flash address or warn on translation.

This option controls the behavior when a [comma] is pressed while
entering aliases or addresses. The default setting flashes the
address associated with an address in the minibuffer briefly, but
does not display a warning if the alias is not found."
  :type '(choice (const :tag "Flash but Don't Warn If No Alias" t)
                 (const :tag "Flash and Warn If No Alias" 1)
                 (const :tag "Don't Flash Nor Warn If No Alias" nil))
  :group 'mh-alias
  :package-version '(MH-E . "7.1"))

(defcustom mh-alias-insert-file nil
  "Filename used to store a new MH-E alias.

The default setting of this option is \"Use Aliasfile Profile
Component\". This option can also hold the name of a file or a
list a file names. If this option is set to a list of file names,
or the \"Aliasfile:\" profile component contains more than one file
name, MH-E will prompt for one of them when MH-E adds an alias."
  :type '(choice (const :tag "Use Aliasfile Profile Component" nil)
                 (file :tag "Alias File")
                 (repeat :tag "List of Alias Files" file))
  :group 'mh-alias
  :package-version '(MH-E . "7.1"))

(defcustom mh-alias-insertion-location 'sorted
  "Specifies where new aliases are entered in alias files.

This option is set to \"Alphabetical\" by default. If you organize
your alias file in other ways, then adding aliases to the \"Top\"
or \"Bottom\" of your alias file might be more appropriate."
  :type '(choice (const :tag "Alphabetical" sorted)
                 (const :tag "Top" top)
                 (const :tag "Bottom" bottom))
  :group 'mh-alias
  :package-version '(MH-E . "7.1"))

(defcustom mh-alias-local-users t
  "Non-nil means local users are added to alias completion.

Aliases are created from \"/etc/passwd\" entries with a user ID
larger than a magical number, typically 200. This can be a handy
tool on a machine where you and co-workers exchange messages.
These aliases have the form \"local.first.last\" if a real name is
present in the password file. Otherwise, the alias will have the
form \"local.login\".

If you're on a system with thousands of users you don't know, and
the loading of local aliases slows MH-E down noticeably, then
turn this option off.

This option also takes a string which is executed to generate the
password file. For example, use \"ypcat passwd\" to obtain the
NIS password file."
  :type '(choice (boolean) (string))
  :group 'mh-alias
  :package-version '(MH-E . "7.1"))

(defcustom mh-alias-local-users-prefix "local."
  "String prefixed to the real names of users from the password file.
This option can also be set to \"Use Login\".

For example, consider the following password file entry:

    psg:x:1000:1000:Peter S Galbraith,,,:/home/psg:/bin/tcsh

The following settings of this option will produce the associated
aliases:

    \"local.\"                  local.peter.galbraith
    \"\"                        peter.galbraith
    Use Login                   psg

This option has no effect if variable `mh-alias-local-users' is
turned off."
  :type '(choice (const :tag "Use Login" nil)
                 (string))
  :group 'mh-alias
  :package-version '(MH-E . "7.4"))

(defcustom mh-alias-passwd-gecos-comma-separator-flag t
  "Non-nil means the gecos field in the password file uses a comma separator.

In the example in `mh-alias-local-users-prefix', commas are used
to separate different values within the so-called gecos field.
This is a fairly common usage. However, in the rare case that the
gecos field in your password file is not separated by commas and
whose contents may contain commas, you can turn this option off."
  :type 'boolean
  :group 'mh-alias
  :package-version '(MH-E . "7.4"))

;;; Organizing Your Mail with Folders (:group 'mh-folder)

(defcustom mh-new-messages-folders t
  "Folders searched for the \"unseen\" sequence.

Set this option to \"Inbox\" to search the \"+inbox\" folder or
\"All\" to search all of the top level folders. Otherwise, list
the folders that should be searched with the \"Choose Folders\"
menu item.

See also `mh-recursive-folders-flag'."
  :type '(choice (const :tag "Inbox" t)
                 (const :tag "All" nil)
                 (repeat :tag "Choose Folders" (string :tag "Folder")))
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defcustom mh-ticked-messages-folders t
  "Folders searched for `mh-tick-seq'.

Set this option to \"Inbox\" to search the \"+inbox\" folder or
\"All\" to search all of the top level folders. Otherwise, list
the folders that should be searched with the \"Choose Folders\"
menu item.

See also `mh-recursive-folders-flag'."
  :type '(choice (const :tag "Inbox" t)
                 (const :tag "All" nil)
                 (repeat :tag "Choose Folders" (string :tag "Folder")))
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defcustom mh-large-folder 200
  "The number of messages that indicates a large folder.

If a folder is deemed to be large, that is the number of messages
in it exceed this value, then confirmation is needed when it is
visited. Even when `mh-show-threads-flag' is non-nil, the folder
is not automatically threaded, if it is large. If set to nil all
folders are treated as if they are small."
  :type '(choice (const :tag "No Limit") integer)
  :group 'mh-folder
  :package-version '(MH-E . "7.0"))

(defcustom mh-recenter-summary-flag nil
  "Non-nil means to recenter the summary window.

If this option is turned on, recenter the summary window when the
show window is toggled off."
  :type 'boolean
  :group 'mh-folder
  :package-version '(MH-E . "7.0"))

(defcustom mh-recursive-folders-flag nil
  "Non-nil means that commands which operate on folders do so recursively."
  :type 'boolean
  :group 'mh-folder
  :package-version '(MH-E . "7.0"))

(defcustom mh-sortm-args nil
  "Additional arguments for \"sortm\"\\<mh-folder-mode-map>.

This option is consulted when a prefix argument is used with
\\[mh-sort-folder]. Normally default arguments to \"sortm\" are
specified in the MH profile. This option may be used to provide
an alternate view. For example, (\"-nolimit\" \"-textfield\"
\"subject\") is a useful setting."
  :type '(repeat string)
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

;;; Folder Selection (:group 'mh-folder-selection)

(defcustom mh-default-folder-for-message-function nil
  "Function to select a default folder for refiling or \"Fcc:\".

When this function is called, the current buffer contains the message
being refiled and point is at the start of the message. This function
should return the default folder as a string with a leading \"+\"
sign. It can also return nil so that the last folder name is used as
the default, or an empty string to suppress the default entirely."
  :type '(choice (const nil) function)
  :group 'mh-folder-selection
  :package-version '(MH-E . "8.0"))

(defcustom mh-default-folder-list nil
  "List of addresses and folders.

The folder name associated with the first address found in this
list is used as the default for `mh-refile-msg' and similar
functions. Each element in this list contains a \"Check Recipient\"
item. If this item is turned on, then the address is checked
against the recipient instead of the sender. This is useful for
mailing lists.

See `mh-prompt-for-refile-folder' and `mh-folder-from-address'
for more information."
  :type '(repeat (list (regexp :tag "Address")
                       (string :tag "Folder")
                       (boolean :tag "Check Recipient")))
  :group 'mh-folder-selection
  :package-version '(MH-E . "7.2"))

(defcustom mh-default-folder-must-exist-flag t
  "Non-nil means guessed folder name must exist to be used.

If the derived folder does not exist, and this option is on, then
the last folder name used is suggested. This is useful if you get
mail from various people for whom you have an alias, but file
them all in the same project folder.

See `mh-prompt-for-refile-folder' and `mh-folder-from-address'
for more information."
  :type 'boolean
  :group 'mh-folder-selection
  :package-version '(MH-E . "7.2"))

(defcustom mh-default-folder-prefix ""
  "Prefix used for folder names generated from aliases.
The prefix is used to prevent clutter in your mail directory.

See `mh-prompt-for-refile-folder' and `mh-folder-from-address'
for more information."
  :type 'string
  :group 'mh-folder-selection
  :package-version '(MH-E . "7.2"))

;;; Identities (:group 'mh-identity)

(eval-and-compile
  (unless (fboundp 'mh-identity-make-menu-no-autoload)
    (defun mh-identity-make-menu-no-autoload ()
      "Temporary definition.
Real definition will take effect when mh-identity is loaded."
      nil)))

(defcustom mh-identity-list nil
  "List of identities.

To customize this option, click on the \"INS\" button and enter a label
such as \"Home\" or \"Work\". Then click on the \"INS\" button with the
label \"Add at least one item below\". Then choose one of the items in
the \"Value Menu\".

You can specify an alternate \"From:\" header field using the \"From
Field\" menu item. You must include a valid email address. A standard
format is \"First Last <login@@host.domain>\". If you use an initial
with a period, then you must quote your name as in `\"First I. Last\"
<login@@host.domain>'. People usually list the name of the company
where they work using the \"Organization Field\" menu item. Set any
arbitrary header field and value in the \"Other Field\" menu item.
Unless the header field is a standard one, precede the name of your
field's label with \"X-\", as in \"X-Fruit-of-the-Day:\". The value of
\"Attribution Verb\" overrides the setting of
`mh-extract-from-attribution-verb'. Set your signature with the
\"Signature\" menu item. You can specify the contents of
`mh-signature-file-name', a file, or a function. Specify a different
key to sign or encrypt messages with the \"GPG Key ID\" menu item.

You can select the identities you have added via the menu called
\"Identity\" in the MH-Letter buffer. You can also use
\\[mh-insert-identity]. To clear the fields and signature added by the
identity, select the \"None\" identity.

The \"Identity\" menu contains two other items to save you from having
to set the identity on every message. The menu item \"Set Default for
Session\" can be used to set the default identity to the current
identity until you exit Emacs. The menu item \"Save as Default\" sets
the option `mh-identity-default' to the current identity setting. You
can also customize the `mh-identity-default' option in the usual
fashion."
  :type '(repeat (list :tag ""
                       (string :tag "Label")
                       (repeat :tag "Add at least one item below"
                               (choice
                                (cons :tag "From Field"
                                      (const "From")
                                      (string :tag "Value"))
                                (cons :tag "Organization Field"
                                      (const "Organization")
                                      (string :tag "Value"))
                                (cons :tag "Other Field"
                                      (string :tag "Field")
                                      (string :tag "Value"))
                                (cons :tag "Attribution Verb"
                                      (const ":attribution-verb")
                                      (string :tag "Value"))
                                (cons :tag "Signature"
                                      (const :tag "Signature"
                                             ":signature")
                                      (choice
                                       (const :tag "mh-signature-file-name"
                                              nil)
                                       (file)
                                       (function)))
                                (cons :tag "GPG Key ID"
                                      (const :tag "GPG Key ID"
                                             ":pgg-default-user-id")
                                      (string :tag "Value"))))))
  :set (lambda (symbol value)
         (set-default symbol value)
         (mh-identity-make-menu-no-autoload))
  :group 'mh-identity
  :package-version '(MH-E . "7.1"))

(defcustom mh-auto-fields-list nil
  "List of recipients for which header lines are automatically inserted.

This option can be used to set the identity depending on the
recipient. To customize this option, click on the \"INS\" button and
enter a regular expression for the recipient's address. Click on the
\"INS\" button with the \"Add at least one item below\" label. Then choose
one of the items in the \"Value Menu\".

The \"Identity\" menu item is used to select an identity from those
configured in `mh-identity-list'. All of the information for that
identity will be added if the recipient matches. The \"Fcc Field\" menu
item is used to select a folder that is used in the \"Fcc:\" header.
When you send the message, MH will put a copy of your message in this
folder. The \"Mail-Followup-To Field\" menu item is used to insert an
\"Mail-Followup-To:\" header field with the recipients you provide. If
the recipient's mail user agent supports this header field (as nmh
does), then their replies will go to the addresses listed. This is
useful if their replies go both to the list and to you and you don't
have a mechanism to suppress duplicates. If you reply to someone not
on the list, you must either remove the \"Mail-Followup-To:\" field, or
ensure the recipient is also listed there so that he receives replies
to your reply. Other header fields may be added using the \"Other
Field\" menu item.

These fields can only be added after the recipient is known. Once the
header contains one or more recipients, run the
\\[mh-insert-auto-fields] command or choose the \"Identity -> Insert
Auto Fields\" menu item to insert these fields manually. However, you
can just send the message and the fields will be added automatically.
You are given a chance to see these fields and to confirm them before
the message is actually sent. You can do away with this confirmation
by turning off the option `mh-auto-fields-prompt-flag'.

You should avoid using the same header field in `mh-auto-fields-list'
and `mh-identity-list' definitions that may apply to the same message
as the result is undefined."
  :type `(repeat
          (list :tag ""
                (string :tag "Recipient")
                (repeat :tag "Add at least one item below"
                        (choice
                         (cons :tag "Identity"
                               (const ":identity")
                               ,(append
                                 '(radio)
                                 (mapcar
                                  (lambda (arg) `(const ,arg))
                                  (mapcar #'car mh-identity-list))))
                         (cons :tag "Fcc Field"
                               (const "fcc")
                               (string :tag "Value"))
                         (cons :tag "Mail-Followup-To Field"
                               (const "Mail-Followup-To")
                               (string :tag "Value"))
                         (cons :tag "Other Field"
                                 (string :tag "Field")
                                 (string :tag "Value"))))))
  :group 'mh-identity
  :package-version '(MH-E . "7.3"))

(defcustom mh-auto-fields-prompt-flag t
  "Non-nil means to prompt before sending if fields inserted.
See `mh-auto-fields-list'."
  :type 'boolean
  :group 'mh-identity
  :package-version '(MH-E . "8.0"))

(defcustom mh-identity-default nil
  "Default identity to use when `mh-letter-mode' is called.
See `mh-identity-list'."
  :type (append
         '(radio)
         (cons '(const :tag "None" nil)
               (mapcar (lambda (arg) `(const ,arg))
                       (mapcar #'car mh-identity-list))))
  :group 'mh-identity
  :package-version '(MH-E . "7.1"))

(defcustom mh-identity-handlers
  '(("From" . mh-identity-handler-top)
    (":default" . mh-identity-handler-bottom)
    (":attribution-verb" . mh-identity-handler-attribution-verb)
    (":signature" . mh-identity-handler-signature)
    (":pgg-default-user-id" . mh-identity-handler-gpg-identity))
  "Handler functions for fields in `mh-identity-list'.

This option is used to change the way that fields, signatures,
and attributions in `mh-identity-list' are added. To customize
`mh-identity-handlers', replace the name of an existing handler
function associated with the field you want to change with the
name of a function you have written. You can also click on an
\"INS\" button and insert a field of your choice and the name of
the function you have written to handle it.

The \"Field\" field can be any field that you've used in your
`mh-identity-list'. The special fields \":attribution-verb\",
\":signature\", or \":pgg-default-user-id\" are used for the
`mh-identity-list' choices \"Attribution Verb\", \"Signature\", and
\"GPG Key ID\" respectively.

The handler associated with the \":default\" field is used when no
other field matches.

The handler functions are passed two or three arguments: the
FIELD itself (for example, \"From\"), or one of the special
fields (for example, \":signature\"), and the ACTION `remove' or
`add'. If the action is `add', an additional argument
containing the VALUE for the field is given."
  :type '(repeat (cons (string :tag "Field") function))
  :group 'mh-identity
  :package-version '(MH-E . "8.0"))

;;; Incorporating Your Mail (:group 'mh-inc)

(defcustom mh-inc-prog "inc"
  "Program to incorporate new mail into a folder.

This program generates a one-line summary for each of the new
messages. Unless it is an absolute pathname, the file is assumed
to be in the `mh-progs' directory. You may also link a file to
\"inc\" that uses a different format. You'll then need to modify
several scan line format variables appropriately."
  :type 'string
  :group 'mh-inc
  :package-version '(MH-E . "6.0"))

(eval-and-compile
  (unless (fboundp 'mh-inc-spool-make-no-autoload)
    (defun mh-inc-spool-make-no-autoload ()
      "Temporary definition.
Real definition will take effect when mh-inc is loaded."
      nil)))

(defcustom mh-inc-spool-list nil
  "Alternate spool files.

You can use the `mh-inc-spool-list' variable to direct MH-E to
retrieve mail from arbitrary spool files other than your system
mailbox, file it in folders other than your \"+inbox\", and assign
key bindings to incorporate this mail.

Suppose you are subscribed to the \"mh-e-devel\" mailing list and
you use \"procmail\" to filter this mail into \"~/mail/mh-e\" with
the following recipe in \".procmailrc\":

    MAILDIR=$HOME/mail
    :0:
    * ^From mh-e-devel-admin@stop.mail-abuse.org
    mh-e

In order to incorporate \"~/mail/mh-e\" into \"+mh-e\" with an
\"I m\" (mh-inc-spool-mh-e) command, customize this option, and click
on the \"INS\" button. Enter a \"Spool File\" of \"~/mail/mh-e\", a
\"Folder\" of \"mh-e\", and a \"Key Binding\" of \"m\".

You can use \"xbuffy\" to automate the incorporation of this mail
using \"emacsclient\" as follows:

    box ~/mail/mh-e
        title mh-e
        origMode
        polltime 10
        headertime 0
        command emacsclient --eval \\='(mh-inc-spool-mh-e)\\='"
  :type '(repeat (list (file :tag "Spool File")
                       (string :tag "Folder")
                       (character :tag "Key Binding")))
  :set (lambda (symbol value)
         (set-default symbol value)
         (mh-inc-spool-make-no-autoload))
  :group 'mh-inc
  :package-version '(MH-E . "7.3"))

;;; Dealing with Junk Mail (:group 'mh-junk)

(defvar mh-junk-choice nil
  "Chosen spam fighting program.")

;; Available spam filter interfaces
(defvar mh-junk-function-alist
  '((spamassassin mh-spamassassin-blocklist mh-spamassassin-allowlist)
    (bogofilter mh-bogofilter-blocklist mh-bogofilter-allowlist)
    (spamprobe mh-spamprobe-blocklist mh-spamprobe-allowlist))
  "Available choices of spam programs to use.

This is an alist. For each element there are functions that
blocklist a message as spam and allowlist a message incorrectly
classified as spam.")

(defun mh-junk-choose (symbol value)
  "Choose spam program to use.

The function is always called with SYMBOL bound to
`mh-junk-program' and VALUE bound to the new value of
`mh-junk-program'. The function sets the variable
`mh-junk-choice' in addition to `mh-junk-program'."
  (set symbol value)                    ;XXX shouldn't this be set-default?
  (setq mh-junk-choice
        (or value
            (cl-loop for element in mh-junk-function-alist
                     until (executable-find (symbol-name (car element)))
                     finally return (car element)))))

(defcustom mh-junk-background nil
  "If on, spam programs are run in background.

By default, the programs are run in the foreground, but this can
be slow when junking large numbers of messages. If you have
enough memory or don't junk that many messages at the same time,
you might try turning on this option.

Note that this option is used as the \"destination\" argument in
the call to `call-process'. Therefore, turning on this option means
setting its value to \"0\". You can also set its value to t to
direct the programs' output to the \"*MH-E Log*\" buffer; this
may be useful for debugging."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "On" 0))
  :group 'mh-junk
  :package-version '(MH-E . "8.0"))

(defcustom mh-junk-disposition nil
  "Disposition of junk mail."
  :type '(choice (const :tag "Delete Spam" nil)
                 (string :tag "Spam Folder"))
  :group 'mh-junk
  :package-version '(MH-E . "8.0"))

(defcustom mh-junk-program nil
  "Spam program that MH-E should use.

The default setting of this option is \"Auto-detect\" which means
that MH-E will automatically choose one of SpamAssassin,
bogofilter, or SpamProbe in that order. If, for example, you have
both SpamAssassin and bogofilter installed and you want to use
bogofilter, then you can set this option to \"Bogofilter\"."
  :type '(choice (const :tag "Auto-detect" nil)
                 (const :tag "SpamAssassin" spamassassin)
                 (const :tag "Bogofilter" bogofilter)
                 (const :tag "SpamProbe" spamprobe))
  :set #'mh-junk-choose
  :group 'mh-junk
  :package-version '(MH-E . "7.3"))

;;; Editing a Draft (:group 'mh-letter)

(defcustom mh-compose-insertion (if (locate-library "mml") 'mml 'mh)
  "Type of tags used when composing MIME messages.

In addition to MH-style directives, MH-E also supports MML (MIME
Meta Language) tags. (see Info node `(emacs-mime)Composing').
This option can be used to choose between them. By default, this
option is set to \"MML\" if it is supported since it provides a
lot more functionality. This option can also be set to \"MH\" if
MH-style directives are preferred."
  :type '(choice (const :tag "MML" mml)
                 (const :tag "MH"  mh))
  :group 'mh-letter
  :package-version '(MH-E . "7.0"))

(defcustom mh-compose-skipped-header-fields
  '("From" "Organization" "References" "In-Reply-To"
    "X-Face" "Face" "X-Image-URL" "X-Mailer")
  "List of header fields to skip over when navigating in draft."
  :type '(repeat (string :tag "Field"))
  :group 'mh-letter
  :package-version '(MH-E . "7.4"))

(defcustom mh-compose-space-does-completion-flag nil
  "Non-nil means \\<mh-letter-mode-map>\\[mh-letter-complete-or-space] does completion in message header."
  :type 'boolean
  :group 'mh-letter
  :package-version '(MH-E . "7.4"))

(defcustom mh-delete-yanked-msg-window-flag nil
  "Non-nil means delete any window displaying the message.

This deletes the window containing the original message after
yanking it with \\<mh-letter-mode-map>\\[mh-yank-cur-msg] to make
more room on your screen for your reply."
  :type 'boolean
  :group 'mh-letter
  :package-version '(MH-E . "7.0"))

(defcustom mh-extract-from-attribution-verb "wrote:"
  "Verb to use for attribution when a message is yanked by \\<mh-letter-mode-map>\\[mh-yank-cur-msg].

The attribution consists of the sender's name and email address
followed by the content of this option. This option can be set to
\"wrote:\", \"a écrit:\", and \"schrieb:\". You can also use the
\"Custom String\" menu item to enter your own verb."
  :type '(choice (const "wrote:")
                 (const "a écrit:")
                 (const "schrieb:")
                 (string :tag "Custom String"))
  :group 'mh-letter
  :package-version '(MH-E . "7.0"))

(defcustom mh-ins-buf-prefix "> "
  "String to put before each line of a yanked or inserted message.

The prefix \"> \" is the default setting of this option. I
suggest that you not modify this option since it is used by many
mailers and news readers: messages are far easier to read if
several included messages have all been indented by the same
string.

This prefix is not inserted if you use one of the supercite
flavors of `mh-yank-behavior' or you have added a
`mail-citation-hook'."
  :type 'string
  :group 'mh-letter
  :package-version '(MH-E . "6.0"))

(defcustom mh-letter-complete-function 'ispell-complete-word
  "Function to call when completing outside of address or folder fields.

In the body of the message,
\\<mh-letter-mode-map>\\[completion-at-point] runs this function,
which is set to \"ispell-complete-word\" by default."
  :type '(choice function (const nil))
  :group 'mh-letter
  :package-version '(MH-E . "7.1"))

(defcustom mh-letter-fill-column 72
  "Fill column to use in MH Letter mode.

By default, this option is 72 to allow others to quote your
message without line wrapping."
  :type 'integer
  :group 'mh-letter
  :package-version '(MH-E . "6.0"))

(defcustom mh-mml-method-default (if mh-pgp-support-flag "pgpmime" "none")
  "Default method to use in security tags.

This option is used to select between a variety of mail security
mechanisms. The default is \"PGP (MIME)\" if it is supported;
otherwise, the default is \"None\". Other mechanisms include
vanilla \"PGP\" and \"S/MIME\"."
  :type '(choice (const :tag "PGP (MIME)" "pgpmime")
                 (const :tag "PGP" "pgp")
                 (const :tag "S/MIME" "smime")
                 (const :tag "None" "none"))
  :group 'mh-letter
  :package-version '(MH-E . "8.0"))

(defcustom mh-signature-file-name "~/.signature"
  "Source of user's signature.

By default, the text of your signature is taken from the file
\"~/.signature\". You can read from other sources by changing this
option. This file may contain a vCard in which case an attachment is
added with the vCard.

This option may also be a symbol, in which case that function is
called. You may not want a signature separator to be added for you;
instead you may want to insert one yourself. Options that you may find
useful to do this include `mh-signature-separator' (when inserting a
signature separator) and `mh-signature-separator-regexp' (for finding
said separator). The function `mh-signature-separator-p', which
reports t if the buffer contains a separator, may be useful as well.

The signature is inserted into your message with the command
\\<mh-letter-mode-map>\\[mh-insert-signature] or with the option
`mh-identity-list'."
  :type 'file
  :group 'mh-letter
  :package-version '(MH-E . "6.0"))

(defcustom mh-signature-separator-flag t
  "Non-nil means a signature separator should be inserted.

It is not recommended that you change this option since various
mail user agents, including MH-E, use the separator to present
the signature differently, and to suppress the signature when
replying or yanking a letter into a draft."
  :type 'boolean
  :group 'mh-letter
  :package-version '(MH-E . "8.0"))

(defcustom mh-x-face-file "~/.face"
  "File containing face header field to insert in outgoing mail.

If the file starts with either of the strings \"X-Face:\", \"Face:\"
or \"X-Image-URL:\" then the contents are added to the message header
verbatim. Otherwise it is assumed that the file contains the value of
the \"X-Face:\" header field.

The \"X-Face:\" header field, which is a low-resolution, black and
white image, can be generated using the \"compface\" command (see URL
`ftp://ftp.cs.indiana.edu/pub/faces/compface/compface.tar.Z'). The
\"Online X-Face Converter\" is a useful resource for quick conversion
of images into \"X-Face:\" header fields (see URL
`https://www.dairiki.org/xface/').

Use the \"make-face\" script to convert a JPEG image to the higher
resolution, color, \"Face:\" header field (see URL
`https://quimby.gnus.org/circus/face/make-face').

The URL of any image can be used for the \"X-Image-URL:\" field and no
processing of the image is required.

To prevent the setting of any of these header fields, either set
`mh-x-face-file' to nil, or simply ensure that the file defined by
this option doesn't exist."
  :type 'file
  :group 'mh-letter
  :package-version '(MH-E . "7.0"))

(defcustom mh-yank-behavior 'attribution
  "Controls which part of a message is yanked by \\<mh-letter-mode-map>\\[mh-yank-cur-msg].

To include the entire message, including the entire header, use
\"Body and Header\". Use \"Body\" to yank just the body without
the header. To yank only the portion of the message following the
point, set this option to \"Below Point\".

Choose \"Invoke supercite\" to pass the entire message and header
through supercite.

If the \"Body With Attribution\" setting is used, then the
message minus the header is yanked and a simple attribution line
is added at the top using the value of the option
`mh-extract-from-attribution-verb'. This is the default.

If the \"Invoke supercite\" or \"Body With Attribution\" settings
are used, the \"-noformat\" argument is passed to the \"repl\"
program to override a \"-filter\" or \"-format\" argument. These
settings also have \"Automatically\" variants that perform the
action automatically when you reply so that you don't need to use
\\[mh-yank-cur-msg] at all. Note that this automatic action is
only performed if the show buffer matches the message being
replied to. People who use the automatic variants tend to turn on
the option `mh-delete-yanked-msg-window-flag' as well so that the
show window is never displayed.

If the show buffer has a region, the option `mh-yank-behavior' is
ignored unless its value is one of Attribution variants in which
case the attribution is added to the yanked region.

If this option is set to one of the supercite flavors, the hook
`mail-citation-hook' is ignored and `mh-ins-buf-prefix' is not
inserted."
  :type '(choice (const :tag "Body and Header" t)
                 (const :tag "Body" body)
                 (const :tag "Below Point" nil)
                 (const :tag "Invoke supercite" supercite)
                 (const :tag "Invoke supercite, Automatically" autosupercite)
                 (const :tag "Body With Attribution" attribution)
                 (const :tag "Body With Attribution, Automatically"
                        autoattrib))
  :group 'mh-letter
  :package-version '(MH-E . "8.0"))

;;; Ranges (:group 'mh-ranges)

(defcustom mh-interpret-number-as-range-flag t
  "Non-nil means interpret a number as a range.

Since one of the most frequent ranges used is \"last:N\", MH-E
will interpret input such as \"200\" as \"last:200\" if this
option is on (which is the default). If you need to scan just the
message 200, then use the range \"200:200\"."
  :type 'boolean
  :group 'mh-ranges
  :package-version '(MH-E . "7.4"))

;;; Scan Line Formats (:group 'mh-scan-line-formats)

(eval-and-compile
  (unless (fboundp 'mh-adaptive-cmd-note-flag-check)
    (defun mh-adaptive-cmd-note-flag-check (symbol value)
      "Temporary definition.
Real definition, below, uses variables that aren't defined yet."
      (set-default symbol value))))

(defcustom mh-adaptive-cmd-note-flag t
  "Non-nil means that the message number width is determined dynamically.

If you've created your own format to handle long message numbers,
you'll be pleased to know you no longer need it since MH-E adapts its
internal format based upon the largest message number if this option
is on (the default). This option may only be turned on when
`mh-scan-format-file' is set to \"Use MH-E scan Format\".

If you prefer fixed-width message numbers, turn off this option and
call `mh-set-cmd-note' with the width specified by your format file
\(see `mh-scan-format-file'). For example, the default width is 4, so
you would use \"(mh-set-cmd-note 4)\"."
  :type 'boolean
  :group 'mh-scan-line-formats
  :set #'mh-adaptive-cmd-note-flag-check
  :package-version '(MH-E . "7.0"))

(defun mh-scan-format-file-check (symbol value)
  "Check if desired setting is valid.
Throw an error if user tries to set `mh-scan-format-file' to
anything but t when `mh-adaptive-cmd-note-flag' is on. Otherwise,
set SYMBOL to VALUE."
  (if (and (not (eq value t))
           mh-adaptive-cmd-note-flag)
      (error "%s %s" "You must turn off `mh-adaptive-cmd-note-flag'"
             "unless you use \"Use MH-E scan Format\"")
    (set-default symbol value)))

(defcustom mh-scan-format-file t
  "Specifies the format file to pass to the scan program.

The default setting for this option is \"Use MH-E scan Format\". This
means that the format string will be taken from the either
`mh-scan-format-mh' or `mh-scan-format-nmh' depending on whether MH or
nmh (or GNU mailutils MH) is in use. This setting also enables you to
turn on the `mh-adaptive-cmd-note-flag' option.

You can also set this option to \"Use Default scan Format\" to get the
same output as you would get if you ran \"scan\" from the shell. If
you have a format file that you want MH-E to use but not MH, you can
set this option to \"Specify a scan Format File\" and enter the name
of your format file.

If you change the format of the scan lines you'll need to tell MH-E
how to parse the new format. As you will see, quite a lot of variables
are involved to do that. Use \"\\[apropos] RET mh-scan.*regexp\" to
obtain a list of these variables. You will also have to call
`mh-set-cmd-note' if your notations are not in column 4 (columns in
Emacs start with 0)."
  :type '(choice (const :tag "Use MH-E scan Format" t)
                 (const :tag "Use Default scan Format" nil)
                 (file  :tag "Specify a scan Format File"))
  :group 'mh-scan-line-formats
  :set #'mh-scan-format-file-check
  :package-version '(MH-E . "6.0"))

(defun mh-adaptive-cmd-note-flag-check (symbol value)
  "Check if desired setting is valid.
Throw an error if user tries to turn on
`mh-adaptive-cmd-note-flag' when `mh-scan-format-file' isn't t.
Otherwise, set SYMBOL to VALUE."
  (if (and value
           (not (eq mh-scan-format-file t)))
      (error "%s %s" "Can't turn on unless `mh-scan-format-file'"
             "is set to \"Use MH-E scan Format\"")
    (set-default symbol value)))

(defcustom mh-scan-prog "scan"
  "Program used to scan messages.

The name of the program that generates a listing of one line per
message is held in this option. Unless this variable contains an
absolute pathname, it is assumed to be in the `mh-progs'
directory. You may link another program to `scan' (see
\"mh-profile(5)\") to produce a different type of listing."
  :type 'string
  :local t
  :group 'mh-scan-line-formats
  :package-version '(MH-E . "6.0"))

;;; Searching (:group 'mh-search)

(defcustom mh-search-program nil
  "Search program that MH-E shall use.

The default setting of this option is \"Auto-detect\" which means
that MH-E will automatically choose one of swish++, swish-e,
mairix, namazu, pick and grep in that order. If, for example, you
have both swish++ and mairix installed and you want to use
mairix, then you can set this option to \"mairix\".

More information about setting up an indexing program to use with
MH-E can be found in the documentation of `mh-search'."
  :type '(choice (const :tag "Auto-detect" nil)
                 (const :tag "swish++" swish++)
                 (const :tag "swish-e" swish)
                 (const :tag "mairix" mairix)
                 (const :tag "namazu" namazu)
                 (const :tag "pick" pick)
                 (const :tag "grep" grep))
  :group 'mh-search
  :package-version '(MH-E . "8.0"))

;;; Sending Mail (:group 'mh-sending-mail)

(defcustom mh-compose-forward-as-mime-flag t
  "Non-nil means that messages are forwarded as attachments.

By default, this option is on which means that the forwarded
messages are included as attachments. If you would prefer to
forward your messages verbatim (as text, inline), then turn off
this option. Forwarding messages verbatim works well for short,
textual messages, but your recipient won't be able to view any
non-textual attachments that were in the forwarded message. Be
aware that if you have \"forw: -mime\" in your MH profile, then
forwarded messages will always be included as attachments
regardless of the settings of this option."
  :type 'boolean
  :group 'mh-sending-mail
  :package-version '(MH-E . "8.0"))

(defcustom mh-compose-letter-function nil
  "Invoked when starting a new draft.

However, it is the last function called before you edit your
message. The consequence of this is that you can write a function
to write and send the message for you. This function is passed
three arguments: the contents of the TO, SUBJECT, and CC header
fields."
  :type '(choice (const nil) function)
  :group 'mh-sending-mail
  :package-version '(MH-E . "6.0"))

(defcustom mh-compose-prompt-flag nil
  "Non-nil means prompt for header fields when composing a new draft."
  :type 'boolean
  :group 'mh-sending-mail
  :package-version '(MH-E . "7.4"))

(defcustom mh-forward-subject-format "%s: %s"
  "Format string for forwarded message subject.

This option is a string which includes two escapes (\"%s\"). The
first \"%s\" is replaced with the sender of the original message,
and the second one is replaced with the original \"Subject:\"."
  :type 'string
  :group 'mh-sending-mail
  :package-version '(MH-E . "6.0"))

(defcustom mh-insert-x-mailer-flag t
  "Non-nil means append an \"X-Mailer:\" header field to the header.

This header field includes the version of MH-E and Emacs that you
are using. If you don't want to participate in our marketing, you
can turn this option off."
  :type 'boolean
  :group 'mh-sending-mail
  :package-version '(MH-E . "7.0"))

(defcustom mh-redist-full-contents-flag nil
  "Non-nil means the \"dist\" command needs entire letter for redistribution.

This option must be turned on if \"dist\" requires the whole
letter for redistribution, which is the case if \"send\" is
compiled with the BERK option (which many people abhor). If you
find that MH will not allow you to redistribute a message that
has been redistributed before, turn off this option."
  :type 'boolean
  :group 'mh-sending-mail
  :package-version '(MH-E . "8.0"))

(defcustom mh-reply-default-reply-to nil
  "Sets the person or persons to whom a reply will be sent.

This option is set to \"Prompt\" by default so that you are
prompted for the recipient of a reply. If you find that most of
the time that you specify \"cc\" when you reply to a message, set
this option to \"cc\". Other choices include \"from\", \"to\", or
\"all\". You can always edit the recipients in the draft."
  :type '(choice (const :tag "Prompt" nil)
                 (const "from")
                 (const "to")
                 (const "cc")
                 (const "all"))
  :group 'mh-sending-mail
  :package-version '(MH-E . "6.0"))

(defcustom mh-reply-show-message-flag t
  "Non-nil means the MH-Show buffer is displayed when replying.

If you include the message automatically, you can hide the
MH-Show buffer by turning off this option.

See also `mh-reply'."
  :type 'boolean
  :group 'mh-sending-mail
  :package-version '(MH-E . "7.0"))

;;; Sequences (:group 'mh-sequences)

;; If `mh-unpropagated-sequences' becomes a defcustom, add the following to
;; the docstring: "Additional sequences that should not to be preserved can be
;; specified by setting `mh-unpropagated-sequences' appropriately." XXX

(defcustom mh-refile-preserves-sequences-flag t
  "Non-nil means that sequences are preserved when messages are refiled.

If a message is in any sequence (except \"Previous-Sequence:\"
and \"cur\") when it is refiled, then it will still be in those
sequences in the destination folder. If this behavior is not
desired, then turn off this option."
  :type 'boolean
  :group 'mh-sequences
  :package-version '(MH-E . "7.4"))

(defcustom mh-tick-seq 'tick
  "The name of the MH sequence for ticked messages.

You can customize this option if you already use the \"tick\"
sequence for your own use. You can also disable all of the
ticking functions by choosing the \"Disable Ticking\" item but
there isn't much advantage to that."
  :type '(choice (const :tag "Disable Ticking" nil)
                 symbol)
  :group 'mh-sequences
  :package-version '(MH-E . "7.3"))

(defcustom mh-update-sequences-after-mh-show-flag t
  "Non-nil means flush MH sequences to disk after message is shown\\<mh-folder-mode-map>.

Three sequences are maintained internally by MH-E and pushed out
to MH when a message is shown. They include the sequence
specified by your \"Unseen-Sequence:\" profile entry, \"cur\",
and the sequence listed by the option `mh-tick-seq' which is
\"tick\" by default. If you do not like this behavior, turn off
this option. You can then update the state manually with the
\\[mh-execute-commands], \\[mh-quit], or \\[mh-update-sequences]
commands."
  :type 'boolean
  :group 'mh-sequences
  :package-version '(MH-E . "7.0"))

(defcustom mh-allowlist-preserves-sequences-flag t
  "Non-nil means that sequences are preserved when messages are allowlisted.

If a message is in any sequence (except \"Previous-Sequence:\"
and \"cur\") when it is allowlisted, then it will still be in
those sequences in the destination folder. If this behavior is
not desired, then turn off this option."
  :type 'boolean
  :group 'mh-sequences
  :package-version '(MH-E . "8.4"))

;;; Reading Your Mail (:group 'mh-show)

(defcustom mh-bury-show-buffer-flag t
  "Non-nil means show buffer is buried.

One advantage of not burying the show buffer is that one can
delete the show buffer more easily in an electric buffer list
because of its proximity to its associated MH-Folder buffer. Try
running \\[electric-buffer-list] to see what I mean."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-clean-message-header-flag t
  "Non-nil means remove extraneous header fields.

See also `mh-invisible-header-fields-default' and
`mh-invisible-header-fields'."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-decode-mime-flag (not (not (locate-library "mm-decode")))
  "Non-nil means attachments are handled\\<mh-folder-mode-map>.

MH-E can handle attachments as well if the Gnus `mm-decode'
library is present. If so, this option will be on. Otherwise,
you'll see the MIME body parts rather than text or attachments.
There isn't much point in turning off this option; however, you
can inspect it if it appears that the body parts are not being
interpreted correctly or toggle it with the command
\\[mh-toggle-mh-decode-mime-flag] to view the raw message.

This option also controls the display of quoted-printable
messages and other graphical widgets. See the options
`mh-graphical-smileys-flag' and `mh-graphical-emphasis-flag'."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-display-buttons-for-alternatives-flag nil
  "Non-nil means display buttons for all alternative attachments.

Sometimes, a mail program will produce multiple alternatives of
the attachment in increasing degree of faithfulness to the
original content. By default, only the preferred alternative is
displayed. If this option is on, then the preferred part is shown
inline and buttons are shown for each of the other alternatives."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.4"))

(defcustom mh-display-buttons-for-inline-parts-flag nil
  "Non-nil means display buttons for all inline attachments\\<mh-folder-mode-map>.

The sender can request that attachments should be viewed inline so
that they do not really appear like an attachment at all to the
reader. Most of the time, this is desirable, so by default MH-E
suppresses the buttons for inline attachments. On the other hand, you
may receive code or HTML which the sender has added to his message as
inline attachments so that you can read them in MH-E. In this case, it
is useful to see the buttons so that you know you don't have to cut
and paste the code into a file; you can simply save the attachment.

If you want to make the buttons visible for inline attachments, you
can use the command \\[mh-toggle-mime-buttons] to toggle the
visibility of these buttons. You can turn on these buttons permanently
by turning on this option.

MH-E cannot display all attachments inline however. It can display
text (including HTML) and images."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-do-not-confirm-flag nil
  "Non-nil means non-reversible commands do not prompt for confirmation.

Commands such as `mh-pack-folder' prompt to confirm whether to
process outstanding moves and deletes or not before continuing.
Turning on this option means that these actions will be
performed--which is usually desired but cannot be
retracted--without question."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-fetch-x-image-url nil
  "Control fetching of \"X-Image-URL:\" header field image.

This option controls the fetching of the \"X-Image-URL:\" header
field image with the following values:

Ask Before Fetching
     You are prompted before the image is fetched. MH-E will
     remember your reply and will either use the already fetched
     image the next time the same URL is encountered or silently
     skip it if you didn't fetch it the first time. This is a
     good setting.

Never Fetch
     Images are never fetched and only displayed if they are
     already present in the cache. This is the default.

There isn't a value of \"Always Fetch\" for privacy and DOS (denial of
service) reasons. For example, fetching a URL can tip off a spammer
that you've read his email (which is why you shouldn't blindly answer
yes if you've set this option to \"Ask Before Fetching\"). Someone may
also flood your network and fill your disk drive by sending a torrent
of messages, each specifying a unique URL to a very large file.

The cache of images is found in the directory \".mhe-x-image-cache\"
within your MH directory. You can add your own face to the \"From:\"
field too. See Info node `(mh-e)Picture'.

This setting only has effect if the option `mh-show-use-xface-flag' is
turned on."

  :type '(choice (const :tag "Ask Before Fetching" ask)
                 (const :tag "Never Fetch" nil))
  :group 'mh-show
  :package-version '(MH-E . "7.3"))

(defcustom mh-graphical-smileys-flag t
  "Non-nil means graphical smileys are displayed.

It is a long standing custom to inject body language using a
cornucopia of punctuation, also known as the \"smileys\". MH-E
can render these as graphical widgets if this option is turned
on, which it is by default. Smileys include patterns such as :-)
and ;-).

This option is disabled if the option `mh-decode-mime-flag' is
turned off."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-graphical-emphasis-flag t
  "Non-nil means graphical emphasis is displayed.

A few typesetting features are indicated in ASCII text with
certain characters. If your terminal supports it, MH-E can render
these typesetting directives naturally if this option is turned
on, which it is by default. For example, _underline_ will be
underlined, *bold* will appear in bold, /italics/ will appear in
italics, and so on. See the option `gnus-emphasis-alist' for the
whole list.

This option is disabled if the option `mh-decode-mime-flag' is
turned off."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-highlight-citation-style 'gnus
  "Style for highlighting citations.

If the sender of the message has cited other messages in his
message, then MH-E will highlight these citations to emphasize
the sender's actual response. This option can be customized to
change the highlighting style. The \"Multicolor\" method uses a
different color for each indentation while the \"Monochrome\"
method highlights all citations in red. To disable highlighting
of citations entirely, choose \"None\"."
  :type '(choice (const :tag "Multicolor" gnus)
                 (const :tag "Monochrome" font-lock)
                 (const :tag "None" nil))
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

;; These entries have been intentionally excluded by the developers.
;;  "Comments:"                         ; RFC 822 (or later) - show this one
;;  "Fax:"                              ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
;;  "Mail-System-Version:"              ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
;;  "Mailer:"                           ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
;;  "Organization:"                     ;
;;  "Phone:"                            ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
;;  "Reply-By:"                         ; RFC 2156
;;  "Reply-To:"                         ; RFC 822 (or later)
;;  "Sender:"                           ;
;;  "User-Agent:"                       ; Similar to X-Mailer, so display it.
;;  "X-Mailer:"                         ;
;;  "X-Operator:"                       ; Similar to X-Mailer, so display it

;; Keep fields alphabetized with case folding. Use M-:(setq
;; sort-fold-case t) from the minibuffer to accomplish this.
;; Mention source, if known.
(defvar mh-invisible-header-fields-internal
  '(
    "Abuse-Reports-To:"                 ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Accept-Language:"
    "AcceptLanguage:"
    "Accreditor:"                       ; Habeas
    "Also-Control:"                     ; H. Spencer: News Article Format and Transmission, June 1994
    "Alternate-recipient:"              ; RFC 2156
    "Approved-By:"                      ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Approved:"                         ; RFC 1036
    "Article-Names:"                    ; H. Spencer: News Article Format and Transmission, June 1994
    "Article-Updates:"                  ; H. Spencer: News Article Format and Transmission, June 1994
    "Authentication-Results:"
    "Auto-forwarded:"                   ; RFC 2156
    "Autoforwarded:"                    ; RFC 2156
    "Bestservhost:"
    "Bounces-To:"
    "Bounces_to:"
    "Bytes:"
    "Cancel-Key:"                       ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Cancel-Lock:"                      ; NNTP posts
    "Comment:"                          ; Shows up with DomainKeys
    "Content-"                          ; RFC 2045, 1123, 1766, 1864, 2045, 2110, 2156, 2183, 2912
    "Control:"                          ; RFC 1036
    "Conversion-With-Loss:"             ; RFC 2156
    "Conversion:"                       ; RFC 2156
    "Delivered-To:"                     ; Egroups/yahoogroups mailing list manager
    "Delivery-Date:"                    ; RFC 2156
    "Delivery:"
    "Discarded-X400-"                   ; RFC 2156
    "Disclose-Recipients:"              ; RFC 2156
    "Disposition-Notification-Options:" ; RFC 2298
    "Disposition-Notification-To:"      ; RFC 2298
    "Distribution:"                     ; RFC 1036
    "DKIM-"                             ; https://en.wikipedia.org/wiki/DomainKeys_Identified_Mail
    "DL-Expansion-History:"             ; RFC 2156
    "DomainKey-"                        ; https://en.wikipedia.org/wiki/DomainKeys_Identified_Mail
    "DomainKey-Signature:"
    "Encoding:"                         ; RFC 1505
    "Envelope-to:"
    "Errors-To:"                        ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Expires:"                          ; RFC 1036
    "Expiry-Date:"                      ; RFC 2156
    "Face:"                             ; Gnus Face header
    "Followup-To:"                      ; RFC 1036
    "For-Approval:"                     ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "For-Comment:"                      ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "For-Handling:"                     ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Forwarded:"                        ; MH
    "From "                             ; sendmail
    "Generate-Delivery-Report:"         ; RFC 2156
    "Importance:"                       ; RFC 2156, 2421
    "In-Reply-To:"                      ; RFC 822 (or later)
    "Incomplete-Copy:"                  ; RFC 2156
    "Keywords:"                         ; RFC 822 (or later)
    "Language:"                         ; RFC 2156
    "Lines:"                            ; RFC 1036
    "List-"                             ; RFC 2369, 2919
    "Mail-Copies-To:"                   ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Mail-Followup-To:"                 ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Mail-from:"                        ; MH
    "Mail-Reply-To:"                    ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Mailing-List:"                     ; Egroups/yahoogroups mailing list manager
    "Message-Content:"                  ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Message-ID:"                       ; RFC 822 (or later)
    "Message-Type:"                     ; RFC 2156
    "Mime-Version"                      ; RFC 2045
    "Msgid:"
    "NNTP-"                             ; News
    "Obsoletes:"                        ; RFC 2156
    "Old-Return-Path:"
    "OpenPGP:"
    "Original-Encoded-Information-Types:"  ; RFC 2156
    "Original-Lines:"                   ; mail to news
    "Original-Newsgroups:"              ; mail to news
    "Original-NNTP-"                    ; mail to news
    "Original-Path:"                    ; mail to news
    "Original-Received:"                ; mail to news
    "Original-Recipient:"               ; RFC 2298
    "Original-To:"                      ; mail to news
    "Original-X-"                       ; mail to news
    "Origination-Client:"               ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Originator:"                       ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "P1-Content-Type:"                  ; X400
    "P1-Message-Id:"                    ; X400
    "P1-Recipient:"                     ; X400
    "Path:"                             ; RFC 1036
    "Pics-Label:"                       ; W3C
    "Posted-To:"                        ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Precedence:"                       ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Prev-Resent"                       ; MH
    "Prevent-NonDelivery-Report:"       ; RFC 2156
    "Priority:"                         ; RFC 2156
    "Read-Receipt-To:"                  ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Received-SPF:"                     ; Gmail
    "Received:"                         ; RFC 822 (or later)
    "References:"                       ; RFC 822 (or later)
    "Registered-Mail-Reply-Requested-By:"       ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Remailed-"                         ; MH
    "Replaces:"                         ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Replied:"                          ; MH
    "Resent-"                           ; RFC 822 (or later)
    "Return-Path:"                      ; RFC 822 (or later)
    "Return-Receipt-Requested:"         ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Return-Receipt-To:"                ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Seal-Send-Time:"
    "See-Also:"                         ; H. Spencer: News Article Format and Transmission, June 1994
    "Sensitivity:"                      ; RFC 2156, 2421
    "Speech-Act:"                       ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Status:"                           ; sendmail
    "Supersedes:"                       ; H. Spencer: News Article Format and Transmission, June 1994
    "Telefax:"                          ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Thread-"
    "Thread-Index:"
    "Thread-Topic:"
    "Translated-By:"                    ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Translation-Of:"                   ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "Ua-Content-Id:"                    ; X400
    "Via:"                              ; MH
    "X-Abuse-and-DMCA-"
    "X-Abuse-Info:"
    "X-Accept-Language:"                ; Netscape/Mozilla
    "X-Ack:"
    "X-ACL-Warn:"			; https://www.exim.org
    "X-Admin:"                          ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Administrivia-To:"
    "X-AMAZON"                          ; Amazon.com
    "X-AnalysisOut:"                    ; Exchange
    "X-AntiAbuse:"                      ; cPanel
    "X-Antivirus-Scanner:"
    "X-AOL-IP:"                         ; AOL WebMail
    "X-Apparently-From:"                ; MS Outlook
    "X-Apparently-To:"           ; Egroups/yahoogroups mailing list manager
    "X-Attribution:"
    "X-AuditID:"
    "X-Authenticated-Info:"             ; Verizon.net?
    "X-Authenticated-Sender:"           ; AT&T Message Center (webmail)
    "X-Authentication-Info:"            ; verizon.net?
    "X-Authentication-Warning:"         ; sendmail
    "X-Authority-Analysis:"
    "X-Auto-Response-Suppress:"         ; Exchange
    "X-Barracuda-"                      ; Barracuda spam scores
    "X-Bayes-Prob:"                     ; IEEE spam filter
    "X-Beenthere:"                      ; Mailman mailing list manager
    "X-BFI:"
    "X-Bigfish:"
    "X-Bogosity:"                       ; bogofilter
    "X-BPS1:"				; http://www.boggletools.com [dead link?]
    "X-BPS2:"				; http://www.boggletools.com [dead link?]
    "X-Brightmail-Tracker:"             ; Brightmail
    "X-BrightmailFiltered:"             ; Brightmail
    "X-Bugzilla-"                       ; Bugzilla
    "X-Cam-"                            ; Cambridge scanners
    "X-Campaign-Id:"
    "X-Campaign:"
    "X-Campaignid:"
    "X-CanIt-Geo:"                      ; IEEE spam filter
    "X-Cloudmark-SP-"			; Cloudmark (www.cloudmark.com)
    "X-Comment:"                        ; AT&T Mailennium
    "X-Complaints-To:"                  ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Completed:"
    "X-Confirm-Reading-To:"             ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Content-Filtered-By:"
    "X-ContentStamp:"                   ; NetZero
    "X-Country-Chain:"                  ; http://www.declude.com/x-note.htm [dead link?]
    "X-Cr-Hashedpuzzle:"
    "X-Cr-Puzzleid:"
    "X-Cron-Env:"
    "X-DCC-"                            ; SpamAssassin
    "X-Declude-"                        ; http://www.declude.com/x-note.htm [dead link?]
    "X-Dedicated:"
    "X-Delivered"
    "X-Destination-ID:"
    "X-detected-operating-system:"	; GNU.ORG?
    "X-DH-Virus-"
    "X-DMCA"
    "X-DocGen-Version:"			; DocGen
    "X-Domain:"
    "X-Echelon-Distraction"
    "X-EFL-Spamscore:"                  ; MIT alumni spam filtering
    "X-eGroups-"                        ; Egroups/yahoogroups mailing list manager
    "X-EID:"
    "X-ELNK-Trace:"                     ; Earthlink mailer
    "X-EM-"				; Some ecommerce software
    "X-Email-Type-Id:"			; Paypal https://www.paypal.com
    "X-Enigmail-Version:"
    "X-Envelope-Date:"                  ; GNU mailutils
    "X-Envelope-From:"                  ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Envelope-Sender:"
    "X-Envelope-To:"                    ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-EviteMessageId:"                 ; evite.com
    "X-Evolution:"                      ; Evolution mail client
    "X-ExtLoop"
    "X-Face:"                           ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Facebook"                        ; Facebook
    "X-FB-SS:"
    "X-fmx-"
    "X-Folder:"                         ; Spam
    "X-Forwarded-"                      ; Google+
    "X-From-Line"
    "X-FuHaFi:"				; https://www.gmx.net/
    "X-Generated-By:"                   ; launchpad.net
    "X-Gmail-"                          ; Gmail
    "X-Gnus-Mail-Source:"               ; gnus
    "X-Google-"                         ; Google mail
    "X-Google-Sender-Auth:"
    "X-Greylist:"                       ; milter-greylist-1.2.1
    "X-Habeas-"				; https://www.returnpath.net
    "X-Hashcash:"                       ; hashcash
    "X-Headers-End:"                    ; SpamCop
    "X-HPL-"
    "X-HR-"
    "X-HTTP-UserAgent:"
    "X-Hz"				; Hertz
    "X-Identity:"                       ; http://www.declude.com/x-note.htm [dead link?]
    "X-IEEE-UCE-"                       ; IEEE spam filter
    "X-Image-URL:"
    "X-IMAP:"                           ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Info:"                           ; NTMail
    "X-IronPort-"                       ; IronPort AV
    "X-ISI-4-30-3-MailScanner:"
    "X-J2-"
    "X-Jira-Fingerprint:"               ; JIRA
    "X-Junkmail-"                       ; RCN?
    "X-Juno-"                           ; Juno
    "X-Key:"
    "X-Launchpad-"                      ; plaunchpad.net
    "X-List-Host:"                      ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-List-Subscribe:"                 ; Unknown mailing list managers
    "X-List-Unsubscribe:"               ; Unknown mailing list managers
    "X-Listprocessor-"                  ; ListProc(tm) by CREN
    "X-Listserver:"                     ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Loop:"                           ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Lrde-Mailscanner:"
    "X-Lumos-SenderID:"                 ; Roving ConstantContact
    "X-mail_abuse_inquiries:"		; https://www.salesforce.com
    "X-Mail-from:"                      ; fastmail.fm
    "X-MAIL-INFO:"                      ; NetZero
    "X-Mailer_"
    "X-MailFlowPolicy:"			; Cisco Email Security (formerly IronPort; http://www.ironport.com)
    "X-Mailing-List:"                   ; Unknown mailing list managers
    "X-MailingID:"
    "X-Mailman-Approved-At:"            ; Mailman mailing list manager
    "X-Mailman-Version:"                ; Mailman mailing list manager
    "X-MailScanner"                     ; ListProc(tm) by CREN
    "X-Mailutils-Message-Id"            ; GNU Mailutils
    "X-Majordomo:"                      ; Majordomo mailing list manager
    "X-Match:"
    "X-MaxCode-Template:"		; Paypal https://www.paypal.com
    "X-MB-Message-"                     ; AOL WebMail
    "X-MDaemon-Deliver-To:"
    "X-MDRemoteIP:"
    "X-ME-Bayesian:"			; https://www.newmediadevelopment.net/page.cfm/parent/Client-Area/content/Managing-spam/
    "X-Message-Id"
    "X-Message-Type:"
    "X-MessageWall-Score:"              ; Unknown mailing list manager, AUC TeX
    "X-MHE-Checksum:"                   ; Checksum added during index search
    "X-MIME-Autoconverted:"             ; sendmail
    "X-MIMEOLE:"                        ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/sendmail
    "X-MIMETrack:"
    "X-Mms-"                            ; T-Mobile pictures
    "X-Mozilla-Status:"                 ; Netscape/Mozilla
    "X-MS-"                             ; MS Outlook
    "X-Msmail-"                         ; MS Outlook
    "X-MSMail-Priority"                 ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-MXL-Hash:"
    "X-NAI-Spam-"                       ; Network Associates Inc. SpamKiller
    "X-News:"                           ; News
    "X-Newsreader:"                     ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-No-Archive:"                     ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Notes-Item:"                     ; Lotus Notes Domino structured header
    "X-Notification-"                   ; Google+
    "X-Notifications:"                  ; Google+
    "X-OperatingSystem:"
    "X-Oracle-Calendar:"                ; Oracle calendar invitations
    "X-ORBL:"
    "X-Orcl-Content-Type:"
    "X-Organization:"
    "X-Original-Arrival-Type:"          ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Original-Complaints-To:"
    "X-Original-Date:"                  ; SourceForge mailing list manager
    "X-Original-To:"
    "X-Original-Trace:"
    "X-OriginalArrivalTime:"            ; Hotmail
    "X-Originating-Email:"              ; Hotmail
    "X-Originating-IP:"                 ; Hotmail
    "X-pair-"
    "X-PGP:"
    "X-PID:"
    "X-PMG-"
    "X-PMX-Version:"
    "X-Policyd-Weight:"                 ; policyd-weight (Postfix)
    "X-Postfilter:"
    "X-Priority:"                       ; MS Outlook
    "X-Proofpoint-"			; Proofpoint mail filter
    "X-Provags-ID:"
    "X-PSTN-"
    "X-Qotd-"                           ; User added
    "X-RCPT-TO:"                        ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Received-Date:"
    "X-Received:"
    "X-Report-Abuse-To:"                ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Request-"
    "X-Resolved-to:"                    ; fastmail.fm
    "X-Return-Path-Hint:"               ; Roving ConstantContact
    "X-RIM-"				; Research In Motion (i.e. BlackBerry)
    "X-RM"
    "X-RocketYMMF:"                     ; Yahoo
    "X-Roving-"                         ; Roving ConstantContact
    "X-SA-Exim-"                        ; Exim SpamAssassin
    "X-Sasl-enc:"                       ; Apple Mail
    "X-SBClass:"                        ; Spam
    "X-SBNote:"                         ; Spam
    "X-SBPass:"                         ; Spam
    "X-SBRS:"
    "X-SBRule:"                         ; Spam
    "X-Scanned-By:"
    "X-Sender-ID:"                      ; Google+
    "X-Sender:"                         ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Sendergroup:"			; Cisco Email Security (formerly IronPort; http://www.ironport.com)
    "X-Server-Date:"
    "X-Server-Uuid:"
    "X-Service-Code:"
    "X-SFDC-"				; https://www.salesforce.com
    "X-Sieve:"                          ; Sieve filtering
    "X-SMFBL:"
    "X-SMHeaderMap:"
    "X-SMTP-"
    "X-Source"
    "X-Spam-"                           ; SpamAssassin
    "X-Spam:"                           ; Exchange
    "X-SpamBouncer:"                    ; Spam
    "X-SPF-"
    "X-Status"
    "X-Submission-Address:"
    "X-Submissions-To:"
    "X-Sun-Charset:"
    "X-Telecom-Digest"
    "X-TM-IMSS-Message-ID:"		; https://www.trendmicro.com
    "X-Trace:"
    "X-UID"
    "X-UIDL:"                           ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-Unity"
    "X-UNTD-"                           ; NetZero
    "X-URI:"                            ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-URL:"                            ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-USANET-"                         ; usa.net
    "X-Usenet-Provider"
    "X-UserInfo1:"
    "X-VGI-OESCD:"
    "X-VirtualServer:"
    "X-VirtualServerGroup:"
    "X-Virus-"                          ;
    "X-Vms-To:"
    "X-VSMLoop:"                        ; NTMail
    "X-WebTV-Signature:"
    "X-Wss-Id:"                         ; Worldtalk gateways
    "X-X-Sender:"                       ; https://people.dsv.su.se/~jpalme/ietf/mail-headers/
    "X-XPT-XSL-Name:"			; Paypal https://www.paypal.com
    "X-xsi-"
    "X-XWALL-"				; https://www.dataenter.co.at/doc/xwall_undocumented_config.htm
    "X-Y-GMX-Trusted:"			; https://www.gmx.net/
    "X-Yahoo"
    "X-Yahoo-Newman-"
    "X-YMail-"
    "X-ZixNet:"
    "X400-"                             ; X400
    "Xref:"                             ; RFC 1036
    )
  "List of default header fields that are not to be shown.

Do not alter this variable directly. Instead, add entries from
here that you would like to be displayed in
`mh-invisible-header-fields-default' and add entries to hide in
`mh-invisible-header-fields'.")

(eval-and-compile
  (unless (fboundp 'mh-invisible-headers)
    (defun mh-invisible-headers ()
      "Temporary definition.
Real definition, below, uses variables that aren't defined yet."
      nil)))

(defcustom mh-invisible-header-fields nil
  "Additional header fields to hide.

Header fields that you would like to hide that aren't listed in
`mh-invisible-header-fields-default' can be added to this option
with a couple of caveats. Regular expressions are not allowed.
Unique fields should have a \":\" suffix; otherwise, the element
can be used to render invisible an entire class of fields that
start with the same prefix.

If you think a header field should be generally ignored, please
update SF #1916032 (see URL
`https://sourceforge.net/tracker/index.php?func=detail&aid=1916032&group_id=13357&atid=113357').

See also `mh-clean-message-header-flag'."

  :type '(repeat (string :tag "Header field"))
  :set (lambda (symbol value)
         (set-default symbol value)
         (mh-invisible-headers))
  :group 'mh-show
  :package-version '(MH-E . "7.1"))

(defcustom mh-invisible-header-fields-default nil
  "List of hidden header fields.

The header fields listed in this option are hidden, although you
can check off any field that you would like to see.

Header fields that you would like to hide that aren't listed can
be added to the option `mh-invisible-header-fields'.

See also `mh-clean-message-header-flag'.

If you think a header field should be added to this list, please
update SF #1916032 (see URL
`https://sourceforge.net/tracker/index.php?func=detail&aid=1916032&group_id=13357&atid=113357')."
  :type `(set ,@(mapcar (lambda (x) `(const ,x))
                        mh-invisible-header-fields-internal))
  :set (lambda (symbol value)
         (set-default symbol value)
         (mh-invisible-headers))
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defvar mh-invisible-header-fields-compiled nil
  "Regexp matching lines in a message header that are not to be shown.
Do not alter this variable directly. Instead, customize
`mh-invisible-header-fields-default' checking for fields normally
hidden that you wish to display, and add extra entries to hide in
`mh-invisible-header-fields'.")

(defun mh-invisible-headers ()
  "Make or remake the variable `mh-invisible-header-fields-compiled'.
Done using `mh-invisible-header-fields-internal' as input, from
which entries from `mh-invisible-header-fields-default' are
removed and entries from `mh-invisible-header-fields' are added."
  (let ((fields mh-invisible-header-fields-internal))
    (when mh-invisible-header-fields-default
      ;; Remove entries from `mh-invisible-header-fields-default'
      (setq fields
            (cl-loop for x in fields
                     unless (member x mh-invisible-header-fields-default)
                     collect x)))
    (when (and (boundp 'mh-invisible-header-fields)
               mh-invisible-header-fields)
      (dolist (x mh-invisible-header-fields)
        (unless (member x fields) (setq fields (cons x fields)))))
    (if fields
        (setq mh-invisible-header-fields-compiled
              (concat
               "^"
               (regexp-opt fields t)))
      (setq mh-invisible-header-fields-compiled nil))))

;; Compile invisible header fields.
(mh-invisible-headers)

(defcustom mh-lpr-command-format "lpr -J '%s'"
  "Command used to print\\<mh-folder-mode-map>.

This option contains the Unix command line which performs the
actual printing for the \\[mh-print-msg] command. The string can
contain one escape, \"%s\", which is replaced by the name of the
folder and the message number and is useful for print job names.
I use \"mpage -h\\='%s\\=' -b Letter -H1of -mlrtb -P\" which produces a
nice header and adds a bit of margin so the text fits within my
printer's margins.

This option is not used by the commands \\[mh-ps-print-msg] or
\\[mh-ps-print-msg-file]."
  :type 'string
  :group 'mh-show
  :package-version '(MH-E . "6.0"))

(defcustom mh-max-inline-image-height nil
  "Maximum inline image height if \"Content-Disposition:\" is not present.

Some older mail programs do not insert this needed plumbing to
tell MH-E whether to display the attachments inline or not. If
this is the case, MH-E will display these images inline if they
are smaller than the window. However, you might want to allow
larger images to be displayed inline. To do this, you can change
the options `mh-max-inline-image-width' and
`mh-max-inline-image-height' from their default value of zero to
a large number. The size of your screen is a good choice for
these numbers."
  :type '(choice (const nil) integer)
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-max-inline-image-width nil
  "Maximum inline image width if \"Content-Disposition:\" is not present.

Some older mail programs do not insert this needed plumbing to
tell MH-E whether to display the attachments inline or not. If
this is the case, MH-E will display these images inline if they
are smaller than the window. However, you might want to allow
larger images to be displayed inline. To do this, you can change
the options `mh-max-inline-image-width' and
`mh-max-inline-image-height' from their default value of zero to
a large number. The size of your screen is a good choice for
these numbers."
  :type '(choice (const nil) integer)
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-mhl-format-file nil
  "Specifies the format file to pass to the \"mhl\" program.

Normally MH-E takes care of displaying messages itself (rather than
calling an MH program to do the work). If you'd rather have \"mhl\"
display the message (within MH-E), change this option from its default
value of \"Use Default mhl Format (Printing Only)\".

You can set this option to \"Use Default mhl Format\" to get the same
output as you would get if you ran \"mhl\" from the shell.

If you have a format file that you want MH-E to use, you can set this
option to \"Specify an mhl Format File\" and enter the name of your
format file. Your format file should specify a non-zero value for
\"overflowoffset\" to allow MH-E to parse the header. Note that
\"mhl\" is always used for printing and forwarding; in this case, the
value of this option is consulted if you have specified a format
file."
  :type '(choice (const :tag "Use Default mhl Format (Printing Only)" nil)
                 (const :tag "Use Default mhl Format" t)
                 (file :tag "Specify an mhl Format File"))
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defcustom mh-mime-save-parts-default-directory t
  "Default directory to use for \\<mh-folder-mode-map>\\[mh-mime-save-parts].

The default value for this option is \"Prompt Always\" so that
you are always prompted for the directory in which to save the
attachments. However, if you usually use the same directory
within a session, then you can set this option to \"Prompt the
First Time\" to avoid the prompt each time. you can make this
directory permanent by choosing \"Directory\" and entering the
directory's name."
  :type '(choice (const :tag "Prompt the First Time" nil)
                 (const :tag "Prompt Always" t)
                 directory)
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-print-background-flag nil
  "Non-nil means messages should be printed in the background\\<mh-folder-mode-map>.

Normally messages are printed in the foreground. If this is slow on
your system, you may elect to turn off this option to print in the
background.

WARNING: If you do this, do not delete the message until it is printed
or else the output may be truncated.

This option is not used by the commands \\[mh-ps-print-msg] or
\\[mh-ps-print-msg-file]."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-show-maximum-size 0
  "Maximum size of message (in bytes) to display automatically.

This option provides an opportunity to skip over large messages
which may be slow to load. The default value of 0 means that all
message are shown regardless of size."
  :type 'integer
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defcustom mh-show-use-xface-flag (>= emacs-major-version 21)
  "Non-nil means display face images in MH-show buffers.

MH-E can display the content of \"Face:\", \"X-Face:\", and
\"X-Image-URL:\" header fields. If any of these fields occur in the
header of your message, the sender's face will appear in the \"From:\"
header field. If more than one of these fields appear, then the first
field found in the order \"Face:\", \"X-Face:\", and \"X-Image-URL:\"
will be used.

The option `mh-show-use-xface-flag' is used to turn this feature on
and off. This feature will be turned on by default if your system
supports it.

The first header field used, if present, is the Gnus-specific
\"Face:\" field. The \"Face:\" field appeared in Emacs 21.
For more information, see URL
`https://quimby.gnus.org/circus/face/'. Next is the traditional
\"X-Face:\" header field. The display of this field requires the
\"uncompface\" program (see URL
`ftp://ftp.cs.indiana.edu/pub/faces/compface/compface.tar.z').

Finally, MH-E will display images referenced by the \"X-Image-URL:\"
header field if neither the \"Face:\" nor the \"X-Face:\" fields are
present. The display of the images requires \"wget\" (see URL
`https://www.gnu.org/software/wget/wget.html'), \"fetch\", or \"curl\"
to fetch the image and the \"convert\" program from the ImageMagick
suite (see URL `https://www.imagemagick.org/'). Of the three header
fields this is the most efficient in terms of network usage since the
image doesn't need to be transmitted with every single mail.

The option `mh-fetch-x-image-url' controls the fetching of the
\"X-Image-URL:\" header field image."
  :type 'boolean
  :group 'mh-show
  :package-version '(MH-E . "7.0"))

(defcustom mh-store-default-directory nil
  "Default directory for \\<mh-folder-mode-map>\\[mh-store-msg].

If you would like to change the initial default directory,
customize this option, change the value from \"Current\" to
\"Directory\", and then enter the name of the directory for storing
the content of these messages."
  :type '(choice (const :tag "Current" nil)
                 directory)
  :group 'mh-show
  :package-version '(MH-E . "6.0"))

(defcustom mh-summary-height nil
  "Number of lines in MH-Folder buffer (including the mode line).

The default value of this option is \"Automatic\" which means
that the MH-Folder buffer will maintain the same proportional
size if the frame is resized. If you'd prefer a fixed height,
then choose the \"Fixed Size\" option and enter the number of
lines you'd like to see."
  :type '(choice (const :tag "Automatic" nil)
                 (integer :tag "Fixed Size"))
  :group 'mh-show
  :package-version '(MH-E . "7.4"))

;;; The Speedbar (:group 'mh-speedbar)

(defcustom mh-speed-update-interval 60
  "Time between speedbar updates in seconds.
Set to 0 to disable automatic update."
  :type 'integer
  :group 'mh-speedbar
  :package-version '(MH-E . "8.0"))

;;; Threading (:group 'mh-thread)

(defcustom mh-show-threads-flag nil
  "Non-nil means new folders start in threaded mode.

Threading large number of messages can be time consuming so this
option is turned off by default. If you turn this option on, then
threading will be done only if the number of messages being
threaded is less than `mh-large-folder'."
  :type 'boolean
  :group 'mh-thread
  :package-version '(MH-E . "7.1"))

;;; The Tool Bar (:group 'mh-tool-bar)

;; mh-tool-bar-folder-buttons and mh-tool-bar-letter-buttons defined
;; dynamically in mh-tool-bar.el.

(defcustom mh-tool-bar-search-function 'mh-search
  "Function called by the tool bar search button.

By default, this is set to `mh-search'. You can also choose
\"Other Function\" from the \"Value Menu\" and enter a function
of your own choosing."
  :type '(choice (const mh-search)
                 (function :tag "Other Function"))
  :group 'mh-tool-bar
  :package-version '(MH-E . "7.0"))



;;; Hooks (:group 'mh-hooks + group where hook described)

(defcustom mh-after-commands-processed-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-execute-commands] after performing outstanding refile and delete requests.

Variables that are useful in this hook include
`mh-folders-changed', which lists which folders were affected by
deletes and refiles. This list will always include the current
folder, which is also available in `mh-current-folder'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defcustom mh-alias-reloaded-hook nil
  "Hook run by `mh-alias-reload' after loading aliases."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-alias
  :package-version '(MH-E . "8.0"))

(defcustom mh-annotate-msg-hook nil
  "Hook run when a message is sent and after annotating the scan lines and message.
Hook functions can access the current folder name with
`mh-current-folder' and obtain the message numbers of the
annotated messages with `mh-annotate-list'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-sending-mail
  :package-version '(MH-E . "8.1"))

(defcustom mh-before-commands-processed-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-execute-commands] before performing outstanding refile and delete requests.

Variables that are useful in this hook include `mh-delete-list',
`mh-refile-list', `mh-blocklist', and `mh-allowlist' which can be
used to see which changes will be made to the current folder,
`mh-current-folder'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defcustom mh-before-quit-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-quit] before quitting MH-E.

This hook is called before the quit occurs, so you might use it
to perform any MH-E operations; you could perform some query and
abort the quit or call `mh-execute-commands', for example.

See also `mh-quit-hook'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "6.0"))

(defcustom mh-before-send-letter-hook nil
  "Hook run at the beginning of the \\<mh-letter-mode-map>\\[mh-send-letter] command.

For example, if you want to check your spelling in your message
before sending, add the `ispell-message' function."
  :type 'hook
  :options '(ispell-message)
  :group 'mh-hooks
  :group 'mh-letter
  :package-version '(MH-E . "6.0"))

(defcustom mh-blocklist-msg-hook nil
  "Hook run by \\<mh-letter-mode-map>\\[mh-junk-blocklist] after marking each message for blocklisting."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-show
  :package-version '(MH-E . "8.4"))

(defcustom mh-delete-msg-hook nil
  "Hook run by \\<mh-letter-mode-map>\\[mh-delete-msg] after marking each message for deletion.

For example, a past maintainer of MH-E used this once when he
kept statistics on his mail usage."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-show
  :package-version '(MH-E . "6.0"))

(defcustom mh-find-path-hook nil
  "Hook run by `mh-find-path' after reading the user's MH profile.

This hook can be used the change the value of the variables that
`mh-find-path' sets if you need to run with different values
between MH and MH-E."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-e
  :package-version '(MH-E . "7.0"))

(defcustom mh-folder-mode-hook nil
  "Hook run by `mh-folder-mode' when visiting a new folder."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "6.0"))

(defcustom mh-forward-hook nil
  "Hook run by `mh-forward' on a forwarded letter."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-sending-mail
  :package-version '(MH-E . "8.0"))

(defcustom mh-inc-folder-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-inc-folder] after incorporating mail into a folder."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-inc
  :package-version '(MH-E . "6.0"))

(defcustom mh-insert-signature-hook nil
  "Hook run by \\<mh-letter-mode-map>\\[mh-insert-signature] after signature has been inserted.

Hook functions may access the actual name of the file or the
function used to insert the signature with
`mh-signature-file-name'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-letter
  :package-version '(MH-E . "8.0"))

(defcustom mh-kill-folder-suppress-prompt-functions '(mh-search-p)
  "Abnormal hook run at the beginning of \\<mh-folder-mode-map>\\[mh-kill-folder].

The hook functions are called with no arguments and should return
a non-nil value to suppress the normal prompt when you remove a
folder. This is useful for folders that are easily regenerated.

The default value of `mh-search-p' suppresses the prompt on
folders generated by searching.

WARNING: Use this hook with care. If there is a bug in your hook
which returns t on \"+inbox\" and you hit \\[mh-kill-folder] by
accident in the \"+inbox\" folder, you will not be happy."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "7.4"))

(defcustom mh-letter-mode-hook nil
  "Hook run by `mh-letter-mode' on a new letter.

This hook allows you to do some processing before editing a
letter. For example, you may wish to modify the header after
\"repl\" has done its work, or you may have a complicated
\"components\" file and need to tell MH-E where the cursor should
go."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-sending-mail
  :package-version '(MH-E . "6.0"))

(defcustom mh-mh-to-mime-hook nil
  "Hook run on the formatted letter by \\<mh-letter-mode-map>\\[mh-mh-to-mime]."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-letter
  :package-version '(MH-E . "8.0"))

(defcustom mh-search-mode-hook nil
  "Hook run upon entry to `mh-search-mode'\\<mh-folder-mode-map>.

If you find that you do the same thing over and over when editing
the search template, you may wish to bind some shortcuts to keys.
This can be done with this hook which is called when
\\[mh-search] is run on a new pattern."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-search
  :package-version '(MH-E . "8.0"))

(defcustom mh-pack-folder-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-pack-folder] after renumbering the messages.
Hook functions can access the current folder name with `mh-current-folder'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "8.2"))

(defcustom mh-quit-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-quit] after quitting MH-E.

This hook is not run in an MH-E context, so you might use it to
modify the window setup.

See also `mh-before-quit-hook'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "6.0"))

(defcustom mh-refile-msg-hook nil
  "Hook run by \\<mh-folder-mode-map>\\[mh-refile-msg] after marking each message for refiling."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-folder
  :package-version '(MH-E . "6.0"))

(defcustom mh-show-hook nil
  "Hook run after \\<mh-folder-mode-map>\\[mh-show] shows a message.

It is the last thing called after messages are displayed. It's
used to affect the behavior of MH-E in general or when
`mh-show-mode-hook' is too early. See `mh-show-mode-hook'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-show
  :package-version '(MH-E . "6.0"))

(defcustom mh-show-mode-hook nil
  "Hook run upon entry to `mh-show-mode'.

This hook is called early on in the process of the message display,
before the message contents have been inserted into the buffer.
It is usually used to perform some action on the
buffer itself. See also `mh-show-hook'."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-show
  :package-version '(MH-E . "8.7"))

(defcustom mh-unseen-updated-hook nil
  "Hook run after the unseen sequence has been updated.

The variable `mh-seen-list' can be used by this hook to obtain
the list of messages which were removed from the unseen
sequence."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-sequences
  :package-version '(MH-E . "6.0"))

(defcustom mh-allowlist-msg-hook nil
  "Hook run by \\<mh-letter-mode-map>\\[mh-junk-allowlist] after marking each message for allowlisting."
  :type 'hook
  :group 'mh-hooks
  :group 'mh-show
  :package-version '(MH-E . "8.4"))



;;; Faces (:group 'mh-faces + group where faces described)

;; To add a new face:
;; 1. Add entry to variable mh-face-data.
;; 2. Create face using defface, accessing face data with function
;;    mh-face-data.
;; 3. Add inherit argument to function mh-face-data if applicable.
(defvar mh-face-data
  '((mh-folder-followup
     ((((class color) (background light))
       (:foreground "blue3"))
      (((class color) (background dark))
       (:foreground "LightGoldenRod"))
      (t
       (:weight bold))))
    (mh-folder-msg-number
     ((((class color) (min-colors 64) (background light))
       (:foreground "snow4"))
      (((class color) (min-colors 64) (background dark))
       (:foreground "snow3"))
      (((class color) (background light))
       (:foreground "purple"))
      (((class color) (background dark))
       (:foreground "cyan"))))
    (mh-folder-refiled
     ((((class color) (min-colors 64) (background light))
       (:foreground "DarkGoldenrod"))
      (((class color) (min-colors 64) (background dark))
       (:foreground "LightGoldenrod"))
      (((class color))
       (:foreground "yellow" :weight light))
      (((class grayscale) (background light))
       (:foreground "Gray90" :weight bold :slant italic))
      (((class grayscale) (background dark))
       (:foreground "DimGray" :weight bold :slant italic))
      (t
       (:weight bold :slant italic))))
    (mh-folder-subject
     ((((class color) (background light))
       (:foreground "blue4"))
      (((class color) (background dark))
       (:foreground "yellow"))
      (t
       (:weight bold))))
    (mh-folder-tick
     ((((class color) (background light))
       (:background "#dddf7e"))
      (((class color) (background dark))
       (:background "#dddf7e"))
      (t
       (:underline t))))
    (mh-folder-to
     ((((class color) (min-colors 64) (background light))
       (:foreground "RosyBrown"))
      (((class color) (min-colors 64) (background dark))
       (:foreground "LightSalmon"))
      (((class color))
       (:foreground "green"))
      (((class grayscale) (background light))
       (:foreground "DimGray" :slant italic))
      (((class grayscale) (background dark))
       (:foreground "LightGray" :slant italic))
      (t
       (:slant italic))))
    (mh-letter-header-field
     ((((class color) (background light))
       (:background "gray90"))
      (((class color) (background dark))
       (:background "gray10"))
      (t
       (:weight bold))))
    (mh-search-folder
     ((((class color) (background light))
       (:foreground "dark green" :weight bold))
      (((class color) (background dark))
       (:foreground "indian red" :weight bold))
      (t
       (:weight bold))))
    (mh-show-cc
     ((((class color) (min-colors 64) (background light))
       (:foreground "DarkGoldenrod"))
      (((class color) (min-colors 64) (background dark))
       (:foreground "LightGoldenrod"))
      (((class color))
       (:foreground "yellow" :weight light))
      (((class grayscale) (background light))
       (:foreground "Gray90" :weight bold :slant italic))
      (((class grayscale) (background dark))
       (:foreground "DimGray" :weight bold :slant italic))
      (t
       (:weight bold :slant italic))))
    (mh-show-date
     ((((class color) (min-colors 64) (background light))
       (:foreground "ForestGreen"))
      (((class color) (min-colors 64) (background dark))
       (:foreground "PaleGreen"))
      (((class color))
       (:foreground "green"))
      (((class grayscale) (background light))
       (:foreground "Gray90" :weight bold))
      (((class grayscale) (background dark))
       (:foreground "DimGray" :weight bold))
      (t
       (:weight bold :underline t))))
    (mh-show-from
     ((((class color) (background light))
       (:foreground "red3"))
      (((class color) (background dark))
       (:foreground "cyan"))
      (t
       (:weight bold))))
    (mh-show-header
     ((((class color) (min-colors 64) (background light))
       (:foreground "RosyBrown"))
      (((class color) (min-colors 64) (background dark))
       (:foreground "LightSalmon"))
      (((class color))
       (:foreground "green"))
      (((class grayscale) (background light))
       (:foreground "DimGray" :slant italic))
      (((class grayscale) (background dark))
       (:foreground "LightGray" :slant italic))
      (t
       (:slant italic))))
    (mh-show-pgg-bad ((t (:weight bold :foreground "DeepPink1"))))
    (mh-show-pgg-good ((t (:weight bold :foreground "LimeGreen"))))
    (mh-show-pgg-unknown ((t (:weight bold :foreground "DarkGoldenrod2"))))
    (mh-show-signature ((t (:slant italic))))
    (mh-show-to
     ((((class color) (background light))
       (:foreground "SaddleBrown"))
      (((class color) (background dark))
       (:foreground "burlywood"))
      (((class grayscale) (background light))
       (:foreground "DimGray" :underline t))
      (((class grayscale) (background dark))
       (:foreground "LightGray" :underline t))
      (t (:underline t))))
    (mh-speedbar-folder
     ((((class color) (background light))
       (:foreground "blue4"))
      (((class color) (background dark))
       (:foreground "light blue"))))
    (mh-speedbar-selected-folder
     ((((class color) (background light))
       (:foreground "red1" :underline t))
      (((class color) (background dark))
       (:foreground "red1" :underline t))
      (t
       (:underline t)))))
  "MH-E face data.
Used by function `mh-face-data' which returns spec that is
consumed by `defface'.")

(require 'cus-face)

(defvar mh-inherit-face-flag t
  "Non-nil means that the `defface' :inherit keyword is available.")
(make-obsolete-variable 'mh-inherit-face-flag nil "29.1")

(defvar mh-min-colors-defined-flag t
  "Non-nil means `defface' supports min-colors display requirement.")
(make-obsolete-variable 'mh-min-colors-defined-flag nil "29.1")

(defun mh-face-data (face &optional inherit)
  "Return spec for FACE.
See `defface' for the spec definition.

If INHERIT is non-nil and `defface' supports the :inherit
keyword, return INHERIT literally; otherwise, return spec for
FACE from the variable `mh-face-data'. This isn't a perfect
implementation. In the case that the :inherit keyword is not
supported, any additional attributes in the inherit parameter are
not added to the returned spec."
  (or inherit
      (cadr (assq face mh-face-data))
      (error "Could not find %s in mh-face-data" face)))

(defface mh-folder-address
  (mh-face-data 'mh-folder-subject '((t (:inherit mh-folder-subject))))
  "Recipient face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-blocklisted
  (mh-face-data 'mh-folder-msg-number '((t (:inherit mh-folder-msg-number))))
  "Blocklisted message face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.4"))

(defface mh-folder-body
  (mh-face-data 'mh-folder-msg-number
                '((((class color))
                   (:inherit mh-folder-msg-number))
                  (t
                   (:inherit mh-folder-msg-number :slant italic))))
  "Body text face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-cur-msg-number
  (mh-face-data 'mh-folder-msg-number
                '((t (:inherit mh-folder-msg-number :weight bold))))
  "Current message number face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-date
  (mh-face-data 'mh-folder-msg-number '((t (:inherit mh-folder-msg-number))))
  "Date face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-deleted
  (mh-face-data 'mh-folder-msg-number '((t (:inherit mh-folder-msg-number))))
  "Deleted message face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-followup (mh-face-data 'mh-folder-followup)
  "\"Re:\" face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-msg-number (mh-face-data 'mh-folder-msg-number)
  "Message number face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-refiled (mh-face-data 'mh-folder-refiled)
  "Refiled message face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-sent-to-me-hint
  (mh-face-data 'mh-folder-msg-number '((t (:inherit mh-folder-date))))
  "Fontification hint face in messages sent directly to us.
The detection of messages sent to us is governed by the scan
format `mh-scan-format-nmh' and the regular expression
`mh-scan-sent-to-me-sender-regexp'."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-sent-to-me-sender
  (mh-face-data 'mh-folder-followup '((t (:inherit mh-folder-followup))))
  "Sender face in messages sent directly to us.
The detection of messages sent to us is governed by the scan
format `mh-scan-format-nmh' and the regular expression
`mh-scan-sent-to-me-sender-regexp'."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-subject (mh-face-data 'mh-folder-subject)
  "Subject face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-tick (mh-face-data 'mh-folder-tick)
  "Ticked message face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-to (mh-face-data 'mh-folder-to)
  "\"To:\" face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.0"))

(defface mh-folder-allowlisted
  (mh-face-data 'mh-folder-refiled '((t (:inherit mh-folder-refiled))))
  "Allowlisted message face."
  :group 'mh-faces
  :group 'mh-folder
  :package-version '(MH-E . "8.4"))

(defface mh-letter-header-field (mh-face-data 'mh-letter-header-field)
  "Editable header field value face in draft buffers."
  :group 'mh-faces
  :group 'mh-letter
  :package-version '(MH-E . "8.0"))

(defface mh-search-folder (mh-face-data 'mh-search-folder)
  "Folder heading face in MH-Folder buffers created by searches."
  :group 'mh-faces
  :group 'mh-search
  :package-version '(MH-E . "8.0"))

(defface mh-show-cc (mh-face-data 'mh-show-cc)
  "Face used to highlight \"cc:\" header fields."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-date (mh-face-data 'mh-show-date)
  "Face used to highlight \"Date:\" header fields."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-from (mh-face-data 'mh-show-from)
  "Face used to highlight \"From:\" header fields."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-header (mh-face-data 'mh-show-header)
  "Face used to deemphasize less interesting header fields."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-pgg-bad (mh-face-data 'mh-show-pgg-bad)
  "Bad PGG signature face."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-pgg-good (mh-face-data 'mh-show-pgg-good)
  "Good PGG signature face."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-pgg-unknown (mh-face-data 'mh-show-pgg-unknown)
  "Unknown or untrusted PGG signature face."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-signature (mh-face-data 'mh-show-signature)
  "Signature face."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-subject
  (mh-face-data 'mh-folder-subject '((t (:inherit mh-folder-subject))))
  "Face used to highlight \"Subject:\" header fields."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-to (mh-face-data 'mh-show-to)
  "Face used to highlight \"To:\" header fields."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-show-xface
  (mh-face-data 'mh-show-from '((t (:inherit (mh-show-from highlight)))))
"X-Face image face.
The background and foreground are used in the image."
  :group 'mh-faces
  :group 'mh-show
  :package-version '(MH-E . "8.0"))

(defface mh-speedbar-folder (mh-face-data 'mh-speedbar-folder)
  "Basic folder face."
  :group 'mh-faces
  :group 'mh-speedbar
  :package-version '(MH-E . "8.0"))

(defface mh-speedbar-folder-with-unseen-messages
  (mh-face-data 'mh-speedbar-folder
                '((t (:inherit mh-speedbar-folder :weight bold))))
  "Folder face when folder contains unread messages."
  :group 'mh-faces
  :group 'mh-speedbar
  :package-version '(MH-E . "8.0"))

(defface mh-speedbar-selected-folder
  (mh-face-data 'mh-speedbar-selected-folder)
  "Selected folder face."
  :group 'mh-faces
  :group 'mh-speedbar
  :package-version '(MH-E . "8.0"))

(defface mh-speedbar-selected-folder-with-unseen-messages
  (mh-face-data 'mh-speedbar-selected-folder
                '((t (:inherit mh-speedbar-selected-folder :weight bold))))
  "Selected folder face when folder contains unread messages."
  :group 'mh-faces
  :group 'mh-speedbar
  :package-version '(MH-E . "8.0"))

(provide 'mh-e)

;; Local Variables:
;; sentence-end-double-space: nil
;; End:

;;; mh-e.el ends here
