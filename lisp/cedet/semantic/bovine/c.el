;;; semantic/bovine/c.el --- Semantic details for C  -*- lexical-binding: t; -*-

;; Copyright (C) 1999-2025 Free Software Foundation, Inc.

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
;; Support for the C/C++ bovine parser for Semantic.
;;
;; @todo - can I support c++-font-lock-extra-types ?

(require 'semantic)
(require 'semantic/analyze)
(require 'semantic/analyze/refs)
(require 'semantic/bovine)
(require 'semantic/bovine/gcc)
(require 'semantic/idle)
(require 'semantic/lex-spp)
(require 'semantic/bovine/c-by)
(require 'semantic/db-find)
(require 'hideif)

(eval-when-compile
  (require 'semantic/find))

(declare-function semantic-brute-find-tag-by-attribute "semantic/find")
(declare-function semanticdb-minor-mode-p "semantic/db-mode")
(declare-function semanticdb-needs-refresh-p "semantic/db")
(declare-function semanticdb-typecache-faux-namespace "semantic/db-typecache")
(declare-function c-forward-conditional "cc-cmds")
(declare-function ede-system-include-path "ede")

(eval-when-compile (require 'cc-mode))

(define-obsolete-function-alias 'semantic-c-end-of-macro
  #'c-end-of-macro "28.1")

;;; Code:
(with-suppressed-warnings ((obsolete define-child-mode))
  ;; FIXME: We should handle this some other way!
  (define-child-mode c++-mode c-mode
  "`c++-mode' uses the same parser as `c-mode'."))


;;; Include Paths
;;
(defcustom-mode-local-semantic-dependency-system-include-path
  c-mode semantic-c-dependency-system-include-path
  '("/usr/include")
  "The system include path used by the C language.")

(defcustom semantic-default-c-path nil
  "Default set of include paths for C code.
Used by `semantic-dep' to define an include path.
NOTE: In process of obsoleting this."
  :group 'c
  :group 'semantic
  :type '(repeat (string :tag "Path")))

(defvar-mode-local c-mode semantic-dependency-include-path
  semantic-default-c-path
  "System path to search for include files.")

;;; Compile Options
;;
;; Compiler options need to show up after path setup, but before
;; the preprocessor section.

(if (memq system-type '(gnu gnu/linux darwin cygwin))
    (semantic-gcc-setup))

;;; Pre-processor maps
;;
;;; Lexical analysis
(defvar semantic-lex-c-preprocessor-symbol-map-builtin
  '( ("__THROW" . "")
     ("__const" . "const")
     ("__restrict" . "")
     ("__attribute_pure__" . "")
     ("__attribute_malloc__" . "")
     ("__nonnull" . "")
     ("__wur" . "")
     ("__declspec" . ((spp-arg-list ("foo") 1 . 2)))
     ("__attribute__" . ((spp-arg-list ("foo") 1 . 2)))
     ("__asm" . ((spp-arg-list ("foo") 1 . 2)))
     )
  "List of symbols to include by default.")

(defvar semantic-c-in-reset-preprocessor-table nil
  "Non-nil while resetting the preprocessor symbol map.
Used to prevent a reset while trying to parse files that are
part of the preprocessor map.")

(defvar semantic-lex-c-preprocessor-symbol-file)
(defvar semantic-lex-c-preprocessor-symbol-map)

(defun semantic-c-reset-preprocessor-symbol-map ()
  "Reset the C preprocessor symbol map based on all input variables."
  (when (and semantic-mode
	     (featurep 'semantic/bovine/c))
    (remove-hook 'mode-local-init-hook
                 #'semantic-c-reset-preprocessor-symbol-map)
    ;; Initialize semantic-lex-spp-macro-symbol-obarray with symbols.
    (setq-mode-local c-mode
		     semantic-lex-spp-macro-symbol-obarray
		     (semantic-lex-make-spp-table
		      (append semantic-lex-c-preprocessor-symbol-map-builtin
			      semantic-lex-c-preprocessor-symbol-map)))
    (let ((filemap nil)
	  )
      (when (and (not semantic-c-in-reset-preprocessor-table)
		 (featurep 'semantic/db-mode)
		 (semanticdb-minor-mode-p))
	(let ( ;; Don't use external parsers.  We need the internal one.
	      (semanticdb-out-of-buffer-create-table-fcn nil)
	      ;; Don't recurse while parsing these files the first time.
	      (semantic-c-in-reset-preprocessor-table t)
	      )
	  (dolist (sf semantic-lex-c-preprocessor-symbol-file)
	    ;; Global map entries
	    (let* ((table (semanticdb-file-table-object sf t)))
	      (when table
		(when (semanticdb-needs-refresh-p table)
		  (condition-case nil
		      ;; Call with FORCE, as the file is very likely to
		      ;; not be in a buffer.
		      (semanticdb-refresh-table table t)
		    (error (message "Error updating tables for %S"
				    (eieio-object-name table)))))
		(setq filemap (append filemap (oref table lexical-table)))
		)))))
      ;; Update symbol obarray
      (setq-mode-local c-mode
		       semantic-lex-spp-macro-symbol-obarray
		       (semantic-lex-make-spp-table
			(append semantic-lex-c-preprocessor-symbol-map-builtin
				semantic-lex-c-preprocessor-symbol-map
				filemap))))))

;; Make sure the preprocessor symbols are set up when mode-local kicks
;; in.
(add-hook 'mode-local-init-hook #'semantic-c-reset-preprocessor-symbol-map)

(defcustom semantic-lex-c-preprocessor-symbol-map nil
  "Table of C Preprocessor keywords used by the Semantic C lexer.
Each entry is a cons cell like this:
  ( \"KEYWORD\" . \"REPLACEMENT\" )
Where KEYWORD is the macro that gets replaced in the lexical phase,
and REPLACEMENT is a string that is inserted in its place.  Empty string
implies that the lexical analyzer will discard KEYWORD when it is encountered.

Alternately, it can be of the form:
  ( \"KEYWORD\" ( LEXSYM1 \"str\" 1 1 ) ... ( LEXSYMN \"str\" 1 1 ) )
where LEXSYM is a symbol that would normally be produced by the
lexical analyzer, such as `symbol' or `string'.  The string in the
second position is the text that makes up the replacement.  This is
the way to have multiple lexical symbols in a replacement.  Using the
first way to specify text like \"foo::bar\" would not work, because :
is a separate lexical symbol.

A quick way to see what you would need to insert is to place a
definition such as:

#define MYSYM foo::bar

into a C file, and do this:
  \\[semantic-lex-spp-describe]

The output table will describe the symbols needed."
  :group 'c
  :type '(repeat (cons (string :tag "Keyword")
		       (sexp :tag "Replacement")))
  :set (lambda (sym value)
	 (set-default sym value)
	 (condition-case nil
	     (semantic-c-reset-preprocessor-symbol-map)
	   (error nil))
	 )
  )

(defcustom semantic-lex-c-preprocessor-symbol-file nil
  "List of C/C++ files that contain preprocessor macros for the C lexer.
Each entry is a filename and each file is parsed, and those macros
are included in every C/C++ file parsed by semantic.
You can use this variable instead of `semantic-lex-c-preprocessor-symbol-map'
to store your global macros in a more natural way."
  :group 'c
  :type '(repeat (file :tag "File"))
  :set (lambda (sym value)
	 (set-default sym value)
	 (condition-case nil
	     (semantic-c-reset-preprocessor-symbol-map)
	   (error nil))
	 )
  )

(defcustom semantic-c-member-of-autocast 't
  "Non-nil means classes with a `->' operator will cast to its return type.

For Examples:

  class Foo {
    Bar *operator->();
  }

  Foo foo;

if `semantic-c-member-of-autocast' is non-nil :
  foo->[here completion will list method of Bar]

if `semantic-c-member-of-autocast' is nil :
  foo->[here completion will list method of Foo]"
  :group 'c
  :type 'boolean)

(define-lex-spp-macro-declaration-analyzer semantic-lex-cpp-define
  "A #define of a symbol with some value.
Record the symbol in the semantic preprocessor.
Return the defined symbol as a special spp lex token."
  "^\\s-*#\\s-*define\\s-+\\(\\(\\sw\\|\\s_\\)+\\)" 1
  (goto-char (match-end 0))
  (skip-chars-forward " \t")
  (if (eolp)
      nil
    (let* (;; (name (buffer-substring-no-properties
	   ;;        (match-beginning 1) (match-end 1)))
	   (beginning-of-define (match-end 1))
	   (with-args (save-excursion
			(goto-char (match-end 0))
			(looking-at "(")))
	   (semantic-lex-spp-replacements-enabled nil)
	   ;; Temporarily override the lexer to include
	   ;; special items needed inside a macro
	   (semantic-lex-analyzer #'semantic-cpp-lexer)
	   (raw-stream
	    (semantic-lex-spp-stream-for-macro (save-excursion
						 (c-end-of-macro)
						 ;; HACK - If there's a C comment after
						 ;; the macro, do not parse it.
						 (if (looking-back "/\\*.*" beginning-of-define)
						     (progn
						       (goto-char (match-beginning 0))
						       (point))
						   (point)))))
	   )

      ;; Only do argument checking if the paren was immediately after
      ;; the macro name.
      (if with-args
	  (semantic-lex-spp-first-token-arg-list (car raw-stream)))

      ;; Magical spp variable for end point.
      (setq semantic-lex-end-point (point))

      ;; Handled nested macro streams.
      (semantic-lex-spp-merge-streams raw-stream)
      )))

(define-lex-spp-macro-undeclaration-analyzer semantic-lex-cpp-undef
  "A #undef of a symbol.
Remove the symbol from the semantic preprocessor.
Return the defined symbol as a special spp lex token."
  "^\\s-*#\\s-*undef\\s-+\\(\\(\\sw\\|\\s_\\)+\\)" 1)


;;; Conditional Skipping
;;
(defcustom semantic-c-obey-conditional-section-parsing-flag t
  "Non-nil means to interpret preprocessor #if sections.
This implies that some blocks of code will not be parsed based on the
values of the conditions in the #if blocks."
  :group 'c
  :type 'boolean)

(defun semantic-c-skip-conditional-section ()
  "Skip one section of a conditional.
Moves forward to a matching #elif, #else, or #endif.
Moves completely over balanced #if blocks."
  (require 'cc-cmds)
  (let ((done nil))
    ;; (if (looking-at "^\\s-*#if")
    ;; (semantic-lex-spp-push-if (point))
    (end-of-line)
    (while (and semantic-c-obey-conditional-section-parsing-flag
		(and (not done)
		     (re-search-forward
		      "^\\s-*#\\s-*\\(if\\(n?def\\)?\\|el\\(if\\|se\\)\\|endif\\)\\>"
		      nil t)))
      (goto-char (match-beginning 0))
      (cond
       ((looking-at "^\\s-*#\\s-*if")
	;; We found a nested if.  Skip it.
	(if (fboundp 'c-scan-conditionals)
	    (goto-char (c-scan-conditionals 1))
	  ;; For older Emacsen, but this will set the mark.
	  (c-forward-conditional 1)))
       ((looking-at "^\\s-*#\\s-*elif")
	;; We need to let the preprocessor analyze this one.
	(beginning-of-line)
	(setq done t)
	)
       ((looking-at "^\\s-*#\\s-*\\(endif\\|else\\)\\>")
	;; We are at the end.  Pop our state.
	;; (semantic-lex-spp-pop-if)
	;; Note: We include ELSE and ENDIF the same. If skip some previous
	;; section, then we should do the else by default, making it much
	;; like the endif.
	(end-of-line)
	(forward-char 1)
	(setq done t))
       (t
	;; We found an elif.  Stop here.
	(setq done t))))))

;;; HIDEIF USAGE:
;; NOTE: All hideif using code was contributed by Brian Carlson as
;;       copies from hideif plus modifications and additions.
;;       Eric then converted things to use hideif functions directly,
;;       deleting most of that code, and added the advice.

;;; SPP SYM EVAL
;;
;; Convert SPP symbols into values usable by hideif.
;;
;; @TODO - can these conversion fcns be a part of semantic-lex-spp.el?
;;       -- TRY semantic-lex-spp-one-token-to-txt
(defun semantic-c-convert-spp-value-to-hideif-value (symbol macrovalue)
  "Convert an spp macro SYMBOL MACROVALUE, to something that hideif can use.
Take the first interesting thing and convert it."
  ;; Just warn for complex macros.
  (when (> (length macrovalue) 1)
    (semantic-push-parser-warning
     (format "Complex macro value (%s) may be improperly evaluated. "
	     symbol) 0 0))

  (let* ((lextoken (car macrovalue))
	 (key (semantic-lex-token-class lextoken))
	 (value (semantic-lex-token-text lextoken)))
    (cond
     ((eq key 'number) (string-to-number value))
     ((eq key 'symbol) (semantic-c-evaluate-symbol-for-hideif value))
     ((eq key 'string)
      (if (string-match "^[0-9]+L?$" value)
	  ;; If it matches a number expression, then
	  ;; convert to a number.
	  (string-to-number value)
	value))
     (t (semantic-push-parser-warning
	 (format "Unknown macro value. Token class = %s value = %s. " key value)
	 0 0)
      nil)
     )))

(defun semantic-c-evaluate-symbol-for-hideif (spp-symbol)
  "Lookup the symbol SPP-SYMBOL (a string) to something hideif can use.
Pull out the symbol list, and call
`semantic-c-convert-spp-value-to-hideif-value'."
  (interactive "sSymbol name: ")
  (when (symbolp spp-symbol) (setq spp-symbol (symbol-name spp-symbol)))

  (if (semantic-lex-spp-symbol-p spp-symbol )
      ;; Convert the symbol into a stream of tokens from the macro which we
      ;; can then interpret.
      (let ((stream (semantic-lex-spp-symbol-stream spp-symbol)))
	(cond
	 ;; Empty string means defined, so t.
	 ((null stream) t)
	 ;; A list means a parsed macro stream.
	 ((listp stream)
	  ;; Convert the macro to something we can return.
	  (semantic-c-convert-spp-value-to-hideif-value spp-symbol stream))

	 ;; Strings might need to be turned into numbers
	 ((stringp stream)
	  (if (string-match "^[0-9]+L?$" stream)
	      ;; If it matches a number expression, then convert to a
	      ;; number.
	      (string-to-number stream)
	    stream))

	 ;; Just return the stream.  A user might have just stuck some
	 ;; value in it directly.
	 (t stream)
	 ))
    ;; Else, store an error, return nil.
    (progn
      (semantic-push-parser-warning
       (format "SPP Symbol %s not available" spp-symbol)
       (point) (point))
      nil)))

;;; HIDEIF HACK support fcns
;;
;; These fcns can replace the impl of some hideif features.
;;
;; @TODO - Should hideif and semantic-c merge?
;;       I picture a grammar just for CPP that expands into
;;       a second token stream for the parser.
(defun semantic-c-hideif-lookup (var)
  "Replacement for `hif-lookup'.
I think it just gets the value for some CPP variable VAR."
  (let ((val (semantic-c-evaluate-symbol-for-hideif
              (cond
               ((stringp var) var)
               ((symbolp var) (symbol-name var))
               (t "Unable to determine var")))))
    (if val
	val
      ;; Real hideif will return the right undefined symbol.
      nil)))

(defun semantic-c-hideif-defined (var)
  "Replacement for `hif-defined'.
I think it just returns t/nil dependent on if VAR has been defined."
  (let ((var-symbol-name
          (cond
           ((symbolp var) (symbol-name var))
           ((stringp var) var)
           (t "Not A Symbol"))))
    (if (not (semantic-lex-spp-symbol-p var-symbol-name))
        (progn
          (semantic-push-parser-warning
	   (format "Skip %s" (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))
           (line-beginning-position) (line-end-position))
          nil)
      t)))

;;; HIDEIF ADVICE
;;
;; Advise hideif functions to use our lexical tables instead.
(defvar semantic-c-takeover-hideif nil
  "Non-nil when Semantic is taking over hideif features.")

;; (defadvice hif-defined (around semantic-c activate)
;;   "Is the variable defined?"
;;   (if semantic-c-takeover-hideif
;;       (setq ad-return-value
;; 	    (semantic-c-hideif-defined (ad-get-arg 0)))
;;     ad-do-it))

;; (defadvice hif-lookup (around semantic-c activate)
;;   "Is the argument defined?  Return true or false."
;;   (let ((ans nil))
;;     (when semantic-c-takeover-hideif
;;       (setq ans (semantic-c-hideif-lookup (ad-get-arg 0))))
;;     (if (null ans)
;; 	ad-do-it
;;       (setq ad-return-value ans))))

;;; #if macros
;;
;; Support #if macros by evaluating the values via use of hideif
;; logic.  See above for hacks to make this work.
(define-lex-regex-analyzer semantic-lex-c-if
  "Code blocks wrapped up in #if, or #ifdef.
Uses known macro tables in SPP to determine what block to skip."
  "^\\s-*#\\s-*\\(if\\|elif\\).*$"
  (semantic-c-do-lex-if))

(defun semantic-c-do-lex-if ()
  "Handle lexical CPP if statements.
Enables a takeover of some hideif functions, then uses hideif to
evaluate the #if expression and enables us to make decisions on which
code to parse."
  ;; Enable our advice, and use hideif to parse.
  (let* ((semantic-c-takeover-hideif t)
	 (hif-ifx-regexp (concat hif-cpp-prefix "\\(elif\\|if\\(n?def\\)?\\)[ \t]+"))
	 (parsedtokelist
	  (condition-case nil
	      ;; This is imperfect, so always assume on error.
	      (hif-canonicalize hif-ifx-regexp)
	    (error nil))))

    (let ((eval-form (condition-case err
			 (eval parsedtokelist t)
		       (error
			(semantic-push-parser-warning
			 (format "Hideif forms produced an error.  Assuming false.\n%S" err)
			 (point) (1+ (point)))
			nil))))
      (if (or (not eval-form)
              (and (numberp eval-form)
                   (equal eval-form 0)));; ifdef line resulted in false

	;; The if indicates to skip this preprocessor section
	(let () ;; (pt nil)
          (semantic-push-parser-warning (format "Skip %s" (buffer-substring-no-properties
                                                           (line-beginning-position)
                                                           (line-end-position)))
                                        (line-beginning-position) (line-end-position))
	  (beginning-of-line)
	  ;; (setq pt (point))
	  ;; This skips only a section of a conditional.  Once that section
	  ;; is opened, encountering any new #else or related conditional
	  ;; should be skipped.
	  (semantic-c-skip-conditional-section)
	  (setq semantic-lex-end-point (point))

	  ;; @TODO -somewhere around here, we also need to skip
	  ;; other sections of the conditional.

	  nil)
      ;; Else, don't ignore it, but do handle the internals.
      (end-of-line)
      (setq semantic-lex-end-point (point))
      nil))))

(define-lex-regex-analyzer semantic-lex-c-ifdef
  "Code blocks wrapped up in #ifdef.
Uses known macro tables in SPP to determine what block to skip."
  "^\\s-*#\\s-*\\(ifndef\\|ifdef\\)\\s-+\\(\\(\\sw\\|\\s_\\)+\\)\\([ \t\C-m].*\\)?$"
  (semantic-c-do-lex-ifdef))

(defun semantic-c-do-lex-ifdef ()
  "Handle lexical CPP if statements."
  (let* ((sym (buffer-substring-no-properties
	       (match-beginning 2) (match-end 2)))
	 (ift (buffer-substring-no-properties
	       (match-beginning 1) (match-end 1)))
	 (ifdef (string= ift "ifdef"))
	 (ifndef (string= ift "ifndef"))
	 )
    (if (or (and ifdef (not (semantic-lex-spp-symbol-p sym)))
	    (and ifndef (semantic-lex-spp-symbol-p sym)))
	;; The if indicates to skip this preprocessor section.
	(let ((pt nil))
	  ;; (message "%s %s yes" ift sym)
	  (beginning-of-line)
	  (setq pt (point))
	  ;; This skips only a section of a conditional.  Once that section
	  ;; is opened, encountering any new #else or related conditional
	  ;; should be skipped.
	  (semantic-c-skip-conditional-section)
	  (setq semantic-lex-end-point (point))
	  (semantic-push-parser-warning (format "Skip #%s %s" ift sym)
					pt (point))
	  ;;	  (semantic-lex-push-token
	  ;;	   (semantic-lex-token 'c-preprocessor-skip pt (point)))
	  nil)
      ;; Else, don't ignore it, but do handle the internals.
      ;;(message "%s %s no" ift sym)
      (end-of-line)
      (setq semantic-lex-end-point (point))
      nil)))

(define-lex-regex-analyzer semantic-lex-c-macro-else
  "Ignore an #else block.
We won't see the #else due to the macro skip section block
unless we are actively parsing an open #if statement.  In that
case, we must skip it since it is the ELSE part."
  "^\\s-*#\\s-*\\(else\\)"
  (let ((pt (point)))
    (semantic-c-skip-conditional-section)
    (setq semantic-lex-end-point (point))
    (semantic-push-parser-warning "Skip #else" pt (point))
;;    (semantic-lex-push-token
;;     (semantic-lex-token 'c-preprocessor-skip pt (point)))
    nil))

(define-lex-regex-analyzer semantic-lex-c-macrobits
  "Ignore various forms of #if/#else/#endif conditionals."
  "^\\s-*#\\s-*\\(if\\(n?def\\)?\\|endif\\|elif\\|else\\)"
  (c-end-of-macro)
  (setq semantic-lex-end-point (point))
  nil)

(define-lex-spp-include-analyzer semantic-lex-c-include-system
  "Identify include strings, and return special tokens."
    "^\\s-*#\\s-*include\\s-*<\\([^ \t\n>]+\\)>" 0
    ;; Hit 1 is the name of the include.
    (goto-char (match-end 0))
    (setq semantic-lex-end-point (point))
    (cons (buffer-substring-no-properties (match-beginning 1)
					  (match-end 1))
	  'system))

(define-lex-spp-include-analyzer semantic-lex-c-include
  "Identify include strings, and return special tokens."
    "^\\s-*#\\s-*include\\s-*\"\\([^ \t\n>]+\\)\"" 0
    ;; Hit 1 is the name of the include.
    (goto-char (match-end 0))
    (setq semantic-lex-end-point (point))
    (cons (buffer-substring-no-properties (match-beginning 1)
					  (match-end 1))
	  nil))


(define-lex-regex-analyzer semantic-lex-c-ignore-ending-backslash
  "Skip backslash ending a line.
Go to the next line."
  "\\\\\\s-*\n"
  (setq semantic-lex-end-point (match-end 0)))

(define-lex-regex-analyzer semantic-lex-c-namespace-begin-macro
  "Handle G++'s namespace macros which the pre-processor can't handle."
  "\\(_GLIBCXX_BEGIN_NAMESPACE\\)(\\s-*\\(\\(?:\\w\\|\\s_\\)+\\)\\s-*)"
  (let* ((nsend (match-end 1))
	 (sym-start (match-beginning 2))
	 (sym-end (match-end 2))
	 (ms (buffer-substring-no-properties sym-start sym-end)))
    ;; Push the namespace keyword.
    (semantic-lex-push-token
     (semantic-lex-token 'NAMESPACE (match-beginning 0) nsend "namespace"))
    ;; Push the name.
    (semantic-lex-push-token
     (semantic-lex-token 'symbol sym-start sym-end ms))
    )
  (goto-char (match-end 0))
  (let ((start (point))
	(end 0))
    ;; If we can't find a matching end, then create the fake list.
    (when (re-search-forward "_GLIBCXX_END_NAMESPACE" nil t)
      (setq end (point))
      (semantic-lex-push-token
       (semantic-lex-token 'semantic-list start end
			   (list 'prefix-fake)))))
  (setq semantic-lex-end-point (point)))

(defcustom semantic-lex-c-nested-namespace-ignore-second t
  "Should _GLIBCXX_BEGIN_NESTED_NAMESPACE ignore the second namespace?
It is really there, but if a majority of uses is to squeeze out
the second namespace in use, then it should not be included.

If you are having problems with smart completion and STL templates,
it may be that this is set incorrectly.  After changing the value
of this flag, you will need to delete any semanticdb cache files
that may have been incorrectly parsed."
  :group 'semantic
  :type 'boolean)

(define-lex-regex-analyzer semantic-lex-c-VC++-begin-std-namespace
  "Handle VC++'s definition of the std namespace."
  "\\(_STD_BEGIN\\)"
  (semantic-lex-push-token
   (semantic-lex-token 'NAMESPACE (match-beginning 0) (match-end 0) "namespace"))
  (semantic-lex-push-token
   (semantic-lex-token 'symbol (match-beginning 0) (match-end 0) "std"))
  (goto-char (match-end 0))
  (let ((start (point))
	(end 0))
    (when (re-search-forward "_STD_END" nil t)
      (setq end (point))
      (semantic-lex-push-token
       (semantic-lex-token 'semantic-list start end
			   (list 'prefix-fake)))))
  (setq semantic-lex-end-point (point)))

(define-lex-regex-analyzer semantic-lex-c-VC++-end-std-namespace
  "Handle VC++'s definition of the std namespace."
  "\\(_STD_END\\)"
  (goto-char (match-end 0))
  (setq semantic-lex-end-point (point)))

(define-lex-regex-analyzer semantic-lex-c-namespace-begin-nested-macro
  "Handle G++'s namespace macros which the pre-processor can't handle."
  "\\(_GLIBCXX_BEGIN_NESTED_NAMESPACE\\)(\\s-*\\(\\(?:\\w\\|\\s_\\)+\\)\\s-*,\\s-*\\(\\(?:\\w\\|\\s_\\)+\\)\\s-*)"
  (goto-char (match-end 0))
  (let* ((nsend (match-end 1))
	 (sym-start (match-beginning 2))
	 (sym-end (match-end 2))
	 (ms (buffer-substring-no-properties sym-start sym-end))
	 (sym2-start (match-beginning 3))
	 (sym2-end (match-end 3))
	 (ms2 (buffer-substring-no-properties sym2-start sym2-end)))
    ;; Push the namespace keyword.
    (semantic-lex-push-token
     (semantic-lex-token 'NAMESPACE (match-beginning 0) nsend "namespace"))
    ;; Push the name.
    (semantic-lex-push-token
     (semantic-lex-token 'symbol sym-start sym-end ms))

    (goto-char (match-end 0))
    (let ((start (point))
	  (end 0))
      ;; If we can't find a matching end, then create the fake list.
      (when (re-search-forward "_GLIBCXX_END_NESTED_NAMESPACE" nil t)
	(setq end (point))
	(if semantic-lex-c-nested-namespace-ignore-second
	    ;; The same as _GLIBCXX_BEGIN_NAMESPACE
	    (semantic-lex-push-token
	     (semantic-lex-token 'semantic-list start end
				 (list 'prefix-fake)))
	  ;; Do both the top and second level namespace
	  (semantic-lex-push-token
	   (semantic-lex-token 'semantic-list start end
			       ;; We'll depend on a quick hack
			       (list 'prefix-fake-plus
				     (semantic-lex-token 'NAMESPACE
							 sym-end sym2-start
							 "namespace")
				     (semantic-lex-token 'symbol
							 sym2-start sym2-end
							 ms2)
				     (semantic-lex-token 'semantic-list start end
							 (list 'prefix-fake)))
			       )))
	)))
  (setq semantic-lex-end-point (point)))

(define-lex-regex-analyzer semantic-lex-c-namespace-end-macro
  "Handle G++'s namespace macros which the pre-processor can't handle."
  "_GLIBCXX_END_\\(NESTED_\\)?NAMESPACE"
  (goto-char (match-end 0))
  (setq semantic-lex-end-point (point)))

(define-lex-regex-analyzer semantic-lex-c-string
  "Detect and create a C string token."
  "L?\\(\\s\"\\)"
  ;; Zing to the end of this string.
  (semantic-lex-push-token
   (semantic-lex-token
    'string (point)
    (save-excursion
      ;; Skip L prefix if present.
      (goto-char (match-beginning 1))
      (semantic-lex-unterminated-syntax-protection 'string
	(forward-sexp 1)
	(point))
      ))))

(define-lex-regex-analyzer semantic-c-lex-ignore-newline
  "Detect and ignore newline tokens.
Use this ONLY if newlines are not whitespace characters (such as when
they are comment end characters)."
  ;; Just like semantic-lex-ignore-newline, but also ignores
  ;; trailing \.
  "\\s-*\\\\?\\s-*\\(\n\\|\\s>\\)"
  (setq semantic-lex-end-point (match-end 0)))


(define-lex semantic-c-lexer
  "Lexical Analyzer for C code.
Use semantic-cpp-lexer for parsing text inside a CPP macro."
  ;; C preprocessor features
  semantic-lex-cpp-define
  semantic-lex-cpp-undef
  semantic-lex-c-ifdef
  semantic-lex-c-if
  semantic-lex-c-macro-else
  semantic-lex-c-macrobits
  semantic-lex-c-include
  semantic-lex-c-include-system
  semantic-lex-c-ignore-ending-backslash
  ;; Whitespace handling
  semantic-lex-ignore-whitespace
  semantic-c-lex-ignore-newline
  ;; Non-preprocessor features
  semantic-lex-number
  ;; Must detect C strings before symbols because of possible L prefix!
  semantic-lex-c-string
  ;; Custom handlers for some macros come before the macro replacement analyzer.
  semantic-lex-c-namespace-begin-macro
  semantic-lex-c-namespace-begin-nested-macro
  semantic-lex-c-namespace-end-macro
  semantic-lex-c-VC++-begin-std-namespace
  semantic-lex-c-VC++-end-std-namespace
  ;; Handle macros, symbols, and keywords
  semantic-lex-spp-replace-or-symbol-or-keyword
  semantic-lex-charquote
  semantic-lex-paren-or-list
  semantic-lex-close-paren
  semantic-lex-ignore-comments
  semantic-lex-punctuation
  semantic-lex-default-action)

(define-lex-simple-regex-analyzer semantic-lex-cpp-hashhash
  "Match ## inside a CPP macro as special."
  "##" 'spp-concat)

(define-lex semantic-cpp-lexer
  "Lexical Analyzer for CPP macros in C code."
  ;; CPP special
  semantic-lex-cpp-hashhash
  ;; C preprocessor features
  semantic-lex-cpp-define
  semantic-lex-cpp-undef
  semantic-lex-c-if
  semantic-lex-c-macro-else
  semantic-lex-c-macrobits
  semantic-lex-c-include
  semantic-lex-c-include-system
  semantic-lex-c-ignore-ending-backslash
  ;; Whitespace handling
  semantic-lex-ignore-whitespace
  semantic-c-lex-ignore-newline
  ;; Non-preprocessor features
  semantic-lex-number
  ;; Must detect C strings before symbols because of possible L prefix!
  semantic-lex-c-string
  ;; Parsing inside a macro means that we don't do macro replacement.
  ;; semantic-lex-spp-replace-or-symbol-or-keyword
  semantic-lex-symbol-or-keyword
  semantic-lex-charquote
  semantic-lex-spp-paren-or-list
  semantic-lex-close-paren
  semantic-lex-ignore-comments
  semantic-lex-punctuation
  semantic-lex-default-action)

(define-mode-local-override semantic-parse-region c-mode
  (start end &optional nonterminal depth returnonerror)
  "Calls `semantic-parse-region-default', except in a macro expansion.
MACRO expansion mode is handled through the nature of Emacs's non-lexical
binding of variables.
START, END, NONTERMINAL, DEPTH, and RETURNONERRORS are the same
as for the parent."
  ;; FIXME: We shouldn't depend on the internals of `semantic-bovinate-stream'.
  (with-suppressed-warnings ((lexical lse)) (defvar lse))
  (if (and (boundp 'lse) (or (/= start (point-min)) (/= end (point-max))))
      (let* ((last-lexical-token lse)
	     (llt-class (semantic-lex-token-class last-lexical-token))
	     (llt-fakebits (car (cdr last-lexical-token)))
	     (macroexpand (stringp (car (cdr last-lexical-token)))))
	(if macroexpand
  	    (progn
	      ;; It is a macro expansion.  Do something special.
	      ;;(message "MOOSE %S %S, %S : %S" start end nonterminal lse)
	      (semantic-c-parse-lexical-token
	       lse nonterminal depth returnonerror)
	      )
	  ;; Not a macro expansion, but perhaps a funny semantic-list
	  ;; is at the start?  Remove the depth if our semantic list is not
	  ;; made of list tokens.
	  (if (and depth (= depth 1)
		   (eq llt-class 'semantic-list)
		   (not (null llt-fakebits))
		   (consp llt-fakebits)
		   (symbolp (car llt-fakebits))
		   )
	      (progn
		(setq depth 0)

		;; This is a copy of semantic-parse-region-default where we
		;; are doing something special with the lexing of the
		;; contents of the semantic-list token.  Stuff not used by C
		;; removed.
		(let ((tokstream
		       (if (and (consp llt-fakebits)
				(eq (car llt-fakebits) 'prefix-fake-plus))
			   ;; If our semantic-list is special, then only stick in the
			   ;; fake tokens.
			   (cdr llt-fakebits)
			 ;; Lex up the region with a depth of 0
			 (semantic-lex start end 0))))

		  ;; Do the parse
		  (nreverse
		   (semantic-repeat-parse-whole-stream tokstream
						       nonterminal
						       returnonerror))

		  ))

	    ;; It was not a macro expansion, nor a special semantic-list.
	    ;; Do old thing.
	    (semantic-parse-region-default start end
					   nonterminal depth
					   returnonerror)
	    )))
    ;; Do the parse
    (semantic-parse-region-default start end nonterminal
				   depth returnonerror)
    ))

(defvar semantic-c-parse-token-hack-depth 0
  "Current depth of recursive calls to `semantic-c-parse-lexical-token'.")

(defun semantic-c-parse-lexical-token (lexicaltoken nonterminal depth
						    returnonerror)
  "Do a region parse on the contents of LEXICALTOKEN.
Presumably, this token has a string in it from a macro.
The text of the token is inserted into a different buffer, and
parsed there.
Argument NONTERMINAL, DEPTH, and RETURNONERROR are passed into
the regular parser."
  (let* ((semantic-c-parse-token-hack-depth (1+ semantic-c-parse-token-hack-depth))
	 (buf (get-buffer-create (format " *C parse hack %d*"
					 semantic-c-parse-token-hack-depth)))
	 (mode major-mode)
	 (spp-syms semantic-lex-spp-dynamic-macro-symbol-obarray)
	 (stream nil)
	 (start (semantic-lex-token-start lexicaltoken))
	 (end (semantic-lex-token-end lexicaltoken))
	 (symtext (semantic-lex-token-text lexicaltoken))
	 (macros (get-text-property 0 'macros symtext))
	 )
    (if (> semantic-c-parse-token-hack-depth 5)
	nil
      (with-current-buffer buf
	(erase-buffer)
	(when (not (eq major-mode mode))
	  (save-match-data

	    ;; Protect against user hooks throwing errors.
	    (condition-case nil
		(funcall mode)
	      (error
	       (if (y-or-n-p
		    (format "There was an error initializing %s in buffer \"%s\".  Debug your hooks? "
			    mode (buffer-name)))
		   (semantic-c-debug-mode-init mode)
		 (message "Macro parsing state may be broken...")
		 (sit-for 1))))
	    )				; save match data

	  ;; Hack in mode-local
	  (mode-local--activate-bindings)
	  ;; Setup C parser
	  (semantic-default-c-setup)
	  ;; CHEATER!  The following 3 lines are from
	  ;; `semantic-new-buffer-fcn', but we don't want to turn
	  ;; on all the other annoying modes for this little task.
	  (setq semantic-new-buffer-fcn-was-run t)
	  (semantic-lex-init)
	  (semantic-clear-toplevel-cache)
	  (remove-hook 'semantic-lex-reset-functions
		       #'semantic-lex-spp-reset-hook t)
	  )
	;; Get the macro symbol table right.
	(setq semantic-lex-spp-dynamic-macro-symbol-obarray spp-syms)
	;; (message "%S" macros)
	(dolist (sym macros)
	  (semantic-lex-spp-symbol-set (car sym) (cdr sym)))

	(insert symtext)

	(setq stream
	      (semantic-parse-region-default
	       (point-min) (point-max) nonterminal depth returnonerror))

	;; Clean up macro symbols
	(dolist (sym macros)
	  (semantic-lex-spp-symbol-remove (car sym)))

	;; Convert the text of the stream.
	(dolist (tag stream)
	  ;; Only do two levels here 'cause I'm lazy.
	  (semantic--tag-set-overlay tag (list start end))
	  (dolist (stag (semantic-tag-components-with-overlays tag))
	    (semantic--tag-set-overlay stag (list start end))
	    ))
	))
    stream))

(defvar semantic-c-debug-mode-init-last-mode nil
  "The most recent mode needing debugging.")

(defun semantic-c-debug-mode-init (mm)
  "Debug mode init for major mode MM after we're done parsing now."
  (interactive (list semantic-c-debug-mode-init-last-mode))
  (if (called-interactively-p 'interactive)
      ;; Do the debug.
      (progn
	(switch-to-buffer (get-buffer-create "*MODE HACK TEST*"))
	(let ((debug-on-error t))
	  (funcall mm)))

    ;; Notify about the debug
    (setq semantic-c-debug-mode-init-last-mode mm)

    (add-hook 'post-command-hook #'semantic-c-debug-mode-init-pch)))

(defun semantic-c-debug-mode-init-pch ()
  "Notify user about needing to debug their major mode hooks."
  (let ((mm semantic-c-debug-mode-init-last-mode))
    (switch-to-buffer-other-window
     (get-buffer-create "*MODE HACK TEST*"))
    (erase-buffer)
    (insert "A failure occurred while parsing your buffers.

The failure occurred while attempting to initialize " (symbol-name mm) " in a
buffer not associated with a file.  To debug this problem, type

M-x semantic-c-debug-mode-init

now.
")
    (remove-hook 'post-command-hook #'semantic-c-debug-mode-init-pch)))

(defun semantic-expand-c-tag (tag)
  "Expand TAG into a list of equivalent tags, or nil."
  (let ((return-list nil)
	)
    ;; Expand an EXTERN C first.
    (when (eq (semantic-tag-class tag) 'extern)
      (setq return-list (semantic-expand-c-extern-C tag))
      ;; The members will be expanded in the next iteration. The
      ;; 'extern' tag itself isn't needed anymore.
      (setq tag nil))

    ;; Check if we have a complex type
    (when (or (semantic-tag-of-class-p tag 'function)
	      (semantic-tag-of-class-p tag 'variable))
      (setq tag (semantic-expand-c-complex-type tag))
      ;; Extract new basetag
      (setq return-list (car tag))
      (setq tag (cdr tag)))

    ;; Name of the tag is a list, so expand it.  Tag lists occur
    ;; for variables like this: int var1, var2, var3;
    ;;
    ;; This will expand that to 3 tags that happen to share the
    ;; same overlay information.
    (if (consp (semantic-tag-name tag))
	(let ((rl (semantic-expand-c-tag-namelist tag)))
	  (cond
	   ;; If this returns nothing, then return nil overall
	   ;; because that will restore the old TAG input.
	   ((not rl) (setq return-list nil))
	   ;; If we have a return, append it to the existing list
	   ;; of returns.
	   ((consp rl)
	    (setq return-list (append rl return-list)))
	   ))
      ;; If we didn't have a list, but the return-list is non-empty,
      ;; that means we still need to take our existing tag, and glom
      ;; it onto our extracted type.
      (if (and tag (consp return-list))
	  (setq return-list (cons tag return-list)))
      )

    ;; Default, don't change the tag means returning nil.
    return-list))

(defun semantic-expand-c-extern-C (tag)
  "Expand TAG containing an `extern \"C\"' statement.
This will return all members of TAG with `extern \"C\"' added to
the typemodifiers attribute."
    (when (eq (semantic-tag-class tag) 'extern)
      (let* ((mb (semantic-tag-get-attribute tag :members))
	     (ret mb))
	(while mb
	  (let ((mods (semantic-tag-get-attribute (car mb) :typemodifiers)))
	    (setq mods (cons "extern" (cons "\"C\"" mods)))
	    (semantic-tag-put-attribute (car mb) :typemodifiers mods))
	  (setq mb (cdr mb)))
	(nreverse ret))))

(defun semantic-expand-c-complex-type (tag)
  "Check if TAG has a full :type with a name on its own.
If so, extract it, and replace it with a reference to that type.
Thus, `struct A { int a; } B;' will create 2 toplevel tags, one
is type A, and the other variable B where the :type of B is just
a type tag A that is a prototype, and the actual struct info of A
is its own toplevel tag.  This function will return (cons A B)."
  (let* ((basetype (semantic-tag-type tag))
	 (typeref nil)
	 (ret nil)
	 (tname (when (consp basetype)
		  (semantic-tag-name basetype))))
    ;; Make tname be a string.
    (when (consp tname) (setq tname (car (car tname))))
    ;; Is the basetype a full type with a name of its own?
    (when (and basetype (semantic-tag-p basetype)
	       (not (semantic-tag-prototype-p basetype))
	       tname
	       (not (string= tname "")))
      ;; a type tag referencing the type we are extracting.
      (setq typeref (semantic-tag-new-type
		     (semantic-tag-name basetype)
		     (semantic-tag-type basetype)
		     nil nil
		     :prototype t))
      ;; Convert original tag to only have a reference.
      (setq tag (semantic-tag-copy tag))
      (semantic-tag-put-attribute tag :type typeref)
      ;; Convert basetype to have the location information.
      (semantic--tag-copy-properties tag basetype)
      (semantic--tag-set-overlay basetype
				 (semantic-tag-overlay tag))
      ;; Store the base tag as part of the return list.
      (setq ret (cons basetype ret)))
    (cons ret tag)))

(defun semantic-expand-c-tag-namelist (tag)
  "Expand TAG whose name is a list into a list of tags, or nil."
  (cond ((semantic-tag-of-class-p tag 'variable)
	 ;; The name part comes back in the form of:
	 ;; ( NAME NUMSTARS BITS ARRAY ASSIGN )
	 (let ((vl nil)
	       (basety (semantic-tag-type tag))
	       (ty "")
	       (mods (semantic-tag-get-attribute tag :typemodifiers))
	       (suffix "")
	       (lst (semantic-tag-name tag))
	       (default nil)
	       (cur nil))
	   ;; Open up each name in the name list.
	   (while lst
	     (setq suffix "" ty "")
	     (setq cur (car lst))
	     (if (nth 2 cur)
		 (setq suffix (concat ":" (nth 2 cur))))
	     (if (= (length basety) 1)
		 (setq ty (car basety))
	       (setq ty basety))
	     (setq default (nth 4 cur))
	     (setq vl (cons
		       (semantic-tag-new-variable
			(car cur)	;name
			ty		;type
			(if (and default
				 (listp (cdr default)))
			    (buffer-substring-no-properties
			     (car default) (car (cdr default))))
			:constant-flag (semantic-tag-variable-constant-p tag)
			:suffix suffix
			:typemodifiers mods
			:dereference (length (nth 3 cur))
			:pointer (nth 1 cur)
			:reference (semantic-tag-get-attribute tag :reference)
			:documentation (semantic-tag-docstring tag) ;doc
			)
		       vl))
	     (semantic--tag-copy-properties tag (car vl))
	     (semantic--tag-set-overlay (car vl)
					(semantic-tag-overlay tag))
	     (setq lst (cdr lst)))
	   ;; Return the list
	   (nreverse vl)))
	((semantic-tag-of-class-p tag 'type)
	 ;; We may someday want to add an extra check for a type
	 ;; of type "typedef".
	 ;; Each elt of NAME is ( STARS NAME )
	 (let ((vl nil)
	       (names (semantic-tag-name tag))
	       (super (semantic-tag-get-attribute tag :superclasses))
	       (addlast nil))

	   (when (and (semantic-tag-of-type-p tag "typedef")
		      (semantic-tag-of-class-p super 'type)
		      (semantic-tag-type-members super))
	     ;; This is a typedef of a real type.  Extract
	     ;; the super class, and stick it into the tags list.
	     (setq addlast super)

	     ;; Clone super and remove the members IFF super has a name.
	     ;; Note: anonymous struct/enums that are typedef'd shouldn't
	     ;; exist in the top level type list, so they will appear only
	     ;; in the :typedef slot of the typedef.
	     (setq super (semantic-tag-clone super))
	     (if (not (string= (semantic-tag-name super) ""))
		 (semantic-tag-put-attribute super :members nil)
	       (setq addlast nil))

	     ;; Add in props to the full superclass.
	     (when addlast
	       (semantic--tag-copy-properties tag addlast)
	       (semantic--tag-set-overlay addlast (semantic-tag-overlay tag)))
	     )

	   (while names

	     (setq vl (cons (semantic-tag-new-type
			     (nth 1 (car names)) ; name
			     "typedef"
			     (semantic-tag-type-members tag)
			     nil
			     :pointer
			     (let ((stars (car (car (car names)))))
			       (if (= stars 0) nil stars))
			     ;; This specifies what the typedef
			     ;; is expanded out as.  Just the
			     ;; name shows up as a parent of this
			     ;; typedef.
			     :typedef super
			     ;;(semantic-tag-type-superclasses tag)
			     :documentation
			     (semantic-tag-docstring tag))
			    vl))
	     (semantic--tag-copy-properties tag (car vl))
	     (semantic--tag-set-overlay (car vl) (semantic-tag-overlay tag))
	     (setq names (cdr names)))

	   ;; Add typedef superclass last.
	   (when addlast (setq vl (cons addlast vl)))

	   vl))
	((and (listp (car tag))
	      (semantic-tag-of-class-p (car tag) 'variable))
	 ;; Argument lists come in this way.  Append all the expansions!
	 (let ((vl nil))
	   (while tag
	     (setq vl (append (semantic-tag-components (car vl))
			      vl)
		   tag (cdr tag)))
	   vl))
	(t nil)))

(defvar-mode-local c-mode semantic-tag-expand-function 'semantic-expand-c-tag
  "Function used to expand tags generated in the C bovine parser.")

(defvar semantic-c-classname nil
  "At parse time, assign a class or struct name text here.
It is picked up by `semantic-c-reconstitute-token' to determine
if something is a constructor.  Value should be:
  (TYPENAME .  TYPEOFTYPE)
where typename is the name of the type, and typeoftype is \"class\"
or \"struct\".")

(define-mode-local-override semantic-analyze-split-name c-mode (name)
  "Split up tag names on colon (:) boundaries."
  (let ((ans (split-string name ":")))
    (if (= (length ans) 1)
	name
      (delete "" ans))))

(define-mode-local-override semantic-analyze-tag-references c-mode (tag &optional db)
  "Analyze the references for TAG.
Returns a class with information about TAG.

Optional argument DB is a database.  It will be used to help
locate TAG.

Use `semantic-analyze-current-tag' to debug this fcn."
  (when (not (semantic-tag-p tag))  (signal 'wrong-type-argument (list 'semantic-tag-p tag)))
  (let ((allhits nil)
	(scope nil)
	) ;; (refs nil)
    (save-excursion
      (semantic-go-to-tag tag db)
      (setq scope (semantic-calculate-scope))

      (setq allhits (semantic--analyze-refs-full-lookup tag scope t))

      (when (or (zerop (semanticdb-find-result-length allhits))
		(and (= (semanticdb-find-result-length allhits) 1)
		     (eq (car (semanticdb-find-result-nth allhits 0)) tag)))
	;; It found nothing or only itself - not good enough.  As a
	;; last resort, let's remove all namespaces from the scope and
	;; search again.
	(oset scope parents
	      (let ((parents (oref scope parents))
		    newparents)
		(dolist (cur parents)
		  (unless (string= (semantic-tag-type cur) "namespace")
		    (push cur newparents)))
		(reverse newparents)))
	(setq allhits (semantic--analyze-refs-full-lookup tag scope t)))

      ;; (setq refs
      (semantic-analyze-references :tag tag
				   :tagdb db
				   :scope scope
				   :rawsearchdata allhits)))) ;;)

(defun semantic-c-reconstitute-token (tokenpart declmods typedecl)
  "Reconstitute a token TOKENPART with DECLMODS and TYPEDECL.
This is so we don't have to match the same starting text several times.
Optional argument STAR and REF indicate the number of * and & in the typedef."
  (when (and (listp typedecl)
	     (= 1 (length typedecl))
	     (stringp (car typedecl)))
    (setq typedecl (car typedecl)))
  (cond ((eq (nth 1 tokenpart) 'variable)
	 (semantic-tag-new-variable
	  (car tokenpart)
	  (or typedecl "int")	;type
	  nil			;default value (filled with expand)
	  :constant-flag (if (member "const" declmods) t nil)
	  :typemodifiers (delete "const" declmods)
	  )
	 )
	((eq (nth 1 tokenpart) 'function)
	 ;; We should look at part 4 (the arglist) here, and throw an
	 ;; error of some sort if it contains parser errors so that we
	 ;; don't parser function calls, but that is a little beyond what
	 ;; is available for data here.
	 (let* ((constructor
		 (and (or (and semantic-c-classname
			       (string= (car semantic-c-classname)
					(car tokenpart)))
			  (and (stringp (car (nth 2 tokenpart)))
			       (string= (car (nth 2 tokenpart)) (car tokenpart)))
			  (nth 10 tokenpart) ; initializers
			  )
		      (not (car (nth 3 tokenpart)))))
		(fcnpointer (and (> (length (car tokenpart)) 0)
				 (= (aref (car tokenpart) 0) ?*)))
		(fnname (if fcnpointer
			    (substring (car tokenpart) 1)
			  (car tokenpart)))
		(operator (if (string-match "[a-zA-Z]" fnname)
			      nil
			    t))
		)
	   ;; The function
	   (semantic-tag-new-function
	    fnname
	    (or typedecl		;type
		(cond ((car (nth 3 tokenpart) )
		       "void")	; Destructors have no return?
		      (constructor
		       ;; Constructors return an object.
		       (semantic-tag-new-type
			;; name
			(or (car semantic-c-classname)
			    (let ((split (semantic-analyze-split-name-c-mode
					  (car (nth 2 tokenpart)))))
			      (if (stringp split) split
				(car (last split)))))
			;; type
			(or (cdr semantic-c-classname)
			    "class")
			;; members
			nil
			;; parents
			nil
			))
		      (t "int")))
	    ;; Argument list can contain things like function pointers
	    (semantic-c-reconstitute-function-arglist (nth 4 tokenpart))
	    :constant-flag (if (member "const" declmods) t nil)
	    :typemodifiers (delete "const" declmods)
	    :parent (car (nth 2 tokenpart))
	    :destructor-flag (if (car (nth 3 tokenpart) ) t)
	    :constructor-flag (if constructor t)
	    :function-pointer fcnpointer
	    :pointer (nth 7 tokenpart)
	    :operator-flag operator
	    ;; Even though it is "throw" in C++, we use
	    ;; `throws' as a common name for things that toss
	    ;; exceptions about.
	    :throws (nth 5 tokenpart)
	    ;; Reentrant is a C++ thingy.  Add it here
	    :reentrant-flag (if (member "reentrant" (nth 6 tokenpart)) t)
	    ;; A function post-const is funky.  Try stuff
	    :methodconst-flag (if (member "const" (nth 6 tokenpart)) t)
            ;; prototypes are functions with no body
	    :prototype-flag (if (nth 8 tokenpart) t)
	    ;; Pure virtual
	    :pure-virtual-flag (if (eq (nth 8 tokenpart) :pure-virtual-flag) t)
	    ;; Template specifier.
	    :template-specifier (nth 9 tokenpart))))))

(defun semantic-c-reconstitute-template (tag specifier)
  "Reconstitute the token TAG with the template SPECIFIER."
  (semantic-tag-put-attribute tag :template (or specifier ""))
  tag)

(defun semantic-c-reconstitute-function-arglist (arglist)
  "Reconstitute the argument list of a function.
This currently only checks if the function expects a function
pointer as argument."
  (let (result)
    (dolist (arg arglist)
      ;; Names starting with a '*' denote a function pointer
      (if (and (> (length (semantic-tag-name arg)) 0)
	       (= (aref (semantic-tag-name arg) 0) ?*))
	  (setq result
		(append result
			(list
			 (semantic-tag-new-function
			  (substring (semantic-tag-name arg) 1)
			  (semantic-tag-type arg)
			  (cadr (semantic-tag-attributes arg))
			  :function-pointer t))))
	(setq result (append result (list arg)))))
    result))


;;; Override methods & Variables
;;
(define-mode-local-override semantic-format-tag-name
  c-mode (tag &optional parent color)
  "Convert TAG to a string that is the print name for TAG.
Optional PARENT and COLOR are ignored."
  (let ((name (semantic-format-tag-name-default tag parent color))
	(fnptr (semantic-tag-get-attribute tag :function-pointer))
	)
    (if (not fnptr)
	name
      (concat "(*" name ")"))
    ))

(define-mode-local-override semantic-format-tag-canonical-name
  c-mode (tag &optional parent color)
  "Create a canonical name for TAG.
PARENT specifies a parent class.
COLOR indicates that the text should be type colorized.
Enhances the base class to search for the entire parent
tree to make the name accurate."
  (semantic-format-tag-canonical-name-default tag parent color)
  )

(define-mode-local-override semantic-format-tag-type c-mode (tag color)
  "Convert the data type of TAG to a string usable in tag formatting.
Adds pointer and reference symbols to the default.
Argument COLOR adds color to the text."
  (let* ((type (semantic-tag-type tag))
	 (defaulttype nil)
	 (point (semantic-tag-get-attribute tag :pointer))
	 (ref (semantic-tag-get-attribute tag :reference))
	 )
    (if (semantic-tag-p type)
	(let ((typetype (semantic-tag-type type))
	      (typename (semantic-tag-name type)))
	  ;; Create the string that expresses the type
	  (if (string= typetype "class")
	      (setq defaulttype typename)
	    (setq defaulttype (concat typetype " " typename))))
      (setq defaulttype (semantic-format-tag-type-default tag color)))

    ;; Colorize
    (when color
      (setq defaulttype (semantic--format-colorize-text defaulttype 'type)))

    ;; Add refs, ptrs, etc
    (if ref (setq ref "&"))
    (if point (setq point (make-string point ?*)) "")
    (when type
      (concat defaulttype ref point))
    ))

(define-mode-local-override semantic-find-tags-by-scope-protection
  c-mode (scopeprotection parent &optional table)
  "Override the usual search for protection.
We can be more effective than the default by scanning through once,
and collecting tags based on the labels we see along the way."
  (if (not table) (setq table (semantic-tag-type-members parent)))
  (if (null scopeprotection)
      table
    (let ((ans nil)
	  (curprot 1)
	  (targetprot (cond ((eq scopeprotection 'public)
			     1)
			    ((eq scopeprotection 'protected)
			     2)
			    (t 3)
			    ))
	  (alist '(("public" . 1)
		   ("protected" . 2)
		   ("private" . 3)))
	  )
      (dolist (tag table)
	(cond
	 ((semantic-tag-of-class-p tag 'label)
	  (setq curprot (cdr (assoc (semantic-tag-name tag) alist)))
	  )
	 ((>= targetprot curprot)
	  (setq ans (cons tag ans)))
	 ))
      ans)))

(define-mode-local-override semantic-tag-protection
  c-mode (tag &optional parent)
  "Return the protection of TAG in PARENT.
Override function for `semantic-tag-protection'."
  (let ((mods (semantic-tag-modifiers tag))
	(prot nil))
    ;; Check the modifiers for protection if we are not a child
    ;; of some class type.
    (if (not (and parent (eq (semantic-tag-class parent) 'type)))
	(while (and (not prot) mods)
	  (if (stringp (car mods))
	      (let ((s (car mods)))
	        ;; A few silly defaults to get things started.
	        (setq prot (pcase s
			     ((or "extern" "export") 'public)
			     ("static" 'private)))))
	  (setq mods (cdr mods)))
      ;; If we have a typed parent, look for :public style labels.
      (let ((pp (semantic-tag-type-members parent)))
	(while (and pp (not (semantic-equivalent-tag-p (car pp) tag)))
	  (when (eq (semantic-tag-class (car pp)) 'label)
	    (setq prot
		  (pcase (semantic-tag-name (car pp))
		    ("public" 'public)
		    ("private" 'private)
		    ("protected" 'protected)))
	    )
	  (setq pp (cdr pp)))))
    (when (and (not prot) (eq (semantic-tag-class parent) 'type))
      (setq prot
	    (pcase (semantic-tag-type parent)
	      ("class" 'private)
	      ("struct" 'public)
	      (_ 'unknown))))
    (or prot
	(if (and parent (semantic-tag-of-class-p parent 'type))
	    'public
	  nil))))

(define-mode-local-override semantic-find-tags-included c-mode
  (&optional table)
  "Find all tags in TABLE that are of the `include' class.
TABLE is a tag table.  See `semantic-something-to-tag-table'.
For C++, we also have to search namespaces for include tags."
  (let ((tags (semantic-find-tags-by-class 'include table))
	(namespaces (semantic-find-tags-by-type "namespace" table)))
    (dolist (cur namespaces)
      (setq tags
	    (append tags
		    (semantic-find-tags-by-class
		     'include
		     (semantic-tag-get-attribute cur :members)))))
    tags))


(define-mode-local-override semantic-tag-components c-mode (tag)
  "Return components for TAG."
  (if (and (eq (semantic-tag-class tag) 'type)
	   (string= (semantic-tag-type tag) "typedef"))
      ;; A typedef can contain a parent who has positional children,
      ;; but that parent will not have a position.  Do this funny hack
      ;; to make sure we can apply overlays properly.
      (let ((sc (semantic-tag-get-attribute tag :typedef)))
	(when (semantic-tag-p sc) (semantic-tag-components sc)))
    (semantic-tag-components-default tag)))

(defun semantic-c-tag-template (tag)
  "Return the template specification for TAG, or nil."
  (semantic-tag-get-attribute tag :template))

(defun semantic-c-tag-template-specifier (tag)
  "Return the template specifier specification for TAG, or nil."
  (semantic-tag-get-attribute tag :template-specifier))

(defun semantic-c-template-string-body (templatespec)
  "Convert TEMPLATESPEC into a string.
This might be a string, or a list of tokens."
  (cond ((stringp templatespec)
	 templatespec)
	((semantic-tag-p templatespec)
	 (semantic-format-tag-abbreviate templatespec))
	((listp templatespec)
	 (mapconcat #'semantic-format-tag-abbreviate templatespec ", "))))

(defun semantic-c-template-string (token &optional parent _color)
  "Return a string representing the TEMPLATE attribute of TOKEN.
This string is prefixed with a space, or is the empty string.
Argument PARENT specifies a parent type.
Argument COLOR specifies that the string should be colorized."
  (let ((t2 (semantic-c-tag-template-specifier token))
	(t1 (semantic-c-tag-template token))
	;; @todo - Need to account for a parent that is a template
	(_pt1 (if parent (semantic-c-tag-template parent)))
	(_pt2 (if parent (semantic-c-tag-template-specifier parent)))
	)
    (cond (t2 ;; we have a template with specifier
	   (concat " <"
		   ;; Fill in the parts here
		   (semantic-c-template-string-body t2)
		   ">"))
	  (t1 ;; we have a template without specifier
	   " <>")
	  (t
	   ""))))

(define-mode-local-override semantic-format-tag-concise-prototype
  c-mode (token &optional parent color)
  "Return an abbreviated string describing TOKEN for C and C++.
Optional PARENT and COLOR as specified with
`semantic-format-tag-abbreviate-default'."
  ;; If we have special template things, append.
  (concat  (semantic-format-tag-concise-prototype-default token parent color)
	   (semantic-c-template-string token parent color)))

(define-mode-local-override semantic-format-tag-uml-prototype
  c-mode (token &optional parent color)
  "Return an UML string describing TOKEN for C and C++.
Optional PARENT and COLOR as specified with
`semantic-format-tag-abbreviate-default'."
  ;; If we have special template things, append.
  (concat  (semantic-format-tag-uml-prototype-default token parent color)
	   (semantic-c-template-string token parent color)))

(define-mode-local-override semantic-tag-abstract-p
  c-mode (tag &optional parent)
  "Return non-nil if TAG is considered abstract.
PARENT is tag's parent.
In C, a method is abstract if it is `virtual', which is already
handled.  A class is abstract only if its destructor is virtual."
  (cond
   ((eq (semantic-tag-class tag) 'type)
    (require 'semantic/find)
    (or (semantic-brute-find-tag-by-attribute :pure-virtual-flag
					      (semantic-tag-components tag)
					      )
	(let* ((ds (semantic-brute-find-tag-by-attribute
		    :destructor-flag
		    (semantic-tag-components tag)
		    ))
	       (cs (semantic-brute-find-tag-by-attribute
		    :constructor-flag
		    (semantic-tag-components tag)
		    )))
	  (and ds (member "virtual" (semantic-tag-modifiers (car ds)))
	       cs (eq 'protected (semantic-tag-protection (car cs) tag))
	       )
	  )))
   ((eq (semantic-tag-class tag) 'function)
    (or (semantic-tag-get-attribute tag :pure-virtual-flag)
        (member "virtual" (semantic-tag-modifiers tag))))
   (t (semantic-tag-abstract-p-default tag parent))))

(defun semantic-c-dereference-typedef (type _scope &optional type-declaration)
  "If TYPE is a typedef, get TYPE's type by name or tag, and return.
SCOPE is not used, and TYPE-DECLARATION is used only if TYPE is not a typedef."
  (if (and (eq (semantic-tag-class type) 'type)
           (string= (semantic-tag-type type) "typedef"))
      (let ((dt (semantic-tag-get-attribute type :typedef)))
        (cond ((and (semantic-tag-p dt)
                    (not (semantic-tag-prototype-p dt)))
	       ;; In this case, DT was declared directly.  We need
	       ;; to clone DT and apply a filename to it.
	       (let* ((fname (semantic-tag-file-name type))
		      (def (semantic-tag-copy dt nil fname)))
		 (list def def)))
              ((stringp dt) (list dt (semantic-tag dt 'type)))
              ((consp dt) (list (car dt) dt))))

    (list type type-declaration)))

(defun semantic-c--instantiate-template (tag def-list spec-list)
  "Replace TAG name according to template specification.
DEF-LIST is the template information.
SPEC-LIST is the template specifier of the datatype instantiated."
  (when (and (car def-list) (car spec-list))

    (when (and (string= (semantic-tag-type (car def-list)) "class")
               (string= (semantic-tag-name tag) (semantic-tag-name (car def-list))))
      (semantic-tag-set-name tag (semantic-tag-name (car spec-list))))

    (semantic-c--instantiate-template tag (cdr def-list) (cdr spec-list))))

(defun semantic-c--template-name-1 (spec-list)
  "Return a string used to compute template class name.
Based on SPEC-LIST, for ref<Foo,Bar> it will return `Foo,Bar'."
  (when (car spec-list)
    (let* ((endpart (semantic-c--template-name-1 (cdr spec-list)))
	   (separator (and endpart ",")))
      (concat (semantic-tag-name (car spec-list)) separator endpart))))

(defun semantic-c--template-name (type spec-list)
  "Return a template class name for TYPE based on SPEC-LIST.
For a type `ref' with a template specifier of (Foo Bar) it will
return `ref<Foo,Bar>'."
  (concat (semantic-tag-name type)
	  "<" (semantic-c--template-name-1 (cdr spec-list)) ">"))

(defun semantic-c-dereference-template (type _scope &optional type-declaration)
  "Dereference any template specifiers in TYPE within SCOPE.
If TYPE is a template, return a TYPE copy with the templates types
instantiated as specified in TYPE-DECLARATION."
  (when (semantic-tag-p type-declaration)
    (let ((def-list  (semantic-tag-get-attribute type :template))
          (spec-list (semantic-tag-get-attribute type-declaration :template-specifier)))
      (when (and def-list spec-list)
        (setq type (semantic-tag-deep-copy-one-tag
		    type
		    (lambda (tag)
		      (when (semantic-tag-of-class-p tag 'type)
			(semantic-c--instantiate-template
			 tag def-list spec-list))
		      tag)
		    ))
        (semantic-tag-set-name type (semantic-c--template-name type spec-list))
        (semantic-tag-put-attribute type :template nil)
        (semantic-tag-set-faux type))))
  (list type type-declaration))

;;; Patch here by "Raf" for instantiating templates.
(defun semantic-c-dereference-member-of (type _scope &optional type-declaration)
  "Dereference through the `->' operator of TYPE.
Uses the return type of the `->' operator if it is contained in TYPE.
SCOPE is the current local scope to perform searches in.
TYPE-DECLARATION is passed through."
  (if semantic-c-member-of-autocast
      (let ((operator (car (semantic-find-tags-by-name "->" (semantic-analyze-scoped-type-parts type)))))
        (if operator
            (list (semantic-tag-get-attribute operator :type) (semantic-tag-get-attribute operator :type))
          (list type type-declaration)))
    (list type type-declaration)))

;; David Engster: The following three functions deal with namespace
;; aliases and types which are member of a namespace through a using
;; statement. For examples, see the file semantic/tests/testusing.cpp,
;; tests 5 and following.

(defun semantic-c-dereference-namespace (type scope &optional type-declaration)
  "Dereference namespace which might hold an `alias' for TYPE.
Such an alias can be created through `using' statements in a
namespace declaration.  This function checks the namespaces in
SCOPE for such statements."
  (let ((scopetypes (oref scope scopetypes))
	typename currentns result namespaces) ;; usingname tmp
    (when (and (semantic-tag-p type-declaration)
	       (or (null type) (semantic-tag-prototype-p type)))
      (setq typename (semantic-analyze-split-name (semantic-tag-name type-declaration)))
      ;; If we already have that TYPE in SCOPE, we do nothing
      (unless (semantic-deep-find-tags-by-name (or (car-safe typename) typename) scopetypes)
	(if (stringp typename)
	    ;; The type isn't fully qualified, so we have to search in all namespaces in SCOPE.
	    (setq namespaces (semantic-find-tags-by-type "namespace" scopetypes))
	  ;; This is a fully qualified name, so we only have to search one namespace.
	  (setq namespaces (semanticdb-typecache-find (car typename)))
	  ;; Make sure it's really a namespace.
	  (if (string= (semantic-tag-type namespaces) "namespace")
	      (setq namespaces (list namespaces))
	    (setq namespaces nil)))
	(setq result nil)
	;; Iterate over all the namespaces we have to check.
	(while (and namespaces
		    (null result))
	  (setq currentns (car namespaces))
	  ;; Check if this is namespace is an alias and dereference it if necessary.
	  (setq result (semantic-c-dereference-namespace-alias type-declaration currentns))
	  (unless result
	    ;; Otherwise, check if we can reach the type through 'using' statements.
	    (setq result
		  (semantic-c-check-type-namespace-using type-declaration currentns)))
	  (setq namespaces (cdr namespaces)))))
    (if result
	;; we have found the original type
	(list result result)
      (list type type-declaration))))

(defun semantic-c-dereference-namespace-alias (type namespace)
  "Dereference TYPE in NAMESPACE, given that NAMESPACE is an alias.
Checks if NAMESPACE is an alias and if so, returns a new type
with a fully qualified name in the original namespace.  Returns
nil if NAMESPACE is not an alias."
  (when (eq (semantic-tag-get-attribute namespace :kind) 'alias)
    (let ((typename (semantic-analyze-split-name (semantic-tag-name type)))
	  ns nstype originaltype) ;; newtype
      ;; Make typename unqualified
      (setq typename (if (listp typename)
	                 (last typename)
	               (list typename)))
      (when
	  (and
	   ;; Get original namespace and make sure TYPE exists there.
	   (setq ns (semantic-tag-name
		     (car (semantic-tag-get-attribute namespace :members))))
	   (setq nstype (semanticdb-typecache-find ns))
	   (setq originaltype (semantic-find-tags-by-name
			       (car typename)
			       (semantic-tag-get-attribute nstype :members))))
	;; Construct new type with name in original namespace.
	(setq ns (semantic-analyze-split-name ns))
	;; (setq newtype
	(semantic-tag-clone
	 (car originaltype)
	 (semantic-analyze-unsplit-name
	  (if (listp ns)
	      (append ns typename)
	    (append (list ns) typename)))))))) ;; )

;; This searches a type in a namespace, following through all using
;; statements.
(defun semantic-c-check-type-namespace-using (type namespace)
  "Check if TYPE is accessible in NAMESPACE through a using statement.
Returns the original type from the namespace where it is defined,
or nil if it cannot be found."
  (let (usings result usingname usingtype unqualifiedname members) ;; shortname tmp
    ;; Get all using statements from NAMESPACE.
    (when (and (setq usings (semantic-tag-get-attribute namespace :members))
	       (setq usings (semantic-find-tags-by-class 'using usings)))
      ;; Get unqualified typename.
      (when (listp (setq unqualifiedname (semantic-analyze-split-name
					  (semantic-tag-name type))))
	(setq unqualifiedname (car (last unqualifiedname))))
      ;; Iterate over all using statements in NAMESPACE.
      (while (and usings
		  (null result))
	(setq usingname (semantic-analyze-split-name
			 (semantic-tag-name (car usings)))
	      usingtype (semantic-tag-type (semantic-tag-type (car usings))))
	(cond
	 ((or (string= usingtype "namespace")
	      (stringp usingname))
	  ;; We are dealing with a 'using [namespace] NAMESPACE;'
	  ;; Search for TYPE in that namespace
	  (setq result
		(semanticdb-typecache-find usingname))
	  (if (and result
		   (setq members (semantic-tag-get-attribute result :members))
		   (setq members (semantic-find-tags-by-name unqualifiedname members)))
	      ;; TYPE is member of that namespace, so we are finished
	      (setq result (car members))
	    ;; otherwise recursively search in that namespace for an alias
	    (setq result (semantic-c-check-type-namespace-using type result))
	    (when result
	      (setq result (semantic-tag-type result)))))
	 ((and (string= usingtype "class")
	       (listp usingname))
	  ;; We are dealing with a 'using TYPE;'
	  (when (string= unqualifiedname (car (last usingname)))
	    ;; We have found the correct tag.
	    (setq result (semantic-tag-type (car usings))))))
	(setq usings (cdr usings))))
    result))


(define-mode-local-override semantic-analyze-dereference-metatype
  c-mode (type scope &optional type-declaration)
  "Dereference TYPE as described in `semantic-analyze-dereference-metatype'.
Handle typedef, template instantiation, and `->' operator."
  (let* ((dereferencer-list '(semantic-c-dereference-typedef
                              semantic-c-dereference-template
                              semantic-c-dereference-member-of
			      semantic-c-dereference-namespace))
         (dereferencer (pop dereferencer-list))
         (type-tuple)
         (original-type type))
    (while dereferencer
      (setq type-tuple (funcall dereferencer type scope type-declaration)
            type (car type-tuple)
            type-declaration (cadr type-tuple))
      (if (not (eq type original-type))
          ;; we found a new type so break the dereferencer loop now !
          ;; (we will be recalled with the new type expanded by
          ;; semantic-analyze-dereference-metatype-stack).
          (setq dereferencer nil)
        ;; no new type found try the next dereferencer :
        (setq dereferencer (pop dereferencer-list)))))
    (list type type-declaration))

(define-mode-local-override semantic-analyze-type-constants c-mode (type)
  "When TYPE is a tag for an enum, return its parts.
These are constants which are of type TYPE."
  (if (and (eq (semantic-tag-class type) 'type)
	   (string= (semantic-tag-type type) "enum"))
      (semantic-tag-type-members type)))

(define-mode-local-override semantic-analyze-unsplit-name c-mode (namelist)
  "Assemble the list of names NAMELIST into a namespace name."
  (mapconcat #'identity namelist "::"))

(define-mode-local-override semantic-ctxt-scoped-types c++-mode (&optional point)
  "Return a list of tags of CLASS type based on POINT.
DO NOT return the list of tags encompassing point."
  (when point (goto-char (point)))
  (let ((tagsaroundpoint (semantic-find-tag-by-overlay))
	(tagreturn nil)
	(tmp nil))
    ;; In C++, we want to find all the namespaces declared
    ;; locally and add them to the list.
    (setq tmp (semantic-find-tags-by-class 'type (current-buffer)))
    (setq tmp (semantic-find-tags-by-type "namespace" tmp))
    (setq tmp (semantic-find-tags-by-name "unnamed" tmp))
    (setq tagreturn tmp)
    ;; We should also find all "using" type statements and
    ;; accept those entities in as well.
    (setq tmp (semanticdb-find-tags-by-class 'using))
    (let ((idx 0)
	  (len (semanticdb-find-result-length tmp)))
      (while (< idx len)
	(setq tagreturn
	      (append tagreturn (list (semantic-tag-type
				       (car (semanticdb-find-result-nth tmp idx))))))
	(setq idx (1+ idx))))
    ;; Use the encompassed types around point to also look for using
    ;; statements.  If we deal with types, search inside members; for
    ;; functions, we have to call `semantic-get-local-variables' to
    ;; parse inside the function's body.
    (dolist (cur tagsaroundpoint)
      (cond
       ((and (eq (semantic-tag-class cur) 'type)
	     (setq tmp (semantic-find-tags-by-class
			'using
			(semantic-tag-components (car tagsaroundpoint)))))
	(dolist (T tmp)
	  (setq tagreturn (cons (semantic-tag-type T) tagreturn))))
       ((and (semantic-tag-of-class-p (car (last tagsaroundpoint)) 'function)
	     (setq tmp (semantic-find-tags-by-class
			'using
			(semantic-get-local-variables))))
	(setq tagreturn
	      (append tagreturn
		      (mapcar #'semantic-tag-type tmp))))))
    ;; Return the stuff
    tagreturn))

(define-mode-local-override semantic-ctxt-imported-packages c++-mode (&optional point)
  "Return the list of using tag types in scope of POINT."
  (when point (goto-char (point)))
  (let ((tagsaroundpoint (semantic-find-tag-by-overlay))
	(namereturn nil)
	(tmp nil)
	)
    ;; Collect using statements from the top level.
    (setq tmp (semantic-find-tags-by-class 'using (current-buffer)))
    (dolist (T tmp) (setq namereturn (cons (semantic-tag-type T) namereturn)))
    ;; Move through the tags around point looking for more using statements
    (while (cdr tagsaroundpoint)  ; don't search the last one
      (setq tmp (semantic-find-tags-by-class 'using (semantic-tag-components (car tagsaroundpoint))))
      (dolist (T tmp) (setq namereturn (cons (semantic-tag-type T) namereturn)))
      (setq tagsaroundpoint (cdr tagsaroundpoint))
      )
    namereturn))

(define-mode-local-override semanticdb-expand-nested-tag c++-mode (tag)
  "Expand TAG if it has a fully qualified name.
For types with a :parent, create faux namespaces to put TAG into."
  (let ((p (semantic-tag-get-attribute tag :parent)))
    (if (and p (semantic-tag-of-class-p tag 'type))
	;; Expand the tag
	(let ((s (semantic-analyze-split-name p))
	      (newtag (semantic-tag-copy tag nil t)))
	  ;; Erase the qualified name.
	  (semantic-tag-put-attribute newtag :parent nil)
	  ;; Fixup the namespace name
	  (setq s (if (stringp s) (list s) (nreverse s)))
	  ;; Loop over all the parents, creating the nested
	  ;; namespace.
	  (require 'semantic/db-typecache)
	  (dolist (namespace s)
	    (setq newtag (semanticdb-typecache-faux-namespace
			  namespace (list newtag)))
	    )
	  ;; Return the last created namespace.
	  newtag)
      ;; Else, return tag unmodified.
      tag)))

(define-mode-local-override semanticdb-find-table-for-include c-mode
  (includetag &optional table)
  "For a single INCLUDETAG found in TABLE, find a `semanticdb-table' object.
INCLUDETAG is a semantic TAG of class `include'.
TABLE is a semanticdb table that identifies where INCLUDETAG came from.
TABLE is optional if INCLUDETAG has an overlay of :filename attribute.

For C++, we also have to check if the include is inside a
namespace, since this means all tags inside this include will
have to be wrapped in that namespace."
  (let ((inctable (semanticdb-find-table-for-include-default includetag table))
	(inside-ns (semantic-tag-get-attribute includetag :inside-ns))
	tags newtags namespaces parenttable newtable) ;; prefix
    (if (or (null inside-ns)
	    (not inctable)
	    (not (slot-boundp inctable 'tags)))
	inctable
      (when (and (eq inside-ns t)
		 ;; Get the table which has this include.
		 (setq parenttable
		       (semanticdb-find-table-for-include-default
			(semantic-tag-new-include
			 (semantic--tag-get-property includetag :filename) nil)))
		 table)
	;; Find the namespace where this include is located.
	(setq namespaces
	      (semantic-find-tags-by-type "namespace" parenttable))
	(when (and namespaces
		   (slot-boundp inctable 'tags))
	  (dolist (cur namespaces)
	    (when (semantic-find-tags-by-name
		   (semantic-tag-name includetag)
		   (semantic-tag-get-attribute cur :members))
	      (setq inside-ns (semantic-tag-name cur))
	      ;; Cache the namespace value.
	      (semantic-tag-put-attribute includetag :inside-ns inside-ns)))))
      (unless (semantic-find-tags-by-name
	       inside-ns
	       (semantic-find-tags-by-type "namespace" inctable))
	(setq tags (oref inctable tags))
	;; Wrap tags inside namespace tag
	(setq newtags
	      (list (semantic-tag-new-type inside-ns "namespace" tags nil)))
	;; Create new semantic-table for the wrapped tags, since we don't want
	;; the namespace to actually be a part of the header file.
	(setq newtable (semanticdb-table))
	(oset newtable tags newtags)
	(oset newtable parent-db (oref inctable parent-db))
	(oset newtable file (oref inctable file)))
      newtable)))


(define-mode-local-override semantic-get-local-variables c++-mode ()
  "Do what `semantic-get-local-variables' does, plus add `this' if needed."
  (let* ((origvar (semantic-get-local-variables-default))
	 (ct (semantic-current-tag))
	 (p (when (semantic-tag-of-class-p ct 'function)
	      (or (semantic-tag-function-parent ct)
		  (car-safe (semantic-find-tags-by-type
			     "class" (semantic-find-tag-by-overlay)))))))
    ;; If we have a function parent, then that implies we can
    (if p
 	;; Append a new tag THIS into our space.
	(cons (semantic-tag-new-variable "this" p nil :pointer 1)
	      origvar)
      ;; No parent, just return the usual
      origvar)))

(define-mode-local-override semantic-idle-summary-current-symbol-info
  c-mode ()
  "Handle the SPP keywords, then use the default mechanism."
  (let* ((sym (car (semantic-ctxt-current-thing)))
	 (spp-sym (semantic-lex-spp-symbol sym)))
    (if spp-sym
	(let* ((txt (concat "Macro: " sym))
	       (sv  (symbol-value spp-sym))
	       (arg (semantic-lex-spp-macro-with-args sv))
	       )
	  (when arg
	    (setq txt (concat txt (format "%S" arg)))
	    (setq sv (cdr sv)))

          ;; This is optional, and potentially fraught with errors.
	  (condition-case nil
	      (dolist (lt sv)
		(setq txt (concat txt " " (semantic-lex-token-text lt))))
	    (error (setq txt (concat txt "  #error in summary fcn"))))

	  txt)
      (semantic-idle-summary-current-symbol-info-default))))

(define-mode-local-override semantic--tag-similar-names-p c-mode (tag1 tag2 blankok)
  "Compare the names of TAG1 and TAG2.
If BLANKOK is false, then the names must exactly match.
If BLANKOK is true, then always return t, as for C, the names don't matter
for arguments compared."
  (if blankok t (semantic--tag-similar-names-p-default tag1 tag2 nil)))

(define-mode-local-override semantic--tag-similar-types-p c-mode (tag1 tag2)
  "For `c-mode', deal with TAG1 and TAG2 being used in different namespaces.
In this case, one type will be shorter than the other.  Instead
of fully resolving all namespaces currently in scope for both
types, we simply compare as many elements as the shorter type
provides."
  ;; First, we see if the default method fails
  (if (semantic--tag-similar-types-p-default tag1 tag2)
      t
    (let* ((names
	    (mapcar
	    (lambda (tag)
	      (let ((type (semantic-tag-type tag)))
		(unless (stringp type)
		  (setq type (semantic-tag-name type)))
		(setq type (semantic-analyze-split-name type))
		(when (stringp type)
		  (setq type (list type)))
		type))
	    (list tag1 tag2)))
	   (len1 (length (car names)))
	   (len2 (length (cadr names))))
      (cond
       ((<= len1 len2)
	(equal (nthcdr len1 (cadr names)) (car names)))
       ((< len2 len1)
	(equal (nthcdr len2 (car names)) (cadr names)))))))


(define-mode-local-override semantic--tag-attribute-similar-p c-mode
  (attr value1 value2 ignorable-attributes)
  "For `c-mode', allow function :arguments to ignore the :name attributes."
  (cond ((eq attr :arguments)
	 (semantic--tag-attribute-similar-p-default attr value1 value2
						    (cons :name ignorable-attributes)))
	(t
	 (semantic--tag-attribute-similar-p-default attr value1 value2
						    ignorable-attributes))))

(defvar-mode-local c-mode semantic-orphaned-member-metaparent-type "struct"
  "When lost members are found in the class hierarchy generator, use a struct.")

(defvar-mode-local c-mode semantic-symbol->name-assoc-list
  '((type     . "Types")
    (variable . "Variables")
    (function . "Functions")
    (include  . "Includes")
    )
  "List of tag classes, and strings to describe them.")

(defvar-mode-local c-mode semantic-symbol->name-assoc-list-for-type-parts
  '((type     . "Types")
    (variable . "Attributes")
    (function . "Methods")
    (label    . "Labels")
    )
  "List of tag classes in a datatype decl, and strings to describe them.")

(defvar-mode-local c-mode imenu-create-index-function 'semantic-create-imenu-index
  "Imenu index function for C.")

(defvar-mode-local c-mode semantic-type-relation-separator-character
  '("." "->" "::")
  "Separator characters between something of a given type, and a field.")

(defvar-mode-local c-mode semantic-command-separation-character ";"
  "Command separation character for C.")

(defvar-mode-local c-mode senator-step-at-tag-classes '(function variable)
  "Tag classes where senator will stop at the end.")

(defvar-mode-local c-mode semantic-tag-similar-ignorable-attributes
  '(:prototype-flag :parent :typemodifiers)
  "Tag attributes to ignore during similarity tests.
:parent is here because some tags might specify a parent, while others are
actually in their parent which is not accessible.")

;;;###autoload
(defun semantic-default-c-setup ()
  "Set up a buffer for semantic parsing of the C language."
  (semantic-c-by--install-parser)
  (setq semantic-lex-syntax-modifications '((?> ".")
                                            (?< ".")))

  (setq semantic-lex-analyzer #'semantic-c-lexer)
  (add-hook 'semantic-lex-reset-functions #'semantic-lex-spp-reset-hook nil t)
  (when (derived-mode-p 'c++-mode)
    (add-to-list 'semantic-lex-c-preprocessor-symbol-map '("__cplusplus" . "")))
  )

;;;###autoload
(defun semantic-c-add-preprocessor-symbol (sym replacement)
  "Add a preprocessor symbol SYM with a REPLACEMENT value."
  (interactive "sSymbol: \nsReplacement: ")
  (let ((SA (assoc sym semantic-lex-c-preprocessor-symbol-map)))
    (if SA
	;; Replace if there is one.
	(setcdr SA replacement)
      ;; Otherwise, append
      (setq semantic-lex-c-preprocessor-symbol-map
	    (cons  (cons sym replacement)
		   semantic-lex-c-preprocessor-symbol-map))))

  (semantic-c-reset-preprocessor-symbol-map)
  )

;;; SETUP QUERY
;;
(defun semantic-c-describe-environment ()
  "Describe the Semantic features of the current C environment."
  (interactive)
  (if (not (derived-mode-p 'c-mode))
      (error "Not useful to query C mode in %s mode" major-mode))
  (let ((gcc (when (boundp 'semantic-gcc-setup-data)
	       semantic-gcc-setup-data))
	)
    (semantic-fetch-tags)

    (with-output-to-temp-buffer "*Semantic C Environment*"
      (when gcc
	(princ "Calculated GCC Parameters:")
	(dolist (P gcc)
	  (princ "\n  ")
	  (princ (car P))
	  (princ " = ")
	  (princ (cdr P))
	  )
	)

      (princ "\n\nInclude Path Summary:\n")
      (when (and (boundp 'ede-object) ede-object)
	(princ (substitute-command-keys
		"\n  This file's project include is handled by:\n"))
	(let ((objs (if (listp ede-object)
			ede-object
		      (list ede-object))))
	  (dolist (O objs)
	    (princ "    EDE : ")
	    (princ 0)
	    (let ((ipath (ede-system-include-path O)))
	      (if (not ipath)
		  (princ "\n     with NO specified system include path.\n")
		(princ "\n     with the system path:\n")
		(dolist (dir ipath)
		  (princ "    ")
		  (princ dir)
		  (princ "\n"))))))
	)

      (when semantic-dependency-include-path
	(princ (substitute-command-keys
		"\n  This file's generic include path is:\n"))
	(dolist (dir semantic-dependency-include-path)
	  (princ "    ")
	  (princ dir)
	  (princ "\n")))

      (when semantic-dependency-system-include-path
	(princ (substitute-command-keys
		"\n  This file's system include path is:\n"))
	(dolist (dir semantic-dependency-system-include-path)
	  (princ "    ")
	  (princ dir)
	  (princ "\n")))

      (princ "\n\nMacro Summary:\n")

      (when semantic-lex-c-preprocessor-symbol-file
	(princ "\n  Your CPP table is primed from these system files:\n")
	(dolist (file semantic-lex-c-preprocessor-symbol-file)
	  (princ "    ")
	  (princ file)
	  (princ "\n")
	  (princ "    in table: ")
	  (let ((fto (semanticdb-file-table-object file)))
	    (if fto
		(princ (cl-prin1-to-string fto))
	      (princ "No Table")))
	  (princ "\n")
	  ))

      (when semantic-lex-c-preprocessor-symbol-map-builtin
	(princ "\n  Built-in symbol map:\n")
	(dolist (S semantic-lex-c-preprocessor-symbol-map-builtin)
	  (princ "    ")
	  (princ (car S))
	  (princ " = ")
	  (princ (cdr S))
	  (princ "\n")
	  ))

      (when semantic-lex-c-preprocessor-symbol-map
	(princ "\n  User symbol map (primed from system files):\n")
	(dolist (S semantic-lex-c-preprocessor-symbol-map)
	  (princ "    ")
	  (princ (car S))
	  (princ " = ")
	  (princ (cdr S))
	  (princ "\n")
	  ))

      (when (and (boundp 'ede-object)
		 ede-object)
	(princ "\n  Project symbol map:\n")
	(when (and (boundp 'ede-object) ede-object)
	  (princ "      Your project symbol map is also derived from the EDE object:\n      ")
	  (princ (cl-prin1-to-string ede-object)))
	(princ "\n\n")
	(if (obarrayp semantic-lex-spp-project-macro-symbol-obarray)
	    (let ((macros nil))
	      (mapatoms
               (lambda (symbol)
                 (setq macros (cons symbol macros)))
	       semantic-lex-spp-project-macro-symbol-obarray)
	      (dolist (S macros)
		(princ "    ")
		(princ (symbol-name S))
		(princ " = ")
		(princ (symbol-value S))
		(princ "\n")
		))
	  ;; Else, not map
	  (princ "    No Symbols.\n")))

      (princ "\n\n  Use: M-x semantic-lex-spp-describe RET\n")
      (princ "\n  to see the complete macro table.\n")

      )))

(provide 'semantic/bovine/c)

(semantic-c-reset-preprocessor-symbol-map)

;; Local variables:
;; generated-autoload-file: "../loaddefs.el"
;; generated-autoload-load-name: "semantic/bovine/c"
;; End:

;;; semantic/bovine/c.el ends here
