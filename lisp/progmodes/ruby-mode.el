;;; ruby-mode.el --- Major mode for editing Ruby files -*- lexical-binding: t -*-

;; Copyright (C) 1994-2025 Free Software Foundation, Inc.

;; Authors: Yukihiro Matsumoto
;;	Nobuyoshi Nakada
;; URL: https://www.emacswiki.org/cgi-bin/wiki/RubyMode
;; Created: Fri Feb  4 14:49:13 JST 1994
;; Keywords: languages ruby
;; Version: 1.2

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

;; Provides font-locking, indentation support, and navigation for Ruby code.
;;
;; Still needs more docstrings; search below for TODO.

;;; Code:

(require 'cl-lib)

(defgroup ruby nil
  "Major mode for editing Ruby code."
  :prefix "ruby-"
  :group 'languages)

(defconst ruby-block-beg-keywords
  '("class" "module" "def" "if" "unless" "case" "while" "until" "for" "begin" "do")
  "Keywords at the beginning of blocks.")

(defconst ruby-block-beg-re
  (regexp-opt ruby-block-beg-keywords)
  "Regexp to match the beginning of blocks.")

(defconst ruby-non-block-do-re
  (regexp-opt '("while" "until" "for" "rescue") 'symbols)
  "Regexp to match keywords that nest without blocks.")

(defconst ruby-indent-beg-re
  (concat "^\\(\\s *" (regexp-opt '("class" "module" "def")) "\\|"
          (regexp-opt '("if" "unless" "case" "while" "until" "for" "begin"))
          "\\)\\_>")
  "Regexp to match where the indentation gets deeper.")

(defconst ruby-modifier-beg-keywords
  '("if" "unless" "while" "until")
  "Modifiers that are the same as the beginning of blocks.")

(defconst ruby-modifier-beg-re
  (regexp-opt ruby-modifier-beg-keywords)
  "Regexp to match modifiers same as the beginning of blocks.")

(defconst ruby-modifier-re
  (regexp-opt (cons "rescue" ruby-modifier-beg-keywords))
  "Regexp to match modifiers.")

(defconst ruby-block-mid-keywords
  '("then" "else" "elsif" "when" "in" "rescue" "ensure")
  "Keywords where the indentation gets shallower in middle of block statements.")

(defconst ruby-block-mid-re
  (regexp-opt ruby-block-mid-keywords)
  "Regexp for where the indentation gets shallower in middle of block statements.")

(defconst ruby-block-op-keywords
  '("and" "or" "not")
  "Regexp to match boolean keywords.")

(defconst ruby-block-hanging-re
  (regexp-opt (append ruby-modifier-beg-keywords ruby-block-op-keywords))
  "Regexp to match hanging block modifiers.")

(defconst ruby-block-end-re "\\_<end\\_>")

(defconst ruby-defun-beg-re
  '"\\(def\\|class\\|module\\)"
  "Regexp to match the beginning of a defun, in the general sense.")

(defconst ruby-singleton-class-re
  "class\\s *<<"
  "Regexp to match the beginning of a singleton class context.")

(eval-and-compile
  (defconst ruby-here-doc-beg-re
  "\\(<\\)<\\([~-]\\)?\\(\\([a-zA-Z0-9_]+\\)\\|[\"]\\([^\"]+\\)[\"]\\|[']\\([^']+\\)[']\\)"
  "Regexp to match the beginning of a heredoc.")

  (defconst ruby-expression-expansion-re
    "#\\({[^}\n\\]*\\(\\\\.[^}\n\\]*\\)*}\\|\\(?:\\$\\|@\\|@@\\)\\(\\w\\|_\\)+\\|\\$[^a-zA-Z \n]\\)"))

(defun ruby-here-doc-end-match ()
  "Return a regexp to find the end of a heredoc.

This should only be called after matching against `ruby-here-doc-beg-re'."
  (concat "^"
          (if (match-string 2) "[ \t]*" nil)
          (regexp-quote
           (or (match-string 4)
               (match-string 5)
               (match-string 6)))))

(defconst ruby-delimiter
  (concat "[?$/%(){}#\"'`.:]\\|<<\\|\\[\\|\\]\\|\\_<\\("
          ruby-block-beg-re
          "\\)\\_>\\|" ruby-block-end-re
          "\\|^=begin\\|" ruby-here-doc-beg-re))

(defconst ruby-negative
  (concat "^[ \t]*\\(\\(" ruby-block-mid-re "\\)\\>\\|"
          ruby-block-end-re "\\|}\\|\\]\\)")
  "Regexp to match where the indentation gets shallower.")

(defconst ruby-operator-re "[-,.+*/%&|^~=<>:]\\|\\\\$"
  "Regexp to match operators.")

(defconst ruby-symbol-chars "a-zA-Z0-9_"
  "List of characters that symbol names may contain.")

(defconst ruby-symbol-re (concat "[" ruby-symbol-chars "]")
  "Regexp to match symbols.")

(defconst ruby-endless-method-head-re
  (format " *\\(%s+\\.\\)?%s+[?!]? *\\(([^()]*)\\)? +="
          ruby-symbol-re ruby-symbol-re)
  "Regexp to match the beginning of an endless method definition.

It should match the part after \"def\" and until \"=\".")

(defconst ruby-builtin-methods-with-reqs
  '( ;; built-in methods on Kernel
    "at_exit"
    "autoload"
    "autoload?"
    "callcc"
    "catch"
    "eval"
    "exec"
    "format"
    "lambda"
    "load"
    "loop"
    "open"
    "p"
    "printf"
    "proc"
    "putc"
    "require"
    "require_relative"
    "spawn"
    "sprintf"
    "syscall"
    "system"
    "throw"
    "trace_var"
    "trap"
    "untrace_var"
    "warn"
    ;; keyword-like private methods on Module
    "alias_method"
    "attr"
    "attr_accessor"
    "attr_reader"
    "attr_writer"
    "define_method"
    "extend"
    "include"
    "module_function"
    "prepend"
    "private_class_method"
    "private_constant"
    "public_class_method"
    "public_constant"
    "refine"
    "using")
  "List of built-in methods that require at least one argument.")

(defconst ruby-builtin-methods-no-reqs
  '("__callee__"
    "__dir__"
    "__method__"
    "abort"
    "binding"
    "block_given?"
    "caller"
    "exit"
    "exit!"
    "fail"
    "fork"
    "global_variables"
    "local_variables"
    "print"
    "private"
    "protected"
    "public"
    "puts"
    "raise"
    "rand"
    "readline"
    "readlines"
    "sleep"
    "srand")
  "List of built-in methods that only have optional arguments.")

(defvar ruby-use-smie t)
(make-obsolete-variable 'ruby-use-smie nil "28.1")

(defvar ruby-mode-map
  (let ((map (make-sparse-keymap)))
    (unless ruby-use-smie
      (define-key map (kbd "M-C-q") 'ruby-indent-exp))
    (when ruby-use-smie
      (define-key map (kbd "M-C-d") 'smie-down-list))
    (define-key map (kbd "M-C-p") 'ruby-beginning-of-block)
    (define-key map (kbd "M-C-n") 'ruby-end-of-block)
    (define-key map (kbd "C-c {") 'ruby-toggle-block)
    (define-key map (kbd "C-c '") 'ruby-toggle-string-quotes)
    (define-key map (kbd "C-c C-f") 'ruby-find-library-file)
    map)
  "Keymap used in Ruby mode.")

(easy-menu-define ruby-mode-menu ruby-mode-map
  "Ruby Mode Menu."
  '("Ruby"
    ["Beginning of Block" ruby-beginning-of-block t]
    ["End of Block" ruby-end-of-block t]
    ["Toggle Block" ruby-toggle-block t]
    "--"
    ["Toggle String Quotes" ruby-toggle-string-quotes t]
    "--"
    ["Backward Sexp" backward-sexp t]
    ["Forward Sexp" forward-sexp t]
    ["Indent Sexp" ruby-indent-exp
     :visible (not ruby-use-smie)]
    ["Indent Sexp" prog-indent-sexp
     :visible ruby-use-smie]))

(defvar ruby-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\' "\"" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\` "\"" table)
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?$ "'" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?: "'" table)
    (modify-syntax-entry ?@ "'" table)
    (modify-syntax-entry ?< "." table)
    (modify-syntax-entry ?> "." table)
    (modify-syntax-entry ?& "." table)
    (modify-syntax-entry ?| "." table)
    (modify-syntax-entry ?% "." table)
    (modify-syntax-entry ?= "." table)
    (modify-syntax-entry ?/ "." table)
    (modify-syntax-entry ?+ "." table)
    (modify-syntax-entry ?* "." table)
    (modify-syntax-entry ?- "." table)
    (modify-syntax-entry ?\; "." table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    table)
  "Syntax table to use in Ruby mode.")

(defcustom ruby-indent-tabs-mode nil
  "Indentation can insert tabs in Ruby mode if this is non-nil."
  :type 'boolean
  :safe 'booleanp)

(defcustom ruby-indent-level 2
  "Number of spaces for each indentation step in `ruby-mode'."
  :type 'integer
  :safe 'integerp)

(defcustom ruby-comment-column (default-value 'comment-column)
  "Indentation column of comments."
  :type 'integer
  :safe 'integerp)

(defconst ruby-alignable-keywords '(if while unless until begin case for def)
  "Keywords that can be used in `ruby-align-to-stmt-keywords'.")

(defcustom ruby-align-to-stmt-keywords '(def)
  "Keywords after which we align the expression body to statement.

When nil, an expression that begins with one these keywords is
indented to the column of the keyword.  Example:

  tee = if foo
          bar
        else
          qux
        end

If this value is t or contains a symbol with the name of given
keyword, the expression is indented to align to the beginning of
the statement:

  tee = if foo
    bar
  else
    qux
  end

Only has effect when `ruby-use-smie' is t."
  :type `(choice
          (const :tag "None" nil)
          (const :tag "All" t)
          (repeat :tag "User defined"
                  (choice ,@(mapcar
                             (lambda (kw) (list 'const kw))
                             ruby-alignable-keywords))))
  :safe 'listp
  :version "24.4")

(defcustom ruby-align-chained-calls nil
  "If non-nil, align chained method calls.

Each method call on a separate line will be aligned to the column
of its parent.  Example:

  my_array.select { |str| str.size > 5 }
          .map    { |str| str.downcase }

When nil, each method call is indented with the usual offset:

  my_array.select { |str| str.size > 5 }
    .map    { |str| str.downcase }

Only has effect when `ruby-use-smie' is t."
  :type 'boolean
  :safe 'booleanp
  :version "24.4")

(defcustom ruby-method-params-indent t
  "Indentation  of multiline method parameters.

When t, the parameters list is indented to the method name:

  def foo(
        baz,
        bar
      )
    hello
  end

When a number, indent the parameters list this many columns
against the beginning of the method (the \"def\" keyword).

The value nil means the same as 0:

  def foo(
    baz,
    bar
  )
    hello
  end

Only has effect when `ruby-use-smie' is t."
  :type '(choice (const :tag "Indent to the method name" t)
                 (number :tag "Indent specified number of columns against def")
                 (const :tag "Indent to def" nil))
  :safe (lambda (val) (or (memq val '(t nil)) (numberp val)))
  :version "29.1")

(defcustom ruby-block-indent t
  "Non-nil to align the body of a block to the statement's start.

The body and the closer will be aligned to the column where the
statement containing the block starts.  Example:

  foo.bar
    .each do
    baz
  end

If nil, it will be aligned instead to the beginning of the line
containing the block's opener:

  foo.bar
    .each do
      baz
    end

Only has effect when `ruby-use-smie' is t."
  :type 'boolean
  :safe 'booleanp
  :version "29.1")

(defcustom ruby-after-operator-indent t
  "Non-nil to use structural indentation after binary operators.

The code will be aligned to the implicit parent expression,
according to the operator precedence:

  qux = 4 + 5 *
            6 +
        7

Set it to nil to align to the beginning of the statement:

  qux = 4 + 5 *
    6 +
    7

Only has effect when `ruby-use-smie' is t."
  :type 'boolean
  :safe 'booleanp
  :version "29.1")

(defcustom ruby-method-call-indent t
  "Non-nil to use the structural indentation algorithm.

The method call will be aligned to the implicit parent
expression, according to the operator precedence:

  foo = subject
          .update(
            1
          )

Set it to nil to align to the beginning of the statement:

  foo = subject
    .update(
      1
    )

Only has effect when `ruby-use-smie' is t."
  :type 'boolean
  :safe 'booleanp
  :version "29.1")

(defcustom ruby-parenless-call-arguments-indent t
  "Non-nil to align arguments in a parenless call vertically.

Example:

  qux :+,
      bar,
      :[]=,
      bar

Set it to nil to align to the beginning of the statement:

  qux :+,
    bar,
    :[]=,
    bar

Only has effect when `ruby-use-smie' is t."
  :type 'boolean
  :safe 'booleanp
  :version "29.1")

(defcustom ruby-bracketed-args-indent t
  "Non-nil to align the contents of bracketed arguments with the brackets.

Example:

  qux({
        foo => bar
      })

Set it to nil to align to the beginning of the statement:

  qux({
    foo => bar
  })

Only has effect when `ruby-use-smie' is t."
  :type 'boolean
  :safe 'booleanp
  :version "30.1")

(defcustom ruby-deep-arglist t
  "Deep indent lists in parenthesis when non-nil.
Also ignores spaces after parenthesis when `space'.
Only has effect when `ruby-use-smie' is nil."
  :type 'boolean
  :safe 'booleanp)

;; FIXME Woefully under documented.  What is the point of the last t?.
(defcustom ruby-deep-indent-paren '(?\( ?\[ ?\] t)
  "Deep indent lists in parenthesis when non-nil.
The value t means continuous line.
Also ignores spaces after parenthesis when `space'.
Only has effect when `ruby-use-smie' is nil."
  :type '(choice (const nil)
                 character
                 (repeat (choice character
                                 (cons character (choice (const nil)
                                                         (const t)))
                                 (const t) ; why?
                                 ))))

(defcustom ruby-deep-indent-paren-style 'space
  "Default deep indent style.
Only has effect when `ruby-use-smie' is nil."
  :type '(choice (const t) (const nil) (const space)))

(defcustom ruby-encoding-map
  '((us-ascii       . nil)       ;; Do not put coding: us-ascii
    (utf-8          . nil)       ;; Default since Ruby 2.0
    (shift-jis      . cp932)     ;; Emacs charset name of Shift_JIS
    (shift_jis      . cp932)     ;; MIME charset name of Shift_JIS
    (japanese-cp932 . cp932))    ;; Emacs charset name of CP932
  "Alist to map encoding name from Emacs to Ruby.
Associating an encoding name with nil means it needs not be
explicitly declared in magic comment."
  :type '(repeat (cons (symbol :tag "From") (symbol :tag "To"))))

(defcustom ruby-insert-encoding-magic-comment t
  "Insert a magic Ruby encoding comment upon save if this is non-nil.
The encoding will be auto-detected.  The format of the encoding comment
is customizable via `ruby-encoding-magic-comment-style'.

When set to `always-utf8' an utf-8 comment will always be added,
even if it's not required."
  :type '(choice (const :tag "Don't insert" nil)
                 (const :tag "Insert utf-8 comment always" always-utf8)
                 (const :tag "Insert only when required" t)))

(defcustom ruby-encoding-magic-comment-style 'ruby
  "The style of the magic encoding comment to use."
  :type '(choice
          (const :tag "Emacs Style" emacs)
          (const :tag "Ruby Style" ruby)
          (const :tag "Custom Style" custom))
  :version "24.4")

(defcustom ruby-custom-encoding-magic-comment-template "# encoding: %s"
  "A custom encoding comment template.
It is used when `ruby-encoding-magic-comment-style' is set to `custom'."
  :type 'string
  :version "24.4")

(defcustom ruby-use-encoding-map t
  "Use `ruby-encoding-map' to set encoding magic comment if this is non-nil."
  :type 'boolean :group 'ruby)

(defcustom ruby-toggle-block-space-before-parameters t
  "When non-nil, ensure space between the \"toggled\" curly and parameters.
This only affects the output of the command `ruby-toggle-block'."
  :type 'boolean
  :safe 'booleanp
  :version "29.1")

;;; SMIE support

(require 'smie)

;; Here's a simplified BNF grammar, for reference:
;; https://www.cse.buffalo.edu/~regan/cse305/RubyBNF.pdf
(defconst ruby-smie-grammar
  (smie-prec2->grammar
   (smie-merge-prec2s
    (smie-bnf->prec2
     '((id)
       (insts (inst) (insts ";" insts))
       (inst (exp) (inst "iuwu-mod" exp)
             ;; Somewhat incorrect (both can be used multiple times),
             ;; but avoids lots of conflicts:
             (exp "and" exp) (exp "or" exp))
       (exp  (exp1) (exp "," exp) (exp "=" exp)
             (id " @ " exp))
       (exp1 (exp2) (exp2 "?" exp1 ":" exp1))
       (exp2 (exp3) (exp3 "." exp3)
             (exp3 "def=" exp3))
       (exp3 ("def" insts "end")
             ("begin" insts-rescue-insts "end")
             ("do" insts "end")
             ("class" insts "end") ("module" insts "end")
             ("for" for-body "end")
             ("[" expseq "]")
             ("{" hashvals "}")
             ("{" insts "}")
             ("while" insts "end")
             ("until" insts "end")
             ("unless" insts "end")
             ("if" if-body "end")
             ("case"  cases "end"))
       (formal-params ("opening-|" exp "closing-|"))
       (for-body (for-head ";" insts))
       (for-head (id "in" exp))
       (cases (exp "then" insts)
              (cases "when" cases)
              (cases "in" cases)
              (insts "else" insts))
       (expseq (exp) );;(expseq "," expseq)
       (hashvals (exp1 "=>" exp1) (hashvals "," hashvals))
       (insts-rescue-insts (insts)
                           (insts-rescue-insts "rescue" insts-rescue-insts)
                           (insts-rescue-insts "ensure" insts-rescue-insts))
       (itheni (insts) (exp "then" insts))
       (ielsei (itheni) (itheni "else" insts))
       (if-body (ielsei) (if-body "elsif" if-body)))
     '((nonassoc "in") (assoc ";") (right " @ ")
       (assoc ",") (right "="))
     '((assoc "when" "in"))
     '((assoc "elsif"))
     '((assoc "rescue" "ensure"))
     '((assoc ",")))

    (smie-precs->prec2
     '((right "=")
       (right "+=" "-=" "*=" "/=" "%=" "**=" "&=" "|=" "^="
              "<<=" ">>=" "&&=" "||=")
       (right "?")
       (nonassoc ".." "...")
       (left "&&" "||")
       (nonassoc "<=>")
       (nonassoc "==" "===" "!=")
       (nonassoc "=~" "!~")
       (nonassoc ">" ">=" "<" "<=")
       (left "^" "&" "|")
       (left "<<" ">>")
       (left "+" "-")
       (left "*" "/" "%")
       (left "**")
       (assoc "."))))))

(defun ruby-smie--bosp ()
  (save-excursion (skip-chars-backward " \t")
                  (or (and (bolp)
                           ;; Newline is escaped.
                           (not (eq (char-before (1- (point))) ?\\)))
                      (eq (char-before) ?\;)
                      (and (eq (char-before) ?=)
                           (equal (syntax-after (1- (point)))
                                  (string-to-syntax "."))))))

(defun ruby-smie--implicit-semi-p ()
  (save-excursion
    (skip-chars-backward " \t")
    (not (or (bolp)
             (memq (char-before) '(?\[ ?\())
             (and (memq (char-before)
                        '(?\; ?- ?+ ?* ?/ ?: ?. ?, ?\\ ?& ?> ?< ?% ?~ ?^ ?= ??))
                  ;; Not a binary operator symbol like :+ or :[]=.
                  ;; Or a (method or symbol) name ending with ?.
                  ;; Or the end of a regexp or a percent literal.
                  (not (memq (car (syntax-after (1- (point)))) '(3 7 15))))
             (and (eq (char-before) ?|)
                  (member (save-excursion (ruby-smie--backward-token))
                          '("|" "||")))
             (and (eq (car (syntax-after (1- (point)))) 2)
                  (member (save-excursion (ruby-smie--backward-token))
                          '("iuwu-mod" "and" "or")))
             (save-excursion
               (forward-comment (point-max))
               (looking-at "&?\\."))))))

(defun ruby-smie--redundant-do-p (&optional skip)
  (save-excursion
    (if skip (backward-word-strictly 1))
    (member (nth 2 (smie-backward-sexp ";")) '("while" "until" "for"))))

(defun ruby-smie--opening-pipe-p ()
  (save-excursion
    (if (eq ?| (char-before)) (forward-char -1))
    (skip-chars-backward " \t\n")
    (or (eq ?\{ (char-before))
        (looking-back "\\_<do" (- (point) 2)))))

(defun ruby-smie--closing-pipe-p ()
  (save-excursion
    (if (eq ?| (char-before)) (forward-char -1))
    (and (re-search-backward "|" (line-beginning-position) t)
         (ruby-smie--opening-pipe-p))))

(defun ruby-smie--args-separator-p (pos)
  (and
   (< pos (line-end-position))
   (or (eq (char-syntax (preceding-char)) '?w)
       ;; FIXME: Check that the preceding token is not a keyword.
       ;; This isn't very important most of the time, though.
       (and (memq (preceding-char) '(?! ??))
            (eq (char-syntax (char-before (1- (point)))) '?w)))
   (save-excursion
     (goto-char pos)
     (or (and (eq (char-syntax (char-after)) ?w)
              (not (looking-at (regexp-opt '("unless" "if" "while" "until" "or"
                                             "else" "elsif" "do" "end" "and")
                                           'symbols))))
         (memq (car (syntax-after pos)) '(7 15))
         (looking-at "[([]\\|[-+!~:@$]\\(?:\\sw\\|\\s_\\)")))))

(defun ruby-smie--before-method-name ()
  ;; Only need to be accurate when method has keyword name.
  (and (eq ?w (char-syntax (following-char)))
       (or
        (and
         (eq (char-before) ?.)
         (not (eq (char-before (1- (point))) ?.)))
        (looking-back "^\\s *def\\s +\\=" (line-beginning-position)))))

(defun ruby-smie--forward-token ()
  (let ((pos (point)))
    (skip-chars-forward " \t")
    (cond
     ((and (looking-at "\n") (looking-at "\\s\""))  ;A heredoc.
      ;; Tokenize the whole heredoc as semicolon.
      (goto-char (scan-sexps (point) 1))
      ";")
     ((and (looking-at "[\n#]")
           (ruby-smie--implicit-semi-p)) ;Only add implicit ; when needed.
      (if (eolp) (forward-char 1) (forward-comment 1))
      ";")
     (t
      (forward-comment (point-max))
      (cond
       ((and (< pos (point))
             (save-excursion
               (ruby-smie--args-separator-p (prog1 (point) (goto-char pos)))))
        " @ ")
       ((looking-at "\\s\"") "")                    ;A string.
       (t
        (let ((dot (ruby-smie--before-method-name))
              (tok (smie-default-forward-token)))
          (when dot
            (setq tok (concat "." tok)))
          (cond
           ((member tok '("unless" "if" "while" "until"))
            (if (save-excursion (forward-word-strictly -1) (ruby-smie--bosp))
                tok "iuwu-mod"))
           ((string-match-p "\\`|[*&]*\\'" tok)
            (forward-char (- 1 (length tok)))
            (setq tok "|")
            (cond
             ((ruby-smie--opening-pipe-p) "opening-|")
             ((ruby-smie--closing-pipe-p) "closing-|")
             (t tok)))
           ((string-match "\\`[^|]+|\\'" tok)
            (forward-char -1)
            (substring tok 0 -1))
           ((and (equal tok "") (looking-at "\\\\\n"))
            (goto-char (match-end 0)) (ruby-smie--forward-token))
           ((equal tok "do")
            (cond
             ((not (ruby-smie--redundant-do-p 'skip)) tok)
             ((> (save-excursion (forward-comment (point-max)) (point))
                 (line-end-position))
              (ruby-smie--forward-token)) ;Fully redundant.
             (t ";")))
           ((equal tok "&.") ".")
           ((and (equal tok "def")
                 (looking-at ruby-endless-method-head-re))
            "def=")
           (t tok)))))))))

(defun ruby-smie--backward-token ()
  (let ((pos (point)))
    (forward-comment (- (point)))
    (cond
     ((and (> pos (line-end-position)) (ruby-smie--implicit-semi-p))
      (skip-chars-forward " \t") ";")
     ((and (bolp) (not (bobp)))         ;Presumably a heredoc.
      ;; Tokenize the whole heredoc as semicolon.
      (goto-char (scan-sexps (point) -1))
      ";")
     ((and (> pos (point)) (not (bolp))
           (ruby-smie--args-separator-p pos))
      ;; We have "ID SPC ID", which is a method call, but it binds less tightly
      ;; than commas, since a method call can also be "ID ARG1, ARG2, ARG3".
      ;; In some textbooks, "e1 @ e2" is used to mean "call e1 with arg e2".
      " @ ")
     (t
      (let ((tok (smie-default-backward-token))
            (dot (ruby-smie--before-method-name)))
        (when dot
          (setq tok (concat "." tok)))
        (cond
         ((member tok '("unless" "if" "while" "until"))
          (if (ruby-smie--bosp)
              tok "iuwu-mod"))
         ((equal tok "|")
          (cond
           ((ruby-smie--opening-pipe-p) "opening-|")
           ((ruby-smie--closing-pipe-p) "closing-|")
           (t tok)))
         ((string-match-p "\\`[^|]+|\\'" tok) "closing-|")
         ((string-match-p "\\`|[*&]*\\'" tok)
          (forward-char 1)
          (substring tok 1))
         ((and (equal tok "") (eq ?\\ (char-before)) (looking-at "\n"))
          (forward-char -1) (ruby-smie--backward-token))
         ((equal tok "do")
          (cond
           ((not (ruby-smie--redundant-do-p)) tok)
           ((> (save-excursion (forward-word-strictly 1)
                               (forward-comment (point-max)) (point))
               (line-end-position))
            (ruby-smie--backward-token)) ;Fully redundant.
           (t ";")))
         ((equal tok "&.") ".")
         ((and (equal tok "def")
               (looking-at (concat "def" ruby-endless-method-head-re)))
          "def=")
         (t tok)))))))

(defun ruby-smie--indent-to-stmt (&optional offset)
  (save-excursion
    (smie-backward-sexp ";")
    (cons 'column (+ (smie-indent-virtual) (or offset 0)))))

(defun ruby-smie--indent-to-stmt-p (keyword)
  (or (eq t ruby-align-to-stmt-keywords)
      (memq (intern keyword) ruby-align-to-stmt-keywords)))

(defun ruby-smie-rules (kind token)
  (pcase (cons kind token)
    ('(:elem . basic) ruby-indent-level)
    ;; "foo" "bar" is the concatenation of the two strings, so the second
    ;; should be aligned with the first.
    ('(:elem . args) (if (looking-at "\\s\"") 0))
    ;; (`(:after . ",") (smie-rule-separator kind))
    ('(:before . ";")
     (cond
      ((smie-rule-parent-p "def" "begin" "do" "class" "module" "for"
                           "while" "until" "unless"
                           "if" "then" "elsif" "else" "when" "in"
                           "rescue" "ensure" "{")
       (smie-rule-parent ruby-indent-level))
      ;; For (invalid) code between switch and case.
      ;; (if (smie-parent-p "switch") 4)
      ))
    (`(:before . ,(or "(" "[" "{"))
     (cond
      ((and (not (eq ruby-bracketed-args-indent t))
            (smie-rule-prev-p "," "(" "["))
       (cons 'column (current-indentation)))
      ((and (equal token "{")
            (not (smie-rule-prev-p "(" "{" "[" "," "=>" "=" "return" ";" "do"))
            (save-excursion
              (forward-comment -1)
              (not (eq (preceding-char) ?:))))
       ;; Curly block opener.
       (if ruby-block-indent
           (ruby-smie--indent-to-stmt)
         (cons 'column (current-indentation))))
      ((smie-rule-hanging-p)
       ;; Treat purely syntactic block-constructs as being part of their parent,
       ;; when the opening token is hanging and the parent is not an
       ;; open-paren.
       (cond
        ((eq (car (smie-indent--parent)) t) nil)
        ;; When after `.', let's always de-indent,
        ;; because when `.' is inside the line, the
        ;; additional indentation from it looks out of place.
        ((smie-rule-parent-p ".")
         ;; Traverse up the call chain until the parent is not `.',
         ;; or `.' at indentation, or at eol.
         (while (and (not (ruby-smie--bosp))
                     (equal (nth 2 (smie-backward-sexp ".")) ".")
                     (not (ruby-smie--bosp)))
           (forward-char -1))
         (smie-indent-virtual))
        ((save-excursion
           (and (smie-rule-parent-p " @ ")
                (goto-char (nth 1 (smie-indent--parent)))
                (smie-rule-prev-p "def=")
                (cons 'column (- (current-column) 3)))))
        (t (smie-rule-parent))))))
    (`(:after . ,(or "(" "[" "{"))
     ;; FIXME: Shouldn't this be the default behavior of
     ;; `smie-indent-after-keyword'?
     (save-excursion
       (forward-char 1)
       (skip-chars-forward " \t")
       ;; `smie-rule-hanging-p' is not good enough here,
       ;; because we want to reject hanging tokens at bol, too.
       (unless (or (eolp) (forward-comment 1))
         (cons 'column (current-column)))))
    ('(:before . " @ ")
     (cond
      ((and (not ruby-parenless-call-arguments-indent)
            (not (smie-rule-parent-p "def" "def=")))
       (ruby-smie--indent-to-stmt ruby-indent-level))
      ((or (eq ruby-method-params-indent t)
           (not (smie-rule-parent-p "def" "def=")))
       (save-excursion
         (skip-chars-forward " \t")
         (cons 'column (current-column))))
      (t (smie-rule-parent (or ruby-method-params-indent 0)))))
    ('(:before . "do")
     (if ruby-block-indent
         (ruby-smie--indent-to-stmt)
       (cons 'column (current-indentation))))
    ('(:before . ".")
     (if (smie-rule-sibling-p)
         (when ruby-align-chained-calls
           (while
               (let ((pos (point))
                     (parent (smie-backward-sexp ".")))
                 (if (not (equal (nth 2 parent) "."))
                     (progn (goto-char pos) nil)
                   (goto-char (nth 1 parent))
                   (not (smie-rule-bolp)))))
           (cons 'column (current-column)))
       (smie-backward-sexp ".")
       (if ruby-method-call-indent
           (cons 'column (+ (current-column)
                            ruby-indent-level))
         (ruby-smie--indent-to-stmt ruby-indent-level))))
    (`(:before . ,(or "else" "then" "elsif" "rescue" "ensure"))
     (smie-rule-parent))
    (`(:before . ,(or "when" "in"))
     ;; Align to the previous `when', but look up the virtual
     ;; indentation of `case'.
     (if (smie-rule-sibling-p) 0 (smie-rule-parent)))
    (`(:after . ,(or "=" "+" "-" "*" "/" "&&" "||" "%" "**" "^" "&"
                     "<=>" ">" "<" ">=" "<=" "==" "===" "!=" "<<" ">>"
                     "+=" "-=" "*=" "/=" "%=" "**=" "&=" "|=" "^=" "|"
                     "<<=" ">>=" "&&=" "||=" "and" "or"))
     (cond
      ((not ruby-after-operator-indent)
       (ruby-smie--indent-to-stmt (if (smie-indent--hanging-p)
                                      ruby-indent-level
                                    0)))
      ((and (smie-rule-parent-p ";" nil)
            (smie-indent--hanging-p))
       ruby-indent-level)))
    (`(:before . "=")
     (or
      (save-excursion
        (and (smie-rule-parent-p " @ ")
             (goto-char (nth 1 (smie-indent--parent)))
             (smie-rule-prev-p "def=")
             (cons 'column (+ (current-column) ruby-indent-level -3))))
      (and (smie-rule-parent-p ",")
           (smie-rule-parent))))
    (`(:after . ,(or "?" ":"))
     (if ruby-after-operator-indent
         ruby-indent-level
       (ruby-smie--indent-to-stmt ruby-indent-level)))
    (`(:before . ,(guard (memq (intern-soft token) ruby-alignable-keywords)))
     (when (not (ruby--at-indentation-p))
       (if (ruby-smie--indent-to-stmt-p token)
           (ruby-smie--indent-to-stmt)
         (cons 'column (current-column)))))
    ('(:before . "iuwu-mod")
     (smie-rule-parent ruby-indent-level))
    (`(:before . ",")
     (and (not ruby-parenless-call-arguments-indent)
          (smie-rule-parent-p " @ ")
          (ruby-smie--indent-to-stmt ruby-indent-level)))))

(defun ruby--at-indentation-p (&optional point)
  (save-excursion
    (unless point (setq point (point)))
    (forward-line 0)
    (skip-chars-forward " \t")
    (eq (point) point)))

(defun ruby-imenu-create-index-in-block (prefix beg end)
  "Create an imenu index of methods inside a block."
  (let ((index-alist '()) (case-fold-search nil)
        name next pos decl sing)
    (goto-char beg)
    (while (re-search-forward "^\\s *\\(\\(class\\s +\\|\\(class\\s *<<\\s *\\)\\|module\\s +\\)\\([^(<\n ]+\\)\\|\\(\\(?:\\(?:private\\|protected\\|public\\) +\\)?def\\|alias\\)\\s +\\([^(\n ]+\\)\\)" end t)
      (setq sing (match-beginning 3))
      (setq decl (match-string 5))
      (setq next (match-end 0))
      (setq name (or (match-string 4) (match-string 6)))
      (setq pos (match-beginning 0))
      (cond
       ((string= "alias" decl)
        (if prefix (setq name (concat prefix name)))
        (push (cons name pos) index-alist))
       ((not (null decl))
        (if prefix
            (setq name
                  (cond
                   ((string-match "^self\\." name)
                    (concat (substring prefix 0 -1) (substring name 4)))
                  (t (concat prefix name)))))
        (push (cons name pos) index-alist)
        (ruby-accurate-end-of-block end))
       (t
        (if (string= "self" name)
            (if prefix (setq name (substring prefix 0 -1)))
          (if prefix (setq name (concat (substring prefix 0 -1) "::" name)))
          (push (cons name pos) index-alist))
        (ruby-accurate-end-of-block end)
        (setq beg (point))
        (setq index-alist
              (nconc (ruby-imenu-create-index-in-block
                      (concat name (if sing "." "#"))
                      next beg) index-alist))
        (goto-char beg))))
    index-alist))

(defun ruby-imenu-create-index ()
  "Create an imenu index of all methods in the buffer."
  (nreverse (ruby-imenu-create-index-in-block nil (point-min) nil)))

(defun ruby-accurate-end-of-block (&optional end)
  "Jump to the end of the current block or END, whichever is closer."
  (let (state
        (end (or end (point-max))))
    (if ruby-use-smie
        (save-restriction
          (back-to-indentation)
          (narrow-to-region (point) end)
          (smie-forward-sexp))
      (while (and (setq state (apply #'ruby-parse-partial end state))
                    (>= (nth 2 state) 0) (< (point) end))))))

(defun ruby--insert-coding-comment (encoding)
  "Insert a magic coding comment for ENCODING.
The style of the comment is controlled by `ruby-encoding-magic-comment-style'."
  (let ((encoding-magic-comment-template
         (pcase ruby-encoding-magic-comment-style
           ('ruby "# coding: %s")
           ('emacs "# -*- coding: %s -*-")
           ('custom
            ruby-custom-encoding-magic-comment-template))))
    (insert
     (format encoding-magic-comment-template encoding)
     "\n")))

(defun ruby--detect-encoding ()
  (if (eq ruby-insert-encoding-magic-comment 'always-utf8)
      'utf-8
    (let ((coding-system
           (or save-buffer-coding-system
               buffer-file-coding-system)))
      (if coding-system
          (setq coding-system
                (or (coding-system-get coding-system 'mime-charset)
                    (coding-system-change-eol-conversion coding-system nil))))
      (if coding-system
          (if ruby-use-encoding-map
              (let ((elt (assq coding-system ruby-encoding-map)))
                (if elt (cdr elt) coding-system))
            coding-system)
        'ascii-8bit))))

(defun ruby--encoding-comment-required-p ()
  (or (eq ruby-insert-encoding-magic-comment 'always-utf8)
      (re-search-forward "[^\0-\177]" nil t)))

(defun ruby-mode-set-encoding ()
  "Insert a magic comment header with the proper encoding if necessary."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (ruby--encoding-comment-required-p)
        (goto-char (point-min))
        (let ((coding-system (ruby--detect-encoding)))
          (when coding-system
            (if (looking-at "^#!") (beginning-of-line 2))
            (cond ((looking-at "\\s *#.*\\(en\\)?coding\\s *:\\s *\\([-a-z0-9_]*\\)")
                   ;; update existing encoding comment if necessary
                   (unless (string= (match-string 2) coding-system)
                     (goto-char (match-beginning 2))
                     (delete-region (point) (match-end 2))
                     (insert (symbol-name coding-system))))
                  ((looking-at "\\s *#.*coding\\s *[:=]"))
                  (t (when ruby-insert-encoding-magic-comment
                       (ruby--insert-coding-comment coding-system))))
            (when (buffer-modified-p)
              (basic-save-buffer-1))))))))

(defvar ruby--electric-indent-chars '(?. ?\) ?} ?\]))

(defun ruby--electric-indent-p (char)
  (cond
   ((memq char ruby--electric-indent-chars)
    ;; Reindent after typing a char affecting indentation.
    (ruby--at-indentation-p (1- (point))))
   ((memq (char-after) ruby--electric-indent-chars)
    ;; Reindent after inserting something in front of the above.
    (ruby--at-indentation-p (1- (point))))
   ((or (and (>= char ?a) (<= char ?z)) (memq char '(?_ ?? ?! ?:)))
    (let ((pt (point)))
      (save-excursion
        (skip-chars-backward "[:alpha:]:_?!")
        (and (ruby--at-indentation-p)
             (looking-at (regexp-opt (cons "end" ruby-block-mid-keywords)))
             ;; Outdent after typing a keyword.
             (or (eq (match-end 0) pt)
                 ;; Reindent if it wasn't a keyword after all.
                 (eq (match-end 0) (1- pt)))))))))

;; FIXME: Remove this?  It's unused here, but some redefinitions of
;; `ruby-calculate-indent' in user init files still call it.
(defun ruby-current-indentation ()
  "Return the indentation level of current line."
  (declare (obsolete current-indentation "28.1"))
  (save-excursion
    (beginning-of-line)
    (back-to-indentation)
    (current-column)))

(defun ruby-indent-line (&optional _ignored)
  "Correct the indentation of the current Ruby line."
  (interactive)
  (ruby-indent-to (ruby-calculate-indent)))

(defun ruby-indent-to (column)
  "Indent the current line to COLUMN."
  (when column
    (let (shift top beg)
      (and (< column 0) (error "Invalid nesting"))
      (setq shift (current-column))
      (beginning-of-line)
      (setq beg (point))
      (back-to-indentation)
      (setq top (current-column))
      (skip-chars-backward " \t")
      (if (>= shift top) (setq shift (- shift top))
        (setq shift 0))
      (if (and (bolp)
               (= column top))
          (move-to-column (+ column shift))
        (move-to-column top)
        (delete-region beg (point))
        (beginning-of-line)
        (indent-to column)
        (move-to-column (+ column shift))))))

(defun ruby-special-char-p (&optional pos)
  "Return t if the character before POS is a special character.
If omitted, POS defaults to the current point.
Special characters are `?', `$', `:' when preceded by whitespace,
and `\\' when preceded by `?'."
  (setq pos (or pos (point)))
  (let ((c (char-before pos)) (b (and (< (point-min) pos)
				      (char-before (1- pos)))))
    (cond ((or (eq c ??) (eq c ?$)))
          ((and (eq c ?:) (or (not b) (eq (char-syntax b) ? ))))
          ((eq c ?\\) (eq b ??)))))

(defun ruby-verify-heredoc (&optional pos)
  (save-excursion
    (when pos (goto-char pos))
    ;; Not right after a symbol or prefix character.
    ;; Method names are only allowed when separated by
    ;; whitespace.  Not a limitation in Ruby, but it's hard for
    ;; us to do better.
    (when (not (memq (car (syntax-after (1- (point)))) '(2 3 6 10)))
      (or (not (memq (char-before) '(?\s ?\t)))
          (ignore (forward-word-strictly -1))
          (eq (char-before) ?_)
          (not (looking-at ruby-singleton-class-re))))))

(defun ruby-expr-beg (&optional option)
  "Check if point is possibly at the beginning of an expression.
OPTION specifies the type of the expression.
Can be one of `heredoc', `modifier', `expr-qstr', `expr-re'."
  (save-excursion
    (store-match-data nil)
    (let ((space (skip-chars-backward " \t"))
          (start (point)))
      (cond
       ((bolp) t)
       ((progn
          (forward-char -1)
          (and (looking-at "\\?")
               (or (eq (char-syntax (char-before (point))) ?w)
                   (ruby-special-char-p))))
        nil)
       ((looking-at ruby-operator-re))
       ((eq option 'heredoc)
        (and (< space 0) (ruby-verify-heredoc start)))
       ((or (looking-at "[\\[({,;]")
            (and (looking-at "[!?]")
                 (or (not (eq option 'modifier))
                     (bolp)
                     (save-excursion (forward-char -1) (looking-at "\\Sw$"))))
            (and (looking-at ruby-symbol-re)
                 (skip-chars-backward ruby-symbol-chars)
                 (cond
                  ((looking-at (regexp-opt
                                (append ruby-block-beg-keywords
                                        ruby-block-op-keywords
                                        ruby-block-mid-keywords)
                                'words))
                   (goto-char (match-end 0))
                   (not (looking-at "\\s_")))
                  ((eq option 'expr-qstr)
                   (looking-at "[a-zA-Z][a-zA-Z0-9_]* +%[^ \t]"))
                  ((eq option 'expr-re)
                   (looking-at "[a-zA-Z][a-zA-Z0-9_]* +/[^ \t]"))
                  (t nil)))))))))

(defun ruby-forward-string (term &optional end no-error expand)
  "Move forward across one balanced pair of string delimiters.
Skips escaped delimiters.  If EXPAND is non-nil, also ignores
delimiters in interpolated strings.

TERM should be a string containing either a single, self-matching
delimiter (e.g. \"/\"), or a pair of matching delimiters with the
close delimiter first (e.g. \"][\").

When non-nil, search is bounded by position END.

Throws an error if a balanced match is not found, unless NO-ERROR
is non-nil, in which case nil will be returned.

This command assumes the character after point is an opening
delimiter."
  (let ((n 1) (c (string-to-char term))
        (re (concat "[^\\]\\(\\\\\\\\\\)*\\("
                    (if (string= term "^") ;[^] is not a valid regexp
                        "\\^"
                      (concat "[" term "]"))
                    (when expand "\\|\\(#{\\)")
                    "\\)")))
    (while (and (re-search-forward re end no-error)
                (if (match-beginning 3)
                    (ruby-forward-string "}{" end no-error nil)
                  (> (setq n (if (eq (char-before (point)) c)
                                     (1- n) (1+ n))) 0)))
      (forward-char -1))
    (cond ((zerop n))
          (no-error nil)
          ((error "Unterminated string")))))

(defun ruby-deep-indent-paren-p (c)
  "TODO: document."
  (cond ((listp ruby-deep-indent-paren)
         (let ((deep (assoc c ruby-deep-indent-paren)))
           (cond (deep
                  (or (cdr deep) ruby-deep-indent-paren-style))
                 ((memq c ruby-deep-indent-paren)
                  ruby-deep-indent-paren-style))))
        ((eq c ruby-deep-indent-paren) ruby-deep-indent-paren-style)
        ((eq c ?\( ) ruby-deep-arglist)))

(defun ruby-parse-partial (&optional end in-string nest depth pcol indent)
  ;; FIXME: Document why we can't just use parse-partial-sexp.
  "TODO: document throughout function body."
  (or depth (setq depth 0))
  (or indent (setq indent 0))
  (when (re-search-forward ruby-delimiter end 'move)
    (let ((pnt (point)) w re expand)
      (goto-char (match-beginning 0))
      (cond
       ((and (memq (char-before) '(?@ ?$)) (looking-at "\\sw"))
        (goto-char pnt))
       ((looking-at "[\"`]")            ;skip string
        (cond
         ((and (not (eobp))
               (ruby-forward-string (buffer-substring (point) (1+ (point)))
                                    end t t))
          nil)
         (t
          (setq in-string (point))
          (goto-char end))))
       ((looking-at "'")
        (cond
         ((and (not (eobp))
               (re-search-forward "[^\\]\\(\\\\\\\\\\)*'" end t))
          nil)
         (t
          (setq in-string (point))
          (goto-char end))))
       ((looking-at "/=")
        (goto-char pnt))
       ((looking-at "/")
        (cond
         ((and (not (eobp)) (ruby-expr-beg 'expr-re))
          (if (ruby-forward-string "/" end t t)
              nil
            (setq in-string (point))
            (goto-char end)))
         (t
          (goto-char pnt))))
       ((looking-at "%")
        (cond
         ((and (not (eobp))
               (ruby-expr-beg 'expr-qstr)
               (not (looking-at "%="))
               (looking-at "%[QqrxWw]?\\([^a-zA-Z0-9 \t\n]\\)"))
          (goto-char (match-beginning 1))
          (setq expand (not (memq (char-before) '(?q ?w))))
          (setq w (match-string 1))
          (cond
           ((string= w "[") (setq re "]["))
           ((string= w "{") (setq re "}{"))
           ((string= w "(") (setq re ")("))
           ((string= w "<") (setq re "><"))
           ((and expand (string= w "\\"))
            (setq w (concat "\\" w))))
          (unless (cond (re (ruby-forward-string re end t expand))
                        (expand (ruby-forward-string w end t t))
                        (t (re-search-forward
                            (if (string= w "\\")
                                "\\\\[^\\]*\\\\"
                              (concat "[^\\]\\(\\\\\\\\\\)*" w))
                            end t)))
            (setq in-string (point))
            (goto-char end)))
         (t
          (goto-char pnt))))
       ((looking-at "\\?")              ;skip ?char
        (cond
         ((and (ruby-expr-beg)
               (looking-at "\\?\\(\\\\C-\\|\\\\M-\\)*\\\\?."))
          (goto-char (match-end 0)))
         (t
          (goto-char pnt))))
       ((looking-at "\\$")              ;skip $char
        (goto-char pnt)
        (forward-char 1))
       ((looking-at "#")                ;skip comment
        (forward-line 1)
        (goto-char (point))
        )
       ((looking-at "[\\[{(]")
        (setq nest (cons (cons (char-after (point)) pnt) nest))
        (setq depth (1+ depth))
        (goto-char pnt)
        )
       ((looking-at "[])}]")
        (setq depth (1- depth))
        (setq nest (cdr nest))
        (goto-char pnt))
       ((looking-at ruby-block-end-re)
        (if (or (and (not (bolp))
                     (progn
                       (forward-char -1)
                       (setq w (char-after (point)))
                       (or (eq ?_ w)
                           (eq ?. w))))
                (progn
                  (goto-char pnt)
                  (setq w (char-after (point)))
                  (or (eq ?_ w)
                      (eq ?! w)
                      (eq ?? w))))
            nil
          (setq nest (cdr nest))
          (setq depth (1- depth)))
        (goto-char pnt))
       ((looking-at "def\\s +[^(\n;]*")
        (if (or (bolp)
                (progn
                  (forward-char -1)
                  (not (eq ?_ (char-after (point))))))
            (progn
              (setq nest (cons (cons nil pnt) nest))
              (setq depth (1+ depth))))
        (goto-char (match-end 0)))
       ((looking-at (concat "\\_<\\(" ruby-block-beg-re "\\)\\_>"))
        (and
         (save-match-data
           (or (not (looking-at "do\\_>"))
               (save-excursion
                 (back-to-indentation)
                 (not (looking-at ruby-non-block-do-re)))))
         (or (bolp)
             (progn
               (forward-char -1)
               (setq w (char-after (point)))
               (not (or (eq ?_ w)
                        (eq ?. w)))))
         (goto-char pnt)
         (not (eq ?! (char-after (point))))
         (skip-chars-forward " \t")
         (goto-char (match-beginning 0))
         (or (not (looking-at ruby-modifier-re))
             (ruby-expr-beg 'modifier))
         (goto-char pnt)
         (setq nest (cons (cons nil pnt) nest))
         (setq depth (1+ depth)))
        (goto-char pnt))
       ((looking-at ":\\(['\"]\\)")
        (goto-char (match-beginning 1))
        (ruby-forward-string (match-string 1) end t))
       ((looking-at ":\\([-,.+*/%&|^~<>]=?\\|===?\\|<=>\\|![~=]?\\)")
        (goto-char (match-end 0)))
       ((looking-at ":\\([a-zA-Z_][a-zA-Z_0-9]*[!?=]?\\)?")
        (goto-char (match-end 0)))
       ((or (looking-at "\\.\\.\\.?")
            (looking-at "\\.[0-9]+")
            (looking-at "\\.[a-zA-Z_0-9]+")
            (looking-at "\\."))
        (goto-char (match-end 0)))
       ((looking-at "^=begin")
        (if (re-search-forward "^=end" end t)
            (forward-line 1)
          (setq in-string (match-end 0))
          (goto-char end)))
       ((looking-at "<<")
        (cond
         ((and (ruby-expr-beg 'heredoc)
               (looking-at "<<\\([-~]\\)?\\(\\([\"'`]\\)\\([^\n]+?\\)\\3\\|\\(?:\\sw\\|\\s_\\)+\\)"))
          (setq re (regexp-quote (or (match-string 4) (match-string 2))))
          (if (match-beginning 1) (setq re (concat "\\s *" re)))
          (let* ((id-end (goto-char (match-end 0)))
                 (line-end-position (line-end-position))
                 (state (list in-string nest depth pcol indent)))
            ;; parse the rest of the line
            (while (and (> line-end-position (point))
                        (setq state (apply #'ruby-parse-partial
                                           line-end-position state))))
            (setq in-string (car state)
                  nest (nth 1 state)
                  depth (nth 2 state)
                  pcol (nth 3 state)
                  indent (nth 4 state))
            ;; skip heredoc section
            (if (re-search-forward (concat "^" re "$") end 'move)
                (forward-line 1)
              (setq in-string id-end)
              (goto-char end))))
         (t
          (goto-char pnt))))
       ((looking-at "^__END__$")
        (goto-char pnt))
       ((and (looking-at ruby-here-doc-beg-re)
	     (boundp 'ruby-indent-point))
        (if (re-search-forward (ruby-here-doc-end-match)
                               ruby-indent-point t)
            (forward-line 1)
          (setq in-string (match-end 0))
          (goto-char ruby-indent-point)))
       (t
        (error "Bad string %s" (buffer-substring (point) pnt))))))
  (list in-string nest depth pcol))

(defun ruby-parse-region (start end)
  "TODO: document."
  (let (state)
    (save-excursion
      (if start
          (goto-char start)
        (ruby-beginning-of-indent))
      (save-restriction
        (narrow-to-region (point) end)
        (while (and (> end (point))
                    (setq state (apply #'ruby-parse-partial end state))))))
    (list (nth 0 state)                 ; in-string
          (car (nth 1 state))           ; nest
          (nth 2 state)                 ; depth
          (car (car (nth 3 state)))     ; pcol
          ;(car (nth 5 state))          ; indent
          )))

(defun ruby-indent-size (pos nest)
  "Return the indentation level in spaces NEST levels deeper than POS."
  (+ pos (* (or nest 1) ruby-indent-level)))

(defun ruby-calculate-indent (&optional parse-start)
  "Return the proper indentation level of the current line."
  ;; TODO: Document body
  (save-excursion
    (beginning-of-line)
    (let ((ruby-indent-point (point))
          (case-fold-search nil)
          state eol begin op-end
          (paren (progn (skip-syntax-forward " ")
                        (and (char-after) (matching-paren (char-after)))))
          (indent 0))
      (if parse-start
          (goto-char parse-start)
        (ruby-beginning-of-indent)
        (setq parse-start (point)))
      (back-to-indentation)
      (setq indent (current-column))
      (setq state (ruby-parse-region parse-start ruby-indent-point))
      (cond
       ((nth 0 state)                   ; within string
        (setq indent nil))              ;  do nothing
       ((car (nth 1 state))             ; in paren
        (goto-char (setq begin (cdr (nth 1 state))))
        (let ((deep (ruby-deep-indent-paren-p (car (nth 1 state)))))
          (if deep
              (cond ((and (eq deep t) (eq (car (nth 1 state)) paren))
                     (skip-syntax-backward " ")
                     (setq indent (1- (current-column))))
                    ((let ((s (ruby-parse-region (point) ruby-indent-point)))
                       (and (nth 2 s) (> (nth 2 s) 0)
                            (or (goto-char (cdr (nth 1 s))) t)))
                     (forward-word-strictly -1)
                     (setq indent (ruby-indent-size (current-column)
						    (nth 2 state))))
                    (t
                     (setq indent (current-column))
                     (cond ((eq deep 'space))
                           (paren (setq indent (1- indent)))
                           (t (setq indent (ruby-indent-size (1- indent) 1))))))
            (if (nth 3 state) (goto-char (nth 3 state))
              (goto-char parse-start) (back-to-indentation))
            (setq indent (ruby-indent-size (current-column) (nth 2 state))))
          (and (eq (car (nth 1 state)) paren)
               (ruby-deep-indent-paren-p (matching-paren paren))
               (search-backward (char-to-string paren))
               (setq indent (current-column)))))
       ((and (nth 2 state) (> (nth 2 state) 0)) ; in nest
        (if (null (cdr (nth 1 state)))
            (error "Invalid nesting"))
        (goto-char (cdr (nth 1 state)))
        (forward-word-strictly -1)               ; skip back a keyword
        (setq begin (point))
        (cond
         ((looking-at "do\\>[^_]")      ; iter block is a special case
          (if (nth 3 state) (goto-char (nth 3 state))
            (goto-char parse-start) (back-to-indentation))
          (setq indent (ruby-indent-size (current-column) (nth 2 state))))
         (t
          (setq indent (+ (current-column) ruby-indent-level)))))

       ((and (nth 2 state) (< (nth 2 state) 0)) ; in negative nest
        (setq indent (ruby-indent-size (current-column) (nth 2 state)))))
      (when indent
        (goto-char ruby-indent-point)
        (end-of-line)
        (setq eol (point))
        (beginning-of-line)
        (cond
         ((and (not (ruby-deep-indent-paren-p paren))
               (re-search-forward ruby-negative eol t))
          (and (not (eq ?_ (char-after (match-end 0))))
               (setq indent (- indent ruby-indent-level))))
         ((and
           (save-excursion
             (beginning-of-line)
             (not (bobp)))
           (or (ruby-deep-indent-paren-p t)
               (null (car (nth 1 state)))))
          ;; goto beginning of non-empty no-comment line
          (let (end done)
            (while (not done)
              (skip-chars-backward " \t\n")
              (setq end (point))
              (beginning-of-line)
              (if (re-search-forward "^\\s *#" end t)
                  (beginning-of-line)
                (setq done t))))
          (end-of-line)
          ;; skip the comment at the end
          (skip-chars-backward " \t")
          (let (end (pos (point)))
            (beginning-of-line)
            (while (and (re-search-forward "#" pos t)
                        (setq end (1- (point)))
                        (or (ruby-special-char-p end)
                            (and (setq state (ruby-parse-region
                                              parse-start end))
                                 (nth 0 state))))
              (setq end nil))
            (goto-char (or end pos))
            (skip-chars-backward " \t")
            (setq begin (if (and end (nth 0 state)) pos (cdr (nth 1 state))))
            (setq state (ruby-parse-region parse-start (point))))
          (or (bobp) (forward-char -1))
          (and
           (or (and (looking-at ruby-symbol-re)
                    (skip-chars-backward ruby-symbol-chars)
                    (looking-at (concat "\\<\\(" ruby-block-hanging-re
                                        "\\)\\>"))
                    (not (eq (point) (nth 3 state)))
                    (save-excursion
                      (goto-char (match-end 0))
                      (not (looking-at "[a-z_]"))))
               (and (looking-at ruby-operator-re)
                    (not (ruby-special-char-p))
                    (save-excursion
                      (forward-char -1)
                      (or (not (looking-at ruby-operator-re))
                          (not (eq (char-before) ?:))))
                    ;; Operator at the end of line.
                    (let ((c (char-after (point))))
                      (and
;;                     (or (null begin)
;;                         (save-excursion
;;                           (goto-char begin)
;;                           (skip-chars-forward " \t")
;;                           (not (or (eolp) (looking-at "#")
;;                                    (and (eq (car (nth 1 state)) ?{)
;;                                         (looking-at "|"))))))
                       ;; Not a regexp or percent literal.
                       (null (nth 0 (ruby-parse-region (or begin parse-start)
                                                       (point))))
                       (or (not (eq ?| (char-after (point))))
                           (save-excursion
                             (or (eolp) (forward-char -1))
                             (cond
                              ((search-backward "|" nil t)
                               (skip-chars-backward " \t\n")
                               (and (not (eolp))
                                    (progn
                                      (forward-char -1)
                                      (not (looking-at "{")))
                                    (progn
                                      (forward-word-strictly -1)
                                      (not (looking-at "do\\>[^_]")))))
                              (t t))))
                       (not (eq ?, c))
                       (setq op-end t)))))
           (setq indent
                 (cond
                  ((and
                    (null op-end)
                    (not (looking-at (concat "\\<\\(" ruby-block-hanging-re
                                             "\\)\\>")))
                    (eq (ruby-deep-indent-paren-p t) 'space)
                    (not (bobp)))
                   (goto-char (or begin parse-start))
                   (skip-syntax-forward " ")
                   (current-column))
                  ((car (nth 1 state)) indent)
                  (t
                   (+ indent ruby-indent-level))))))))
      (goto-char ruby-indent-point)
      (beginning-of-line)
      (skip-syntax-forward " ")
      (if (looking-at "\\.[^.]\\|&\\.")
          (+ indent ruby-indent-level)
        indent))))

(defun ruby-beginning-of-defun (&optional arg)
  "Move backward to the beginning of the current defun.
With ARG, move backward multiple defuns.  Negative ARG means
move forward."
  (interactive "p")
  (let (case-fold-search)
    (when (re-search-backward (concat "^\\s *" ruby-defun-beg-re "\\_>")
                              nil t (or arg 1))
      (beginning-of-line)
      t)))

(defun ruby-end-of-defun ()
  "Move point to the end of the current defun.
The defun begins at or after the point.  This function is called
by `end-of-defun'."
  (interactive "p")
  (with-suppressed-warnings ((obsolete ruby-forward-sexp))
    (ruby-forward-sexp))
  (let (case-fold-search)
    (when (looking-back (concat "^\\s *" ruby-block-end-re)
                        (line-beginning-position))
      (forward-line 1))))

(defun ruby-beginning-of-indent ()
  "Backtrack to a line which can be used as a reference for
calculating indentation on the lines after it."
  (while (and (re-search-backward ruby-indent-beg-re nil 'move)
              (if (ruby-in-ppss-context-p 'anything)
                  t
                ;; We can stop, then.
                (beginning-of-line)))))

(defun ruby-move-to-block (n)
  "Move to the beginning (N < 0) or the end (N > 0) of the
current block, a sibling block, or an outer block.  Do that (abs N) times."
  (back-to-indentation)
  (let ((signum (if (> n 0) 1 -1))
        (backward (< n 0))
        (depth (or (nth 2 (ruby-parse-region (point) (line-end-position))) 0))
        case-fold-search
        down done)
    (when (looking-at ruby-block-mid-re)
      (setq depth (+ depth signum)))
    (when (< (* depth signum) 0)
      ;; Moving end -> end or beginning -> beginning.
      (setq depth 0))
    (dotimes (_ (abs n))
      (setq done nil)
      (setq down (save-excursion
                   (back-to-indentation)
                   ;; There is a block start or block end keyword on this
                   ;; line, don't need to look for another block.
                   (and (re-search-forward
                         (if backward ruby-block-end-re
                           (concat "\\_<\\(" ruby-block-beg-re "\\)\\_>"))
                         (line-end-position) t)
                        (not (nth 8 (syntax-ppss))))))
      (while (and (not done) (not (if backward (bobp) (eobp))))
        (forward-line signum)
        (cond
         ;; Skip empty and commented out lines.
         ((looking-at "^\\s *$"))
         ((looking-at "^\\s *#"))
         ;; Skip block comments;
         ((and (not backward) (looking-at "^=begin\\>"))
          (re-search-forward "^=end\\>"))
         ((and backward (looking-at "^=end\\>"))
          (re-search-backward "^=begin\\>"))
         ;; Jump over a multiline literal.
         ((ruby-in-ppss-context-p 'string)
          (goto-char (nth 8 (syntax-ppss)))
          (unless backward
            (forward-sexp)
            (when (bolp) (forward-char -1)))) ; After a heredoc.
         (t
          (let ((state (ruby-parse-region (point) (line-end-position))))
            (unless (car state) ; Line ends with unfinished string.
              (setq depth (+ (nth 2 state) depth))))
          (cond
           ;; Increased depth, we found a block.
           ((> (* signum depth) 0)
            (setq down t))
           ;; We're at the same depth as when we started, and we've
           ;; encountered a block before.  Stop.
           ((and down (zerop depth))
            (setq done t))
           ;; Lower depth, means outer block, can stop now.
           ((< (* signum depth) 0)
            (setq done t)))))))
    (back-to-indentation)))

(defun ruby-beginning-of-block (&optional arg)
  "Move backward to the beginning of the current block.
With ARG, move up multiple blocks."
  (interactive "p")
  (ruby-move-to-block (- (or arg 1))))

(defun ruby-end-of-block (&optional arg)
  "Move forward to the end of the current block.
With ARG, move out of multiple blocks."
  (interactive "p")
  (ruby-move-to-block (or arg 1)))

(defun ruby-forward-sexp (&optional arg)
  "Move forward across one balanced expression (sexp).
With ARG, do it many times.  Negative ARG means move backward."
  (declare (obsolete forward-sexp "28.1"))
  ;; TODO: Document body
  (interactive "p")
  (cond
   (ruby-use-smie (forward-sexp arg))
   ((and (numberp arg) (< arg 0))
    (with-suppressed-warnings ((obsolete ruby-backward-sexp))
      (ruby-backward-sexp (- arg))))
   (t
    (let ((i (or arg 1)))
      (condition-case nil
          (while (> i 0)
            (skip-syntax-forward " ")
	    (if (looking-at ",\\s *") (goto-char (match-end 0)))
            (cond ((looking-at "\\?\\(\\\\[CM]-\\)*\\\\?\\S ")
                   (goto-char (match-end 0)))
                  ((progn
                     (skip-chars-forward "-,.:;|&^~=!?+*")
                     (looking-at "\\s("))
                   (goto-char (scan-sexps (point) 1)))
                  ((and (looking-at (concat "\\<\\(" ruby-block-beg-re
                                            "\\)\\>"))
                        (not (eq (char-before (point)) ?.))
                        (not (eq (char-before (point)) ?:)))
                   (ruby-end-of-block)
                   (forward-word-strictly 1))
                  ((looking-at "\\(\\$\\|@@?\\)?\\sw")
                   (while (progn
                            (while (progn (forward-word-strictly 1)
                                          (looking-at "_")))
                            (cond ((looking-at "::") (forward-char 2) t)
                                  ((> (skip-chars-forward ".") 0))
                                  ((looking-at "\\?\\|!\\(=[~=>]\\|[^~=]\\)")
                                   (forward-char 1) nil)))))
                  ((let (state expr)
                     (while
                         (progn
                           (setq expr (or expr (ruby-expr-beg)
                                          (looking-at "%\\sw?\\Sw\\|[\"'`/]")))
                           (nth 1 (setq state (apply #'ruby-parse-partial
                                                     nil state))))
                       (setq expr t)
                       (skip-chars-forward "<"))
                     (not expr))))
            (setq i (1- i)))
        ((error) (forward-word-strictly 1)))
      i))))

(defun ruby-backward-sexp (&optional arg)
  "Move backward across one balanced expression (sexp).
With ARG, do it many times.  Negative ARG means move forward."
  (declare (obsolete backward-sexp "28.1"))
  ;; TODO: Document body
  (interactive "p")
  (cond
   (ruby-use-smie (backward-sexp arg))
   ((and (numberp arg) (< arg 0))
    (with-suppressed-warnings ((obsolete ruby-forward-sexp))
      (ruby-forward-sexp (- arg))))
   (t
    (let ((i (or arg 1)))
      (condition-case nil
          (while (> i 0)
            (skip-chars-backward "- \t\n,.:;|&^~=!?+*")
            (forward-char -1)
            (cond ((looking-at "\\s)")
                   (goto-char (scan-sexps (1+ (point)) -1))
                   (pcase (char-before)
                     (?% (forward-char -1))
                     ((or ?q ?Q ?w ?W ?r ?x)
                      (if (eq (char-before (1- (point))) ?%)
                          (forward-char -2))))
                   nil)
                  ((looking-at "\\s\"\\|\\\\\\S_")
                   (let ((c (char-to-string (char-before (match-end 0)))))
                     (while (and (search-backward c)
				 (oddp (skip-chars-backward "\\\\")))))
                   nil)
                  ((looking-at "\\s.\\|\\s\\")
                   (if (ruby-special-char-p) (forward-char -1)))
                  ((looking-at "\\s(") nil)
                  (t
                   (forward-char 1)
                   (while (progn (forward-word-strictly -1)
                                 (pcase (char-before)
                                   (?_ t)
                                   (?. (forward-char -1) t)
                                   ((or ?$ ?@)
                                    (forward-char -1)
                                    (and (eq (char-before) (char-after))
                                         (forward-char -1)))
                                   (?:
                                    (forward-char -1)
                                    (eq (char-before) :)))))
                   (if (looking-at ruby-block-end-re)
                       (ruby-beginning-of-block))
                   nil))
            (setq i (1- i)))
        ((error)))
      i))))

(defun ruby-indent-exp (&optional _ignored)
  "Indent each line in the balanced expression following the point."
  (interactive "*P")
  (let ((here (point-marker)) start top column (nest t))
    (set-marker-insertion-type here t)
    (unwind-protect
        (progn
          (beginning-of-line)
          (setq start (point) top (current-indentation))
          (while (and (not (eobp))
                      (progn
                        (setq column (ruby-calculate-indent start))
                        (cond ((> column top)
                               (setq nest t))
                              ((and (= column top) nest)
                               (setq nest nil) t))))
            (ruby-indent-to column)
            (beginning-of-line 2)))
      (goto-char here)
      (set-marker here nil))))

(defun ruby-add-log-current-method ()
  "Return the current method name as a string.
This string includes all namespaces.

For example:

  #exit
  String#gsub
  Net::HTTP#active?
  File.open

See `add-log-current-defun-function'."
  (save-excursion
    (let* ((indent (ruby--add-log-current-indent))
           mname mlist
           (start (point))
           (make-definition-re
            (lambda (re &optional method-name?)
              (concat "^[ \t]*" re "[ \t]+"
                      "\\("
                      ;; \\. and :: for class methods
                      "\\([A-Za-z_]" ruby-symbol-re "*[?!]?"
                      "\\|"
                      (if method-name? ruby-operator-re "\\.")
                      "\\|::" "\\)"
                      "+\\)")))
           (definition-re (funcall make-definition-re ruby-defun-beg-re t))
           (module-re (funcall make-definition-re "\\(class\\|module\\)")))
      ;; Get the current method definition (or class/module).
      (when (catch 'found
              (while (and (re-search-backward definition-re nil t)
                          (if (if (string-equal "def" (match-string 1))
                                  ;; We're inside a method.
                                  (if (ruby-block-contains-point (1- start))
                                      t
                                    ;; Try to match a method only once.
                                    (setq definition-re module-re)
                                    nil)
                                ;; Class/module. For performance,
                                ;; comparing indentation.
                                (or (not (numberp indent))
                                    (> indent (current-indentation))))
                              (throw 'found t)
                            t))))
        (goto-char (match-beginning 1))
        (if (not (string-equal "def" (match-string 1)))
            (setq mlist (list (match-string 2)))
          (setq mname (match-string 2)))
        (setq indent (current-column))
        (beginning-of-line))
      ;; Walk up the class/module nesting.
      (while (and indent
                  (> indent 0)
                  (re-search-backward module-re nil t))
        (goto-char (match-beginning 1))
        (when (< (current-column) indent)
          (setq mlist (cons (match-string 2) mlist))
          (setq indent (current-column))
          (beginning-of-line)))
      ;; Process the method name.
      (when mname
        (let ((mn (split-string mname "\\.\\|::")))
          (if (cdr mn)
              (progn
                (unless (string-equal "self" (car mn)) ; def self.foo
                  ;; def C.foo
                  (let ((ml (reverse mlist)))
                    ;; If the method name references one of the
                    ;; containing modules, drop the more nested ones.
                    (while ml
                      (if (string-equal (car ml) (car mn))
                          (setq mlist (nreverse (cdr ml)) ml nil))
                      (setq ml (cdr ml))))
                  (if mlist
                      (setcdr (last mlist) (butlast mn))
                    (setq mlist (butlast mn))))
                (setq mname (concat "." (car (last mn)))))
            ;; See if the method is in singleton class context.
            (let ((in-singleton-class
                   (when (re-search-forward ruby-singleton-class-re start t)
                     (goto-char (match-beginning 0))
                     ;; FIXME: Optimize it out, too?
                     ;; This can be slow in a large file, but
                     ;; unlike class/module declaration
                     ;; indentations, method definitions can be
                     ;; intermixed with these, and may or may not
                     ;; be additionally indented after visibility
                     ;; keywords.
                     (ruby-block-contains-point start))))
              (setq mname (concat
                           (if in-singleton-class "." "#")
                           mname))))))
      ;; Generate the string.
      (if (consp mlist)
          (setq mlist (mapconcat (function identity) mlist "::")))
      (if mname
          (if mlist (concat mlist mname) mname)
        mlist))))

(defun ruby-block-contains-point (pt)
  (save-excursion
    (save-match-data
      (with-suppressed-warnings ((obsolete ruby-forward-sexp))
        (ruby-forward-sexp))
      (> (point) pt))))

(defun ruby--add-log-current-indent ()
  (save-excursion
    (back-to-indentation)
    (cond
     ((looking-at "[[:graph:]]")
      (current-indentation))
     (ruby-use-smie
      (smie-indent-calculate))
     (t
      (ruby-calculate-indent)))))

(defun ruby-brace-to-do-end (orig end)
  (let (beg-marker end-marker)
    (goto-char end)
    (when (eq (char-before) ?\})
      (delete-char -1)
      (when (save-excursion
              (let ((n (skip-chars-backward " \t")))
                (if (< n 0) (delete-char (- n))))
              (not (bolp)))
        (insert "\n"))
      (insert "end")
      (setq end-marker (point-marker))
      (when (and (not (eobp)) (eq (char-syntax (char-after)) ?w))
        (insert " "))
      (goto-char orig)
      (delete-char 1)
      (when (eq (char-syntax (char-before)) ?w)
        (insert " "))
      (insert "do")
      (setq beg-marker (point-marker))
      (when (looking-at "\\(\\s \\)*|")
        (unless (match-beginning 1)
          (insert " "))
        (goto-char (1+ (match-end 0)))
        (search-forward "|"))
      (unless (looking-at "\\s *$")
        (insert "\n"))
      (indent-region beg-marker end-marker)
      (goto-char beg-marker)
      t)))

(defun ruby-do-end-to-brace (orig end)
  (let (beg-marker end-marker beg-pos end-pos)
    (goto-char (- end 3))
    (when (looking-at ruby-block-end-re)
      (delete-char 3)
      (setq end-marker (point-marker))
      (insert "}")
      (goto-char orig)
      (delete-char 2)
      (insert "{")
      (if (looking-at "\\s +|")
          (progn
            (just-one-space (if ruby-toggle-block-space-before-parameters 1 0))
            (setq beg-marker (point-marker))
            (forward-char)
            (re-search-forward "|" (line-end-position) t))
        (setq beg-marker (point-marker)))
      (save-excursion
        (skip-chars-forward " \t\n\r")
        (setq beg-pos (point))
        (goto-char end-marker)
        (skip-chars-backward " \t\n\r")
        (setq end-pos (point)))
      (when (or
             (< end-pos beg-pos)
             (and (= (line-number-at-pos beg-pos) (line-number-at-pos end-pos))
                  (< (+ (current-column) (- end-pos beg-pos) 2) fill-column)))
        (just-one-space -1)
        (goto-char end-marker)
        (just-one-space -1))
      (goto-char beg-marker)
      t)))

(defun ruby-toggle-block ()
  "Toggle block type from do-end to braces or back.
The block must begin on the current line or above it and end after the point.
If the result is do-end block, it will always be multiline."
  (interactive)
  (let ((start (point)) beg end)
    (end-of-line)
    (unless
        (if (and (re-search-backward "\\(?:[^#]\\)\\({\\)\\|\\(\\_<do\\_>\\)")
                 (let ((ruby-use-smie (and ruby-use-smie (consp smie-grammar))))
                   (goto-char (or (match-beginning 1) (match-beginning 2)))
                   (setq beg (point))
                   (with-suppressed-warnings ((obsolete ruby-forward-sexp))
                     (save-match-data (ruby-forward-sexp)))
                   (setq end (point))
                   (> end start)))
            (if (match-beginning 1)
                (ruby-brace-to-do-end beg end)
              (ruby-do-end-to-brace beg end)))
      (goto-char start))))

(defun ruby--string-region ()
  "Return region for string at point."
  (let ((state (syntax-ppss)))
    (when (memq (nth 3 state) '(?' ?\"))
      (save-excursion
        (goto-char (nth 8 state))
        (forward-sexp)
        (list (nth 8 state) (point))))))

(defun ruby-string-at-point-p ()
  "Check if cursor is at a string or not."
  (ruby--string-region))

(defun ruby--inverse-string-quote (string-quote)
  "Get the inverse string quoting for STRING-QUOTE."
  (if (equal string-quote "\"") "'" "\""))

(defun ruby-toggle-string-quotes ()
  "Toggle string literal quoting between single and double."
  (interactive)
  (when (ruby-string-at-point-p)
    (let* ((region (ruby--string-region))
           (min (nth 0 region))
           (max (nth 1 region))
           (string-quote (ruby--inverse-string-quote (buffer-substring-no-properties min (1+ min))))
           (content
            (buffer-substring-no-properties (1+ min) (1- max))))
      (setq content
            (if (equal string-quote "'")
                (string-replace "\\\"" "\"" (replace-regexp-in-string "\\(\\`\\|[^\\]\\)'" "\\1\\\\'" content))
              (string-replace "\\'" "'" (replace-regexp-in-string "\\(\\`\\|[^\\]\\)\"" "\\1\\\\\"" content))))
      (let ((orig-point (point)))
        (delete-region min max)
        (insert
         (format "%s%s%s" string-quote content string-quote))
        (goto-char orig-point)))))

(defun ruby-find-library-file (&optional feature-name)
  "Visit a library file denoted by FEATURE-NAME.
FEATURE-NAME is a relative file name, file extension is optional.
This commands delegates to `gem which', which searches both
installed gems and the standard library.  When called
interactively, defaults to the feature name in the `require'
or `gem' statement around point."
  (interactive)
  (unless feature-name
    (let ((init (save-excursion
                  (forward-line 0)
                  (when (looking-at "\\(?:require\\| *gem\\) [\"']\\(.*?\\)[\"']")
                    (match-string 1)))))
      (setq feature-name (read-string "Feature name: " init))))
  (let ((out
         (substring
          (shell-command-to-string (concat "gem which " (shell-quote-argument feature-name)))
          0 -1)))
    (if (string-match-p "\\`ERROR" out)
        (user-error "%s" out)
      (find-file out))))

(eval-and-compile
  (defconst ruby-percent-literal-beg-re
    "\\(%\\)[qQrswWxIi]?\\([[:punct:]]\\)"
    "Regexp to match the beginning of percent literal.")

  (defvar ruby-syntax-before-regexp-re
    (concat
     ;; Special tokens that can't be followed by a division operator.
     "\\(^\\|[[{|=(,~;<>!]"
     ;; Distinguish ternary operator tokens.
     ;; FIXME: They don't really have to be separated with spaces.
     "\\|[?:] "
     ;; Control flow keywords and operators following bol or whitespace.
     "\\|\\(?:^\\|\\s \\)"
     (regexp-opt '("if" "elsif" "unless" "while" "until" "when" "and"
                   "or" "not" "&&" "||"))
     "\\)\\s *")
    "Regexp to match text that disambiguates a regular expression.
A slash character after any of these should begin a regexp."))

(defun ruby-syntax-propertize (start end)
  "Syntactic keywords for Ruby mode.  See `syntax-propertize-function'."
  (let (case-fold-search)
    (goto-char start)
    (remove-text-properties start end '(ruby-expansion-match-data nil))
    (ruby-syntax-propertize-heredoc end)
    (ruby-syntax-enclosing-percent-literal end)
    (funcall
     (syntax-propertize-rules
      ;; $' $" $` .... are variables.
      ;; ?' ?" ?` are character literals (one-char strings in 1.9+).
      ("\\([?$]\\)[#\"'`:?]"
       (1 (if (save-excursion
                (nth 3 (syntax-ppss (match-beginning 0))))
              ;; Within a string, skip.
              (ignore
               (goto-char (match-end 1)))
            (put-text-property (match-end 1) (match-end 0)
                               'syntax-table (string-to-syntax "_"))
            (string-to-syntax "'"))))
      ;; Symbols with special characters.
      (":\\([-+~]@?\\|[/%&|^`]\\|\\*\\*?\\|<\\(<\\|=>?\\)?\\|>[>=]?\\|===?\\|=~\\|![~=]?\\|\\[\\]=?\\)"
       (1 (unless (or
                   (nth 8 (syntax-ppss (match-beginning 1)))
                   (eq (char-before (match-beginning 0)) ?:))
            (goto-char (match-end 0))
            (string-to-syntax "_"))))
      ;; Symbols ending with '=' (bug#42846).
      (":[[:alpha:]][[:alnum:]_]*\\(=\\)"
       (1 (unless (or (nth 8 (syntax-ppss))
                      (eq (char-before (match-beginning 0)) ?:)
                      (eq (char-after (match-end 3)) ?>))
            (string-to-syntax "_"))))
      ;; Part of method name when at the end of it.
      ("[!?]"
       (0 (unless (save-excursion
                    (or (nth 8 (syntax-ppss (match-beginning 0)))
                        (let (parse-sexp-lookup-properties)
                          (zerop (skip-syntax-backward "w_")))
                        (memq (preceding-char) '(?@ ?$))))
            (string-to-syntax "_"))))
      ;; Backtick method redefinition.
      ("^[ \t]*def +\\(`\\)" (1 "_"))
      ;; Ternary operator colon followed by opening paren or bracket
      ;; (semi-important for indentation).
      ("\\(:\\)\\(?:[({]\\|\\[[^]]\\)"
       (1 (string-to-syntax ".")))
      ;; Regular expressions.
      ("\\(/\\)"
       (1
        ;; No unescaped slashes in front.
        (when (save-excursion
                (forward-char -1)
                (cl-evenp (skip-chars-backward "\\\\")))
          (let ((state (save-excursion (syntax-ppss (match-beginning 1)))))
            (when (or
                   ;; Beginning of a regexp.
                   (and (null (nth 8 state))
                        (or (not
                             ;; Looks like division.
                             (or (eql (char-after) ?\s)
                                 (not (eql (char-before (1- (point))) ?\s))))
                            (save-excursion
                              (forward-char -1)
                              (looking-back ruby-syntax-before-regexp-re
                                            (line-beginning-position)))))
                   ;; End of regexp.  We don't match the whole
                   ;; regexp at once because it can have
                   ;; string interpolation inside, or span
                   ;; several lines.
                   (eq ?/ (nth 3 state)))
              (string-to-syntax "\"/"))))))
      ;; Expression expansions in strings.  We're handling them
      ;; here, so that the regexp rule never matches inside them.
      (ruby-expression-expansion-re
       (0 (ignore
           (if (save-excursion
                 (goto-char (match-beginning 0))
                 ;; The hash character is not escaped.
                 (cl-evenp (skip-chars-backward "\\\\")))
               (ruby-syntax-propertize-expansion)
             (goto-char (match-beginning 1))))))
      ("^=en\\(d\\)\\_>" (1 "!"))
      ("^\\(=\\)begin\\_>" (1 "!"))
      ;; Handle here documents.
      ((concat ruby-here-doc-beg-re ".*\\(\n\\)")
       (7 (when (and (not (nth 8 (save-excursion
                                   (syntax-ppss (match-beginning 0)))))
                     (ruby-verify-heredoc (match-beginning 0)))
            (put-text-property (match-beginning 7) (match-end 7)
                               'syntax-table (string-to-syntax "\""))
            (ruby-syntax-propertize-heredoc end))))
      ;; Handle percent literals: %w(), %q{}, etc.
      ((concat "\\(?:^\\|[[ \t\n<+(,=*]\\)" ruby-percent-literal-beg-re)
       (1 (unless (nth 8 (save-excursion (syntax-ppss (match-beginning 1))))
            ;; Not inside a string, a comment, or a percent literal.
            (ruby-syntax-propertize-percent-literal end)
            (string-to-syntax "|")))))
     (point) end)))

(define-obsolete-function-alias
  'ruby-syntax-propertize-function 'ruby-syntax-propertize "25.1")

(defun ruby-syntax-propertize-heredoc (limit)
  (let ((ppss (syntax-ppss))
        (res '()))
    (when (eq ?\n (nth 3 ppss))
      (save-excursion
        (goto-char (nth 8 ppss))
        (beginning-of-line)
        (while (re-search-forward ruby-here-doc-beg-re
                                  (line-end-position) t)
          (when (ruby-verify-heredoc (match-beginning 0))
            (push (concat (ruby-here-doc-end-match) "\n") res))))
      (save-excursion
        ;; With multiple openers on the same line, we don't know in which
        ;; part `start' is, so we have to go back to the beginning.
        (when (cdr res)
          (goto-char (nth 8 ppss))
          (setq res (nreverse res)))
        (while (and res (re-search-forward (pop res) limit 'move))
          (if (null res)
              (put-text-property (1- (point)) (point)
                                 'syntax-table (string-to-syntax "\""))))
        ;; End up at bol following the heredoc openers.
        ;; Propertize expression expansions from this point forward.
        ))))

(defun ruby-syntax-enclosing-percent-literal (limit)
  (let ((state (syntax-ppss))
        (start (point)))
    ;; When already inside percent literal, re-propertize it.
    (when (eq t (nth 3 state))
      (goto-char (nth 8 state))
      (when (looking-at ruby-percent-literal-beg-re)
        (ruby-syntax-propertize-percent-literal limit))
      (when (< (point) start) (goto-char start)))))

(defun ruby-syntax-propertize-percent-literal (limit)
  (goto-char (match-beginning 2))
  (let* ((op (char-after))
         (ops (char-to-string op))
         (cl (or (cdr (aref (syntax-table) op))
                 (cdr (assoc op '((?< . ?>))))))
         parse-sexp-lookup-properties)
    (save-excursion
      (condition-case nil
          (progn
            (if cl              ; Paired delimiters.
                ;; Delimiter pairs of the same kind can be nested
                ;; inside the literal, as long as they are balanced.
                ;; Create syntax table that ignores other characters.
                (with-syntax-table (make-char-table 'syntax-table nil)
                  (modify-syntax-entry op (concat "(" (char-to-string cl)))
                  (modify-syntax-entry cl (concat ")" ops))
                  (modify-syntax-entry ?\\ "\\")
                  (save-restriction
                    (narrow-to-region (point) limit)
                    (forward-list))) ; skip to the paired character
              ;; Single character delimiter.
              (re-search-forward (concat "[^\\]\\(?:\\\\\\\\\\)*"
                                         (regexp-quote ops)) limit nil))
            ;; Found the closing delimiter.
            (put-text-property (1- (point)) (point) 'syntax-table
                               (string-to-syntax "|")))
        ;; Unclosed literal, do nothing.
        ((scan-error search-failed))))))

(defun ruby-syntax-propertize-expansion ()
  ;; Save the match data to a text property, for font-locking later.
  ;; Set the syntax of all double quotes and backticks to punctuation.
  (let* ((beg (match-beginning 0))
         (end (match-end 0))
         (state (and beg (save-excursion (syntax-ppss beg)))))
    (when (ruby-syntax-expansion-allowed-p state)
      (put-text-property beg (1+ beg) 'ruby-expansion-match-data
                         (match-data))
      (goto-char beg)
      (while (re-search-forward "[\"`]" end 'move)
        (put-text-property (match-beginning 0) (match-end 0)
                           'syntax-table (string-to-syntax "."))))))

(defun ruby-syntax-expansion-allowed-p (parse-state)
  "Return non-nil if expression expansion is allowed."
  (let ((term (nth 3 parse-state)))
    (cond
     ((memq term '(?\" ?` ?\n ?/)))
     ((eq term t)
      (save-match-data
        (save-excursion
          (goto-char (nth 8 parse-state))
          (looking-at "%\\(?:[QWrxI]\\|\\W\\)")))))))

(defun ruby-syntax-propertize-expansions (start end)
  (save-excursion
    (goto-char start)
    (while (re-search-forward ruby-expression-expansion-re end 'move)
      (ruby-syntax-propertize-expansion))))

(defun ruby-in-ppss-context-p (context &optional ppss)
  (let ((ppss (or ppss (syntax-ppss (point)))))
    (if (cond
         ((eq context 'anything)
          (or (nth 3 ppss)
              (nth 4 ppss)))
         ((eq context 'string)
          (nth 3 ppss))
         ((eq context 'heredoc)
          (eq ?\n (nth 3 ppss)))
         ((eq context 'non-heredoc)
          (and (ruby-in-ppss-context-p 'anything)
               (not (ruby-in-ppss-context-p 'heredoc))))
         ((eq context 'comment)
          (nth 4 ppss))
         (t
          (error (concat
                  "Internal error on `ruby-in-ppss-context-p': "
                  "context name `%s' is unknown")
                 context)))
        t)))

(defconst ruby-font-lock-keyword-beg-re "\\(?:^\\|[^.@$:]\\|\\.\\.\\)")

(defconst ruby-font-lock-keywords
  `(;; Functions.
    ("^\\s *def\\s +\\(?:[^( \t\n.]*\\.\\)?\\([^( \t\n]+\\)"
     1 font-lock-function-name-face)
    ;; Keywords.
    (,(concat
       ruby-font-lock-keyword-beg-re
       (regexp-opt
        '("alias"
          "and"
          "begin"
          "break"
          "case"
          "class"
          "def"
          "defined?"
          "do"
          "elsif"
          "else"
          "fail"
          "ensure"
          "for"
          "end"
          "if"
          "in"
          "module"
          "next"
          "not"
          "or"
          "redo"
          "rescue"
          "retry"
          "return"
          "self"
          "super"
          "then"
          "unless"
          "undef"
          "until"
          "when"
          "while"
          "yield")
        'symbols))
     (1 font-lock-keyword-face))
    ;; Core methods that have required arguments.
    (,(concat
       ruby-font-lock-keyword-beg-re
       (regexp-opt ruby-builtin-methods-with-reqs 'symbols))
     (1 (unless (looking-at " *\\(?:[]|,.)}=]\\|$\\)")
          font-lock-builtin-face)))
    ;; Kernel methods that have no required arguments.
    (,(concat
       ruby-font-lock-keyword-beg-re
       (regexp-opt ruby-builtin-methods-no-reqs 'symbols))
     (1 font-lock-builtin-face))
    ;; Here-doc beginnings.
    (,ruby-here-doc-beg-re
     (0 (when (ruby-verify-heredoc (match-beginning 0))
          'font-lock-string-face)))
    ;; Perl-ish keywords.
    "\\_<\\(?:BEGIN\\|END\\)\\_>\\|^__END__$"
    ;; Singleton objects.
    (,(concat ruby-font-lock-keyword-beg-re
              "\\_<\\(nil\\|true\\|false\\)\\_>")
     1 font-lock-constant-face)
    ;; Keywords that evaluate to certain values.
    ("\\_<__\\(?:LINE\\|ENCODING\\|FILE\\)__\\_>"
     (0 font-lock-builtin-face))
    ;; Symbols.
    ("\\(^\\|[^:]\\)\\(:@\\{0,2\\}\\(?:\\sw\\|\\s_\\)+\\)"
     (2 font-lock-constant-face))
    ;; Special globals.
    (,(concat "\\$\\(?:[:\"!@;,/._><\\$?~=*&`'+0-9]\\|-[0adFiIlpvw]\\|"
              (regexp-opt '("LOAD_PATH" "LOADED_FEATURES" "PROGRAM_NAME"
                            "ERROR_INFO" "ERROR_POSITION"
                            "FS" "FIELD_SEPARATOR"
                            "OFS" "OUTPUT_FIELD_SEPARATOR"
                            "RS" "INPUT_RECORD_SEPARATOR"
                            "ORS" "OUTPUT_RECORD_SEPARATOR"
                            "NR" "INPUT_LINE_NUMBER"
                            "LAST_READ_LINE" "DEFAULT_OUTPUT" "DEFAULT_INPUT"
                            "PID" "PROCESS_ID" "CHILD_STATUS"
                            "LAST_MATCH_INFO" "IGNORECASE"
                            "ARGV" "MATCH" "PREMATCH" "POSTMATCH"
                            "LAST_PAREN_MATCH" "stdin" "stdout" "stderr"
                            "DEBUG" "FILENAME" "VERBOSE" "SAFE" "CLASSPATH"
                            "JRUBY_VERSION" "JRUBY_REVISION" "ENV_JAVA"))
              "\\_>\\)")
     0 font-lock-builtin-face)
    ("\\(\\$\\|@\\|@@\\)\\(\\w\\|_\\)+"
     0 font-lock-variable-name-face)
    ;; Constants.
    ("\\_<\\([A-Z]+\\(\\w\\|_\\)*\\)"
     1 (unless (eq ?\( (char-after)) font-lock-type-face))
    ;; Ruby 1.9-style symbol hash keys.
    ("\\(?:^\\s *\\|[[{(,]\\s *\\|\\sw\\s +\\)\\(\\(\\sw\\|_\\)+:\\)[^:]"
     (1 (progn (forward-char -1) font-lock-constant-face)))
    ;; Conversion methods on Kernel.
    (,(concat ruby-font-lock-keyword-beg-re
              (regexp-opt '("Array" "Complex" "Float" "Hash"
                            "Integer" "Rational" "String")
                          'symbols))
     (1 font-lock-builtin-face))
    ;; Expression expansion.
    (ruby-match-expression-expansion
     0 font-lock-variable-name-face t)
    ;; Negation char.
    ("\\(?:^\\|[^[:alnum:]_]\\)\\(!+\\)[^=~]"
     1 font-lock-negation-char-face)
    ;; Character literals.
    ;; FIXME: Support longer escape sequences.
    ("\\?\\\\?\\_<.\\_>" 0 font-lock-string-face)
    ;; Regexp options.
    ("\\(?:\\s|\\|/\\)\\([imxo]+\\)"
     1 (when (save-excursion
               (let ((state (syntax-ppss (match-beginning 0))))
                 (and (nth 3 state)
                      (or (eq (char-after) ?/)
                          (progn
                            (goto-char (nth 8 state))
                            (looking-at "%r"))))))
         font-lock-preprocessor-face))
    )
  "Additional expressions to highlight in Ruby mode.")

(defun ruby-match-expression-expansion (limit)
  (let* ((prop 'ruby-expansion-match-data)
         (pos (next-single-char-property-change (point) prop nil limit))
         value)
    (when (and pos (> pos (point)))
      (goto-char pos)
      (or (and (setq value (get-text-property pos prop))
               (progn (set-match-data value) t))
          (ruby-match-expression-expansion limit)))))

;;; Flymake support
(defvar-local ruby--flymake-proc nil)

(defun ruby-flymake-simple (report-fn &rest _args)
  "`ruby -wc' backend for Flymake."
  (unless (executable-find "ruby")
    (error "Cannot find the ruby executable"))

  (ruby-flymake--helper
   "ruby-flymake"
   '("ruby" "-w" "-c")
   (lambda (_proc source)
     (goto-char (point-min))
     (cl-loop
      while (search-forward-regexp
             "^\\(?:.*\\.rb\\|-\\):\\([0-9]+\\): \\(.*\\)$"
             nil t)
      for msg = (match-string 2)
      for (beg . end) = (flymake-diag-region
                         source
                         (string-to-number (match-string 1)))
      for type = (if (string-match "^warning" msg)
                     :warning
                   :error)
      collect (flymake-make-diagnostic source
                                       beg
                                       end
                                       type
                                       msg)
      into diags
      finally (funcall report-fn diags)))))

(defun ruby-flymake--helper (process-name command parser-fn)
  (when (process-live-p ruby--flymake-proc)
    (kill-process ruby--flymake-proc))

  (let ((source (current-buffer)))
    (save-restriction
      (widen)
      (setq
       ruby--flymake-proc
       (make-process
        :name process-name :noquery t :connection-type 'pipe
        :buffer (generate-new-buffer (format " *%s*" process-name))
        :command command
        :sentinel
        (lambda (proc _event)
          (when (and (eq 'exit (process-status proc)) (buffer-live-p source))
            (unwind-protect
                (if (with-current-buffer source (eq proc ruby--flymake-proc))
                    (with-current-buffer (process-buffer proc)
                      (funcall parser-fn proc source))
                  (flymake-log :debug "Canceling obsolete check %s"
                               proc))
              (kill-buffer (process-buffer proc)))))))
      (process-send-region ruby--flymake-proc (point-min) (point-max))
      (process-send-eof ruby--flymake-proc))))

(defcustom ruby-flymake-use-rubocop-if-available t
  "Non-nil to use the RuboCop Flymake backend.
Only takes effect if RuboCop is installed.

If there is no Rubocop config file, Rubocop will be passed a flag
'--lint' to only show syntax errors and important problems."
  :version "26.1"
  :type 'boolean
  :safe 'booleanp)

(defcustom ruby-rubocop-config ".rubocop.yml"
  "Configuration file for `ruby-flymake-rubocop'."
  :version "26.1"
  :type 'string
  :safe 'stringp)

(defcustom ruby-rubocop-use-bundler 'check
  "Non-nil with allow `ruby-flymake-rubocop' to use `bundle exec'.
When the value is `check', it will first see whether Gemfile exists in
the same directory as the configuration file, and whether it mentions
the gem \"rubocop\".  When t, it is used unconditionally."
  :type '(choice (const :tag "Always" t)
                 (const :tag "No" nil)
                 (const :tag "If rubocop is in Gemfile" check))
  :version "30.1"
  :safe 'booleanp)

(defun ruby-flymake-rubocop (report-fn &rest _args)
  "RuboCop backend for Flymake."
  (unless (executable-find "rubocop")
    (error "Cannot find the rubocop executable"))

  (let ((command (list "rubocop" "--stdin" buffer-file-name "--format" "emacs"
                       "--cache" "false" ; Work around a bug in old version.
                       "--display-cop-names"))
        (default-directory default-directory)
        config-dir)
    (when buffer-file-name
      (setq config-dir (locate-dominating-file buffer-file-name
                                               ruby-rubocop-config))
      (if (not config-dir)
          (setq command (append command '("--lint")))
        (setq command (append command (list "--config"
                                            (expand-file-name ruby-rubocop-config
                                                              config-dir))))
        (when (ruby-flymake-rubocop--use-bundler-p config-dir)
          (setq command (append '("bundle" "exec") command))
          ;; In case of a project with multiple nested subprojects,
          ;; each one with a Gemfile.
          (setq default-directory config-dir)))

      (ruby-flymake--helper
       "rubocop-flymake"
       command
       (lambda (proc source)
         ;; Finding the executable is no guarantee of
         ;; rubocop working, especially in the presence
         ;; of rbenv shims (which cross ruby versions).
         (when (eq (process-exit-status proc) 127)
           ;; Not sure what to do in this case.  Maybe ideally we'd
           ;; switch back to ruby-flymake-simple.
           (flymake-log :warning "RuboCop returned status 127: %s"
                        (buffer-string)))
         (goto-char (point-min))
         (cl-loop
          while (search-forward-regexp
                 "^\\(?:.*\\.rb\\|-\\):\\([0-9]+\\):\\([0-9]+\\): \\(.*\\)$"
                 nil t)
          for msg = (match-string 3)
          for (beg . end) = (flymake-diag-region
                             source
                             (string-to-number (match-string 1))
                             (string-to-number (match-string 2)))
          for type = (cond
                      ((string-match "^[EF]: " msg)
                       :error)
                      ((string-match "^W: " msg)
                       :warning)
                      (t :note))
          collect (flymake-make-diagnostic source
                                           beg
                                           end
                                           type
                                           (substring msg 3))
          into diags
          finally (funcall report-fn diags)))))))

(defun ruby-flymake-rubocop--use-bundler-p (dir)
  (cond
   ((eq t ruby-rubocop-use-bundler)
    t)
   ((null ruby-rubocop-use-bundler)
    nil)
   (t
    (let ((file (expand-file-name "Gemfile" dir)))
      (and (file-exists-p file)
           (with-temp-buffer
             (insert-file-contents file)
             (re-search-forward "^ *gem ['\"]rubocop['\"]" nil t)))))))

(defun ruby-flymake-auto (report-fn &rest args)
  (apply
   (if (and ruby-flymake-use-rubocop-if-available
            (executable-find "rubocop"))
       #'ruby-flymake-rubocop
     #'ruby-flymake-simple)
   report-fn
   args))

(defconst ruby--prettify-symbols-alist
  '(("<=" . ?≤)
    (">=" . ?≥)
    ("->"  . ?→)
    ("=>"  . ?⇒)
    ("::" . ?∷)
    ("lambda" . ?λ))
  "Value for `prettify-symbols-alist' in `ruby-mode'.")

;;;###autoload
(define-derived-mode ruby-base-mode prog-mode "Ruby"
  "Generic major mode for editing Ruby.

This mode is intended to be inherited by concrete major modes.
Currently there are `ruby-mode' and `ruby-ts-mode'."
  (setq indent-tabs-mode ruby-indent-tabs-mode)

  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-column ruby-comment-column)
  (setq-local comment-start-skip "#+ *")

  (setq-local parse-sexp-ignore-comments t)
  (setq-local parse-sexp-lookup-properties t)

  (setq-local paragraph-start (concat "$\\|" page-delimiter))
  (setq-local paragraph-separate paragraph-start)
  (setq-local paragraph-ignore-fill-prefix t)

  ;; `outline-regexp' contains the first part of `ruby-indent-beg-re'
  (setq-local outline-regexp (concat "^\\s *"
                                     (regexp-opt '("class" "module" "def"))
                                     "\\_>"))
  (setq-local outline-level (lambda () (1+ (/ (current-indentation)
                                         ruby-indent-level))))

  (add-hook 'after-save-hook #'ruby-mode-set-encoding nil 'local)
  (add-hook 'electric-indent-functions #'ruby--electric-indent-p nil 'local)
  (add-hook 'flymake-diagnostic-functions #'ruby-flymake-auto nil 'local)

  (setq-local prettify-symbols-alist ruby--prettify-symbols-alist))

;;;###autoload
(define-derived-mode ruby-mode ruby-base-mode "Ruby"
  "Major mode for editing Ruby code."
  (smie-setup ruby-smie-grammar #'ruby-smie-rules
              :forward-token  #'ruby-smie--forward-token
              :backward-token #'ruby-smie--backward-token)
  (unless ruby-use-smie
    (setq-local indent-line-function #'ruby-indent-line))

  (setq-local imenu-create-index-function #'ruby-imenu-create-index)
  (setq-local add-log-current-defun-function #'ruby-add-log-current-method)
  (setq-local beginning-of-defun-function #'ruby-beginning-of-defun)
  (setq-local end-of-defun-function #'ruby-end-of-defun)

  (setq-local font-lock-defaults '((ruby-font-lock-keywords) nil nil
                                   ((?_ . "w"))))

  (setq-local syntax-propertize-function #'ruby-syntax-propertize))

;;; Invoke ruby-mode when appropriate

;;;###autoload
(add-to-list 'auto-mode-alist
             (cons (concat "\\(?:\\.\\(?:"
                           "rbw?\\|ru\\|rake\\|thor\\|axlsx"
                           "\\|jbuilder\\|rabl\\|gemspec\\|podspec"
                           "\\)"
                           "\\|/"
                           "\\(?:Gem\\|Rake\\|Cap\\|Thor"
                           "\\|Puppet\\|Berks\\|Brew\\|Fast"
                           "\\|Vagrant\\|Guard\\|Pod\\)file"
                           "\\)\\'")
                   'ruby-mode))

;;;###autoload
(dolist (name (list "ruby" "rbx" "jruby" "j?ruby\\(?:[0-9.]+\\)"))
  (add-to-list 'interpreter-mode-alist (cons name 'ruby-mode)))

;; See ruby-ts-mode.el for why we do this.
(setq major-mode-remap-defaults
      (assq-delete-all 'ruby-mode major-mode-remap-defaults))

(provide 'ruby-mode)

;;; ruby-mode.el ends here
