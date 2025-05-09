;;; srecode/table.el --- Tables of Semantic Recoders  -*- lexical-binding: t; -*-

;; Copyright (C) 2007-2025 Free Software Foundation, Inc.

;; Author: Eric M. Ludlam <zappo@gnu.org>

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
;;
;; Semantic Recoder tables manage lists of templates and the major
;; modes they are associated with.
;;

(require 'eieio)
(require 'cl-generic)
(require 'eieio-base)
(require 'mode-local)
(require 'srecode)

(declare-function srecode-load-tables-for-mode "srecode/find")
(declare-function srecode-template-table-in-project-p "srecode/find")

;;; Code:

;;; TEMPLATE TABLE
;;
(defclass srecode-template-table ()
  (;;
   ;; Raw file tracking
   ;;
   (file :initarg :file
	 :type string
	 :documentation
	 "The name of the file this table was built from.")
   (filesize :initarg :filesize
	     :type number
	     :documentation
	     "The size of the file when it was parsed.")
   (filedate :initarg :filedate
	     :type cons
	     :documentation
	     "Date from the inode of the file when it was last edited.
Format is from the `file-attributes' function.")
   (major-mode :initarg :major-mode
	       :documentation
	       "The major mode this table of templates is associated with.")
   ;;
   ;; Template file sorting data
   ;;
   (application :initarg :application
		:type symbol
		:documentation
		"Tracks the name of the application these templates belong to.
If this is nil, then this template table belongs to a set of generic
templates that can be used with no additional dictionary values.
When it is non-nil, it is assumed the template macros need specialized
Emacs Lisp code to fill in the dictionary.")
   (framework :initarg :framework
	      :type symbol
	      :documentation
	      "Tracks the name of the framework these templates belong to.
If nil, then this template table belongs to any framework, or can be
considered generic for all files of this language.
A framework might be a specific library or build environment for which
special templates are desired.  OpenGL might be a framework that
exists for multiple languages.")
   (priority :initarg :priority
	     :type number
	     :documentation
	     "For file of this Major Mode, what is the priority of this file.
When there are multiple template files with similar names, templates with
the highest priority are scanned last, allowing them to override values in
previous template files.")
   (project :initarg :project
	    :type (or null string)
	    :documentation
	    "Scope some project files to a specific project.
The value is a directory which forms the root of a particular project,
or a subset of a particular project.")
   ;;
   ;; Parsed Data from the template file
   ;;
   (templates :initarg :templates
	      :type list
	      :documentation
	      "The list of templates compiled into this table.")
   (namehash :initarg :namehash
	     :documentation
	     "Hash table containing the names of all the templates.")
   (contexthash :initarg :contexthash
		:documentation
		"")
   (variables :initarg :variables
	      :documentation
	      "AList of variables.
These variables are used to initialize dictionaries.")
   )
  "Semantic recoder template table.
A Table contains all templates from a single .srt file.
Tracks various lookup hash tables.")

;;; MODE TABLE
;;
(defvar srecode-mode-table-list nil
  "List of all the SRecode mode table classes that have been built.")

(defclass srecode-mode-table (eieio-instance-tracker)
   ((tracking-symbol :initform 'srecode-mode-table-list)
    (major-mode :initarg :major-mode
		:documentation
		"Table of template tables for this major-mode.")
    (modetables :initarg :modetables
		:documentation
		"All that tables unique to this major mode.")
    (tables :initarg :tables
	    :documentation
	    "All the tables that can be used for this major mode.")
    )
   "Track template tables for a particular major mode.
Tracks all the template-tables for a specific major mode.")

(defun srecode-get-mode-table (mode)
  "Get the SRecoder mode table for the major mode MODE.
This will find the mode table specific to MODE, and then
calculate all inherited templates from parent modes."
  (let ((table nil))
    (dolist (mode (derived-mode-all-parents mode))
      (let ((tmptable (eieio-instance-tracker-find
		       mode 'major-mode 'srecode-mode-table-list)))
	(when tmptable
	  (if (not table)
	      (progn
	        ;; If this is the first, update tables to have
	        ;; all the mode specific tables in it.
	        (setq table tmptable)
	        (oset table tables (oref table modetables)))
	    ;; If there already is a table, then reset the tables
	    ;; slot to include all the tables belonging to this new child node.
	    (oset table tables (append (oref table modetables)
				       (oref tmptable modetables)))))
	))
    table))

(defun srecode-make-mode-table (mode)
  "Get the SRecoder mode table for the major mode MODE."
  (let ((old (eieio-instance-tracker-find
	      mode 'major-mode 'srecode-mode-table-list)))
    (or old
	(let* ((new (srecode-mode-table :major-mode mode
				        :modetables nil
				        :tables nil)))
	  ;; Save this new mode table in that mode's variable.
	  (eval `(setq-mode-local ,mode srecode-table ,new) t)

	  new))))

(cl-defmethod srecode-mode-table-find ((mt srecode-mode-table) file)
  "Look in the mode table MT for a template table from FILE.
Return nil if there was none."
  (object-assoc file 'file (oref mt modetables)))

(defun srecode-mode-table-new (mode file &rest init)
  "Create a new template table for MODE in FILE.
INIT are the initialization parameters for the new template table."
  (let* ((mt (srecode-make-mode-table mode))
	 (old (srecode-mode-table-find mt file))
	 (attr (file-attributes file))
	 (new (apply #'srecode-template-table
		     :file file
		     :filesize (file-attribute-size attr)
		     :filedate (file-attribute-modification-time attr)
		     :major-mode mode
		     init
		     )))
    ;; Whack the old table.
    (when old (object-remove-from-list mt 'modetables old))
    ;; Add the new table
    (object-add-to-list mt 'modetables new)
    ;; Sort the list in reverse order.  When other routines
    ;; go front-to-back, the highest priority items are put
    ;; into the search table first, allowing lower priority items
    ;; to be the items found in the search table.
    (srecode-object-sort-list mt 'modetables (lambda (a b)
                                               (> (oref a priority)
                                                  (oref b priority))))
    ;; Return it.
    new))

(defun srecode-object-sort-list (object slot predicate)
  "Sort the items in OBJECT's SLOT.
Use PREDICATE is the same as for the `sort' function."
  (when (slot-boundp object slot)
    (when (listp (eieio-oref object slot))
      (eieio-oset object slot (sort (eieio-oref object slot) predicate)))))

;;; DEBUG
;;
;; Dump out information about the current srecoder compiled templates.
;;
(defun srecode-dump-templates (mode)
  "Dump a list of the current templates for MODE."
  (interactive "sMode: ")
  (require 'srecode/find)
  (let ((modesym (cond ((string= mode "")
			major-mode)
		       ((not (string-match "-mode" mode))
			(intern-soft (concat mode "-mode")))
		       (t
			(intern-soft mode)))))
    (srecode-load-tables-for-mode modesym)
    (let ((tmp (srecode-get-mode-table modesym))
	  )
      (if (not tmp)
	  (error "No table found for mode %S" modesym))
      (with-output-to-temp-buffer "*SRECODE DUMP*"
	(srecode-dump tmp))
      )))

(cl-defmethod srecode-dump ((tab srecode-mode-table))
  "Dump the contents of the SRecode mode table TAB."
  (princ "MODE TABLE FOR ")
  (princ (oref tab major-mode))
  (princ "\n--------------------------------------------\n\nNumber of tables: ")
  (let ((subtab (oref tab tables)))
    (princ (length subtab))
    (princ "\n\n")
    (while subtab
      (srecode-dump (car subtab))
      (setq subtab (cdr subtab)))
    ))

(cl-defmethod srecode-dump ((tab srecode-template-table))
  "Dump the contents of the SRecode template table TAB."
  (princ "Template Table for ")
  (princ (eieio-object-name-string tab))
  (princ "\nPriority: ")
  (prin1 (oref tab priority))
  (when (oref tab application)
    (princ "\nApplication: ")
    (princ (oref tab application)))
  (when (oref tab framework)
    (princ "\nFramework: ")
    (princ (oref tab framework)))
  (when (oref tab project)
    (require 'srecode/find) ; For srecode-template-table-in-project-p
    (princ "\nProject Directory: ")
    (princ (oref tab project))
    (when (not (srecode-template-table-in-project-p tab))
      (princ "\n   ** Not Usable in this file. **")))
  (princ "\n\nVariables:\n")
  (let ((vars (oref tab variables)))
    (while vars
      (princ (car (car vars)))
      (princ "\t")
      (if (< (length (car (car vars))) 9)
	  (princ "\t"))
      (prin1 (cdr (car vars)))
      (princ "\n")
      (setq vars (cdr vars))))
  (princ "\n\nTemplates:\n")
  (let ((temp (oref tab templates)))
    (while temp
      (srecode-dump (car temp))
      (setq temp (cdr temp))))
  )

(define-obsolete-function-alias 'object-sort-list
  #'srecode-object-sort-list "29.1")

(provide 'srecode/table)

;;; srecode/table.el ends here
