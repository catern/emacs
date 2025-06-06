;;; minibuffer.el --- Minibuffer and completion functions -*- lexical-binding: t -*-

;; Copyright (C) 2008-2025 Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Package: emacs

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

;; Names with "--" are for functions and variables that are meant to be for
;; internal use only.

;; Functional completion tables have an extended calling conventions:
;; The `action' can be (additionally to nil, t, and lambda) of the form
;; - (boundaries . SUFFIX) in which case it should return
;;   (boundaries START . END).  See `completion-boundaries'.
;;   Any other return value should be ignored (so we ignore values returned
;;   from completion tables that don't know about this new `action' form).
;; - `metadata' in which case it should return (metadata . ALIST) where
;;   ALIST is the metadata of this table.  See `completion-metadata'.
;;   Any other return value should be ignored (so we ignore values returned
;;   from completion tables that don't know about this new `action' form).

;;; Bugs:

;; - completion-all-sorted-completions lists all the completions, whereas
;;   it should only lists the ones that `try-completion' would consider.
;;   E.g.  it should honor completion-ignored-extensions.
;; - choose-completion can't automatically figure out the boundaries
;;   corresponding to the displayed completions because we only
;;   provide the start info but not the end info in
;;   completion-base-position.
;; - C-x C-f ~/*/sr ? should not list "~/./src".
;; - minibuffer-force-complete completes ~/src/emacs/t<!>/lisp/minibuffer.el
;;   to ~/src/emacs/trunk/ and throws away lisp/minibuffer.el.

;;; Todo:

;; - Make *Completions* readable even if some of the completion
;;   entries have LF chars or spaces in them (including at
;;   beginning/end) or are very long.
;; - for M-x, cycle-sort commands that have no key binding first.
;; - Make things like icomplete-mode or lightning-completion work with
;;   completion-in-region-mode.
;; - extend `metadata':
;;   - indicate how to turn all-completion's output into
;;     try-completion's output: e.g. completion-ignored-extensions.
;;     maybe that could be merged with the "quote" operation.
;;   - indicate that `all-completions' doesn't do prefix-completion
;;     but just returns some list that relates in some other way to
;;     the provided string (as is the case in filecache.el), in which
;;     case partial-completion (for example) doesn't make any sense
;;     and neither does the completions-first-difference highlight.
;;   - indicate how to display the completions in *Completions* (turn
;;     \n into something else, add special boundaries between
;;     completions).  E.g. when completing from the kill-ring.

;; - case-sensitivity currently confuses two issues:
;;   - whether or not a particular completion table should be case-sensitive
;;     (i.e. whether strings that differ only by case are semantically
;;     equivalent)
;;   - whether the user wants completion to pay attention to case.
;;   e.g. we may want to make it possible for the user to say "first try
;;   completion case-sensitively, and if that fails, try to ignore case".
;;   Maybe the trick is that we should distinguish completion-ignore-case in
;;   try/all-completions (obey user's preference) from its use in
;;   test-completion (obey the underlying object's semantics).

;; - add support for ** to pcm.
;; - Add vc-file-name-completion-table to read-file-name-internal.

;;; Code:

(eval-when-compile (require 'cl-lib))

(declare-function widget-put "wid-edit" (widget property value))

;;; Completion table manipulation

;; New completion-table operation.
(defun completion-boundaries (string collection pred suffix)
  "Return the boundaries of text on which COLLECTION will operate.
STRING is the string on which completion will be performed.
SUFFIX is the string after point.
If COLLECTION is a function, it is called with 3 arguments: STRING,
PRED, and a cons cell of the form (boundaries . SUFFIX).

The result is of the form (START . END) where START is the position
in STRING of the beginning of the completion field and END is the position
in SUFFIX of the end of the completion field.
E.g. for simple completion tables, the result is always (0 . (length SUFFIX))
and for file names the result is the positions delimited by
the closest directory separators."
  (let ((boundaries (if (functionp collection)
                        (funcall collection string pred
                                 (cons 'boundaries suffix)))))
    (if (not (eq (car-safe boundaries) 'boundaries))
        (setq boundaries nil))
    (cons (or (cadr boundaries) 0)
          (or (cddr boundaries) (length suffix)))))

(defun completion-metadata (string table pred)
  "Return the metadata of elements to complete at the end of STRING.
This metadata is an alist.  Currently understood keys are:
- `category': the kind of objects returned by `all-completions'.
   Used by `completion-category-overrides'.
- `annotation-function': function to add annotations in *Completions*.
   Takes one argument (STRING), which is a possible completion and
   returns a string to append to STRING.
- `affixation-function': function to prepend/append a prefix/suffix to
   entries.  Takes one argument (COMPLETIONS) and should return a list
   of annotated completions.  The elements of the list must be
   three-element lists: completion, its prefix and suffix.  This
   function takes priority over `annotation-function' when both are
   provided, so only this function is used.
- `group-function': function for grouping the completion candidates.
   Takes two arguments: a completion candidate (COMPLETION) and a
   boolean flag (TRANSFORM).  If TRANSFORM is nil, the function
   returns the group title of the group to which the candidate
   belongs.  The returned title may be nil.  Otherwise the function
   returns the transformed candidate.  The transformation can remove a
   redundant prefix, which is displayed in the group title.
- `display-sort-function': function to sort entries in *Completions*.
   Takes one argument (COMPLETIONS) and should return a new list
   of completions.  Can operate destructively.
- `cycle-sort-function': function to sort entries when cycling.
   Works like `display-sort-function'.
- `eager-display': non-nil to request eager display of the
  completion candidates.  Can also be a function which is invoked
  after minibuffer setup.
The metadata of a completion table should be constant between two boundaries."
  (let ((metadata (if (functionp table)
                      (funcall table string pred 'metadata))))
    (cons 'metadata
          (if (eq (car-safe metadata) 'metadata)
              (cdr metadata)))))

(defun completion--field-metadata (field-start)
  (completion-metadata (buffer-substring-no-properties field-start (point))
                       minibuffer-completion-table
                       minibuffer-completion-predicate))

(defun completion--metadata-get-1 (metadata prop)
  (or (alist-get prop metadata)
      (plist-get completion-extra-properties
                 ;; Cache the keyword
                 (or (get prop 'completion-extra-properties--keyword)
                     (put prop 'completion-extra-properties--keyword
                          (intern (concat ":" (symbol-name prop))))))))

(defun completion-metadata-get (metadata prop)
  "Get property PROP from completion METADATA.
If the metadata specifies a completion category, the variables
`completion-category-overrides' and
`completion-category-defaults' take precedence for
category-specific overrides.  If the completion metadata does not
specify the property, the `completion-extra-properties' plist is
consulted.  Note that the keys of the
`completion-extra-properties' plist are keyword symbols, not
plain symbols."
  (if-let* (((not (eq prop 'category)))
            (cat (completion--metadata-get-1 metadata 'category))
            (over (completion--category-override cat prop)))
      (cdr over)
    (completion--metadata-get-1 metadata prop)))

(defun complete-with-action (action collection string predicate)
  "Perform completion according to ACTION.
STRING, COLLECTION and PREDICATE are used as in `try-completion'.

If COLLECTION is a function, it will be called directly to
perform completion, no matter what ACTION is.

If ACTION is `metadata' or a list where the first element is
`boundaries', return nil.  If ACTION is nil, this function works
like `try-completion'; if it is t, this function works like
`all-completion'; and any other value makes it work like
`test-completion'."
  (cond
   ((functionp collection) (funcall collection string predicate action))
   ((eq (car-safe action) 'boundaries) nil)
   ((eq action 'metadata) nil)
   (t
    (funcall
     (cond
      ((null action) 'try-completion)
      ((eq action t) 'all-completions)
      (t 'test-completion))
     string collection predicate))))

(defun completion-table-dynamic (fun &optional switch-buffer)
  "Use function FUN as a dynamic completion table.
FUN is called with one argument, the string for which completion is requested,
and it should return a completion table containing all the intended possible
completions.
This table is allowed to include elements that do not actually match the
string: they will be automatically filtered out.
The completion table returned by FUN can use any of the usual formats of
completion tables such as lists, alists, and hash-tables.

If SWITCH-BUFFER is non-nil and completion is performed in the
minibuffer, FUN will be called in the buffer from which the minibuffer
was entered.

The result of the `completion-table-dynamic' form is a function
that can be used as the COLLECTION argument to `try-completion' and
`all-completions'.  See Info node `(elisp)Programmed Completion'.
The completion table returned by `completion-table-dynamic' has empty
metadata and trivial boundaries.

See also the related function `completion-table-with-cache'."
  (lambda (string pred action)
    (if (or (eq (car-safe action) 'boundaries) (eq action 'metadata))
        ;; `fun' is not supposed to return another function but a plain old
        ;; completion table, whose boundaries are always trivial.
        nil
      (with-current-buffer (if (not switch-buffer) (current-buffer)
                             (let ((win (minibuffer-selected-window)))
                               (if (window-live-p win) (window-buffer win)
                                 (current-buffer))))
        (complete-with-action action (funcall fun string) string pred)))))

(defun completion-table-with-cache (fun &optional ignore-case)
  "Create dynamic completion table from function FUN, with cache.
This is a wrapper for `completion-table-dynamic' that saves the last
argument-result pair from FUN, so that several lookups with the
same argument (or with an argument that starts with the first one)
only need to call FUN once.  This can be useful when FUN performs a
relatively slow operation, such as calling an external process.

When IGNORE-CASE is non-nil, FUN is expected to be case-insensitive."
  ;; See eg bug#11906.
  (let* (last-arg last-result
         (new-fun
          (lambda (arg)
            (if (and last-arg (string-prefix-p last-arg arg ignore-case))
                last-result
              (prog1
                  (setq last-result (funcall fun arg))
                (setq last-arg arg))))))
    (completion-table-dynamic new-fun)))

(defmacro lazy-completion-table (var fun)
  "Initialize variable VAR as a lazy completion table.
If the completion table VAR is used for the first time (e.g., by passing VAR
as an argument to `try-completion'), the function FUN is called with no
arguments.  FUN must return the completion table that will be stored in VAR.
If completion is requested in the minibuffer, FUN will be called in the buffer
from which the minibuffer was entered.  The return value of
`lazy-completion-table' must be used to initialize the value of VAR.

You should give VAR a non-nil `risky-local-variable' property."
  (declare (debug (symbolp lambda-expr)))
  (let ((str (make-symbol "string")))
    `(completion-table-dynamic
      (lambda (,str)
        (when (functionp ,var)
          (setq ,var (funcall #',fun)))
        ,var)
      'do-switch-buffer)))

(defun completion-table-case-fold (table &optional dont-fold)
  "Return new completion TABLE that is case insensitive.
If DONT-FOLD is non-nil, return a completion table that is
case sensitive instead."
  (lambda (string pred action)
    (let ((completion-ignore-case (not dont-fold)))
      (complete-with-action action table string pred))))

(defun completion-table-with-metadata (table metadata)
  "Return new completion TABLE with METADATA.
METADATA should be an alist of completion metadata.  See
`completion-metadata' for a list of supported metadata."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata . ,metadata)
      (complete-with-action action table string pred))))

(defun completion-table-subvert (table s1 s2)
  "Return a completion table from TABLE with S1 replaced by S2.
The result is a completion table which completes strings of the
form (concat S1 S) in the same way as TABLE completes strings of
the form (concat S2 S)."
  (lambda (string pred action)
    (let* ((str (if (string-prefix-p s1 string completion-ignore-case)
                    (concat s2 (substring string (length s1)))))
           (res (if str (complete-with-action action table str pred))))
      (when (or res (eq (car-safe action) 'boundaries))
        (cond
         ((eq (car-safe action) 'boundaries)
          (let ((beg (or (and (eq (car-safe res) 'boundaries) (cadr res)) 0)))
            `(boundaries
              ,(min (length string)
                    (max (length s1)
                         (+ beg (- (length s1) (length s2)))))
              . ,(and (eq (car-safe res) 'boundaries) (cddr res)))))
         ((stringp res)
          (if (string-prefix-p s2 res completion-ignore-case)
              (concat s1 (substring res (length s2)))))
         ((eq action t)
          (let ((bounds (completion-boundaries str table pred "")))
            (if (>= (car bounds) (length s2))
                res
              (let ((re (concat "\\`"
                                (regexp-quote (substring s2 (car bounds))))))
                (delq nil
                      (mapcar (lambda (c)
                                (if (string-match re c)
                                    (substring c (match-end 0))))
                              res))))))
         ;; E.g. action=nil and it's the only completion.
         (res))))))

(defun completion-table-with-context (prefix table string pred action)
  ;; TODO: add `suffix' maybe?
  (let ((pred
         (if (not (functionp pred))
             ;; Notice that `pred' may not be a function in some abusive cases.
             pred
           ;; Predicates are called differently depending on the nature of
           ;; the completion table :-(
           (cond
            ((obarrayp table)
             (lambda (sym) (funcall pred (concat prefix (symbol-name sym)))))
            ((hash-table-p table)
             (lambda (s _v) (funcall pred (concat prefix s))))
            ((functionp table)
             (lambda (s) (funcall pred (concat prefix s))))
            (t                          ;Lists and alists.
             (lambda (s)
               (funcall pred (concat prefix (if (consp s) (car s) s)))))))))
    (if (eq (car-safe action) 'boundaries)
        (let* ((len (length prefix))
               (bound (completion-boundaries string table pred (cdr action))))
          `(boundaries ,(+ (car bound) len) . ,(cdr bound)))
      (let ((comp (complete-with-action action table string pred)))
        (cond
         ;; In case of try-completion, add the prefix.
         ((stringp comp) (concat prefix comp))
         (t comp))))))

(defun completion-table-with-terminator (terminator table string pred action)
  "Construct a completion table like TABLE but with an extra TERMINATOR.
This is meant to be called in a curried way by first passing TERMINATOR
and TABLE only (via `apply-partially').
TABLE is a completion table, and TERMINATOR is a string appended to TABLE's
completion if it is complete.  TERMINATOR is also used to determine the
completion suffix's boundary.
TERMINATOR can also be a cons cell (TERMINATOR . TERMINATOR-REGEXP)
in which case TERMINATOR-REGEXP is a regular expression whose submatch
number 1 should match TERMINATOR.  This is used when there is a need to
distinguish occurrences of the TERMINATOR strings which are really terminators
from others (e.g. escaped).  In this form, the car of TERMINATOR can also be,
instead of a string, a function that takes the completion and returns the
\"terminated\" string."
  ;; FIXME: This implementation is not right since it only adds the terminator
  ;; in try-completion, so any completion-style that builds the completion via
  ;; all-completions won't get the terminator, and selecting an entry in
  ;; *Completions* won't get the terminator added either.
  (cond
   ((eq (car-safe action) 'boundaries)
    (let* ((suffix (cdr action))
           (bounds (completion-boundaries string table pred suffix))
           (terminator-regexp (if (consp terminator)
                                  (cdr terminator) (regexp-quote terminator)))
           (max (and terminator-regexp
                     (string-match terminator-regexp suffix))))
      `(boundaries ,(car bounds)
                   . ,(min (cdr bounds) (or max (length suffix))))))
   ((eq action nil)
    (let ((comp (try-completion string table pred)))
      (if (consp terminator) (setq terminator (car terminator)))
      (if (eq comp t)
          (if (functionp terminator)
              (funcall terminator string)
            (concat string terminator))
        (if (and (stringp comp) (not (zerop (length comp)))
                 ;; Try to avoid the second call to try-completion, since
                 ;; it may be very inefficient (because `comp' made us
                 ;; jump to a new boundary, so we complete in that
                 ;; boundary with an empty start string).
                 (let ((newbounds (completion-boundaries comp table pred "")))
                   (< (car newbounds) (length comp)))
                 (eq (try-completion comp table pred) t))
            (if (functionp terminator)
                (funcall terminator comp)
              (concat comp terminator))
          comp))))
   ;; completion-table-with-terminator is always used for
   ;; "sub-completions" so it's only called if the terminator is missing,
   ;; in which case `test-completion' should return nil.
   ((eq action 'lambda) nil)
   (t
    ;; FIXME: We generally want the `try' and `all' behaviors to be
    ;; consistent so pcm can merge the `all' output to get the `try' output,
    ;; but that sometimes clashes with the need for `all' output to look
    ;; good in *Completions*.
    ;; (mapcar (lambda (s) (concat s terminator))
    ;;         (all-completions string table pred))))
    (complete-with-action action table string pred))))

(defun completion-table-with-predicate (table pred1 strict string pred2 action)
  "Make a completion table equivalent to TABLE but filtered through PRED1.
PRED1 is a function of one argument which returns non-nil if and
only if the argument is an element of TABLE which should be
considered for completion.  STRING, PRED2, and ACTION are the
usual arguments to completion tables, as described in
`try-completion', `all-completions', and `test-completion'.  If
STRICT is non-nil, the predicate always applies; if nil it only
applies if it does not reduce the set of possible completions to
nothing.  Note: TABLE needs to be a proper completion table which
obeys predicates."
  (cond
   ((and (not strict) (eq action 'lambda))
    ;; Ignore pred1 since it doesn't really have to apply anyway.
    (test-completion string table pred2))
   (t
    (or (complete-with-action action table string
                              (if (not (and pred1 pred2))
                                  (or pred1 pred2)
                                (lambda (x)
                                  ;; Call `pred1' first, so that `pred2'
                                  ;; really can't tell that `x' is in table.
                                  (and (funcall pred1 x) (funcall pred2 x)))))
        ;; If completion failed and we're not applying pred1 strictly, try
        ;; again without pred1.
        (and (not strict) pred1
             (complete-with-action action table string pred2))))))

(defun completion-table-in-turn (&rest tables)
  "Create a completion table that tries each table in TABLES in turn."
  ;; FIXME: the boundaries may come from TABLE1 even when the completion list
  ;; is returned by TABLE2 (because TABLE1 returned an empty list).
  ;; Same potential problem if any of the tables use quoting.
  (lambda (string pred action)
    (seq-some (lambda (table)
                (complete-with-action action table string pred))
              tables)))

(defun completion-table-merge (&rest tables)
  "Create a completion table that collects completions from all TABLES."
  ;; FIXME: same caveats as in `completion-table-in-turn'.
  (lambda (string pred action)
    (cond
     ((null action)
      (let ((retvals (mapcar (lambda (table)
                               (try-completion string table pred))
                             tables)))
        (if (member string retvals)
            string
          (try-completion string
                          (mapcar (lambda (value)
                                    (if (eq value t) string value))
                                  (delq nil retvals))
                          pred))))
     ((eq action t)
      (apply #'append (mapcar (lambda (table)
                                (all-completions string table pred))
                              tables)))
     (t
      (seq-some (lambda (table)
                  (complete-with-action action table string pred))
                tables)))))

(defun completion-table-with-quoting (table unquote requote)
  ;; A difficult part of completion-with-quoting is to map positions in the
  ;; quoted string to equivalent positions in the unquoted string and
  ;; vice-versa.  There is no efficient and reliable algorithm that works for
  ;; arbitrary quote and unquote functions.
  ;; So to map from quoted positions to unquoted positions, we simply assume
  ;; that `concat' and `unquote' commute (which tends to be the case).
  ;; And we ask `requote' to do the work of mapping from unquoted positions
  ;; back to quoted positions.
  ;; FIXME: For some forms of "quoting" such as the truncation behavior of
  ;; substitute-in-file-name, it would be desirable not to requote completely.
  "Return a new completion table operating on quoted text.
TABLE operates on the unquoted text.
UNQUOTE is a function that takes a string and returns a new unquoted string.
REQUOTE is a function of 2 args (UPOS QSTR) where
  QSTR is a string entered by the user (and hence indicating
  the user's preferred form of quoting); and
  UPOS is a position within the unquoted form of QSTR.
REQUOTE should return a pair (QPOS . QFUN) such that QPOS is the
position corresponding to UPOS but in QSTR, and QFUN is a function
of one argument (a string) which returns that argument appropriately quoted
for use at QPOS."
  ;; FIXME: One problem with the current setup is that `qfun' doesn't know if
  ;; its argument is "the end of the completion", so if the quoting used double
  ;; quotes (for example), we end up completing "fo" to "foobar and throwing
  ;; away the closing double quote.
  (lambda (string pred action)
    (cond
     ((eq action 'metadata)
      (append (completion-metadata string table pred)
              '((completion--unquote-requote . t))))

     ((eq action 'lambda) ;;test-completion
      (let ((ustring (funcall unquote string)))
        (test-completion ustring table pred)))

     ((eq (car-safe action) 'boundaries)
      (let* ((ustring (funcall unquote string))
             (qsuffix (cdr action))
             (ufull (if (zerop (length qsuffix)) ustring
                      (funcall unquote (concat string qsuffix))))
             ;; If (not (string-prefix-p ustring ufull)) we have a problem:
             ;; unquoting the qfull gives something "unrelated" to ustring.
             ;; E.g. "~/" and "/" where "~//" gets unquoted to just "/" (see
             ;; bug#47678).
             ;; In that case we can't even tell if we're right before the
             ;; "/" or right after it (aka if this "/" is from qstring or
             ;; from qsuffix), thus which usuffix to use is very unclear.
             (usuffix (if (string-prefix-p ustring ufull)
                          (substring ufull (length ustring))
                        ;; FIXME: Maybe "" is preferable/safer?
                        qsuffix))
             (boundaries (completion-boundaries ustring table pred usuffix))
             (qlboundary (car (funcall requote (car boundaries) string)))
             (qrboundary (if (zerop (cdr boundaries)) 0 ;Common case.
                           (let* ((urfullboundary
                                   (+ (cdr boundaries) (length ustring))))
                             (- (car (funcall requote urfullboundary
                                              (concat string qsuffix)))
                                (length string))))))
        `(boundaries ,qlboundary . ,qrboundary)))

     ;; In "normal" use a c-t-with-quoting completion table should never be
     ;; called with action in (t nil) because `completion--unquote' should have
     ;; been called before and would have returned a different completion table
     ;; to apply to the unquoted text.  But there's still a lot of code around
     ;; that likes to use all/try-completions directly, so we do our best to
     ;; handle those calls as well as we can.

     ((eq action nil) ;;try-completion
      (let* ((ustring (funcall unquote string))
             (completion (try-completion ustring table pred)))
        ;; Most forms of quoting allow several ways to quote the same string.
        ;; So here we could simply requote `completion' in a kind of
        ;; "canonical" quoted form without paying attention to the way
        ;; `string' was quoted.  But since we have to solve the more complex
        ;; problems of "pay attention to the original quoting" for
        ;; all-completions, we may as well use it here, since it provides
        ;; a nicer behavior.
        (if (not (stringp completion)) completion
          (car (completion--twq-try
                string ustring completion 0 unquote requote)))))

     ((eq action t) ;;all-completions
      ;; When all-completions is used for completion-try/all-completions
      ;; (e.g. for `pcm' style), we can't do the job properly here because
      ;; the caller will match our output against some pattern derived from
      ;; the user's (quoted) input, and we don't have access to that
      ;; pattern, so we can't know how to requote our output so that it
      ;; matches the quoting used in the pattern.  It is to fix this
      ;; fundamental problem that we have to introduce the new
      ;; unquote-requote method so that completion-try/all-completions can
      ;; pass the unquoted string to the style functions.
      (pcase-let*
          ((ustring (funcall unquote string))
           (completions (all-completions ustring table pred))
           (boundary (car (completion-boundaries ustring table pred "")))
           (completions
            (completion--twq-all
             string ustring completions boundary unquote requote))
           (last (last completions)))
        (when (consp last) (setcdr last nil))
        completions))

     ((eq action 'completion--unquote)
      ;; PRED is really a POINT in STRING.
      ;; We should return a new set (STRING TABLE POINT REQUOTE)
      ;; where STRING is a new (unquoted) STRING to match against the new TABLE
      ;; using a new POINT inside it, and REQUOTE is a requoting function which
      ;; should reverse the unquoting, (i.e. it receives the completion result
      ;; of using the new TABLE and should turn it into the corresponding
      ;; quoted result).
      (let* ((qpos pred)
	     (ustring (funcall unquote string))
	     (uprefix (funcall unquote (substring string 0 qpos)))
	     ;; FIXME: we really should pass `qpos' to `unquote' and have that
	     ;; function give us the corresponding `uqpos'.  But for now we
	     ;; presume (more or less) that `concat' and `unquote' commute.
	     (uqpos (if (string-prefix-p uprefix ustring)
			;; Yay!!  They do seem to commute!
			(length uprefix)
		      ;; They don't commute this time!  :-(
		      ;; Maybe qpos is in some text that disappears in the
		      ;; ustring (bug#17239).  Let's try a second chance guess.
		      (let ((usuffix (funcall unquote (substring string qpos))))
			(if (string-suffix-p usuffix ustring)
			    ;; Yay!!  They still "commute" in a sense!
			    (- (length ustring) (length usuffix))
			  ;; Still no luck!  Let's just choose *some* position
			  ;; within ustring.
			  (/ (+ (min (length uprefix) (length ustring))
				(max (- (length ustring) (length usuffix)) 0))
			     2))))))
        (list ustring table uqpos
              (lambda (unquoted-result op)
                (pcase op
                  (1 ;;try
                   (if (not (stringp (car-safe unquoted-result)))
                       unquoted-result
                     (completion--twq-try
                      string ustring
                      (car unquoted-result) (cdr unquoted-result)
                      unquote requote)))
                  (2 ;;all
                   (let* ((last (last unquoted-result))
                          (base (or (cdr last) 0)))
                     (when last
                       (setcdr last nil)
                       (completion--twq-all string ustring
                                            unquoted-result base
                                            unquote requote))))))))))))

(defun completion--twq-try (string ustring completion point
                                   unquote requote)
  ;; Basically two cases: either the new result is
  ;; - commonprefix1 <point> morecommonprefix <qpos> suffix
  ;; - commonprefix <qpos> newprefix <point> suffix
  (pcase-let*
      ((prefix (fill-common-string-prefix ustring completion))
       (suffix (substring completion (max point (length prefix))))
       (`(,qpos . ,qfun) (funcall requote (length prefix) string))
       (qstr1 (if (> point (length prefix))
                  (funcall qfun (substring completion (length prefix) point))))
       (qsuffix (funcall qfun suffix))
       (qstring (concat (substring string 0 qpos) qstr1 qsuffix))
       (qpoint
        (cond
         ((zerop point) 0)
         ((> point (length prefix)) (+ qpos (length qstr1)))
         (t (car (funcall requote point string))))))
    ;; Make sure `requote' worked.
    (if (equal (funcall unquote qstring) completion)
	(cons qstring qpoint)
      ;; If requote failed (e.g. because sifn-requote did not handle
      ;; Tramp's "/foo:/bar//baz -> /foo:/baz" truncation), then at least
      ;; try requote properly.
      (let ((qstr (funcall qfun completion)))
	(cons qstr (length qstr))))))

(defun completion--twq-all (string ustring completions boundary
                                   _unquote requote)
  (when completions
    (pcase-let*
        ((prefix
          (let ((completion-regexp-list nil))
            (try-completion "" (cons (substring ustring boundary)
                                     completions))))
         (`(,qfullpos . ,qfun)
          (funcall requote (+ boundary (length prefix)) string))
         (qfullprefix (substring string 0 qfullpos))
	 ;; FIXME: This assertion can be wrong, e.g. in Cygwin, where
	 ;; (unquote "c:\bin") => "/usr/bin" but (unquote "c:\") => "/".
         ;;(cl-assert (string-equal-ignore-case
         ;;            (funcall unquote qfullprefix)
         ;;            (concat (substring ustring 0 boundary) prefix))
         ;;           t))
         (qboundary (car (funcall requote boundary string)))
         (_ (cl-assert (<= qboundary qfullpos)))
         ;; FIXME: this split/quote/concat business messes up the carefully
         ;; placed completions-common-part and completions-first-difference
         ;; faces.  We could try within the mapcar loop to search for the
         ;; boundaries of those faces, pass them to `requote' to find their
         ;; equivalent positions in the quoted output and re-add the faces:
         ;; this might actually lead to correct results but would be
         ;; pretty expensive.
         ;; The better solution is to not quote the *Completions* display,
         ;; which nicely circumvents the problem.  The solution I used here
         ;; instead is to hope that `qfun' preserves the text-properties and
         ;; presume that the `first-difference' is not within the `prefix';
         ;; this presumption is not always true, but at least in practice it is
         ;; true in most cases.
         (qprefix (propertize (substring qfullprefix qboundary)
                              'face 'completions-common-part))
         (no-quoting-in-prefix (string-equal qprefix prefix)))

      ;; Here we choose to quote all elements returned, but a better option
      ;; would be to return unquoted elements together with a function to
      ;; requote them, so that *Completions* can show nicer unquoted values
      ;; which only get quoted when needed by choose-completion.
      ;; FIXME: *Completions* now shows unquoted values by using
      ;; completion--unquoted, so this function can be greatly simplified.
      (nconc
       (mapcar (lambda (completion)
                 (cl-assert (string-prefix-p prefix completion 'ignore-case) t)
                 (let* ((new (substring completion (length prefix)))
                        (qnew (funcall qfun new))
                        (qprefix
                         (cond
                          (no-quoting-in-prefix
                           ;; We can just use the existing prefix, which
                           ;; preserves the existing faces.
                           (substring completion 0 (length prefix)))
                          ((not completion-ignore-case) qprefix)
                          (t
                           ;; Make qprefix inherit the case from `completion'.
                           (let* ((rest (substring completion
                                                   0 (length prefix)))
                                  (qrest (funcall qfun rest)))
                             (if (string-equal-ignore-case qprefix qrest)
                                 (propertize qrest 'face
                                             'completions-common-part)
                               qprefix)))))
                        (qcompletion (concat qprefix qnew)))
                   ;; Some completion tables (including this one) pass
                   ;; along necessary information as text properties
                   ;; on the first character of the completion.  Make
                   ;; sure the quoted completion has these properties
                   ;; too.
                   (add-text-properties 0 1 (text-properties-at 0 completion)
                                        qcompletion)
                   ;; Attach unquoted completion string, which is needed
                   ;; to score the completion in `completion--flex-score'.
                   (put-text-property 0 1 'completion--unquoted
                                      completion qcompletion)
		   ;; FIXME: Similarly here, Cygwin's mapping trips this
		   ;; assertion.
                   ;;(cl-assert
                   ;; (string-equal-ignore-case
		   ;;  (funcall unquote
		   ;;           (concat (substring string 0 qboundary)
		   ;;                   qcompletion))
		   ;;  (concat (substring ustring 0 boundary)
		   ;;          completion))
		   ;; t)
                   qcompletion))
               completions)
       qboundary))))

;;; Minibuffer completion

(defgroup minibuffer nil
  "Controlling the behavior of the minibuffer."
  :link '(custom-manual "(emacs)Minibuffer")
  :group 'environment)

(defvar minibuffer-message-properties nil
  "Text properties added to the text shown by `minibuffer-message'.")

(defun minibuffer-message (message &rest args)
  "Temporarily display MESSAGE at the end of minibuffer text.
This function is designed to be called from the minibuffer, i.e.,
when Emacs prompts the user for some input, and the user types
into the minibuffer.  If called when the current buffer is not
the minibuffer, this function just calls `message', and thus
displays MESSAGE in the echo-area.
When called from the minibuffer, this function displays MESSAGE
at the end of minibuffer text for `minibuffer-message-timeout'
seconds, or until the next input event arrives, whichever comes first.
It encloses MESSAGE in [...] if it is not yet enclosed.
The intent is to show the message without hiding what the user typed.
If ARGS are provided, then the function first passes MESSAGE
through `format-message'.
If some of the minibuffer text has the `minibuffer-message' text
property, MESSAGE is shown at that position instead of EOB."
  (if (not (minibufferp (current-buffer) t))
      (progn
        (if args
            (apply #'message message args)
          (message "%s" message))
        (prog1 (sit-for (or minibuffer-message-timeout 1000000))
          (message nil)))
    ;; Clear out any old echo-area message to make way for our new thing.
    (message nil)
    (setq message (if (and (null args)
                           (string-match-p "\\` *\\[.+\\]\\'" message))
                      ;; Make sure we can put-text-property.
                      (copy-sequence message)
                    (concat " [" message "]")))
    (when args (setq message (apply #'format-message message args)))
    (unless (or (null minibuffer-message-properties)
                ;; Don't overwrite the face properties the caller has set
                (text-properties-at 0 message))
      (setq message (apply #'propertize message minibuffer-message-properties)))
    ;; Put overlay either on `minibuffer-message' property, or at EOB.
    (let* ((ovpos (minibuffer--message-overlay-pos))
           (ol (make-overlay ovpos ovpos nil t t))
           ;; A quit during sit-for normally only interrupts the sit-for,
           ;; but since minibuffer-message is used at the end of a command,
           ;; at a time when the command has virtually finished already, a C-g
           ;; should really cause an abort-recursive-edit instead (i.e. as if
           ;; the C-g had been typed at top-level).  Binding inhibit-quit here
           ;; is an attempt to get that behavior.
           (inhibit-quit t))
      (unwind-protect
          (progn
            (unless (zerop (length message))
              ;; The current C cursor code doesn't know to use the overlay's
              ;; marker's stickiness to figure out whether to place the cursor
              ;; before or after the string, so let's spoon-feed it the pos.
              (put-text-property 0 1 'cursor t message))
            (overlay-put ol 'after-string message)
            ;; Make sure the overlay with the message is displayed before
            ;; any other overlays in that position, in case they have
            ;; resize-mini-windows set to nil and the other overlay strings
            ;; are too long for the mini-window width.  This makes sure the
            ;; temporary message will always be visible.
            (overlay-put ol 'priority 1100)
            (sit-for (or minibuffer-message-timeout 1000000)))
        (delete-overlay ol)))))

(defcustom minibuffer-message-clear-timeout nil
  "How long to display an echo-area message when the minibuffer is active.
If the value is a number, it is the time in seconds after which to
remove the echo-area message from the active minibuffer.
If the value is not a number, such messages are never removed,
and their text is displayed until the next input event arrives.
Unlike `minibuffer-message-timeout' used by `minibuffer-message',
this option affects the pair of functions `set-minibuffer-message'
and `clear-minibuffer-message' called automatically via
`set-message-function' and `clear-message-function'."
  :type '(choice (const :tag "Never time out" nil)
                 (integer :tag "Wait for the number of seconds" 2))
  :version "27.1")

(defvar minibuffer-message-timer nil)
(defvar minibuffer-message-overlay nil)

(defun minibuffer--message-overlay-pos ()
  "Return position where minibuffer message functions shall put message overlay.
The minibuffer message functions include `minibuffer-message' and
`set-minibuffer-message'."
  ;; Starting from point, look for non-nil `minibuffer-message'
  ;; property, and return its position.  If none found, return the EOB
  ;; position.
  (let* ((pt (point))
         (propval (get-text-property pt 'minibuffer-message)))
    (if propval pt
      (next-single-property-change pt 'minibuffer-message nil (point-max)))))

(defun set-minibuffer-message (message)
  "Temporarily display MESSAGE at the end of the active minibuffer window.
If some part of the minibuffer text has the `minibuffer-message' property,
the message will be displayed before the first such character, instead of
at the end of the minibuffer.
The text is displayed for `minibuffer-message-clear-timeout' seconds
\(if the value is a number), or until the next input event arrives,
whichever comes first.
Unlike `minibuffer-message', this function is called automatically
via `set-message-function'."
  (let* ((minibuf-window (active-minibuffer-window))
         (minibuf-frame (and (window-live-p minibuf-window)
                             (window-frame minibuf-window))))
    (when (and (not noninteractive)
               (window-live-p minibuf-window)
               (or (eq (window-frame) minibuf-frame)
                   (eq (frame-parameter minibuf-frame 'minibuffer) 'only)))
      (with-current-buffer (window-buffer minibuf-window)
        (setq message (if (string-match-p "\\` *\\[.+\\]\\'" message)
                          ;; Make sure we can put-text-property.
                          (copy-sequence message)
                        (concat " [" message "]")))
        (unless (or (null minibuffer-message-properties)
                    ;; Don't overwrite the face properties the caller has set
                    (text-properties-at 0 message))
          (setq message
                (apply #'propertize message minibuffer-message-properties)))

        (clear-minibuffer-message)

        (let ((ovpos (minibuffer--message-overlay-pos)))
          (setq minibuffer-message-overlay
                (make-overlay ovpos ovpos nil t t)))
        (unless (zerop (length message))
          ;; The current C cursor code doesn't know to use the overlay's
          ;; marker's stickiness to figure out whether to place the cursor
          ;; before or after the string, so let's spoon-feed it the pos.
          (put-text-property 0 1 'cursor t message))
        (overlay-put minibuffer-message-overlay 'after-string message)
        ;; Make sure the overlay with the message is displayed before
        ;; any other overlays in that position, in case they have
        ;; resize-mini-windows set to nil and the other overlay strings
        ;; are too long for the mini-window width.  This makes sure the
        ;; temporary message will always be visible.
        (overlay-put minibuffer-message-overlay 'priority 1100)

        (when (numberp minibuffer-message-clear-timeout)
          (setq minibuffer-message-timer
                (run-with-timer minibuffer-message-clear-timeout nil
                                #'clear-minibuffer-message)))

        ;; Return t telling the caller that the message
        ;; was handled specially by this function.
        t))))

(setq set-message-function 'set-message-functions)

(defcustom set-message-functions '(set-minibuffer-message)
  "List of functions to handle display of echo-area messages.
Each function is called with one argument that is the text of a message.
If a function returns nil, a previous message string is given to the
next function in the list, and if the last function returns nil, the
last message string is displayed in the echo area.
If a function returns a string, the returned string is given to the
next function in the list, and if the last function returns a string,
it's displayed in the echo area.
If a function returns any other non-nil value, no more functions are
called from the list, and no message will be displayed in the echo area.

Useful functions to add to this list are:

 `inhibit-message'        -- if this function is the first in the list,
                             messages that match the value of
                             `inhibit-message-regexps' will be suppressed.
 `set-multi-message'      -- accumulate multiple messages and display them
                             together as a single message.
 `set-minibuffer-message' -- if the minibuffer is active, display the
                             message at the end of the minibuffer text
                             (this is the default)."
  :type '(choice (const :tag "No special message handling" nil)
                 (repeat
                  (choice (function-item :tag "Inhibit some messages"
                                         inhibit-message)
                          (function-item :tag "Accumulate messages"
                                         set-multi-message)
                          (function-item :tag "Handle minibuffer"
                                         set-minibuffer-message)
                          (function :tag "Custom function"))))
  :version "29.1")

(defun set-message-functions (message)
  (run-hook-wrapped 'set-message-functions
                    (lambda (fun)
                      (when (stringp message)
                        (let ((ret (funcall fun message)))
                          (when ret (setq message ret))))
                      nil))
  message)

(defcustom inhibit-message-regexps nil
  "List of regexps that inhibit messages by the function `inhibit-message'.
When the list in `set-message-functions' has `inhibit-message' as its
first element, echo-area messages which match the value of this variable
will not be displayed."
  :type '(repeat regexp)
  :version "29.1")

(defun inhibit-message (message)
  "Don't display MESSAGE when it matches the regexp `inhibit-message-regexps'.
This function is intended to be added to `set-message-functions'.
To suppress display of echo-area messages that match `inhibit-message-regexps',
make this function be the first element of `set-message-functions'."
  (or (and (consp inhibit-message-regexps)
           (string-match-p (mapconcat #'identity inhibit-message-regexps "\\|")
                           message))
      message))

(defcustom multi-message-timeout 2
  "Number of seconds between messages before clearing the accumulated list."
  :type 'number
  :version "29.1")

(defcustom multi-message-max 8
  "Max size of the list of accumulated messages."
  :type 'number
  :version "29.1")

(defvar multi-message-separator "\n")

(defvar multi-message-list nil)

(defun set-multi-message (message)
  "Return recent messages as one string to display in the echo area.
Individual messages will be separated by a newline.
Up to `multi-message-max' messages can be accumulated, and the
accumulated messages are discarded when `multi-message-timeout'
seconds have elapsed since the first message.
Note that this feature works best only when `resize-mini-windows'
is at its default value `grow-only'."
  (let ((last-message (car multi-message-list)))
    (unless (and last-message (equal message (aref last-message 1)))
      (when last-message
        (cond
         ((> (float-time) (+ (aref last-message 0) multi-message-timeout))
          (setq multi-message-list nil))
         ((or
           ;; `message-log-max' was nil, potential clutter.
           (aref last-message 2)
           ;; Remove old message that is substring of the new message
           (string-prefix-p (aref last-message 1) message))
          (setq multi-message-list (cdr multi-message-list)))))
      (push (vector (float-time) message (not message-log-max)) multi-message-list)
      (when (> (length multi-message-list) multi-message-max)
        (setf (nthcdr multi-message-max multi-message-list) nil)))
    (mapconcat (lambda (m) (aref m 1))
               (reverse multi-message-list)
               multi-message-separator)))

(defvar touch-screen-current-tool)

(defun clear-minibuffer-message ()
  "Clear message temporarily shown in the minibuffer.
Intended to be called via `clear-message-function'."
  (when (not noninteractive)
    (when (timerp minibuffer-message-timer)
      (cancel-timer minibuffer-message-timer)
      (setq minibuffer-message-timer nil))
    (when (overlayp minibuffer-message-overlay)
      (delete-overlay minibuffer-message-overlay)
      (setq minibuffer-message-overlay nil)))
  ;; Don't clear the message if touch screen drag-to-select is in
  ;; progress, because a preview message might currently be displayed
  ;; in the echo area.  FIXME: find some way to place this in
  ;; touch-screen.el.
  (if (and (bound-and-true-p touch-screen-preview-select)
           (eq (nth 3 touch-screen-current-tool) 'drag))
      'dont-clear-message
    ;; Return nil telling the caller that the message
    ;; should be also handled by the caller.
    nil))

(setq clear-message-function 'clear-minibuffer-message)

(defun minibuffer-completion-contents ()
  "Return the user input in a minibuffer before point as a string.
In Emacs 22, that was what completion commands operated on.
If the current buffer is not a minibuffer, return everything before point."
  (declare (obsolete nil "24.4"))
  (buffer-substring (minibuffer-prompt-end) (point)))

(defun delete-minibuffer-contents ()
  "Delete all user input in a minibuffer.
If the current buffer is not a minibuffer, erase its entire contents."
  (interactive)
  ;; We used to do `delete-field' here, but when file name shadowing
  ;; is on, the field doesn't cover the entire minibuffer contents.
  (delete-region (minibuffer-prompt-end) (point-max)))

(defun minibuffer--completion-prompt-end ()
  (let ((end (minibuffer-prompt-end)))
    (if (< (point) end)
        (user-error "Can't complete in prompt")
      end)))

(defvar completion-show-inline-help t
  "If non-nil, print helpful inline messages during completion.")

(defcustom completion-eager-display 'auto
  "Whether completion commands should display *Completions* buffer eagerly.

If the variable is set to t, completion commands show the *Completions*
buffer always immediately.  Setting the variable to nil disables the
eager *Completions* display for all commands.

For the value `auto', completion commands show the *Completions* buffer
immediately only if requested by the completion command.  Completion
tables can request eager display via the `eager-display' metadata.

See also the variables `completion-category-overrides' and
`completion-extra-properties' for the `eager-display' completion
metadata."
  :type '(choice (const :tag "Never show *Completions* eagerly" nil)
                 (const :tag "Always show *Completions* eagerly" t)
                 (const :tag "If requested by the completion command" auto))
  :version "31.1")

(defcustom completion-eager-update 'auto
  "Whether typing should update the *Completions* buffer eagerly.

If `t', always update as you type.

If `auto', only update if the completion table has requested it or
`eager-update' is set in in `completion-category-defaults'.

This only affects the *Completions* buffer if it is already
displayed."
  :type '(choice (const :tag "Do nothing when you type" nil)
                 (const :tag "Auto-update based on the category" auto)
                 (const :tag "Always update as you type" t))
  :version "31.1")

(defcustom completion-auto-help t
  "Non-nil means automatically provide help for invalid completion input.
If the value is t, the *Completions* buffer is displayed whenever completion
is requested but cannot be done.
If the value is `lazy', the *Completions* buffer is only displayed after
the second failed attempt to complete.
If the value is `always', the *Completions* buffer is always shown
after a completion attempt, and the list of completions is updated if
already visible.
If the value is `visible', the *Completions* buffer is displayed
whenever completion is requested but cannot be done for the first time,
but remains visible thereafter, and the list of completions in it is
updated for subsequent attempts to complete."
  :type '(choice (const :tag "Don't show" nil)
                 (const :tag "Show only when cannot complete" t)
                 (const :tag "Show after second failed completion attempt" lazy)
                 (const :tag
                        "Leave visible after first failed completion" visible)
                 (const :tag "Always visible" always)))

(defvar completion-styles-alist
  '((emacs21
     completion-emacs21-try-completion completion-emacs21-all-completions
     "Simple prefix-based completion.
I.e. when completing \"foo_bar\" (where _ is the position of point),
it will consider all completions candidates matching the glob
pattern \"foobar*\".")
    (emacs22
     completion-emacs22-try-completion completion-emacs22-all-completions
     "Prefix completion that only operates on the text before point.
I.e. when completing \"foo_bar\" (where _ is the position of point),
it will consider all completions candidates matching the glob
pattern \"foo*\" and will add back \"bar\" to the end of it.")
    (ignore-after-point
     completion-ignore-after-point-try-completion completion-ignore-after-point-all-completions
     "Prefix completion that only operates on the text before point.
I.e. when completing \"foo_bar\" (where _ is the position of point),
it will consider all completions candidates matching the glob
pattern \"foo*\" and will add back \"bar\" to the end of it.")
    (basic
     completion-basic-try-completion completion-basic-all-completions
     "Completion of the prefix before point and the suffix after point.
I.e. when completing \"foo_bar\" (where _ is the position of point),
it will consider all completions candidates matching the glob
pattern \"foo*bar*\".")
    (partial-completion
     completion-pcm-try-completion completion-pcm-all-completions
     "Completion of multiple words, each one taken as a prefix.
I.e. when completing \"l-co_h\" (where _ is the position of point),
it will consider all completions candidates matching the glob
pattern \"l*-co*h*\".
Furthermore, for completions that are done step by step in subfields,
the method is applied to all the preceding fields that do not yet match.
E.g. C-x C-f /u/mo/s TAB could complete to /usr/monnier/src.
Additionally the user can use the char \"*\" as a glob pattern.")
    (substring
     completion-substring-try-completion completion-substring-all-completions
     "Completion of the string taken as a substring.
I.e. when completing \"foo_bar\" (where _ is the position of point),
it will consider all completions candidates matching the glob
pattern \"*foo*bar*\".")
    (flex
     completion-flex-try-completion completion-flex-all-completions
     "Completion of an in-order subset of characters.
When completing \"foo\" the glob \"*f*o*o*\" is used, so that
\"foo\" can complete to \"frodo\".")
    (initials
     completion-initials-try-completion completion-initials-all-completions
     "Completion of acronyms and initialisms.
E.g. can complete M-x lch to list-command-history
and C-x C-f ~/sew to ~/src/emacs/work.")
    (shorthand
     completion-shorthand-try-completion completion-shorthand-all-completions
     "Completion of symbol shorthands setup in `read-symbol-shorthands'.
E.g. can complete \"x-foo\" to \"xavier-foo\" if the shorthand
((\"x-\" . \"xavier-\")) is set up in the buffer of origin."))
  "List of available completion styles.
Each element has the form (NAME TRY-COMPLETION ALL-COMPLETIONS DOC):
where NAME is the name that should be used in `completion-styles',
TRY-COMPLETION is the function that does the completion (it should
follow the same calling convention as `completion-try-completion'),
ALL-COMPLETIONS is the function that lists the completions (it should
follow the calling convention of `completion-all-completions'),
and DOC describes the way this style of completion works.")

(defun completion--update-styles-options (widget)
  "Function to keep updated the options in `completion-category-overrides'."
  (let ((lst (mapcar (lambda (x)
                       (list 'const (car x)))
		     completion-styles-alist)))
    (widget-put widget :args (mapcar #'widget-convert lst))
    widget))

(defconst completion--styles-type
  '(repeat :tag "insert a new menu to add more styles"
           (single-or-list
            (choice :convert-widget completion--update-styles-options)
            (repeat :tag "Variable overrides" (group variable sexp)))))

(defconst completion--cycling-threshold-type
  '(choice (const :tag "No cycling" nil)
           (const :tag "Always cycle" t)
           (integer :tag "Threshold")))

(defcustom completion-styles
  ;; First, use `basic' because prefix completion has been the standard
  ;; for "ever" and works well in most cases, so using it first
  ;; ensures that we obey previous behavior in most cases.
  '(basic
    ;; Then use `partial-completion' because it has proven to
    ;; be a very convenient extension.
    partial-completion
    ;; Finally use `emacs22' so as to maintain (in many/most cases)
    ;; the previous behavior that when completing "foobar" with point
    ;; between "foo" and "bar" the completion try to complete "foo"
    ;; and simply add "bar" to the end of the result.
    emacs22)
  "List of completion styles to use.
An element should be a symbol which is listed in
`completion-styles-alist'.

An element can also be a list of the form
(STYLE ((VARIABLE VALUE) ...))
STYLE must be a symbol listed in `completion-styles-alist', followed by
a `let'-style list of variable/value pairs.  VARIABLE will be bound to
VALUE (without evaluating it) while the style is handling completion.
This allows repeating the same style with different configurations.

Note that `completion-category-overrides' may override these
styles for specific categories, such as files, buffers, etc."
  :type completion--styles-type
  :version "31.1")

(defvar completion-category-defaults
  '((buffer (styles . (basic substring)))
    (unicode-name (styles . (basic substring)))
    ;; A new style that combines substring and pcm might be better,
    ;; e.g. one that does not anchor to bos.
    (project-file (styles . (substring)))
    (xref-location (styles . (substring)))
    (info-menu (styles . (basic substring)))
    (symbol-help (styles . (basic shorthand substring))))
  "Default settings for specific completion categories.

Each entry has the shape (CATEGORY . ALIST) where ALIST is
an association list that can specify properties such as:
- `styles': the list of `completion-styles' to use for that category.
- `cycle': the `completion-cycle-threshold' to use for that category.
- `cycle-sort-function': function to sort entries when cycling.
- `display-sort-function': function to sort entries in *Completions*.
- `group-function': function for grouping the completion candidates.
- `annotation-function': function to add annotations in *Completions*.
- `affixation-function': function to prepend/append a prefix/suffix.
- `eager-display': function to show *Completions* eagerly.

Categories are symbols such as `buffer' and `file', used when
completing buffer and file names, respectively.

Also see `completion-category-overrides'.")

(defcustom completion-category-overrides nil
  "List of category-specific user overrides for completion metadata.

Each override has the shape (CATEGORY . ALIST) where ALIST is
an association list that can specify properties such as:
- `styles': the list of `completion-styles' to use for that category.
- `cycle': the `completion-cycle-threshold' to use for that category.
- `cycle-sort-function': function to sort entries when cycling.
- `display-sort-function': nil means to use either the sorting
function from metadata, or if that is nil, fall back to `completions-sort';
`identity' disables sorting and keeps the original order; and other
possible values are the same as in `completions-sort'.
- `group-function': function for grouping the completion candidates.
- `annotation-function': function to add annotations in *Completions*.
- `affixation-function': function to prepend/append a prefix/suffix.
- `eager-display': function to show *Completions* eagerly.
See more description of metadata in `completion-metadata'.

Categories are symbols such as `buffer' and `file', used when
completing buffer and file names, respectively.

If a property in a category is specified by this variable, it
overrides the default specified in `completion-category-defaults'."
  :version "31.1"
  :type `(alist :key-type (choice :tag "Category"
				  (const buffer)
                                  (const file)
                                  (const unicode-name)
				  (const bookmark)
                                  symbol)
          :value-type
          (set :tag "Properties to override"
	   (cons :tag "Completion Styles"
		 (const :tag "Select a style from the menu;" styles)
		 ,completion--styles-type)
           (cons :tag "Completion Cycling"
		 (const :tag "Select one value from the menu." cycle)
                 ,completion--cycling-threshold-type)
           (cons :tag "Cycle Sorting"
                 (const :tag "Select one value from the menu."
                        cycle-sort-function)
                 (choice (function :tag "Custom function")))
           (cons :tag "Completion Sorting"
                 (const :tag "Select one value from the menu."
                        display-sort-function)
                 (choice (const :tag "Use default" nil)
                         (const :tag "No sorting" identity)
                         (const :tag "Alphabetical sorting"
                                minibuffer-sort-alphabetically)
                         (const :tag "Historical sorting"
                                minibuffer-sort-by-history)
                         (function :tag "Custom function")))
           (cons :tag "Completion Groups"
                 (const :tag "Select one value from the menu."
                        group-function)
                 (choice (function :tag "Custom function")))
           (cons :tag "Completion Annotation"
                 (const :tag "Select one value from the menu."
                        annotation-function)
                 (choice (function :tag "Custom function")))
           (cons :tag "Completion Affixation"
                 (const :tag "Select one value from the menu."
                        affixation-function)
                 (choice (function :tag "Custom function")))
           (cons :tag "Eager display"
                 (const :tag "Select one value from the menu."
                        eager-display)
                 boolean))))

(defun completion--category-override (category tag)
  (or (assq tag (cdr (assq category completion-category-overrides)))
      (assq tag (cdr (assq category completion-category-defaults)))))

(defun completion--styles (metadata)
  (let* ((cat (completion-metadata-get metadata 'category))
         (over (completion--category-override cat 'styles)))
    (if over
        (delete-dups (append (cdr over) (copy-sequence completion-styles)))
       completion-styles)))

(defun completion--nth-completion (n string table pred point metadata)
  "Call the Nth method of completion styles."
  ;; We provide special support for quoting/unquoting here because it cannot
  ;; reliably be done within the normal completion-table routines: Completion
  ;; styles such as `substring' or `partial-completion' need to match the
  ;; output of all-completions with the user's input, and since most/all
  ;; quoting mechanisms allow several equivalent quoted forms, the
  ;; completion-style can't do this matching (e.g. `substring' doesn't know
  ;; that "\a\b\e" is a valid (quoted) substring of "label").
  ;; The quote/unquote function needs to come from the completion table (rather
  ;; than from completion-extra-properties) because it may apply only to some
  ;; part of the string (e.g. substitute-in-file-name).
  (let* ((md (or metadata
                 (completion-metadata (substring string 0 point) table pred)))
         (requote
          (when (and
                 (completion-metadata-get md 'completion--unquote-requote)
                 ;; Sometimes a table's metadata is used on another
                 ;; table (typically that other table is just a list taken
                 ;; from the output of `all-completions' or something
                 ;; equivalent, for progressive refinement).
                 ;; See bug#28898 and bug#16274.
                 ;; FIXME: Rather than do nothing, we should somehow call
                 ;; the original table, in that case!
                 (functionp table))
            (let ((new (funcall table string point 'completion--unquote)))
              (setq string (pop new))
              (setq table (pop new))
              (setq point (pop new))
              (cl-assert (<= point (length string)))
              (pop new))))
         (result-and-style
          (seq-some
           (lambda (style)
             (let (symbols values)
               (when (consp style)
                 (dolist (binding (cadr style))
                   (push (car binding) symbols)
                   (push (cadr binding) values))
                 (setq style (car style)))
               (cl-progv symbols values
                 (let ((probe (funcall
                               (or (nth n (assq style completion-styles-alist))
                                   (error "Invalid completion style %s" style))
                               string table pred point)))
                   (and probe (cons probe style))))))
           (completion--styles md)))
         (adjust-fn (get (cdr result-and-style) 'completion--adjust-metadata))
         (adjusted (completion-metadata-get
                    metadata 'completion--adjusted-metadata)))
    (when (and adjust-fn metadata
               ;; Avoid re-applying the same adjustment (bug#74718).
               (not (memq (cdr result-and-style) adjusted)))
      (setcdr metadata `((completion--adjusted-metadata
                          ,(cdr result-and-style) . ,adjusted)
                         . ,(cdr (funcall adjust-fn metadata)))))
    (if requote
        (funcall requote (car result-and-style) n)
      (car result-and-style))))

(defun completion-try-completion (string table pred point &optional metadata)
  "Try to complete STRING using completion table TABLE.
Only the elements of table that satisfy predicate PRED are considered.
POINT is the position of point within STRING.
The return value can be either nil to indicate that there is no completion,
t to indicate that STRING is the only possible completion,
or a pair (NEWSTRING . NEWPOINT) of the completed result string together with
a new position for point."
  (completion--nth-completion 1 string table pred point metadata))

(defun completion-all-completions (string table pred point &optional metadata)
  "List the possible completions of STRING in completion table TABLE.
Only the elements of table that satisfy predicate PRED are considered.
POINT is the position of point within STRING.
The return value is a list of completions and may contain the base-size
in the last `cdr'."
  (setq completion-lazy-hilit-fn nil)
  ;; FIXME: We need to additionally return the info needed for the
  ;; second part of completion-base-position.
  (completion--nth-completion 2 string table pred point metadata))

(defun minibuffer--bitset (modified completions exact)
  (logior (if modified    4 0)
          (if completions 2 0)
          (if exact       1 0)))

(defun completion--replace (beg end newtext)
  "Replace the buffer text between BEG and END with NEWTEXT.
Moves point to the end of the new text."
  ;; The properties on `newtext' include things like the
  ;; `completions-first-difference' face, which we don't want to
  ;; include upon insertion.
  (setq newtext (copy-sequence newtext)) ;Don't modify the arg by side-effect.
  (if minibuffer-allow-text-properties
      ;; If we're preserving properties, then just remove the faces
      ;; and other properties added by the completion machinery.
      (remove-text-properties 0 (length newtext) '(face completion-score)
                              newtext)
    ;; Remove all text properties.
    (set-text-properties 0 (length newtext) nil newtext))
  (replace-region-contents beg end newtext 0.1 nil 'inherit)
  (goto-char (+ beg (length newtext))))

(defcustom completion-cycle-threshold nil
  "Number of completion candidates below which cycling is used.
Depending on this setting `completion-in-region' may use cycling,
whereby invoking a completion command several times in a row
completes to each of the candidates in turn, in a cyclic manner.
If nil, cycling is never used.
If t, cycling is always used.
If an integer, cycling is used so long as there are not more
completion candidates than this number."
  :version "24.1"
  :type completion--cycling-threshold-type)

(defcustom completions-sort 'alphabetical
  "Sort candidates in the *Completions* buffer.

Completion candidates in the *Completions* buffer are sorted
depending on the value.

If it's nil, sorting is disabled.
If it's the symbol `alphabetical', candidates are sorted by
`minibuffer-sort-alphabetically'.
If it's the symbol `historical', candidates are sorted by
`minibuffer-sort-by-history', which first sorts alphabetically,
and then rearranges the order according to the order of the
candidates in the minibuffer history.
If it's a function, the function is called to sort the candidates.
The sorting function takes a list of completion candidate
strings, which it may modify; it should return a sorted list,
which may be the same.

If the completion-specific metadata provides a
`display-sort-function', that function overrides the value of
this variable."
  :type '(choice (const :tag "No sorting" nil)
                 (const :tag "Alphabetical sorting" alphabetical)
                 (const :tag "Historical sorting" historical)
                 (function :tag "Custom function"))
  :version "30.1")

(defcustom completions-group nil
  "Enable grouping of completion candidates in the *Completions* buffer.
See also `completions-group-format' and `completions-group-sort'."
  :type 'boolean
  :version "28.1")

(defcustom completions-group-sort nil
  "Sort groups in the *Completions* buffer.

The value can either be nil to disable sorting, `alphabetical' for
alphabetical sorting or a custom sorting function.  The sorting
function takes and returns an alist of groups, where each element is a
pair of a group title string and a list of group candidate strings."
  :type '(choice (const :tag "No sorting" nil)
                 (const :tag "Alphabetical sorting" alphabetical)
                 function)
  :version "28.1")

(defcustom completions-group-format
  (concat
   (propertize "    " 'face 'completions-group-separator)
   (propertize " %s " 'face 'completions-group-title)
   (propertize " " 'face 'completions-group-separator
               'display '(space :align-to right)))
  "Format string used for the group title."
  :type 'string
  :version "28.1")

(defface completions-group-title
  '((t :inherit shadow :slant italic))
  "Face used for the title text of the candidate group headlines."
  :version "28.1")

(defface completions-group-separator
  '((t :inherit shadow :strike-through t))
  "Face used for the separator lines between the candidate groups."
  :version "28.1")

(defun completion--cycle-threshold (metadata)
  (let* ((cat (completion-metadata-get metadata 'category))
         (over (completion--category-override cat 'cycle)))
    (if over (cdr over) completion-cycle-threshold)))

(defvar-local completion-all-sorted-completions nil)
(defvar-local completion--all-sorted-completions-location nil)
(defvar completion-cycling nil)      ;Function that takes down the cycling map.
(defvar completion-tab-width nil)

(defvar completion-fail-discreetly nil
  "If non-nil, stay quiet when there is no match.")

(defun completion--message (msg)
  (if completion-show-inline-help
      (minibuffer-message msg)))

(defun completion--do-completion (beg end &optional
                                      try-completion-function expect-exact)
  "Do the completion and return a summary of what happened.
M = completion was performed, the text was Modified.
C = there were available Completions.
E = after completion we now have an Exact match.

 MCE
 000  0 no possible completion
 001  1 was already an exact and unique completion
 010  2 no completion happened
 011  3 was already an exact completion
 100  4 ??? impossible
 101  5 ??? impossible
 110  6 some completion happened
 111  7 completed to an exact completion

TRY-COMPLETION-FUNCTION is a function to use in place of `try-completion'.
EXPECT-EXACT, if non-nil, means that there is no need to tell the user
when the buffer's text is already an exact match."
  (let* ((string (buffer-substring beg end))
         (md (completion--field-metadata beg))
         (comp (funcall (or try-completion-function
                            #'completion-try-completion)
                        string
                        minibuffer-completion-table
                        minibuffer-completion-predicate
                        (- (point) beg)
                        md)))
    (cond
     ((null comp)
      (minibuffer-hide-completions)
      (unless completion-fail-discreetly
	(ding)
	(completion--message "No match"))
      (minibuffer--bitset nil nil nil))
     ((eq t comp)
      (minibuffer-hide-completions)
      (goto-char end)
      (completion--done string 'finished
                        (unless expect-exact "Sole completion"))
      (minibuffer--bitset nil nil t))   ;Exact and unique match.
     (t
      ;; `completed' should be t if some completion was done, which doesn't
      ;; include simply changing the case of the entered string.  However,
      ;; for appearance, the string is rewritten if the case changes.
      (let* ((comp-pos (cdr comp))
             (completion (car comp))
             (completed (not (string-equal-ignore-case completion string)))
             (unchanged (string-equal completion string)))
        (if unchanged
	    (goto-char end)
          ;; Insert in minibuffer the chars we got.
          (completion--replace beg end completion)
          (setq end (+ beg (length completion))))
	;; Move point to its completion-mandated destination.
	(forward-char (- comp-pos (length completion)))

        (if (not (or unchanged completed))
            ;; The case of the string changed, but that's all.  We're not sure
            ;; whether this is a unique completion or not, so try again using
            ;; the real case (this shouldn't recurse again, because the next
            ;; time try-completion will return either t or the exact string).
            (completion--do-completion beg end
                                       try-completion-function expect-exact)

          ;; It did find a match.  Do we match some possibility exactly now?
          (let* ((exact (test-completion completion
                                         minibuffer-completion-table
                                         minibuffer-completion-predicate))
                 (threshold (completion--cycle-threshold md))
                 (comps
                  ;; Check to see if we want to do cycling.  We do it
                  ;; here, after having performed the normal completion,
                  ;; so as to take advantage of the difference between
                  ;; try-completion and all-completions, for things
                  ;; like completion-ignored-extensions.
                  (when (and threshold
                             ;; Check that the completion didn't make
                             ;; us jump to a different boundary.
                             (or (not completed)
                                 (< (car (completion-boundaries
                                          (substring completion 0 comp-pos)
                                          minibuffer-completion-table
                                          minibuffer-completion-predicate
                                         ""))
                                   comp-pos)))
                   (completion-all-sorted-completions beg end))))
            (completion--flush-all-sorted-completions)
            (cond
             ((and (consp (cdr comps)) ;; There's something to cycle.
                   (not (ignore-errors
                          ;; This signal an (intended) error if comps is too
                          ;; short or if completion-cycle-threshold is t.
                          (consp (nthcdr threshold comps)))))
              ;; Not more than completion-cycle-threshold remaining
              ;; completions: let's cycle.
              (setq completed t exact t)
              (completion--cache-all-sorted-completions beg end comps)
              (minibuffer-force-complete beg end))
             (completed
              (cond
               ((pcase completion-auto-help
                  ('visible (get-buffer-window "*Completions*" 0))
                  ('always t))
                (minibuffer-completion-help beg end))
               (t (minibuffer-hide-completions)
                  (when exact
                    ;; If completion did not put point at end of field,
                    ;; it's a sign that completion is not finished.
                    (completion--done completion
                                      (if (< comp-pos (length completion))
                                          'exact 'unknown))))))
             ;; Show the completion table, if requested.
             ((not exact)
	      (if (pcase completion-auto-help
                    ('lazy (eq this-command last-command))
                    (_ completion-auto-help))
                  (minibuffer-completion-help beg end)
                (completion--message "Next char not unique")))
             ;; If the last exact completion and this one were the same, it
             ;; means we've already given a "Complete, but not unique" message
             ;; and the user's hit TAB again, so now we give him help.
             (t
              (if (and (eq this-command last-command) completion-auto-help)
                  (minibuffer-completion-help beg end))
              (completion--done completion 'exact
                                (unless (or expect-exact
                                            (and completion-auto-select
                                                 (eq this-command last-command)
                                                 completion-auto-help))
                                  "Complete, but not unique"))))

            (minibuffer--bitset completed t exact))))))))

(defun minibuffer-complete ()
  "Complete the minibuffer contents as far as possible.
Return nil if there is no valid completion, else t.
If no characters can be completed, display a list of possible completions.
If you repeat this command after it displayed such a list,
scroll the window of possible completions."
  (interactive)
  (completion-in-region (minibuffer--completion-prompt-end) (point-max)
                        minibuffer-completion-table
                        minibuffer-completion-predicate))

(defun completion--in-region-1 (beg end)
  ;; If the previous command was not this,
  ;; mark the completion buffer obsolete.
  (setq this-command 'completion-at-point)
  (unless (eq 'completion-at-point last-command)
    (completion--flush-all-sorted-completions)
    (setq minibuffer-scroll-window nil))

  (cond
   ;; If there's a fresh completion window with a live buffer,
   ;; and this command is repeated, scroll that window.
   ((and (window-live-p minibuffer-scroll-window)
         (eq t (frame-visible-p (window-frame minibuffer-scroll-window))))
    (let ((window minibuffer-scroll-window))
      (with-current-buffer (window-buffer window)
        (cond
         ;; Here this is possible only when second-tab, but instead of
         ;; scrolling the completion list window, switch to it below,
         ;; outside of `with-current-buffer'.
         ((eq completion-auto-select 'second-tab))
         ;; Reverse tab
         ((equal (this-command-keys) [backtab])
          (completion--lazy-insert-strings)
          (if (pos-visible-in-window-p (point-min) window)
              ;; If beginning is in view, scroll up to the end.
              (set-window-point window (point-max))
            ;; Else scroll down one screen.
            (with-selected-window window (scroll-down))))
         ;; Normal tab
         (t
          (completion--lazy-insert-strings)
          (if (pos-visible-in-window-p (point-max) window)
              ;; If end is in view, scroll up to the end.
              (set-window-start window (point-min) nil)
            ;; Else scroll down one screen.
            (with-selected-window window (scroll-up))))))
      (when (eq completion-auto-select 'second-tab)
        (switch-to-completions))
      nil))
   ;; If we're cycling, keep on cycling.
   ((and completion-cycling completion-all-sorted-completions)
    (minibuffer-force-complete beg end)
    t)
   (t (prog1 (pcase (completion--do-completion beg end)
               (#b000 nil)
               (_     t))
        (if (window-live-p minibuffer-scroll-window)
            (and (eq completion-auto-select t)
                 (eq t (frame-visible-p (window-frame minibuffer-scroll-window)))
                 ;; When the completion list window was displayed, select it.
                 (switch-to-completions))
          (completion-in-region-mode -1))))))

(defun completion--cache-all-sorted-completions (beg end comps)
  (add-hook 'after-change-functions
            #'completion--flush-all-sorted-completions nil t)
  (setq completion--all-sorted-completions-location
        (cons (copy-marker beg) (copy-marker end)))
  (setq completion-all-sorted-completions comps))

(defun completion--flush-all-sorted-completions (&optional start end _len)
  (unless (and start end
               (or (> start (cdr completion--all-sorted-completions-location))
                   (< end (car completion--all-sorted-completions-location))))
    (remove-hook 'after-change-functions
                 #'completion--flush-all-sorted-completions t)
    ;; Remove the transient map if applicable.
    (when completion-cycling
      (funcall (prog1 completion-cycling (setq completion-cycling nil))))
    (setq completion-all-sorted-completions nil)))

(defun completion--metadata (string base md-at-point table pred)
  ;; Like completion-metadata, but for the specific case of getting the
  ;; metadata at `base', which tends to trigger pathological behavior for old
  ;; completion tables which don't understand `metadata'.
  (let ((bounds (completion-boundaries string table pred "")))
    (if (eq (car bounds) base) md-at-point
      (completion-metadata (substring string 0 base) table pred))))

(defun minibuffer--sort-by-key (elems keyfun)
  "Return ELEMS sorted by increasing value of their KEYFUN.
KEYFUN takes an element of ELEMS and should return a numerical value."
  (mapcar #'cdr
          (sort (mapcar (lambda (x) (cons (funcall keyfun x) x)) elems)
                 #'car-less-than-car)))

(defun minibuffer--sort-by-position (hist elems)
  "Sort ELEMS by their position in HIST."
  (let ((hash (make-hash-table :test #'equal :size (length hist)))
        (index 0))
    ;; Record positions in hash
    (dolist (c hist)
      (unless (gethash c hash)
        (puthash c index hash))
      (incf index))
    (minibuffer--sort-by-key
     elems (lambda (x) (gethash x hash most-positive-fixnum)))))

(defun minibuffer--sort-by-length-alpha (elems)
  "Sort ELEMS first by length, then alphabetically."
  (sort elems (lambda (c1 c2)
                (or (< (length c1) (length c2))
                    (and (= (length c1) (length c2))
                         (string< c1 c2))))))

(defun minibuffer--sort-preprocess-history (base)
  "Preprocess history.
Remove completion BASE prefix string from history elements."
  (let* ((def (if (stringp minibuffer-default)
                  minibuffer-default
                (car-safe minibuffer-default)))
         (hist (and (not (eq minibuffer-history-variable t))
                    (symbol-value minibuffer-history-variable)))
         (base-size (length base)))
    ;; Default comes first.
    (setq hist (if def (cons def hist) hist))
    ;; Drop base string from the history elements.
    (if (= base-size 0)
        hist
      (delq nil (mapcar
                 (lambda (c)
                   (when (string-prefix-p base c)
                     (substring c base-size)))
                 hist)))))

(defun minibuffer-sort-alphabetically (completions)
  "Sort COMPLETIONS alphabetically.

COMPLETIONS are sorted alphabetically by `string-lessp'.

This is a suitable function to use for `completions-sort' or to
include as `display-sort-function' in completion metadata."
  (sort completions #'string-lessp))

(defvar minibuffer-completion-base nil
  "The base for the current completion.

This is the part of the current minibuffer input which comes
before the current completion field, as determined by
`completion-boundaries'.  This is primarily relevant for file
names, where this is the directory component of the file name.")

(defun minibuffer-sort-by-history (completions)
  "Sort COMPLETIONS by their position in `minibuffer-history-variable'.

COMPLETIONS are sorted first by `minibuffer-sort-alphbetically',
then any elements occurring in the minibuffer history list are
moved to the front based on the chronological order they occur in
the history.  If a history variable hasn't been specified for
this call of `completing-read', COMPLETIONS are sorted only by
`minibuffer-sort-alphbetically'.

This is a suitable function to use for `completions-sort' or to
include as `display-sort-function' in completion metadata."
  (let ((alphabetized (sort completions #'string-lessp)))
    ;; Only use history when it's specific to these completions.
    (if (eq minibuffer-history-variable
            (default-value minibuffer-history-variable))
        alphabetized
      (minibuffer--sort-by-position
       (minibuffer--sort-preprocess-history minibuffer-completion-base)
       alphabetized))))

(defun minibuffer--group-by (group-fun sort-fun elems)
  "Group ELEMS by GROUP-FUN and sort groups by SORT-FUN."
  (let ((groups))
    (dolist (cand elems)
      (let* ((key (funcall group-fun cand nil))
             (group (assoc key groups)))
        (if group
            (setcdr group (cons cand (cdr group)))
          (push (list key cand) groups))))
    (setq groups (nreverse groups)
          groups (mapc (lambda (x)
                         (setcdr x (nreverse (cdr x))))
                       groups)
          groups (funcall sort-fun groups))
    (mapcan #'cdr groups)))

(defun completion-all-sorted-completions (&optional start end)
  (or completion-all-sorted-completions
      (let* ((start (or start (minibuffer-prompt-end)))
             (end (or end (point-max)))
             (string (buffer-substring start end))
             (md (completion--field-metadata start))
             (all (completion-all-completions
                   string
                   minibuffer-completion-table
                   minibuffer-completion-predicate
                   (- (point) start)
                   md))
             (last (last all))
             (base-size (or (cdr last) 0))
             (all-md (completion--metadata (buffer-substring-no-properties
                                            start (point))
                                           base-size md
                                           minibuffer-completion-table
                                           minibuffer-completion-predicate))
             (sort-fun (completion-metadata-get all-md 'cycle-sort-function))
             (group-fun (completion-metadata-get all-md 'group-function)))
        (when last
          (setcdr last nil)

          ;; Delete duplicates: do it after setting last's cdr to nil (so
          ;; it's a proper list), and be careful to reset `last' since it
          ;; may be a different cons-cell.
          (setq all (delete-dups all))
          (setq last (last all))

          (cond
           (sort-fun (setq all (funcall sort-fun all)))
           ((and completions-group group-fun)
            ;; TODO: experiment with re-grouping here.  Might be slow
            ;; if the group-fun (given by the table and out of our
            ;; control) is slow and/or allocates too much.
            )
           (t
            ;; If the table doesn't stipulate a sorting function or a
            ;; group function, sort first by length and
            ;; alphabetically.
            (setq all (minibuffer--sort-by-length-alpha all))
            ;; Then sort by history position, and put the default, if it
            ;; exists, on top.
            (when (minibufferp)
              (setq all (minibuffer--sort-by-position
                         (minibuffer--sort-preprocess-history
                          (substring string 0 base-size))
                         all)))))

          ;; Cache the result.  This is not just for speed, but also so that
          ;; repeated calls to minibuffer-force-complete can cycle through
          ;; all possibilities.
          (completion--cache-all-sorted-completions
           start end (nconc all base-size))))))

(defun minibuffer-force-complete-and-exit ()
  "Complete the minibuffer with first of the matches and exit."
  (interactive)
  ;; If `completion-cycling' is t, then surely a
  ;; `minibuffer-force-complete' has already executed.  This is not
  ;; just for speed: the extra rotation caused by the second
  ;; unnecessary call would mess up the final result value
  ;; (bug#34116).
  (unless completion-cycling
    (minibuffer-force-complete nil nil 'dont-cycle))
  (completion--complete-and-exit
   (minibuffer--completion-prompt-end) (point-max) #'exit-minibuffer
   ;; If the previous completion completed to an element which fails
   ;; test-completion, then we shouldn't exit, but that should be rare.
   (lambda ()
     (if minibuffer--require-match
         (completion--message "Incomplete")
       ;; If a match is not required, exit after all.
       (exit-minibuffer)))))

(defun minibuffer-force-complete (&optional start end dont-cycle)
  "Complete the minibuffer to an exact match.
Repeated uses step through the possible completions.
DONT-CYCLE tells the function not to setup cycling."
  (interactive)
  (setq minibuffer-scroll-window nil)
  ;; FIXME: Need to deal with the extra-size issue here as well.
  ;; FIXME: ~/src/emacs/t<M-TAB>/lisp/minibuffer.el completes to
  ;; ~/src/emacs/trunk/ and throws away lisp/minibuffer.el.
  (let* ((start (copy-marker (or start (minibuffer--completion-prompt-end))))
         (end (or end (point-max)))
         ;; (md (completion--field-metadata start))
         (all (completion-all-sorted-completions start end))
         (base (+ start (or (cdr (last all)) 0))))
    (cond
     ((not (consp all))
      (completion--message
       (if all "No more completions" "No completions")))
     ((not (consp (cdr all)))
      (let ((done (equal (car all) (buffer-substring-no-properties base end))))
        (unless done (completion--replace base end (car all)))
        (completion--done (buffer-substring-no-properties start (point))
                          'finished (when done "Sole completion"))))
     (t
      (completion--replace base end (car all))
      (setq end (+ base (length (car all))))
      (completion--done (buffer-substring-no-properties start (point)) 'sole)
      (setq this-command 'completion-at-point) ;For completion-in-region.
      ;; Set cycling after modifying the buffer since the flush hook resets it.
      (unless dont-cycle
        ;; If completing file names, (car all) may be a directory, so we'd now
        ;; have a new set of possible completions and might want to reset
        ;; completion-all-sorted-completions to nil, but we prefer not to,
        ;; so that repeated calls minibuffer-force-complete still cycle
        ;; through the previous possible completions.
        (let ((last (last all)))
          (setcdr last (cons (car all) (cdr last)))
          (completion--cache-all-sorted-completions start end (cdr all)))
        ;; Make sure repeated uses cycle, even though completion--done might
        ;; have added a space or something that moved us outside of the field.
        ;; (bug#12221).
        (let* ((table minibuffer-completion-table)
               (pred minibuffer-completion-predicate)
               (extra-prop completion-extra-properties)
               (cmd
                (lambda () "Cycle through the possible completions."
                  (interactive)
                  (let ((completion-extra-properties extra-prop))
                    (completion-in-region start (point) table pred)))))
          (setq completion-cycling
                (set-transient-map
                 (let ((map (make-sparse-keymap)))
                   (define-key map [remap completion-at-point] cmd)
                   (define-key map (vector last-command-event) cmd)
                   map)))))))))

(defvar minibuffer-confirm-exit-commands
  '( completion-at-point minibuffer-complete
     minibuffer-complete-word)
  "List of commands which cause an immediately following
`minibuffer-complete-and-exit' to ask for extra confirmation.")

(defvar minibuffer--require-match nil
  "Value of REQUIRE-MATCH passed to `completing-read'.")

(defvar minibuffer--original-buffer nil
  "Buffer that was current when `completing-read' was called.")

(defun minibuffer-complete-and-exit ()
  "Exit if the minibuffer contains a valid completion.
Otherwise, try to complete the minibuffer contents.  If
completion leads to a valid completion, a repetition of this
command will exit.

If `minibuffer-completion-confirm' is `confirm', do not try to
 complete; instead, ask for confirmation and accept any input if
 confirmed.
If `minibuffer-completion-confirm' is `confirm-after-completion',
 do not try to complete; instead, ask for confirmation if the
 preceding minibuffer command was a member of
 `minibuffer-confirm-exit-commands', and accept the input
 otherwise."
  (interactive)
  (completion-complete-and-exit (minibuffer--completion-prompt-end) (point-max)
                                #'exit-minibuffer))

(defun completion-complete-and-exit (beg end exit-function)
  (completion--complete-and-exit
   beg end exit-function
   (lambda ()
     (pcase (condition-case nil
                (completion--do-completion beg end
                                           nil 'expect-exact)
              (error 1))
       ((or #b001 #b011) (funcall exit-function))
       (#b111 (if (not minibuffer-completion-confirm)
                  (funcall exit-function)
                (minibuffer-message "Confirm")
                nil))
       (_ nil)))))

(defun completion--complete-and-exit (beg end
                                          exit-function completion-function)
  "Exit from `require-match' minibuffer.
COMPLETION-FUNCTION is called if the current buffer's content does not
appear to be a match."
  (cond
   ;; Allow user to specify null string
   ((= beg end) (funcall exit-function))
   ;; The CONFIRM argument is a predicate.
   ((functionp minibuffer-completion-confirm)
    (if (funcall minibuffer-completion-confirm
                 (buffer-substring beg end))
        (funcall exit-function)
      (unless completion-fail-discreetly
	(ding)
	(completion--message "No match"))))
   ;; See if we have a completion from the table.
   ((test-completion (buffer-substring beg end)
                     minibuffer-completion-table
                     minibuffer-completion-predicate)
    ;; FIXME: completion-ignore-case has various slightly
    ;; incompatible meanings.  E.g. it can reflect whether the user
    ;; wants completion to pay attention to case, or whether the
    ;; string will be used in a context where case is significant.
    ;; E.g. usually try-completion should obey the first, whereas
    ;; test-completion should obey the second.
    (when completion-ignore-case
      ;; Fixup case of the field, if necessary.
      (let* ((string (buffer-substring beg end))
             (compl (try-completion
                     string
                     minibuffer-completion-table
                     minibuffer-completion-predicate)))
        (when (and (stringp compl) (not (equal string compl))
                   ;; If it weren't for this piece of paranoia, I'd replace
                   ;; the whole thing with a call to do-completion.
                   ;; This is important, e.g. when the current minibuffer's
                   ;; content is a directory which only contains a single
                   ;; file, so `try-completion' actually completes to
                   ;; that file.
                   (= (length string) (length compl)))
          (completion--replace beg end compl))))
    (funcall exit-function))
   ;; The user is permitted to exit with an input that's rejected
   ;; by test-completion, after confirming her choice.
   ((memq minibuffer-completion-confirm '(confirm confirm-after-completion))
    (if (or (eq last-command this-command)
            ;; For `confirm-after-completion' we only ask for confirmation
            ;; if trying to exit immediately after typing TAB (this
            ;; catches most minibuffer typos).
            (and (eq minibuffer-completion-confirm 'confirm-after-completion)
                 (not (memq last-command minibuffer-confirm-exit-commands))))
        (funcall exit-function)
      (minibuffer-message "Confirm")
      nil))

   (t
    ;; Call do-completion, but ignore errors.
    (funcall completion-function))))

(defun completion--try-word-completion (string table predicate point md)
  (let ((comp (completion-try-completion string table predicate point md)))
    (if (not (consp comp))
        comp

      ;; If completion finds next char not unique,
      ;; consider adding a space or a hyphen.
      (when (= (length string) (length (car comp)))
        ;; Mark the added char with the `completion-word' property, so it
        ;; can be handled specially by completion styles such as
        ;; partial-completion.
        ;; We used to remove `partial-completion' from completion-styles
        ;; instead, but it was too blunt, leading to situations where SPC
        ;; was the only insertable char at point but minibuffer-complete-word
        ;; refused inserting it.
        (let ((exts (mapcar (lambda (str) (propertize str 'completion-try-word t))
                            '(" " "-")))
              (before (substring string 0 point))
              (after (substring string point))
	      tem)
          ;; If both " " and "-" lead to completions, prefer " " so SPC behaves
          ;; a bit more like a self-inserting key (bug#17375).
	  (while (and exts (not (consp tem)))
            (setq tem (completion-try-completion
		       (concat before (pop exts) after)
		       table predicate (1+ point) md)))
	  (if (consp tem) (setq comp tem))))

      ;; Completing a single word is actually more difficult than completing
      ;; as much as possible, because we first have to find the "current
      ;; position" in `completion' in order to find the end of the word
      ;; we're completing.  Normally, `string' is a prefix of `completion',
      ;; which makes it trivial to find the position, but with fancier
      ;; completion (plus env-var expansion, ...) `completion' might not
      ;; look anything like `string' at all.
      (let* ((comppoint (cdr comp))
	     (completion (car comp))
	     (before (substring string 0 point))
	     (combined (concat before "\n" completion)))
        ;; Find in completion the longest text that was right before point.
        (when (string-match "\\(.+\\)\n.*?\\1" combined)
          (let* ((prefix (match-string 1 before))
                 ;; We used non-greedy match to make `rem' as long as possible.
                 (rem (substring combined (match-end 0)))
                 ;; Find in the remainder of completion the longest text
                 ;; that was right after point.
                 (after (substring string point))
                 (suffix (if (string-match "\\`\\(.+\\).*\n.*\\1"
                                           (concat after "\n" rem))
                             (match-string 1 after))))
            ;; The general idea is to try and guess what text was inserted
            ;; at point by the completion.  Problem is: if we guess wrong,
            ;; we may end up treating as "added by completion" text that was
            ;; actually painfully typed by the user.  So if we then cut
            ;; after the first word, we may throw away things the
            ;; user wrote.  So let's try to be as conservative as possible:
            ;; only cut after the first word, if we're reasonably sure that
            ;; our guess is correct.
            ;; Note: a quick survey on emacs-devel seemed to indicate that
            ;; nobody actually cares about the "word-at-a-time" feature of
            ;; minibuffer-complete-word, whose real raison-d'être is that it
            ;; tries to add "-" or " ".  One more reason to only cut after
            ;; the first word, if we're really sure we're right.
            (when (and (or suffix (zerop (length after)))
                       (string-match (concat
                                      ;; Make submatch 1 as small as possible
                                      ;; to reduce the risk of cutting
                                      ;; valuable text.
                                      ".*" (regexp-quote prefix) "\\(.*?\\)"
                                      (if suffix (regexp-quote suffix) "\\'"))
                                     completion)
                       ;; The new point in `completion' should also be just
                       ;; before the suffix, otherwise something more complex
                       ;; is going on, and we're not sure where we are.
                       (eq (match-end 1) comppoint)
                       ;; (match-beginning 1)..comppoint is now the stretch
                       ;; of text in `completion' that was completed at point.
		       (string-match "\\W" completion (match-beginning 1))
		       ;; Is there really something to cut?
		       (> comppoint (match-end 0)))
              ;; Cut after the first word.
              (let ((cutpos (match-end 0)))
                (setq completion (concat (substring completion 0 cutpos)
                                         (substring completion comppoint)))
                (setq comppoint cutpos)))))

	(cons completion comppoint)))))


(defun minibuffer-complete-word ()
  "Complete the minibuffer contents at most a single word.
After one word is completed as much as possible, a space or hyphen
is added, provided that matches some possible completion.
Return nil if there is no valid completion, else t."
  (interactive)
  (completion-in-region--single-word
   (minibuffer--completion-prompt-end) (point-max)))

(defun completion-in-region--single-word (beg end)
  (pcase (completion--do-completion beg end #'completion--try-word-completion)
    (#b000 nil)
    (_     t)))

(defface completions-annotations '((t :inherit (italic shadow)))
  "Face to use for annotations in the *Completions* buffer.
This face is only used if the strings used for completions
doesn't already specify a face.")

(defface completions-highlight
  '((t :inherit highlight))
  "Default face for highlighting the current completion candidate."
  :version "29.1")

(defcustom completions-highlight-face 'completions-highlight
  "A face name to highlight the current completion candidate.
If the value is nil, no highlighting is performed."
  :type '(choice (const nil) face)
  :version "29.1")

(defcustom completions-format 'horizontal
  "Define the appearance and sorting of completions.
If the value is `vertical', display completions sorted vertically
in columns in the *Completions* buffer.
If the value is `horizontal', display completions sorted in columns
horizontally in alphabetical order, rather than down the screen.
If the value is `one-column', display completions down the screen
in one column."
  :type '(choice (const horizontal) (const vertical) (const one-column))
  :version "23.2")

(defcustom completions-detailed nil
  "When non-nil, display completions with details added as prefix/suffix.
This makes some commands (for instance, \\[describe-symbol]) provide a
detailed view with more information prepended or appended to
completions."
  :type 'boolean
  :version "28.1")

(defcustom completions-header-format
  (propertize "%s possible completions:\n" 'face 'shadow)
  "If non-nil, the format string for completions heading line.
The heading line is inserted before the completions, and is intended
to summarize the completions.
The format string may include one %s, which will be replaced with
the total count of possible completions.
If this is nil, no heading line will be shown."
  :type '(choice (const :tag "No heading line" nil)
                 (string :tag "Format string for heading line"))
  :version "29.1")

(defvar-local completions--lazy-insert-button nil)

(defun completion--insert-strings (strings &optional group-fun)
  "Insert a list of STRINGS into the current buffer.
The candidate strings are inserted into the buffer depending on the
completions format as specified by the variable `completions-format'.
Runs of equal candidate strings are eliminated.  GROUP-FUN is a
`group-function' used for grouping the completion candidates."
  (when (consp strings)
    (let* ((length (apply #'max
			  (mapcar (lambda (s)
				    (if (consp s)
				        (apply #'+ (mapcar #'string-width s))
				      (string-width s)))
				  strings)))
	   (window (get-buffer-window (current-buffer) 0))
	   (wwidth (if window (1- (window-width window)) 79))
	   (columns (min
		     ;; At least 2 spaces between columns.
		     (max 1 (/ wwidth (+ 2 length)))
		     ;; Don't allocate more columns than we can fill.
		     ;; Windows can't show less than 3 lines anyway.
		     (max 1 (/ (length strings) 2))))
	   (colwidth (/ wwidth columns))
	   (lines (or completions-max-height (frame-height))))
      (unless (or tab-stop-list (null completion-tab-width)
                  (zerop (mod colwidth completion-tab-width)))
        ;; Align to tab positions for the case
        ;; when the caller uses tabs inside prefix.
        (setq colwidth (- colwidth (mod colwidth completion-tab-width))))
      (let ((completions-continuation
             (catch 'completions-truncated
               (funcall (intern (format "completion--insert-%s"
                                        completions-format))
                        strings group-fun length wwidth colwidth columns lines)
               nil)))
        (when completions-continuation
          ;; If there's a bug which causes us to not insert the remaining
          ;; completions automatically, the user can at least press this button.
          (setq-local completions--lazy-insert-button
                      (insert-button
                       "[Completions truncated, click here to insert the rest.]"
                       'action #'completion--lazy-insert-strings))
          (button-put completions--lazy-insert-button
                      'completions-continuation completions-continuation))))))

(defun completion--lazy-insert-strings (&optional button)
  (setq button (or button completions--lazy-insert-button))
  (when button
    (let ((completion-lazy-hilit t)
          (standard-output (current-buffer))
          (inhibit-read-only t)
          (completions-continuation
           (button-get button 'completions-continuation)))
      (save-excursion
        (goto-char (button-start button))
        (delete-region (point) (button-end button))
        (setq-local completions--lazy-insert-button nil)
        (funcall completions-continuation)))))

(defun completion--insert-horizontal (strings group-fun
                                              length wwidth
                                              colwidth columns lines
                                              &optional last-title)
  (let ((column 0)
        (first t)
        (last-string nil)
        str)
    (while strings
      (setq str (pop strings))
      (unless (equal last-string str) ; Remove (consecutive) duplicates.
	(setq last-string str)
        (when group-fun
          (let ((title (funcall group-fun (if (consp str) (car str) str) nil)))
            (unless (equal title last-title)
              (setq last-title title)
              (when title
               (insert (if first "" "\n")
                       (format completions-group-format title) "\n")
                (setq column 0
                      first t)))))
	(unless first
          ;; FIXME: `string-width' doesn't pay attention to
          ;; `display' properties.
	  (if (< wwidth (+ column
                           (max colwidth
                                (if (consp str)
                                    (apply #'+ (mapcar #'string-width str))
                                  (string-width str)))))
	      ;; No space for `str' at point, move to next line.
	      (progn
                (insert "\n")
                (when (and lines (> (line-number-at-pos) lines))
                  (throw 'completions-truncated
                         (lambda ()
                           (completion--insert-horizontal
                            ;; Add str back, since we haven't inserted it yet.
                            (cons str strings) group-fun length wwidth colwidth
                            columns nil last-title))))
                (setq column 0))
	    (insert " \t")
	    ;; Leave the space unpropertized so that in the case we're
	    ;; already past the goal column, there is still
	    ;; a space displayed.
	    (set-text-properties (1- (point)) (point)
				 ;; We can set tab-width using
				 ;; completion-tab-width, but
				 ;; the caller can prefer using
				 ;; \t to align prefixes.
				 `(display (space :align-to ,column)))
	    nil))
        (setq first nil)
        (completion--insert str group-fun)
	;; Next column to align to.
	(setq column (+ column
			;; Round up to a whole number of columns.
			(* colwidth (ceiling length colwidth))))))))

(defun completion--insert-vertical (strings group-fun
                                            _length _wwidth
                                            colwidth columns _lines)
  (while strings
    (let ((group nil)
          (column 0)
	  (row 0)
          (rows)
          (last-string nil))
      (if group-fun
          (let* ((str (car strings))
                 (title (funcall group-fun (if (consp str) (car str) str) nil)))
            (while (and strings
                        (equal title (funcall group-fun
                                              (if (consp (car strings))
                                                  (car (car strings))
                                                (car strings))
                                              nil)))
              (push (car strings) group)
              (pop strings))
            (setq group (nreverse group)))
        (setq group strings
              strings nil))
      (setq rows (/ (length group) columns))
      (when group-fun
        (let* ((str (car group))
               (title (funcall group-fun (if (consp str) (car str) str) nil)))
          (when title
            (goto-char (point-max))
            (insert (format completions-group-format title) "\n"))))
      (dolist (str group)
        (unless (equal last-string str) ; Remove (consecutive) duplicates.
	  (setq last-string str)
	  (when (> row rows)
            (forward-line (- -1 rows))
	    (setq row 0 column (+ column colwidth)))
	  (when (> column 0)
	    (end-of-line)
	    (while (> (current-column) column)
	      (if (eobp)
		  (insert "\n")
	        (forward-line 1)
	        (end-of-line)))
	    (insert " \t")
	    (set-text-properties (1- (point)) (point)
			         `(display (space :align-to ,column))))
          (completion--insert str group-fun)
	  (if (> column 0)
	      (forward-line)
	    (insert "\n"))
	  (setq row (1+ row)))))))

(defun completion--insert-one-column ( strings group-fun length wwidth colwidth
                                       columns lines &optional last-title)
  (let ((last-string nil)
        str)
    (while strings
      (setq str (pop strings))
      (unless (equal last-string str) ; Remove (consecutive) duplicates.
	(setq last-string str)
        (when group-fun
          (let ((title (funcall group-fun (if (consp str) (car str) str) nil)))
            (unless (equal title last-title)
              (setq last-title title)
              (when title
                (insert (format completions-group-format title) "\n")))))
        (completion--insert str group-fun)
        (insert "\n")
        (when (and lines (> (line-number-at-pos) lines))
          (throw 'completions-truncated
                 (lambda ()
                   (completion--insert-one-column
                    strings group-fun length wwidth colwidth columns nil
                    last-title))))))
    (delete-char -1)))

(defun completion--insert (str group-fun)
  (if (not (consp str))
      (add-text-properties
       (point)
       (let ((str (completion-for-display str)))
         (insert
          (if group-fun
              (funcall group-fun str 'transform)
            str))
         (point))
       `(mouse-face highlight cursor-face ,completions-highlight-face completion--string ,str))
    ;; If `str' is a list that has 2 elements,
    ;; then the second element is a suffix annotation.
    ;; If `str' has 3 elements, then the second element
    ;; is a prefix, and the third element is a suffix.
    (let* ((prefix (when (nth 2 str) (nth 1 str)))
           (suffix (or (nth 2 str) (nth 1 str))))
      (when prefix
        (let ((beg (point))
              (end (progn (insert prefix) (point))))
          (add-text-properties beg end `(mouse-face nil completion--string ,(car str)))))
      (completion--insert (car str) group-fun)
      (let ((beg (point))
            (end (progn (insert suffix) (point))))
        (add-text-properties beg end `(mouse-face nil completion--string ,(car str)))
        ;; Put the predefined face only when suffix
        ;; is added via annotation-function without prefix,
        ;; and when the caller doesn't use own face.
        (unless (or prefix (text-property-not-all
                            0 (length suffix) 'face nil suffix))
          (font-lock-prepend-text-property
           beg end 'face 'completions-annotations))))))

(defvar completion-setup-hook nil
  "Normal hook run at the end of setting up a completion list buffer.
When this hook is run, the current buffer is the one in which the
command to display the completion list buffer was run.
The completion list buffer is available as the value of `standard-output'.
See also `display-completion-list'.")

(defface completions-first-difference
  '((t (:inherit bold)))
  "Face for the first character after point in completions.
See also the face `completions-common-part'.")

(defface completions-common-part
  '((((class color) (min-colors 16) (background light)) :foreground "blue3")
    (((class color) (min-colors 16) (background dark)) :foreground "lightblue"))
  "Face for the parts of completions which matched the pattern.
See also the face `completions-first-difference'.")

(defun completion-hilit-commonality (completions prefix-len &optional base-size)
  "Apply font-lock highlighting to a list of completions, COMPLETIONS.
PREFIX-LEN is an integer.  BASE-SIZE is an integer or nil (meaning zero).

This adds the face `completions-common-part' to the first
\(PREFIX-LEN - BASE-SIZE) characters of each completion, and the face
`completions-first-difference' to the first character after that.

It returns a list with font-lock properties applied to each element,
and with BASE-SIZE appended as the last element."
  (when completions
    (let* ((com-str-len (- prefix-len (or base-size 0)))
           (hilit-fn
            (lambda (str)
              (font-lock-prepend-text-property
               0
               ;; If completion-boundaries returns incorrect values,
               ;; all-completions may return strings that don't contain
               ;; the prefix.
               (min com-str-len (length str))
               'face 'completions-common-part str)
              (when (> (length str) com-str-len)
                (font-lock-prepend-text-property
                 com-str-len (1+ com-str-len)
                 'face 'completions-first-difference str))
              str)))
      (if completion-lazy-hilit
          (setq completion-lazy-hilit-fn hilit-fn)
        (setq completions
              (mapcar
               (lambda (elem)
                 ;; Don't modify the string itself, but a copy, since
                 ;; the string may be read-only or used for other
                 ;; purposes.  Furthermore, since `completions' may come
                 ;; from display-completion-list, `elem' may be a list.
                 (funcall hilit-fn
                          (if (consp elem)
                              (car (setq elem (cons (copy-sequence (car elem))
                                                    (cdr elem))))
                            (setq elem (copy-sequence elem))))
                 elem)
               completions)))
      (nconc completions base-size))))

(defun display-completion-list (completions &optional common-substring group-fun)
  "Display the list of completions, COMPLETIONS, using `standard-output'.
Each element may be just a symbol or string
or may be a list of two strings to be printed as if concatenated.
If it is a list of two strings, the first is the actual completion
alternative, the second serves as annotation.
`standard-output' must be a buffer.
The actual completion alternatives, as inserted, are given `mouse-face'
properties of `highlight'.
At the end, this runs the normal hook `completion-setup-hook'.
It can find the completion buffer in `standard-output'.
GROUP-FUN is a `group-function' used for grouping the completion
candidates."
  (declare (advertised-calling-convention (completions) "24.4"))
  (if common-substring
      (setq completions (completion-hilit-commonality
                         completions (length common-substring)
                         ;; We don't know the base-size.
                         nil)))
  (if (not (bufferp standard-output))
      ;; This *never* (ever) happens, so there's no point trying to be clever.
      (with-temp-buffer
	(let ((standard-output (current-buffer))
	      (completion-setup-hook nil))
          (with-suppressed-warnings ((callargs display-completion-list))
	    (display-completion-list completions common-substring group-fun)))
	(princ (buffer-string)))

    (with-current-buffer standard-output
      (goto-char (point-max))
      (if completions-header-format
          (insert (format completions-header-format (length completions)))
        (unless completion-show-help
          ;; Ensure beginning-of-buffer isn't a completion.
          (insert (propertize "\n" 'face '(:height 0)))))
      (completion--insert-strings completions group-fun)))

  (run-hooks 'completion-setup-hook)
  nil)

(defvar completion-extra-properties nil
  "Property list of extra properties of the current completion job.
These include:

`:category': the kind of objects returned by `all-completions'.
   Used by `completion-category-overrides'.

`:annotation-function': Function to annotate the completions buffer.
   The function must accept one argument, a completion string,
   and return either nil or a string which is to be displayed
   next to the completion (but which is not part of the
   completion).  The function can access the completion data via
   `minibuffer-completion-table' and related variables.

`:affixation-function': Function to prepend/append a prefix/suffix to
   completions.  The function must accept one argument, a list of
   completions, and return a list of annotated completions.  The
   elements of the list must be three-element lists: completion, its
   prefix and suffix.  This function takes priority over
   `:annotation-function' when both are provided, so only this
   function is used.

`:group-function': Function for grouping the completion candidates.

`:display-sort-function': Function to sort entries in *Completions*.

`:cycle-sort-function': Function to sort entries when cycling.

`:eager-display': Show the *Completions* buffer eagerly.

See more information about these functions above
in `completion-metadata'.

`:exit-function': Function to run after completion is performed.

   The function must accept two arguments, STRING and STATUS.
   STRING is the text to which the field was completed, and
   STATUS indicates what kind of operation happened:
     `finished' - text is now complete
     `sole'     - text cannot be further completed but
                  completion is not finished
     `exact'    - text is a valid completion but may be further
                  completed.")

(defun completion--done (string &optional finished message)
  (let* ((exit-fun (plist-get completion-extra-properties :exit-function))
         (pre-msg (and exit-fun (current-message))))
    (cl-assert (memq finished '(exact sole finished unknown)))
    (when exit-fun
      (when (eq finished 'unknown)
        (setq finished
              (if (eq (try-completion string
                                      minibuffer-completion-table
                                      minibuffer-completion-predicate)
                      t)
                  'finished 'exact)))
      (funcall exit-fun string finished))
    (when (and message
               ;; Don't output any message if the exit-fun already did so.
               (equal pre-msg (and exit-fun (current-message))))
      (completion--message message))))

(defcustom completions-max-height nil
  "Maximum height for *Completions* buffer window."
  :type '(choice (const nil) natnum)
  :version "29.1")

(defun completions--fit-window-to-buffer (&optional win &rest _)
  "Resize *Completions* buffer window."
  (if temp-buffer-resize-mode
      (let ((temp-buffer-max-height (or completions-max-height
                                        temp-buffer-max-height)))
        (resize-temp-buffer-window win))
    (fit-window-to-buffer win completions-max-height)))

(defcustom completion-auto-deselect t
  "If non-nil, deselect current completion candidate when you type in minibuffer.

A non-nil value means that after typing at the minibuffer prompt,
any completion candidate highlighted in *Completions* window (to
indicate that it is the selected candidate) will be un-highlighted,
and point in the *Completions* window will be moved off such a candidate.
This means that `RET' (`minibuffer-choose-completion-or-exit') will exit
the minibuffer with the minibuffer's current contents, instead of the
selected completion candidate."
  :type '(choice (const :tag "Candidates in *Completions* stay selected as you type" nil)
                 (const :tag "Typing deselects any completion candidate in *Completions*" t))
  :version "30.1")

(defun completions--deselect ()
  "If point is in a completion candidate, move to just after the end of it.

The candidate will still be chosen by `choose-completion' unless
`choose-completion-deselect-if-after' is non-nil."
  (when (get-text-property (point) 'completion--string)
    (goto-char (or (next-single-property-change (point) 'completion--string)
                   (point-max)))))

(defun completion--eager-update-p (start)
  "Return non-nil if *Completions* should be automatically updated.

If `completion-eager-update' is the symbol `auto', checks completion
metadata for the string from START to point."
  (if (eq completion-eager-update 'auto)
      (completion-metadata-get (completion--field-metadata start) 'eager-update)
    completion-eager-update))

(defun completions--background-update ()
  "Try to update *Completions* without blocking input.

This function uses `while-no-input' and sets `non-essential' to t
so that the update is less likely to interfere with user typing."
  (while-no-input
    (let ((non-essential t))
      (redisplay)
      (cond
       (completion-in-region-mode (completion-help-at-point t))
       ((completion--eager-update-p (minibuffer-prompt-end))
        (minibuffer-completion-help))))))

(defun completions--post-command-update ()
  "Update displayed *Completions* buffer after command, once."
  (remove-hook 'post-command-hook #'completions--post-command-update)
  (when (and completion-eager-update (get-buffer-window "*Completions*" 0))
    (completions--background-update)))

(defun completions--after-change (_start _end _old-len)
  "Update displayed *Completions* buffer after change in buffer contents."
  (when (or completion-auto-deselect completion-eager-update)
    (when-let* ((window (get-buffer-window "*Completions*" 0)))
      (when completion-auto-deselect
        (with-selected-window window
          (completions--deselect)))
      (when completion-eager-update
        (add-hook 'post-command-hook #'completions--post-command-update)))))

(defun minibuffer-completion-help (&optional start end)
  "Display a list of possible completions of the current minibuffer contents."
  (interactive)
  (message "Making completion list...")
  (let* ((start (or start (minibuffer--completion-prompt-end)))
         (end (or end (point-max)))
         (string (buffer-substring start end))
         (md (completion--field-metadata start))
         (completion-lazy-hilit t)
         (completions (completion-all-completions
                       string
                       minibuffer-completion-table
                       minibuffer-completion-predicate
                       (- (point) start)
                       md)))
    (message nil)
    (if (or (null completions)
            (and (not (consp (cdr completions)))
                 (equal (car completions) string)))
        (progn
          ;; If there are no completions, or if the current input is already
          ;; the sole completion, then hide (previous&stale) completions.
          (minibuffer-hide-completions)
          (remove-hook 'after-change-functions #'completions--after-change t)
          (if completions
              (completion--message "Sole completion")
            (unless completion-fail-discreetly
	      (ding)
	      (completion--message "No match"))))

      (let* ((last (last completions))
             (base-size (or (cdr last) 0))
             (prefix (unless (zerop base-size) (substring string 0 base-size)))
             (minibuffer-completion-base (substring string 0 base-size))
             (ctable minibuffer-completion-table)
             (cpred minibuffer-completion-predicate)
             (cprops completion-extra-properties)
             (field-end
              (save-excursion
                (forward-char
                 (cdr (completion-boundaries (buffer-substring start (point))
                                             ctable
                                             cpred
                                             (buffer-substring (point) end))))
                (point)))
             (field-char (and (< field-end end) (char-after field-end)))
             (base-position (list (+ start base-size) field-end))
             (all-md (completion--metadata (buffer-substring-no-properties
                                            start (point))
                                           base-size md
                                           ctable
                                           cpred))
             (ann-fun (completion-metadata-get all-md 'annotation-function))
             (aff-fun (completion-metadata-get all-md 'affixation-function))
             (sort-fun (completion-metadata-get all-md 'display-sort-function))
             (group-fun (completion-metadata-get all-md 'group-function))
             (mainbuf (current-buffer))
             (current-candidate-and-offset
              (when-let* ((buffer (get-buffer "*Completions*"))
                          (window (get-buffer-window buffer 0)))
                (with-current-buffer buffer
                  (when-let* ((cand (completion-list-candidate-at-point
                                     (window-point window))))
                    (cons (car cand) (- (point) (cadr cand)))))))
             ;; If the *Completions* buffer is shown in a new
             ;; window, mark it as softly-dedicated, so bury-buffer in
             ;; minibuffer-hide-completions will know whether to
             ;; delete the window or not.
             (display-buffer-mark-dedicated 'soft))
        (with-current-buffer-window
          "*Completions*"
          ;; This is a copy of `display-buffer-fallback-action'
          ;; where `display-buffer-use-some-window' is replaced
          ;; with `display-buffer-at-bottom'.
          `((display-buffer--maybe-same-window
             display-buffer-reuse-window
             display-buffer--maybe-pop-up-frame
             ;; Use `display-buffer-below-selected' for inline completions,
             ;; but not in the minibuffer (e.g. in `eval-expression')
             ;; for which `display-buffer-at-bottom' is used.
             ,(if (eq (selected-window) (minibuffer-window))
                  'display-buffer-at-bottom
                'display-buffer-below-selected))
            (window-height . completions--fit-window-to-buffer)
            ,(when temp-buffer-resize-mode
               '(preserve-size . (nil . t)))
            (body-function
             . ,#'(lambda (window)
                    (with-current-buffer mainbuf
                      (when (or completion-auto-deselect completion-eager-update)
                        (add-hook 'after-change-functions #'completions--after-change nil t))
                      ;; Remove the base-size tail because `sort' requires a properly
                      ;; nil-terminated list.
                      (when last (setcdr last nil))

                      ;; Sort first using the `display-sort-function'.
                      ;; FIXME: This function is for the output of
                      ;; all-completions, not
                      ;; completion-all-completions.  Often it's the
                      ;; same, but not always.
                      (setq completions (if sort-fun
                                            (funcall sort-fun completions)
                                          (pcase completions-sort
                                            ('nil completions)
                                            ('alphabetical (minibuffer-sort-alphabetically completions))
                                            ('historical (minibuffer-sort-by-history completions))
                                            (_ (funcall completions-sort completions)))))

                      ;; After sorting, group the candidates using the
                      ;; `group-function'.
                      (when group-fun
                        (setq completions
                              (minibuffer--group-by
                               group-fun
                               (pcase completions-group-sort
                                 ('nil #'identity)
                                 ('alphabetical
                                  (lambda (groups)
                                    (sort groups
                                          (lambda (x y)
                                            (string< (car x) (car y))))))
                                 (_ completions-group-sort))
                               completions)))

                      (cond
                       (aff-fun
                        (setq completions
                              (funcall aff-fun completions)))
                       (ann-fun
                        (setq completions
                              (mapcar (lambda (s)
                                        (let ((ann (funcall ann-fun s)))
                                          (if ann (list s ann) s)))
                                      completions))))

                      (with-current-buffer standard-output
                        (setq-local completion-base-position base-position)
                        (setq-local completion-list-insert-choice-function
                               (lambda (start end choice)
                                 (unless (or (zerop (length prefix))
                                             (equal prefix
                                                    (buffer-substring-no-properties
                                                     (max (point-min)
                                                          (- start (length prefix)))
                                                     start)))
                                   (message "*Completions* out of date"))
                                 (when (> (point) end)
                                   ;; Completion suffix has changed, have to adapt.
                                   (setq end (+ end
                                                (cdr (completion-boundaries
                                                      (concat prefix choice) ctable cpred
                                                      (buffer-substring end (point))))))
                                   ;; Stopped before some field boundary.
                                   (when (> (point) end)
                                     (setq field-char (char-after end))))
                                 (when (and field-char
                                            (= (aref choice (1- (length choice)))
                                               field-char))
                                   (setq end (1+ end)))
                                 ;; Tried to use a marker to track buffer changes
                                 ;; but that clashed with another existing marker.
                                 (decf (nth 1 base-position)
                                          (- end start (length choice)))
                                 ;; FIXME: Use `md' to do quoting&terminator here.
                                 (completion--replace start (min end (point-max)) choice)
                                 (let* ((minibuffer-completion-table ctable)
                                        (minibuffer-completion-predicate cpred)
                                        (completion-extra-properties cprops)
                                        (result (concat prefix choice))
                                        (bounds (completion-boundaries
                                                 result ctable cpred "")))
                                   ;; If the completion introduces a new field, then
                                   ;; completion is not finished.
                                   (completion--done result
                                                     (if (eq (car bounds) (length result))
                                                         'exact 'finished))))))

                      (display-completion-list completions nil group-fun)
                      (when current-candidate-and-offset
                        (with-current-buffer standard-output
                          (when-let* ((match (text-property-search-forward
                                              'completion--string (car current-candidate-and-offset) t)))
                            (goto-char (prop-match-beginning match))
                            ;; Preserve the exact offset for the sake of
                            ;; `choose-completion-deselect-if-after'.
                            (forward-char (cdr current-candidate-and-offset))
                            (set-window-point window (point)))))))))
          nil)))
    nil))

(defun minibuffer-hide-completions ()
  "Get rid of an out-of-date *Completions* buffer."
  ;; FIXME: We could/should use minibuffer-scroll-window here, but it
  ;; can also point to the minibuffer-parent-window, so it's a bit tricky.
  (interactive)
  (when-let* ((win (get-buffer-window "*Completions*" 0)))
    (with-selected-window win
      ;; Move point off any completions, so we don't move point there
      ;; again the next time `minibuffer-completion-help' is called.
      (goto-char (point-min))
      (bury-buffer))))

(defun exit-minibuffer ()
  "Terminate this minibuffer argument."
  (interactive)
  (when (minibufferp)
    (when (not (minibuffer-innermost-command-loop-p))
      (error "%s" "Not in most nested command loop"))
    (when (not (innermost-minibuffer-p))
      (error "%s" "Not in most nested minibuffer")))
  ;; If the command that uses this has made modifications in the minibuffer,
  ;; we don't want them to cause deactivation of the mark in the original
  ;; buffer.
  ;; A better solution would be to make deactivate-mark buffer-local
  ;; (or to turn it into a list of buffers, ...), but in the mean time,
  ;; this should do the trick in most cases.
  (setq deactivate-mark nil)
  (throw 'exit nil))

(defun minibuffer-restore-windows ()
  "Restore some windows on exit from minibuffer.
When `read-minibuffer-restore-windows' is nil, then this function
added to `minibuffer-exit-hook' will remove at least the window
that displays the \"*Completions*\" buffer."
  (unless read-minibuffer-restore-windows
    (minibuffer-hide-completions)))

(add-hook 'minibuffer-exit-hook 'minibuffer-restore-windows)

(defun minibuffer-quit-recursive-edit (&optional levels)
  "Quit the command that requested this recursive edit or minibuffer input.
Do so without terminating keyboard macro recording or execution.
LEVELS specifies the number of nested recursive edits to quit.
If nil, it defaults to 1."
  (unless levels
    (setq levels 1))
  (if (> levels 1)
      ;; See Info node `(elisp)Recursive Editing' for an explanation
      ;; of throwing a function to `exit'.
      (throw 'exit (lambda () (minibuffer-quit-recursive-edit (1- levels))))
    (throw 'exit (lambda () (signal 'minibuffer-quit nil)))))

(defun self-insert-and-exit ()
  "Terminate minibuffer input."
  (interactive)
  (if (characterp last-command-event)
      (call-interactively 'self-insert-command)
    (ding))
  (exit-minibuffer))

(defvar completion-in-region-functions nil
  "Wrapper hook around `completion--in-region'.
\(See `with-wrapper-hook' for details about wrapper hooks.)")
(make-obsolete-variable 'completion-in-region-functions
                        'completion-in-region-function "24.4")

(defvar completion-in-region-function #'completion--in-region
  "Function to perform the job of `completion-in-region'.
The function is called with 4 arguments: START END COLLECTION PREDICATE.
The arguments and expected return value are as specified for
`completion-in-region'.")

(defvar completion-in-region--data nil)

(defvar completion-in-region-mode-predicate nil
  "Predicate to tell `completion-in-region-mode' when to exit.
It is called with no argument and should return nil when
`completion-in-region-mode' should exit (and hence pop down
the *Completions* buffer).")

(defvar completion-in-region-mode--predicate nil
  "Copy of the value of `completion-in-region-mode-predicate'.
This holds the value `completion-in-region-mode-predicate' had when
we entered `completion-in-region-mode'.")

(defun completion-in-region (start end collection &optional predicate)
  "Complete the text between START and END using COLLECTION.
Point needs to be somewhere between START and END.
PREDICATE (a function called with no arguments) says when to exit.
This calls the function that `completion-in-region-function' specifies
\(passing the same four arguments that it received) to do the work,
and returns whatever it does.  The return value should be nil
if there was no valid completion, else t."
  (cl-assert (<= start (point) end) t)
  (funcall completion-in-region-function start end collection predicate))

(defcustom read-file-name-completion-ignore-case
  (if (memq system-type '(ms-dos windows-nt darwin cygwin))
      t nil)
  "Non-nil means when reading a file name completion ignores case."
  :type 'boolean
  :version "22.1")

(defun completion--in-region (start end collection &optional predicate)
  "Default function to use for `completion-in-region-function'.
Its arguments and return value are as specified for `completion-in-region'.
Also respects the obsolete wrapper hook `completion-in-region-functions'.
\(See `with-wrapper-hook' for details about wrapper hooks.)"
  (subr--with-wrapper-hook-no-warnings
      ;; FIXME: Maybe we should use this hook to provide a "display
      ;; completions" operation as well.
      completion-in-region-functions (start end collection predicate)
    (let ((minibuffer-completion-table collection)
          (minibuffer-completion-predicate predicate))
      ;; HACK: if the text we are completing is already in a field, we
      ;; want the completion field to take priority (e.g. Bug#6830).
      (when completion-in-region-mode-predicate
        (setq completion-in-region--data
	      `(,(if (markerp start) start (copy-marker start))
                ,(copy-marker end t) ,collection ,predicate))
        (completion-in-region-mode 1))
      (completion--in-region-1 start end))))

(defvar-keymap completion-in-region-mode-map
  :doc "Keymap activated during `completion-in-region'."
  ;; FIXME: Only works if completion-in-region-mode was activated via
  ;; completion-at-point called directly.
  "M-?" #'completion-help-at-point
  "TAB" #'completion-at-point
  "M-<up>"   #'minibuffer-previous-completion
  "M-<down>" #'minibuffer-next-completion
  "M-RET"    #'minibuffer-choose-completion)

;; It is difficult to know when to exit completion-in-region-mode (i.e. hide
;; the *Completions*).  Here's how previous packages did it:
;; - lisp-mode: never.
;; - comint: only do it if you hit SPC at the right time.
;; - pcomplete: pop it down on SPC or after some time-delay.
;; - semantic: use a post-command-hook check similar to this one.
(defun completion-in-region--postch ()
  (or unread-command-events ;Don't pop down the completions in the middle of
                            ;mouse-drag-region/mouse-set-point.
      (and completion-in-region--data
           (and (eq (marker-buffer (nth 0 completion-in-region--data))
                    (current-buffer))
                (>= (point) (nth 0 completion-in-region--data))
                (<= (point)
                    (save-excursion
                      (goto-char (nth 1 completion-in-region--data))
                      (line-end-position)))
		(funcall completion-in-region-mode--predicate)))
      (completion-in-region-mode -1)))

;; (defalias 'completion-in-region--prech 'completion-in-region--postch)

(defvar completion-in-region-mode nil)  ;Explicit defvar, i.s.o defcustom.

(define-minor-mode completion-in-region-mode
  "Transient minor mode used during `completion-in-region'."
  :global t
  :group 'minibuffer
  ;; Prevent definition of a custom-variable since it makes no sense to
  ;; customize this variable.
  :variable completion-in-region-mode
  ;; (remove-hook 'pre-command-hook #'completion-in-region--prech)
  (remove-hook 'post-command-hook #'completion-in-region--postch)
  (setq minor-mode-overriding-map-alist
        (delq (assq 'completion-in-region-mode minor-mode-overriding-map-alist)
              minor-mode-overriding-map-alist))
  (if (null completion-in-region-mode)
      (progn
        (setq completion-in-region--data nil)
        (unless (equal "*Completions*" (buffer-name (window-buffer)))
          (minibuffer-hide-completions)))
    ;; (add-hook 'pre-command-hook #'completion-in-region--prech)
    (cl-assert completion-in-region-mode-predicate)
    (setq completion-in-region-mode--predicate
	  completion-in-region-mode-predicate)
    (setq-local minibuffer-completion-auto-choose nil)
    (add-hook 'post-command-hook #'completion-in-region--postch)
    (let* ((keymap completion-in-region-mode-map)
           (keymap (if minibuffer-visible-completions
                       (make-composed-keymap
                        (list minibuffer-visible-completions-map
                              keymap))
                     keymap)))
      (push `(completion-in-region-mode . ,keymap)
            minor-mode-overriding-map-alist))))

;; Define-minor-mode added our keymap to minor-mode-map-alist, but we want it
;; on minor-mode-overriding-map-alist instead.
(setq minor-mode-map-alist
      (delq (assq 'completion-in-region-mode minor-mode-map-alist)
            minor-mode-map-alist))

(defvar completion-at-point-functions '(tags-completion-at-point-function)
  "Special hook to find the completion table for the entity at point.
Each function on this hook is called in turn without any argument and
should return either nil, meaning it is not applicable at point,
or a function of no arguments to perform completion (discouraged),
or a list of the form (START END COLLECTION . PROPS), where:
 START and END delimit the entity to complete and should include point,
 COLLECTION is the completion table to use to complete the entity, and
 PROPS is a property list for additional information.
Currently supported properties are all the properties that can appear in
`completion-extra-properties' plus:
 `:predicate'	a predicate that completion candidates need to satisfy.
 `:exclusive'	value of `no' means that if the completion table fails to
   match the text at point, then instead of reporting a completion
   failure, the completion should try the next completion function.
As is the case with most hooks, the functions are responsible for
preserving things like point and current buffer.

NOTE: These functions should be cheap to run since they're sometimes
run from `post-command-hook'; and they should ideally only choose
which kind of completion table to use, and not pre-filter it based
on the current text between START and END (e.g., they should not
obey `completion-styles').")

(defvar completion--capf-misbehave-funs nil
  "List of functions found on `completion-at-point-functions' that misbehave.
These are functions that neither return completion data nor a completion
function but instead perform completion right away.")
(defvar completion--capf-safe-funs nil
  "List of well-behaved functions found on `completion-at-point-functions'.
These are functions which return proper completion data rather than
a completion function or god knows what else.")

(defun completion--capf-wrapper (fun which)
  ;; FIXME: The safe/misbehave handling assumes that a given function will
  ;; always return the same kind of data, but this breaks down with functions
  ;; like comint-completion-at-point or mh-letter-completion-at-point, which
  ;; could be sometimes safe and sometimes misbehaving (and sometimes neither).
  (if (pcase which
        ('all t)
        ('safe (member fun completion--capf-safe-funs))
        ('optimist (not (member fun completion--capf-misbehave-funs))))
      (let ((res (funcall fun)))
        (cond
         ((and (consp res) (not (functionp res)))
          (unless (member fun completion--capf-safe-funs)
            (push fun completion--capf-safe-funs))
          (and (eq 'no (plist-get (nthcdr 3 res) :exclusive))
               ;; FIXME: Here we'd need to decide whether there are
               ;; valid completions against the current text.  But this depends
               ;; on the actual completion UI (e.g. with the default completion
               ;; it depends on completion-style) ;-(
               ;; We approximate this result by checking whether prefix
               ;; completion might work, which means that non-prefix completion
               ;; will not work (or not right) for completion functions that
               ;; are non-exclusive.
               (null (try-completion (buffer-substring-no-properties
                                      (car res) (point))
                                     (nth 2 res)
                                     (plist-get (nthcdr 3 res) :predicate)))
               (setq res nil)))
         ((not (or (listp res) (functionp res)))
          (unless (member fun completion--capf-misbehave-funs)
            (message
             "Completion function %S uses a deprecated calling convention" fun)
            (push fun completion--capf-misbehave-funs))))
        (if res (cons fun res)))))

(defun completion-at-point ()
  "Perform completion on the text around point.
The completion method is determined by `completion-at-point-functions'."
  (interactive)
  (let ((res (run-hook-wrapped 'completion-at-point-functions
                               #'completion--capf-wrapper 'all)))
    (pcase res
      (`(,_ . ,(and (pred functionp) f)) (funcall f))
      (`(,hookfun . (,start ,end ,collection . ,plist))
       (unless (markerp start) (setq start (copy-marker start)))
       (let* ((completion-extra-properties plist)
              (completion-in-region-mode-predicate
               (lambda ()
                 ;; We're still in the same completion field.
                 (let ((newstart (car-safe (funcall hookfun))))
                   (and newstart (= newstart start))))))
         (completion-in-region start end collection
                               (plist-get plist :predicate))))
      ;; Maybe completion already happened and the function returned t.
      (_
       (when (cdr res)
         (message "Warning: %S failed to return valid completion data!"
                  (car res)))
       (cdr res)))))

(defun completion-help-at-point (&optional only-if-eager)
  "Display the completions on the text around point.
The completion method is determined by `completion-at-point-functions'."
  (interactive)
  (let ((res (run-hook-wrapped 'completion-at-point-functions
                               ;; Ignore misbehaving functions.
                               #'completion--capf-wrapper 'optimist)))
    (pcase res
      (`(,_ . ,(and (pred functionp) f))
       (message "Don't know how to show completions for %S" f))
      (`(,hookfun . (,start ,end ,collection . ,plist))
       (unless (markerp start) (setq start (copy-marker start)))
       (let* ((minibuffer-completion-table collection)
              (minibuffer-completion-predicate (plist-get plist :predicate))
              (completion-extra-properties plist)
              (completion-in-region-mode-predicate
               (lambda ()
                 ;; We're still in the same completion field.
                 (let ((newstart (car-safe (funcall hookfun))))
                   (and newstart (= newstart start))))))
         ;; FIXME: We should somehow (ab)use completion-in-region-function or
         ;; introduce a corresponding hook (plus another for word-completion,
         ;; and another for force-completion, maybe?).
         (setq completion-in-region--data
               `(,start ,(copy-marker end t) ,collection
                        ,(plist-get plist :predicate)))
         (completion-in-region-mode 1)
         (when (or (not only-if-eager) (completion--eager-update-p start))
           (minibuffer-completion-help start end))))
      (`(,hookfun . ,_)
       ;; The hook function already performed completion :-(
       ;; Not much we can do at this point.
       (message "%s already performed completion!" hookfun)
       nil)
      (_ (message "Nothing to complete at point")))))

;;; Key bindings.

(let ((map minibuffer-local-map))
  (define-key map "\C-g" 'abort-minibuffers)
  (define-key map "\M-<" 'minibuffer-beginning-of-buffer)

  ;; Put RET last so that it is shown in doc strings in preference to
  ;; C-j, when using the \\[exit-minibuffer] notation.
  (define-key map "\n" 'exit-minibuffer)
  (define-key map "\r" 'exit-minibuffer))

(defvar-keymap minibuffer-local-completion-map
  :doc "Local keymap for minibuffer input with completion."
  :parent minibuffer-local-map
  "TAB"       #'minibuffer-complete
  "<backtab>" #'minibuffer-complete
  ;; M-TAB is already abused for many other purposes, so we should find
  ;; another binding for it.
  ;; "M-TAB"  #'minibuffer-force-complete
  "SPC"       #'minibuffer-complete-word
  "?"         #'minibuffer-completion-help
  "<prior>"   #'switch-to-completions
  "M-v"       #'switch-to-completions
  "M-g M-c"   #'switch-to-completions
  "M-<up>"    #'minibuffer-previous-completion
  "M-<down>"  #'minibuffer-next-completion
  "M-RET"     #'minibuffer-choose-completion)

(defvar-keymap minibuffer-local-must-match-map
  :doc "Local keymap for minibuffer input with completion, for exact match."
  :parent minibuffer-local-completion-map
  "RET" #'minibuffer-complete-and-exit
  "C-j" #'minibuffer-complete-and-exit)

(defvar-keymap minibuffer-local-filename-completion-map
  :doc "Local keymap for minibuffer input with completion for filenames.
Gets combined either with `minibuffer-local-completion-map' or
with `minibuffer-local-must-match-map'."
  "SPC" nil)

(defvar-keymap minibuffer-local-ns-map
  :doc "Local keymap for the minibuffer when spaces are not allowed."
  :parent minibuffer-local-map
  "SPC" #'exit-minibuffer
  "TAB" #'exit-minibuffer
  "?"   #'self-insert-and-exit)

(defun read-no-blanks-input (prompt &optional initial inherit-input-method)
  "Read and return a string from the terminal, not allowing blanks.
Prompt with PROMPT.  Whitespace terminates the input.  If INITIAL is
non-nil, it should be a string, which is used as initial input, with
point positioned at the end, so that SPACE will accept the input.
\(Actually, INITIAL can also be a cons of a string and an integer.
Such values are treated as in `read-from-minibuffer', but are normally
not useful in this function.)

Third arg INHERIT-INPUT-METHOD, if non-nil, means the minibuffer inherits
the current input method and the setting of `enable-multibyte-characters'.

If `inhibit-interaction' is non-nil, this function will signal an
`inhibited-interaction' error."
  (read-from-minibuffer prompt initial minibuffer-local-ns-map
		        nil 'minibuffer-history nil inherit-input-method))

;;; Major modes for the minibuffer

(defvar-keymap minibuffer-inactive-mode-map
  :doc "Keymap for use in the minibuffer when it is not active.
The non-mouse bindings in this keymap can only be used in minibuffer-only
frames, since the minibuffer can normally not be selected when it is
not active."
  :full t
  :suppress t
  "e" #'find-file-other-frame
  "f" #'find-file-other-frame
  "b" #'switch-to-buffer-other-frame
  "i" #'info
  "m" #'mail
  "n" #'make-frame
  "<mouse-1>"      #'view-echo-area-messages
  ;; So the global down-mouse-1 binding doesn't clutter the execution of the
  ;; above mouse-1 binding.
  "<down-mouse-1>" #'ignore)

(define-derived-mode minibuffer-inactive-mode nil "InactiveMinibuffer"
  ;; Note: this major mode is called from minibuf.c.
  "Major mode to use in the minibuffer when it is not active.
This is only used when the minibuffer area has no active minibuffer.

Note that the minibuffer may change to this mode more often than
you might expect.  For instance, typing \\`M-x' may change the
buffer to this mode, then to a different mode, and then back
again to this mode upon exit.  Code running from
`minibuffer-inactive-mode-hook' has to be prepared to run
multiple times per minibuffer invocation.  Also see
`minibuffer-exit-hook'.")

(defvaralias 'minibuffer-mode-map 'minibuffer-local-map)

(define-derived-mode minibuffer-mode nil "Minibuffer"
  "Major mode used for active minibuffers.

For customizing this mode, it is better to use
`minibuffer-setup-hook' and `minibuffer-exit-hook' rather than
the mode hook of this mode."
  :syntax-table nil
  :interactive nil
  ;; Enable text conversion, but always make sure `RET' does
  ;; something.
  (setq text-conversion-style 'action)
  (when minibuffer-visible-completions
    (setq-local minibuffer-completion-auto-choose nil)))

(defcustom minibuffer-visible-completions nil
  "Whether candidates shown in *Completions* can be navigated from minibuffer.
When non-nil, if the *Completions* buffer is displayed in a window,
you can use the arrow keys in the minibuffer to move the cursor in
the window showing the *Completions* buffer.  Typing `RET' selects
the highlighted completion candidate.
If the *Completions* buffer is not displayed on the screen, or this
variable is nil, the arrow keys move point in the minibuffer as usual,
and `RET' accepts the input typed into the minibuffer."
  :type 'boolean
  :version "30.1")

(defvar minibuffer-visible-completions--always-bind nil
  "If non-nil, force the `minibuffer-visible-completions' bindings on.")

(defun minibuffer-visible-completions--filter (cmd)
  "Return CMD if `minibuffer-visible-completions' bindings should be active."
  (if minibuffer-visible-completions--always-bind
      cmd
    (when-let* ((window (get-buffer-window "*Completions*" 0)))
      (when (and (eq (buffer-local-value 'completion-reference-buffer
                                         (window-buffer window))
                     (window-buffer (active-minibuffer-window)))
                 (if (eq cmd #'minibuffer-choose-completion-or-exit)
                     (with-current-buffer (window-buffer window)
                       (get-text-property (point) 'completion--string))
                   t))
        cmd))))

(defun minibuffer-visible-completions--bind (binding)
  "Use BINDING when completions are visible.
Return an item that is enabled only when a window
displaying the *Completions* buffer exists."
  `(menu-item
    "" ,binding
    :filter ,#'minibuffer-visible-completions--filter))

(defvar-keymap minibuffer-visible-completions-map
  :doc "Local keymap for minibuffer input with visible completions."
  "<left>"  (minibuffer-visible-completions--bind #'minibuffer-previous-completion)
  "<right>" (minibuffer-visible-completions--bind #'minibuffer-next-completion)
  "<up>"    (minibuffer-visible-completions--bind #'minibuffer-previous-line-completion)
  "<down>"  (minibuffer-visible-completions--bind #'minibuffer-next-line-completion)
  "RET"     (minibuffer-visible-completions--bind #'minibuffer-choose-completion-or-exit)
  "C-g"     (minibuffer-visible-completions--bind #'minibuffer-hide-completions))

;;; Completion tables.

(defun minibuffer--double-dollars (str)
  ;; Reuse the actual "$" from the string to preserve any text-property it
  ;; might have, such as `face'.
  (replace-regexp-in-string "\\$" (lambda (dollar) (concat dollar dollar))
                            str))

(defun minibuffer-maybe-quote-filename (filename)
  "Protect FILENAME from `substitute-in-file-name', as needed.
Useful to give the user default values that won't be substituted."
  (if (and (not (file-name-quoted-p filename))
           (file-name-absolute-p filename)
           (string-match-p (if (memq system-type '(windows-nt ms-dos))
                               "[/\\]~" "/~")
                           (file-local-name filename)))
      (file-name-quote filename)
    (minibuffer--double-dollars filename)))

(defun completion--make-envvar-table ()
  (mapcar (lambda (enventry)
            (substring enventry 0 (string-search "=" enventry)))
          process-environment))

(defconst completion--embedded-envvar-re
  ;; We can't reuse env--substitute-vars-regexp because we need to match only
  ;; potentially-unfinished envvars at end of string.
  (concat "\\(?:^\\|[^$]\\(?:\\$\\$\\)*\\)"
          "\\$\\([[:alnum:]_]*\\|{\\([^}]*\\)\\)\\'"))

(defun completion--embedded-envvar-table (string _pred action)
  "Completion table for envvars embedded in a string.
The envvar syntax (and escaping) rules followed by this table are the
same as `substitute-in-file-name'."
  ;; We ignore `pred', because the predicates passed to us via
  ;; read-file-name-internal are not 100% correct and fail here:
  ;; e.g. we get predicates like file-directory-p there, whereas the filename
  ;; completed needs to be passed through substitute-in-file-name before it
  ;; can be passed to file-directory-p.
  (when (string-match completion--embedded-envvar-re string)
    (let* ((beg (or (match-beginning 2) (match-beginning 1)))
           (table (completion--make-envvar-table))
           (prefix (substring string 0 beg)))
      (cond
       ((eq action 'lambda)
        ;; This table is expected to be used in conjunction with some
        ;; other table that provides the "main" completion.  Let the
        ;; other table handle the test-completion case.
        nil)
       ((or (eq (car-safe action) 'boundaries) (eq action 'metadata))
        ;; Only return boundaries/metadata if there's something to complete,
        ;; since otherwise when we're used in
        ;; completion-table-in-turn, we could return boundaries and
        ;; let some subsequent table return a list of completions.
        ;; FIXME: Maybe it should rather be fixed in
        ;; completion-table-in-turn instead, but it's difficult to
        ;; do it efficiently there.
        (when (try-completion (substring string beg) table nil)
          ;; Compute the boundaries of the subfield to which this
          ;; completion applies.
          (if (eq action 'metadata)
              '(metadata (category . environment-variable))
            (let ((suffix (cdr action)))
              `(boundaries
                ,(or (match-beginning 2) (match-beginning 1))
                . ,(when (string-match "[^[:alnum:]_]" suffix)
                     (match-beginning 0)))))))
       (t
        (if (eq (aref string (1- beg)) ?{)
            (setq table (apply-partially #'completion-table-with-terminator
                                         "}" table)))
        ;; Even if file-name completion is case-insensitive, we want
        ;; envvar completion to be case-sensitive.
        (let ((completion-ignore-case nil))
          (completion-table-with-context
           prefix table (substring string beg) nil action)))))))

(defun completion-file-name-table (string pred action)
  "Completion table for file names."
  (condition-case nil
      (cond
       ((eq action 'metadata) '(metadata (category . file)))
       ((string-match-p "\\`~[^/\\]*\\'" string)
        (completion-table-with-context "~"
                                       (mapcar (lambda (u) (concat u "/"))
                                               (system-users))
                                       (substring string 1)
                                       pred action))
       ((eq (car-safe action) 'boundaries)
        (let ((start (length (file-name-directory string)))
              (end (string-search "/" (cdr action))))
          `(boundaries
            ;; if `string' is "C:" in w32, (file-name-directory string)
            ;; returns "C:/", so `start' is 3 rather than 2.
            ;; Not quite sure what is The Right Fix, but clipping it
            ;; back to 2 will work for this particular case.  We'll
            ;; see if we can come up with a better fix when we bump
            ;; into more such problematic cases.
            ,(min start (length string)) . ,end)))

       ((eq action 'lambda)
        (if (zerop (length string))
            nil          ;Not sure why it's here, but it probably doesn't harm.
          (funcall (or pred 'file-exists-p) string)))

       (t
        (let* ((name (file-name-nondirectory string))
               (specdir (file-name-directory string))
               (realdir (or specdir default-directory)))

          (cond
           ((null action)
            (let ((comp (file-name-completion name realdir pred)))
              (if (stringp comp)
                  (concat specdir comp)
                comp)))

           ((eq action t)
            (let ((all (file-name-all-completions name realdir)))

              ;; Check the predicate, if necessary.
              (unless (memq pred '(nil file-exists-p))
                (let ((comp ())
                      (pred
                       (if (eq pred 'file-directory-p)
                           ;; Brute-force speed up for directory checking:
                           ;; Discard strings which don't end in a slash.
                           (lambda (s)
                             (let ((len (length s)))
                               (and (> len 0) (eq (aref s (1- len)) ?/))))
                         ;; Must do it the hard (and slow) way.
                         pred)))
                  (let ((default-directory (expand-file-name realdir)))
                    (dolist (tem all)
                      (if (funcall pred tem) (push tem comp))))
                  (setq all (nreverse comp))))

              all))))))
    (file-error nil)))               ;PCM often calls with invalid directories.

(defun completion--sifn-requote (upos qstr)
  ;; We're looking for (the largest) `qpos' such that:
  ;; (equal (substring (substitute-in-file-name qstr) 0 upos)
  ;;        (substitute-in-file-name (substring qstr 0 qpos)))
  ;; Big problem here: we have to reverse engineer substitute-in-file-name to
  ;; find the position corresponding to UPOS in QSTR, but
  ;; substitute-in-file-name can do anything, depending on file-name-handlers.
  ;; substitute-in-file-name does the following kind of things:
  ;; - expand env-var references.
  ;; - turn backslashes into slashes.
  ;; - truncate some prefix of the input.
  ;; - rewrite some prefix.
  ;; Some of these operations are written in external libraries and we'd rather
  ;; not hard code any assumptions here about what they actually do.  IOW, we
  ;; want to treat substitute-in-file-name as a black box, as much as possible.
  ;; Kind of like in rfn-eshadow-update-overlay, only worse.
  ;; Example of things we need to handle:
  ;; - Tramp (substitute-in-file-name "/foo:~/bar//baz") => "/scpc:foo:/baz".
  ;; - Cygwin (substitute-in-file-name "C:\bin") => "/usr/bin"
  ;;          (substitute-in-file-name "C:\") => "/"
  ;;          (substitute-in-file-name "C:\bi") => "/bi"
  (let* ((ustr (substitute-in-file-name qstr))
         (uprefix (substring ustr 0 upos))
         qprefix)
    (if (eq upos (length ustr))
        ;; Easy and common case.  This not only speed things up in a very
        ;; common case but it also avoids problems in some cases (bug#53053).
        (cons (length qstr) #'minibuffer-maybe-quote-filename)
      ;; Main assumption: nothing after qpos should affect the text before upos,
      ;; so we can work our way backward from the end of qstr, one character
      ;; at a time.
      ;; Second assumption: If qpos is far from the end this can be a bit slow,
      ;; so we speed it up by doing a first loop that skips a word at a time.
      ;; This word-sized loop is careful not to cut in the middle of env-vars.
      (while (let ((boundary (string-match "\\(\\$+{?\\)?\\w+\\W*\\'" qstr)))
               (and boundary
                    ;; Try and make sure we keep the largest `qpos' (bug#72176).
                    (not (string-match-p "/[/~]" qstr boundary))
                    (progn
                      (setq qprefix (substring qstr 0 boundary))
                      (string-prefix-p uprefix
                                       (substitute-in-file-name qprefix)))))
        (setq qstr qprefix))
      (let ((qpos (length qstr)))
        (while (and (> qpos 0)
                    (string-prefix-p uprefix
                                     (substitute-in-file-name
                                      (substring qstr 0 (1- qpos)))))
          (setq qpos (1- qpos)))
        (cons qpos #'minibuffer-maybe-quote-filename)))))

(defun completion--sifn-boundaries (string table pred suffix)
  "Return completion boundaries on file name STRING.

Runs `substitute-in-file-name' on STRING first, but returns completion
boundaries for the original string."
  ;; We want to compute the start boundary on the result of
  ;; `substitute-in-file-name' (since that's what we use for actual completion),
  ;; and then transform that into an offset in STRING instead.  We can't do this
  ;; if we expand environment variables, so double the $s to prevent that.
  (let* ((doubled-string (replace-regexp-in-string "\\$" "$$" string t t))
         ;; sifn will change $$ back into $, so SIFNED is mostly the
         ;; same as STRING, with some text deleted.
         (sifned (substitute-in-file-name doubled-string))
         (bounds (completion-boundaries sifned table pred suffix))
         (sifned-start (car bounds))
         ;; Adjust SIFNED-START to be an offset in STRING instead of in SIFNED.
         (string-start (+ (- sifned-start (length sifned)) (length string))))
    ;; The text within the boundaries should be identical.
    (cl-assert
     (eq t (compare-strings sifned sifned-start nil string string-start nil))
     t)
    ;; No special processing happens on SUFFIX and the end boundary.
    (cons string-start (cdr bounds))))

(defun completion--file-name-table (orig pred action)
  "Internal subroutine for `read-file-name'.  Do not call this.
This is a completion table for file names, like `completion-file-name-table'
except that it passes the file name through `substitute-in-file-name'."
  (let ((table #'completion-file-name-table))
    (if (eq (car-safe action) 'boundaries)
        (cons 'boundaries (completion--sifn-boundaries orig table pred (cdr action)))
      (let* ((sifned (substitute-in-file-name orig))
             (orig-start (car (completion--sifn-boundaries orig table pred "")))
             (sifned-start (car (completion-boundaries sifned table pred "")))
             (orig-in-bounds (substring orig orig-start))
             (sifned-in-bounds (substring sifned sifned-start))
             (only-need-double-dollars
              ;; If true, sifn only un-doubled $s in ORIG, so we can fix a
              ;; completion to match ORIG by just doubling $s again.  This
              ;; preserves more text from the completion, behaving better with
              ;; non-nil `completion-ignore-case'.
              (string-equal orig-in-bounds (minibuffer--double-dollars sifned-in-bounds)))
             (result
              (let ((completion-regexp-list
                     ;; Regexps are matched against the real file names after
                     ;; expansion, so regexps containing $ won't work.  Drop
                     ;; them; we'll return more completions, but callers need to
                     ;; handle that anyway.
                     (seq-remove (lambda (regexp) (string-search "$" regexp))
                                 completion-regexp-list)))
                (complete-with-action action table sifned pred))))
        (cond
         ((null action)                 ; try-completion
          (if (stringp result)
              ;; Extract the newly added text, quote any dollar signs, and
              ;; append it to ORIG.
              (if only-need-double-dollars
                  (concat (substring orig nil orig-start)
                          (minibuffer--double-dollars (substring result sifned-start)))
                (let ((new-text (substring result (length sifned))))
                  (concat orig (minibuffer--double-dollars new-text))))
            result))
         ((eq action t)                 ; all-completions
          (mapcar
           (if only-need-double-dollars
               #'minibuffer--double-dollars
             ;; Extract the newly added text, quote any dollar signs, and append
             ;; it to the part of ORIG inside the completion boundaries.
             (lambda (compl)
               (let ((new-text (substring compl (length sifned-in-bounds))))
                 (concat orig-in-bounds (minibuffer--double-dollars new-text)))))
           result))
         (t result))))))

(defalias 'read-file-name-internal
  (completion-table-in-turn #'completion--embedded-envvar-table
                            #'completion--file-name-table)
  "Internal subroutine for `read-file-name'.  Do not call this.")

(defvar read-file-name-function #'read-file-name-default
  "The function called by `read-file-name' to do its work.
It should accept the same arguments as `read-file-name'.")

(defcustom insert-default-directory t
  "Non-nil means when reading a filename start with default dir in minibuffer.

When the initial minibuffer contents show a name of a file or a directory,
typing RETURN without editing the initial contents is equivalent to typing
the default file name.

If this variable is non-nil, the minibuffer contents are always
initially non-empty, and typing RETURN without editing will fetch the
default name, if one is provided.  Note however that this default name
is not necessarily the same as initial contents inserted in the minibuffer,
if the initial contents is just the default directory.

If this variable is nil, the minibuffer often starts out empty.  In
that case you may have to explicitly fetch the next history element to
request the default name; typing RETURN without editing will leave
the minibuffer empty.

For some commands, exiting with an empty minibuffer has a special meaning,
such as making the current buffer visit no file in the case of
`set-visited-file-name'."
  :type 'boolean)

(defcustom minibuffer-beginning-of-buffer-movement nil
  "Control how the \\<minibuffer-local-map>\\[minibuffer-beginning-of-buffer] \
command in the minibuffer behaves.
If non-nil, the command will go to the end of the prompt (if
point is after the end of the prompt).  If nil, it will behave
like the `beginning-of-buffer' command."
  :version "27.1"
  :type 'boolean)

;; Not always defined, but only called if next-read-file-uses-dialog-p says so.
(declare-function x-file-dialog "xfns.c"
                  (prompt dir &optional default-filename mustmatch only-dir-p))

(defun read-file-name--defaults (&optional dir initial)
  (let ((default
	  (cond
	   ;; With non-nil `initial', use `dir' as the first default.
	   ;; Essentially, this mean reversing the normal order of the
	   ;; current directory name and the current file name, i.e.
	   ;; 1. with normal file reading:
	   ;; 1.1. initial input is the current directory
	   ;; 1.2. the first default is the current file name
	   ;; 2. with non-nil `initial' (e.g. for `find-alternate-file'):
	   ;; 2.2. initial input is the current file name
	   ;; 2.1. the first default is the current directory
	   (initial (abbreviate-file-name dir))
	   ;; In file buffers, try to get the current file name
	   (buffer-file-name
	    (abbreviate-file-name buffer-file-name))))
	(file-name-at-point
	 (run-hook-with-args-until-success 'file-name-at-point-functions)))
    (when file-name-at-point
      (setq default (delete-dups
		     (delete "" (delq nil (list file-name-at-point default))))))
    ;; Append new defaults to the end of existing `minibuffer-default'.
    (append
     (if (listp minibuffer-default) minibuffer-default (list minibuffer-default))
     (if (listp default) default (list default)))))

(defun read-file-name (prompt &optional dir default-filename mustmatch initial predicate)
  "Read a file name, prompting with PROMPT and completing in directory DIR.
Return the file name as a string.
The return value is not expanded---you must call `expand-file-name'
yourself.

DIR is the directory to use for completing relative file names.
It should be an absolute directory name, or nil (which means the
current buffer's value of `default-directory').

DEFAULT-FILENAME specifies the default file name to return if the
user exits the minibuffer with the same non-empty string inserted
by this function.  If DEFAULT-FILENAME is a string, that serves
as the default.  If DEFAULT-FILENAME is a list of strings, the
first string is the default.  If DEFAULT-FILENAME is omitted or
nil, then if INITIAL is non-nil, the default is DIR combined with
INITIAL; otherwise, if the current buffer is visiting a file,
that file serves as the default; otherwise, the default is simply
the string inserted into the minibuffer.

If the user exits with an empty minibuffer, return an empty
string.  (This happens only if the user erases the pre-inserted
contents, or if `insert-default-directory' is nil.)

Fourth arg MUSTMATCH can take the following values:
- nil means that the user can exit with any input.
- t means that the user is not allowed to exit unless
  the input is (or completes to) an existing file.
- `confirm' means that the user can exit with any input, but she needs
  to confirm her choice if the input is not an existing file.
- `confirm-after-completion' means that the user can exit with any
  input, but she needs to confirm her choice if she called
  `minibuffer-complete' right before `minibuffer-complete-and-exit'
  and the input is not an existing file.
- a function, which will be called with a single argument, the
  input unquoted by `substitute-in-file-name', which see.  If the
  function returns a non-nil value, the minibuffer is exited with
  that argument as the value.
- anything else behaves like t except that typing RET does not exit if
  it does non-null completion.

Fifth arg INITIAL specifies text to start with.  It will be
interpreted as the trailing part of DEFAULT-FILENAME, so using a
full file name for INITIAL will usually lead to surprising
results.

Sixth arg PREDICATE, if non-nil, should be a function of one
argument; then a file name is considered an acceptable completion
alternative only if PREDICATE returns non-nil with the file name
as its argument.

If this command was invoked with the mouse, use a graphical file
dialog if `use-dialog-box' is non-nil, and the window system or X
toolkit in use provides a file dialog box, and DIR is not a
remote file.  For graphical file dialogs, any of the special values
of MUSTMATCH `confirm' and `confirm-after-completion' are
treated as equivalent to nil.  Some graphical file dialogs respect
a MUSTMATCH value of t, and some do not (or it only has a cosmetic
effect, and does not actually prevent the user from entering a
non-existent file).

See also `read-file-name-completion-ignore-case'
and `read-file-name-function'."
  ;; If x-gtk-use-old-file-dialog = t (xg_get_file_with_selection),
  ;; then MUSTMATCH is enforced.  But with newer Gtk
  ;; (xg_get_file_with_chooser), it only has a cosmetic effect.
  ;; The user can still type a non-existent file name.
  (funcall (or read-file-name-function #'read-file-name-default)
           prompt dir default-filename mustmatch initial predicate))

(defvar minibuffer-local-filename-syntax
  (let ((table (make-syntax-table))
	(punctuation (car (string-to-syntax "."))))
    ;; Convert all punctuation entries to symbol.
    (map-char-table (lambda (c syntax)
		      (when (eq (car syntax) punctuation)
			(modify-syntax-entry c "_" table)))
		    table)
    (mapc
     (lambda (c)
       (modify-syntax-entry c "." table))
     '(?/ ?: ?\\))
    table)
  "Syntax table used when reading a file name in the minibuffer.")

;; minibuffer-completing-file-name is a variable used internally in minibuf.c
;; to determine whether to use minibuffer-local-filename-completion-map or
;; minibuffer-local-completion-map.  It shouldn't be exported to Elisp.
;; FIXME: Actually, it is also used in rfn-eshadow.el we'd otherwise have to
;; use (eq minibuffer-completion-table #'read-file-name-internal), which is
;; probably even worse.  Maybe We should add some read-file-name-setup-hook
;; instead, but for now, let's keep this non-obsolete.
;;(make-obsolete-variable 'minibuffer-completing-file-name nil "future" 'get)

(defun read-file-name-default (prompt &optional dir default-filename mustmatch initial predicate)
  "Default method for reading file names.
See `read-file-name' for the meaning of the arguments."
  (unless dir (setq dir (or default-directory "~/")))
  (unless (file-name-absolute-p dir) (setq dir (expand-file-name dir)))
  (unless default-filename
    (setq default-filename
          (cond
           ((null initial) buffer-file-name)
           ;; Special-case "" because (expand-file-name "" "/tmp/") returns
           ;; "/tmp" rather than "/tmp/" (bug#39057).
           ((equal "" initial) dir)
           (t (expand-file-name initial dir)))))
  ;; If dir starts with user's homedir, change that to ~.
  (setq dir (abbreviate-file-name dir))
  ;; Likewise for default-filename.
  (if default-filename
      (setq default-filename
	    (if (consp default-filename)
		(mapcar 'abbreviate-file-name default-filename)
	      (abbreviate-file-name default-filename))))
  (let ((insdef (cond
                 ((and insert-default-directory (stringp dir))
                  (if initial
                      (cons (minibuffer-maybe-quote-filename (concat dir initial))
                            (length (minibuffer-maybe-quote-filename dir)))
                    (minibuffer-maybe-quote-filename dir)))
                 (initial (cons (minibuffer-maybe-quote-filename initial) 0)))))

    (let ((ignore-case read-file-name-completion-ignore-case)
          (minibuffer-completing-file-name t)
          (pred (or predicate 'file-exists-p))
          (add-to-history nil)
          (require-match (if (functionp mustmatch)
                             (lambda (input)
                               (funcall mustmatch
                                        ;; User-supplied MUSTMATCH expects an unquoted filename
                                        (substitute-in-file-name input)))
                           mustmatch)))

      (let* ((val
              (if (or (not (next-read-file-uses-dialog-p))
                      ;; Graphical file dialogs can't handle remote
                      ;; files (Bug#99).
                      (file-remote-p dir))
                  ;; We used to pass `dir' to `read-file-name-internal' by
                  ;; abusing the `predicate' argument.  It's better to
                  ;; just use `default-directory', but in order to avoid
                  ;; changing `default-directory' in the current buffer,
                  ;; we don't let-bind it.
                  (let ((dir (file-name-as-directory
                              (expand-file-name dir))))
                    (minibuffer-with-setup-hook
                        (lambda ()
                          (setq default-directory dir)
                          ;; When the first default in `minibuffer-default'
                          ;; duplicates initial input `insdef',
                          ;; reset `minibuffer-default' to nil.
                          (when (equal (or (car-safe insdef) insdef)
                                       (or (car-safe minibuffer-default)
                                           minibuffer-default))
                            (setq minibuffer-default
                                  (cdr-safe minibuffer-default)))
                          (setq-local completion-ignore-case ignore-case)
                          ;; On the first request on `M-n' fill
                          ;; `minibuffer-default' with a list of defaults
                          ;; relevant for file-name reading.
                          (setq-local minibuffer-default-add-function
                               (lambda ()
                                 (with-current-buffer
                                     (window-buffer (minibuffer-selected-window))
				   (read-file-name--defaults dir initial))))
			  (set-syntax-table minibuffer-local-filename-syntax))
                      (completing-read prompt 'read-file-name-internal
                                       pred require-match insdef
                                       'file-name-history default-filename)))
                ;; If DEFAULT-FILENAME not supplied and DIR contains
                ;; a file name, split it.
                (let ((file (file-name-nondirectory dir))
                      ;; When using a dialog, revert to nil and non-nil
                      ;; interpretation of mustmatch. confirm options
                      ;; need to be interpreted as nil, otherwise
                      ;; it is impossible to create new files using
                      ;; dialogs with the default settings.
                      (dialog-mustmatch
                       (not (memq mustmatch
                                  '(nil confirm confirm-after-completion)))))
                  (when (and (not default-filename)
                             (not (zerop (length file))))
                    (setq default-filename file)
                    (setq dir (file-name-directory dir)))
                  (when default-filename
                    (setq default-filename
                          (expand-file-name (if (consp default-filename)
                                                (car default-filename)
                                              default-filename)
                                            dir)))
                  (setq add-to-history t)
                  (x-file-dialog prompt dir default-filename
                                 dialog-mustmatch
                                 (eq predicate 'file-directory-p)))))

             (replace-in-history (eq (car-safe file-name-history) val)))
        ;; If completing-read returned the inserted default string itself
        ;; (rather than a new string with the same contents),
        ;; it has to mean that the user typed RET with the minibuffer empty.
        ;; In that case, we really want to return ""
        ;; so that commands such as set-visited-file-name can distinguish.
        (when (consp default-filename)
          (setq default-filename (car default-filename)))
        (when (eq val default-filename)
          ;; In this case, completing-read has not added an element
          ;; to the history.  Maybe we should.
          (if (not replace-in-history)
              (setq add-to-history t))
          (setq val ""))
        (unless val (error "No file name specified"))

        (if (and default-filename
                 (string-equal val (if (consp insdef) (car insdef) insdef)))
            (setq val default-filename))
        (setq val (substitute-in-file-name val))

        (if replace-in-history
            ;; Replace what Fcompleting_read added to the history
            ;; with what we will actually return.  As an exception,
            ;; if that's the same as the second item in
            ;; file-name-history, it's really a repeat (Bug#4657).
            (let ((val1 (minibuffer-maybe-quote-filename val)))
              (if history-delete-duplicates
                  (setcdr file-name-history
                          (delete val1 (cdr file-name-history))))
              (if (string= val1 (cadr file-name-history))
                  (pop file-name-history)
                (setcar file-name-history val1)))
          (when add-to-history
            (add-to-history 'file-name-history
                            (minibuffer-maybe-quote-filename val))))
	val))))

(defun internal-complete-buffer-except (&optional buffer)
  "Perform completion on all buffers excluding BUFFER.
BUFFER nil or omitted means use the current buffer.
Like `internal-complete-buffer', but removes BUFFER from the completion list."
  (let ((except (if (stringp buffer) buffer (buffer-name buffer))))
    (apply-partially #'completion-table-with-predicate
		     #'internal-complete-buffer
		     (lambda (name)
		       (not (equal (if (consp name) (car name) name) except)))
		     nil)))

;;; Old-style completion, used in Emacs-21 and Emacs-22.

(defun completion-emacs21-try-completion (string table pred _point)
  (let ((completion (try-completion string table pred)))
    (if (stringp completion)
        (cons completion (length completion))
      completion)))

(defun completion-emacs21-all-completions (string table pred _point)
  (completion-hilit-commonality
   (all-completions string table pred)
   (length string)
   (car (completion-boundaries string table pred ""))))

(defun completion-emacs22-try-completion (string table pred point)
  (let ((suffix (substring string point))
        (completion (try-completion (substring string 0 point) table pred)))
    (cond
     ((eq completion t)
      (if (equal "" suffix)
          t
        (cons string point)))
     ((not (stringp completion)) completion)
     (t
      ;; Merge a trailing / in completion with a / after point.
      ;; We used to only do it for word completion, but it seems to make
      ;; sense for all completions.
      ;; Actually, claiming this feature was part of Emacs-22 completion
      ;; is pushing it a bit: it was only done in minibuffer-completion-word,
      ;; which was (by default) not bound during file completion, where such
      ;; slashes are most likely to occur.
      (if (and (not (zerop (length completion)))
               (eq ?/ (aref completion (1- (length completion))))
               (not (zerop (length suffix)))
               (eq ?/ (aref suffix 0)))
          ;; This leaves point after the / .
          (setq suffix (substring suffix 1)))
      (cons (concat completion suffix) (length completion))))))

(defun completion-emacs22-all-completions (string table pred point)
  (let ((beforepoint (substring string 0 point)))
    (completion-hilit-commonality
     (all-completions beforepoint table pred)
     point
     (car (completion-boundaries beforepoint table pred "")))))

;;; ignore-after-point completion style.

(defvar completion-ignore-after-point--force-nil nil
  "When non-nil, the ignore-after-point style always returns nil.")

(defface completions-ignored
  '((t (:inherit shadow)))
  "Face for text which was ignored by the completion style.")

(defun completion-ignore-after-point-try-completion (string table pred point)
  "Run `completion-try-completion' ignoring the part of STRING after POINT.

We add the part of STRING after POINT back to the result."
  (let* ((old-point (next-single-property-change 0 'completion-ignore-after-point-old-point string))
         (point (if old-point (max point old-point) point))
         (prefix (substring string 0 point))
         (suffix (substring string point)))
    (when-let ((completion
                (unless completion-ignore-after-point--force-nil
                  (let ((completion-ignore-after-point--force-nil t))
                    (completion-try-completion prefix table pred point)))))
      ;; Add SUFFIX back to COMPLETION.  However, previous completion styles failed and
      ;; this one succeeded by ignoring SUFFIX.  The success of future completion depends
      ;; on ignoring SUFFIX.  We mostly do that by keeping point right before SUFFIX.
      (if (eq completion t)
          ;; Keep point in the same place, right before SUFFIX.
          (cons string point)
        (let ((newstring (car completion))
              (newpoint (cdr completion)))
          (cond
           ((= (length newstring) newpoint)
            ;; NEWPOINT is already right before SUFFIX.
            (cons (concat newstring suffix) newpoint))
           ((string-empty-p suffix)
            ;; Nothing to ignore
            (cons newstring newpoint))
           ((get-text-property 0 'completion-ignore-after-point-old-point suffix)
            ;; The suffix already has the text property which makes us ignore it.
            (cons (concat newstring suffix) newpoint))
           ((= (aref suffix 0) ? )
            ;; The suffix starts with a space; add the text property so we ignore it.
            (setq-local minibuffer-allow-text-properties t)
            (put-text-property 0 1 'completion-ignore-after-point-old-point t suffix)
            (cons (concat newstring suffix) newpoint))
           (t
            ;; Add a space with the text property.
            (setq-local minibuffer-allow-text-properties t)
            (let ((space (propertize " " 'completion-ignore-after-point-old-point t)))
              (cons (concat newstring space suffix) newpoint)))))))))

(defun completion-ignore-after-point-all-completions (string table pred point)
  "Run `completion-all-completions' ignoring the part of STRING after POINT."
  (let* ((old-point (next-single-property-change 0 'completion-ignore-after-point-old-point string))
         (point (if old-point (max point old-point) point))
         (prefix (substring string 0 point))
         (suffix (substring string point)))
    (when-let ((completions
                (unless completion-ignore-after-point--force-nil
                  (let ((completion-ignore-after-point--force-nil t))
                    (completion-all-completions prefix table pred point)))))
      ;; Add SUFFIX back to some completions.  COMPLETIONS may be an improper
      ;; list (with the base position in its last cdr) so we can't use `mapcar'.
      (let ((tail completions))
        (while (consp tail)
          (let* ((completion (car tail))
                 (bounds (completion-boundaries completion table pred suffix)))
            ;; Include the suffix if this completion is like a directory: it
            ;; leads to new completions.  There's a similar check in
            ;; `choose-completion-string'.
            (when (= (car bounds) (length completion))
              (let ((end-of-real-completion (length completion)))
                (setcar tail (concat completion suffix))
                ;; When chosen, point should go before SUFFIX.
                (put-text-property
                 0 1 'completion-position-after-insert end-of-real-completion
                 (car tail)))))
          (setq tail (cdr tail))))
      completions)))

;;; Basic completion.

(defun completion--merge-suffix (completion point suffix)
  "Merge end of COMPLETION with beginning of SUFFIX.
Simple generalization of the \"merge trailing /\" done in Emacs-22.
Return the new suffix."
  (if (and (not (zerop (length suffix)))
           (string-match "\\(.+\\)\n\\1" (concat completion "\n" suffix)
                         ;; Make sure we don't compress things to less
                         ;; than we started with.
                         point)
           ;; Just make sure we didn't match some other \n.
           (eq (match-end 1) (length completion)))
      (substring suffix (- (match-end 1) (match-beginning 1)))
    ;; Nothing to merge.
    suffix))

(defun completion-basic--pattern (beforepoint afterpoint bounds)
  (list (substring beforepoint (car bounds))
        'point
        (substring afterpoint 0 (cdr bounds))))

(defun completion-basic-try-completion (string table pred point)
  (let* ((beforepoint (substring string 0 point))
         (afterpoint (substring string point))
         (bounds (completion-boundaries beforepoint table pred afterpoint)))
    (if (zerop (cdr bounds))
        ;; `try-completion' may return a subtly different result
        ;; than `all+merge', so try to use it whenever possible.
        (let ((completion (try-completion beforepoint table pred)))
          (if (not (stringp completion))
              completion
            (cons
             (concat completion
                     (completion--merge-suffix completion point afterpoint))
             (length completion))))
      (let* ((suffix (substring afterpoint (cdr bounds)))
             (prefix (substring beforepoint 0 (car bounds)))
             (pattern (completion-pcm--optimize-pattern
                       (completion-basic--pattern
                        beforepoint afterpoint bounds)))
             (all (completion-pcm--all-completions prefix pattern table pred)))
        (if minibuffer-completing-file-name
            (setq all (completion-pcm--filename-try-filter all)))
        (completion-pcm--merge-try pattern all prefix suffix)))))

(defun completion-basic-all-completions (string table pred point)
  (let* ((beforepoint (substring string 0 point))
         (afterpoint (substring string point))
         (bounds (completion-boundaries beforepoint table pred afterpoint))
         ;; (suffix (substring afterpoint (cdr bounds)))
         (prefix (substring beforepoint 0 (car bounds)))
         (pattern (delete
                   "" (list (substring beforepoint (car bounds))
                            'point
                            (substring afterpoint 0 (cdr bounds)))))
         (all (completion-pcm--all-completions prefix pattern table pred)))
    (when all
      (nconc (completion-pcm--hilit-commonality pattern all)
             (car bounds)))))

;;; Partial-completion-mode style completion.

(defvar completion-pcm--delim-wild-regex nil
  "Regular expression matching delimiters controlling the partial-completion.
Typically, this regular expression simply matches a delimiter, meaning
that completion can add something at (match-beginning 0), but if it has
a submatch 1, then completion can add something at (match-end 1).
This is used when the delimiter needs to be of size zero (e.g. the transition
from lowercase to uppercase characters).")

(defun completion-pcm--prepare-delim-re (delims)
  (setq completion-pcm--delim-wild-regex (concat "[" delims "*]")))

(defcustom completion-pcm-word-delimiters "-_./:| "
  "A string of characters treated as word delimiters for completion.
Some arcane rules:
If `]' is in this string, it must come first.
If `^' is in this string, it must not come first.
If `-' is in this string, it must come first or right after `]'.
In other words, if S is this string, then `[S]' must be a valid Emacs regular
expression (not containing character ranges like `a-z')."
  :set (lambda (symbol value)
         (set-default symbol value)
         ;; Refresh other vars.
         (completion-pcm--prepare-delim-re value))
  :initialize 'custom-initialize-reset
  :type 'string)

(defcustom completion-pcm-complete-word-inserts-delimiters nil
  "Treat the SPC or - inserted by `minibuffer-complete-word' as delimiters.
Those chars are treated as delimiters if this variable is non-nil.
I.e. if non-nil, M-x SPC will just insert a \"-\" in the minibuffer, whereas
if nil, it will list all possible commands in *Completions* because none of
the commands start with a \"-\" or a SPC."
  :version "24.1"
  :type 'boolean)

(defun completion-pcm--pattern-trivial-p (pattern)
  (and (stringp (car pattern))
       ;; It can be followed by `point' and "" and still be trivial.
       (let ((trivial t))
	 (dolist (elem (cdr pattern))
	   (unless (member elem '(point ""))
	     (setq trivial nil)))
	 trivial)))

(defcustom completion-pcm-leading-wildcard nil
  "If non-nil, partial-completion behaves as if each word is preceded by wildcard.

If nil (the default), partial-completion requires each word in a
matching completion alternative to have the same beginning as each
\"word\" in the minibuffer text, where \"word\" is determined by
`completion-pcm-word-delimiters'.

If non-nil, partial-completion allows any string of characters to occur
at the beginning of each word in a completion alternative, as if a
wildcard such as \"*\" was present at the beginning of each word.  This
makes partial-completion behave more like the substring completion
style."
  :version "31.1"
  :type 'boolean)

(defun completion-pcm--string->pattern (string &optional point)
  "Split STRING into a pattern.
A pattern is a list where each element is either a string
or a symbol, see `completion-pcm--merge-completions'."
  (if (and point (< point (length string)))
      (let ((prefix (substring string 0 point))
            (suffix (substring string point)))
        (append (completion-pcm--string->pattern prefix)
                '(point)
                (completion-pcm--string->pattern suffix)))
    (let* ((pattern nil)
           (p 0)
           (p0 p)
           (pending nil))

      (while (and (setq p (string-match completion-pcm--delim-wild-regex
                                        string p))
                  (or completion-pcm-complete-word-inserts-delimiters
                      ;; If the char was added by minibuffer-complete-word,
                      ;; then don't treat it as a delimiter, otherwise
                      ;; "M-x SPC" ends up inserting a "-" rather than listing
                      ;; all completions.
                      (not (get-text-property p 'completion-try-word string))))
        ;; Usually, completion-pcm--delim-wild-regex matches a delimiter,
        ;; meaning that something can be added *before* it, but it can also
        ;; match a prefix and postfix, in which case something can be added
        ;; in-between (e.g. match [[:lower:]][[:upper:]]).
        ;; This is determined by the presence of a submatch-1 which delimits
        ;; the prefix.
        (if (match-end 1) (setq p (match-end 1)))
        (unless (= p0 p)
          (if pending (push pending pattern))
          (push (substring string p0 p) pattern))
        (setq pending nil)
        (if (eq (aref string p) ?*)
            (progn
              (push 'star pattern)
              (setq p0 (1+ p)))
          (push 'any pattern)
          (if (match-end 1)
              (setq p0 p)
            (push (substring string p (match-end 0)) pattern)
            ;; `any-delim' is used so that "a-b" also finds "array->beginning".
            (setq pending (if completion-pcm-leading-wildcard 'star 'any-delim))
            (setq p0 (match-end 0))))
        (setq p p0))

      (when (> (length string) p0)
        (if pending (push pending pattern))
        (push (substring string p0) pattern))
      (setq pattern (nreverse pattern))
      (when completion-pcm-leading-wildcard
        (when (stringp (car pattern))
          (push 'star pattern)))
      pattern)))

(defun completion-pcm--optimize-pattern (p)
  ;; Remove empty strings in a separate phase since otherwise a ""
  ;; might prevent some other optimization, as in '(any "" any).
  (setq p (delete "" p))
  (let ((n '()))
    (while p
      (pcase p
        (`(,(or 'any 'any-delim) ,(or 'any 'point) . ,_)
         (setq p (cdr p)))
        ;; This is not just a performance improvement: it turns a
        ;; terminating `point' into an implicit `any', which affects
        ;; the final position of point (because `point' gets turned
        ;; into a non-greedy ".*?" regexp whereas we need it to be
        ;; greedy when it's at the end, see bug#38458).
        (`(point) (setq p nil)) ;Implicit terminating `any'.
        (_ (push (pop p) n))))
    (nreverse n)))

(defun completion-pcm--pattern->regex (pattern &optional group)
  (let ((re
         (concat "\\`"
                 (mapconcat
                  (lambda (x)
                    (cond
                     ((stringp x) (regexp-quote x))
                     (t
                      (let ((re (if (eq x 'any-delim)
                                    (concat completion-pcm--delim-wild-regex "*?")
                                  "[^z-a]*?")))
                        (if (if (consp group) (memq x group) group)
                            (concat "\\(" re "\\)")
                          re)))))
                  pattern
                  ""))))
    ;; Avoid pathological backtracking.
    (while (string-match "\\.\\*\\?\\(?:\\\\[()]\\)*\\(\\.\\*\\?\\)" re)
      (setq re (replace-match "" t t re 1)))
    re))

(defun completion-pcm--pattern-point-idx (pattern)
  "Return index of subgroup corresponding to `point' element of PATTERN.
Return nil if there's no such element."
  (let ((idx nil)
        (i 0))
    (dolist (x pattern)
      (unless (stringp x)
        (incf i)
        (if (eq x 'point) (setq idx i))))
    idx))

(defun completion-pcm--all-completions (prefix pattern table pred)
  "Find all completions for PATTERN in TABLE obeying PRED.
PATTERN is as returned by `completion-pcm--string->pattern'."
  ;; (cl-assert (= (car (completion-boundaries prefix table pred ""))
  ;;            (length prefix)))
  ;; Find an initial list of possible completions.
  (if (completion-pcm--pattern-trivial-p pattern)

      ;; Minibuffer contains no delimiters -- simple case!
      (all-completions (concat prefix (car pattern)) table pred)

    ;; Use all-completions to do an initial cull.  This is a big win,
    ;; since all-completions is written in C!
    (let* (;; Convert search pattern to a standard regular expression.
	   (regex (completion-pcm--pattern->regex pattern))
           (case-fold-search completion-ignore-case)
           (completion-regexp-list (cons regex completion-regexp-list))
	   (compl (all-completions
                   (concat prefix
                           (if (stringp (car pattern)) (car pattern) ""))
		   table pred)))
      (if (not (functionp table))
	  ;; The internal functions already obeyed completion-regexp-list.
	  compl
	(let ((poss ()))
	  (dolist (c compl)
	    (when (string-match-p regex c) (push c poss)))
	  (nreverse poss))))))

(defvar flex-score-match-tightness 3
  "Controls how the `flex' completion style scores its matches.

Value is a positive number.  A number smaller than 1 makes the
scoring formula reward matches scattered along the string, while
a number greater than one make the formula reward matches that
are clumped together.  I.e \"foo\" matches both strings
\"fbarbazoo\" and \"fabrobazo\", which are of equal length, but
only a value greater than one will score the former (which has
one large \"hole\" and a clumped-together \"oo\" match) higher
than the latter (which has two \"holes\" and three
one-letter-long matches).")

(defvar completion-lazy-hilit nil
  "If non-nil, request lazy highlighting of completion candidates.

Lisp programs (a.k.a. \"front ends\") that present completion
candidates may opt to bind this variable to a non-nil value when
calling functions (such as `completion-all-completions') which
produce completion candidates.  This tells the underlying
completion styles that they do not need to fontify (i.e.,
propertize with the `face' property) completion candidates in a
way that highlights the matching parts.  Then it is the front end
which presents the candidates that becomes responsible for this
fontification.  The front end does that by calling the function
`completion-lazy-hilit' on each completion candidate that is to be
displayed to the user.

Note that only some completion styles take advantage of this
variable for optimization purposes.  Other styles will ignore the
hint and fontify eagerly as usual.  It is still safe for a
front end to call `completion-lazy-hilit' in these situations.

To author a completion style that takes advantage of this variable,
see `completion-lazy-hilit-fn' and `completion-pcm--hilit-commonality'.")

(defvar completion-lazy-hilit-fn nil
  "Fontification function set by lazy-highlighting completions styles.
When a given style wants to enable support for `completion-lazy-hilit'
\(which see), that style should set this variable to a function of one
argument.  It will be called with each completion candidate, a string, to
be displayed to the user, and should destructively propertize these
strings with the `face' property.")

(defun completion-lazy-hilit (str)
  "Return a copy of completion candidate STR that is `face'-propertized.
See documentation of the variable `completion-lazy-hilit' for more
details."
  (if (and completion-lazy-hilit completion-lazy-hilit-fn)
      (funcall completion-lazy-hilit-fn (copy-sequence str))
    str))

(defun completion-for-display (str)
  "Return the string that should be displayed for completion candidate STR.

This will be `face'-propertized as appropriate."
  (completion-lazy-hilit (or (get-text-property 0 'completion--unquoted str) str)))

(defun completion--hilit-from-re (string regexp &optional point-idx)
  "Fontify STRING using REGEXP POINT-IDX.
Uses `completions-common-part' and `completions-first-difference'
faces to fontify STRING.
POINT-IDX is the position of point in the presumed \"PCM\" pattern
from which REGEXP was generated."
  (let* ((md (and regexp (string-match regexp string) (cddr (match-data t))))
         (pos (if point-idx (match-beginning point-idx) (match-end 0)))
         (me (and md (match-end 0)))
         (from 0))
    (while md
      (add-face-text-property from (pop md)
                              'completions-common-part nil string)
      (setq from (pop md)))
    (if (and (numberp pos) (> (length string) pos))
        (add-face-text-property
         pos (1+ pos)
         'completions-first-difference
         nil string))
    (unless (or (not me) (= from me))
      (add-face-text-property from me 'completions-common-part nil string))
    string))

(defun completion--flex-score-1 (md-groups match-end len)
  "Compute matching score of completion.
The score lies in the range between 0 and 1, where 1 corresponds to
the full match.
MD-GROUPS is the \"group\"  part of the match data.
MATCH-END is the end of the match.
LEN is the length of the completion string."
  (let* ((from 0)
         ;; To understand how this works, consider these simple
         ;; ascii diagrams showing how the pattern "foo"
         ;; flex-matches "fabrobazo", "fbarbazoo" and
         ;; "barfoobaz":

         ;;      f abr o baz o
         ;;      + --- + --- +

         ;;      f barbaz oo
         ;;      + ------ ++

         ;;      bar foo baz
         ;;          +++

         ;; "+" indicates parts where the pattern matched.  A
         ;; "hole" in the middle of the string is indicated by
         ;; "-".  Note that there are no "holes" near the edges
         ;; of the string.  The completion score is a number
         ;; bound by (0..1] (i.e., larger than (but not equal
         ;; to) zero, and smaller or equal to one): the higher
         ;; the better and only a perfect match (pattern equals
         ;; string) will have score 1.  The formula takes the
         ;; form of a quotient.  For the numerator, we use the
         ;; number of +, i.e. the length of the pattern.  For
         ;; the denominator, it first computes
         ;;
         ;;     hole_i_contrib = 1 + (Li-1)^(1/tightness)
         ;;
         ;; , for each hole "i" of length "Li", where tightness
         ;; is given by `flex-score-match-tightness'.  The
         ;; final value for the denominator is then given by:
         ;;
         ;;    (SUM_across_i(hole_i_contrib) + 1) * len
         ;;
         ;; , where "len" is the string's length.
         (score-numerator 0)
         (score-denominator 0)
         (last-b 0))
    (while (and md-groups (car md-groups))
      (let ((a from)
            (b (pop md-groups)))
        (setq
         score-numerator   (+ score-numerator (- b a)))
        (unless (or (= a last-b)
                    (zerop last-b)
                    (= a len))
          (setq
           score-denominator (+ score-denominator
                                1
                                (expt (- a last-b 1)
                                      (/ 1.0
                                         flex-score-match-tightness)))))
        (setq
         last-b              b))
      (setq from (pop md-groups)))
    ;; If `pattern' doesn't have an explicit trailing any, the
    ;; regex `re' won't produce match data representing the
    ;; region after the match.  We need to account to account
    ;; for that extra bit of match (bug#42149).
    (unless (= from match-end)
      (let ((a from)
            (b match-end))
        (setq
         score-numerator   (+ score-numerator (- b a)))
        (unless (or (= a last-b)
                    (zerop last-b)
                    (= a len))
          (setq
           score-denominator (+ score-denominator
                                1
                                (expt (- a last-b 1)
                                      (/ 1.0
                                         flex-score-match-tightness)))))
        (setq
         last-b              b)))
    (/ score-numerator (* len (1+ score-denominator)) 1.0)))

(defvar completion--flex-score-last-md nil
  "Helper variable for `completion--flex-score'.")

(defun completion--flex-score (str re &optional dont-error)
  "Compute flex score of completion STR based on RE.
If DONT-ERROR, just return nil if RE doesn't match STR."
  (let ((case-fold-search completion-ignore-case))
    (cond ((string-match re str)
           (let* ((match-end (match-end 0))
                  (md (cddr
                       (setq
                        completion--flex-score-last-md
                        (match-data t completion--flex-score-last-md)))))
             (completion--flex-score-1 md match-end (length str))))
          ((not dont-error)
           (error "Internal error: %s does not match %s" re str)))))

(defvar completion-pcm--regexp nil
  "Regexp from PCM pattern in `completion-pcm--hilit-commonality'.")

(defun completion-pcm--hilit-commonality (pattern completions)
  "Show where and how well PATTERN matches COMPLETIONS.
PATTERN, a list of symbols and strings as seen
`completion-pcm--merge-completions', is assumed to match every
string in COMPLETIONS.

If `completion-lazy-hilit' is nil, return a deep copy of
COMPLETIONS where each string is propertized with
`completion-score', a number between 0 and 1, and with faces
`completions-common-part', `completions-first-difference' in the
relevant segments.

Else, if `completion-lazy-hilit' is t, return COMPLETIONS
unchanged, but setup a suitable `completion-lazy-hilit-fn' (which
see) for later lazy highlighting."
  (setq completion-pcm--regexp nil
        completion-lazy-hilit-fn nil)
  (cond
   ((and completions (cl-loop for e in pattern thereis (stringp e)))
    (let* ((re (completion-pcm--pattern->regex pattern 'group))
           (point-idx (completion-pcm--pattern-point-idx pattern)))
      (setq completion-pcm--regexp re)
      (cond (completion-lazy-hilit
             (setq completion-lazy-hilit-fn
                   (lambda (str) (completion--hilit-from-re str re point-idx)))
             completions)
            (t
             (mapcar
              (lambda (str)
                (completion--hilit-from-re (copy-sequence str) re point-idx))
              completions)))))
   (t completions)))

(defun completion-pcm--find-all-completions (string table pred point
                                                    &optional filter)
  "Find all completions for STRING at POINT in TABLE, satisfying PRED.
POINT is a position inside STRING.
FILTER is a function applied to the return value, that can be used, e.g. to
filter out additional entries (because TABLE might not obey PRED)."
  (unless filter (setq filter 'identity))
  (let* ((beforepoint (substring string 0 point))
         (afterpoint (substring string point))
         (bounds (completion-boundaries beforepoint table pred afterpoint))
         (prefix (substring beforepoint 0 (car bounds)))
         (suffix (substring afterpoint (cdr bounds)))
         firsterror)
    (setq string (substring string (car bounds) (+ point (cdr bounds))))
    (let* ((relpoint (- point (car bounds)))
           (pattern (completion-pcm--optimize-pattern
                     (completion-pcm--string->pattern string relpoint)))
           (all (condition-case-unless-debug err
                    (funcall filter
                             (completion-pcm--all-completions
                              prefix pattern table pred))
                  (error (setq firsterror err) nil))))
      (when (and (null all)
                 (> (car bounds) 0)
                 (null (ignore-errors (try-completion prefix table pred))))
        ;; The prefix has no completions at all, so we should try and fix
        ;; that first.
        (pcase-let* ((substring (substring prefix 0 -1))
                     (`(,subpat ,suball ,subprefix ,_subsuffix)
                      (completion-pcm--find-all-completions
                       substring table pred (length substring) filter))
                     (sep (aref prefix (1- (length prefix))))
                     ;; Text that goes between the new submatches and the
                     ;; completion substring.
                     (between nil))
          ;; Eliminate submatches that don't end with the separator.
          (dolist (submatch (prog1 suball (setq suball ())))
            (when (eq sep (aref submatch (1- (length submatch))))
              (push submatch suball)))
          (when suball
            ;; Update the boundaries and corresponding pattern.
            ;; We assume that all submatches result in the same boundaries
            ;; since we wouldn't know how to merge them otherwise anyway.
            ;; FIXME: COMPLETE REWRITE!!!
            (let* ((newbeforepoint
                    (concat subprefix (car suball)
                            (substring string 0 relpoint)))
                   (leftbound (+ (length subprefix) (length (car suball))))
                   (newbounds (completion-boundaries
                               newbeforepoint table pred afterpoint)))
              (unless (or (and (eq (cdr bounds) (cdr newbounds))
                               (eq (car newbounds) leftbound))
                          ;; Refuse new boundaries if they step over
                          ;; the submatch.
                          (< (car newbounds) leftbound))
                ;; The new completed prefix does change the boundaries
                ;; of the completed substring.
                (setq suffix (substring afterpoint (cdr newbounds)))
                (setq string
                      (concat (substring newbeforepoint (car newbounds))
                              (substring afterpoint 0 (cdr newbounds))))
                (setq between (substring newbeforepoint leftbound
                                         (car newbounds)))
                (setq pattern (completion-pcm--optimize-pattern
                               (completion-pcm--string->pattern
                                string
                                (- (length newbeforepoint)
                                   (car newbounds))))))
              (dolist (submatch suball)
                (setq all (nconc
                           (mapcar
                            (lambda (s) (concat submatch between s))
                            (funcall filter
                                     (completion-pcm--all-completions
                                      (concat subprefix submatch between)
                                      pattern table pred)))
                           all)))
              ;; FIXME: This can come in handy for try-completion,
              ;; but isn't right for all-completions, since it lists
              ;; invalid completions.
              ;; (unless all
              ;;   ;; Even though we found expansions in the prefix, none
              ;;   ;; leads to a valid completion.
              ;;   ;; Let's keep the expansions, tho.
              ;;   (dolist (submatch suball)
              ;;     (push (concat submatch between newsubstring) all)))
              ))
          (setq pattern (append subpat (list 'any (string sep))
                                (if between (list between)) pattern))
          (setq prefix subprefix)))
      (if (and (null all) firsterror)
          (signal (car firsterror) (cdr firsterror))
        (list pattern all prefix suffix)))))

(defun completion-pcm-all-completions (string table pred point)
  (pcase-let ((`(,pattern ,all ,prefix ,_suffix)
               (completion-pcm--find-all-completions string table pred point)))
    (when all
      (nconc (completion-pcm--hilit-commonality pattern all)
             (length prefix)))))

(defun completion--common-suffix (strs)
  "Return the common suffix of the strings STRS."
  (nreverse (try-completion "" (mapcar #'reverse strs))))

(defun completion-pcm--merge-completions (strs pattern)
  "Extract the commonality in STRS, with the help of PATTERN.
PATTERN can contain strings and symbols chosen among `star', `any', `point',
and `prefix'.  They all match anything (aka \".*\") but are merged differently:
`any' only grows from the left (when matching \"a1b\" and \"a2b\" it gets
  completed to just \"a\").
`prefix' only grows from the right (when matching \"a1b\" and \"a2b\" it gets
  completed to just \"b\").
`star' grows from both ends and is reified into a \"*\"  (when matching \"a1b\"
  and \"a2b\" it gets completed to \"a*b\").
`point' is like `star' except that it gets reified as the position of point
  instead of being reified as a \"*\" character.
The underlying idea is that we should return a string which still matches
the same set of elements."
  ;; When completing while ignoring case, we want to try and avoid
  ;; completing "fo" to "foO" when completing against "FOO" (bug#4219).
  ;; So we try and make sure that the string we return is all made up
  ;; of text from the completions rather than part from the
  ;; completions and part from the input.
  ;; FIXME: This reduces the problems of inconsistent capitalization
  ;; but it doesn't fully fix it: we may still end up completing
  ;; "fo-ba" to "foo-BAR" or "FOO-bar" when completing against
  ;; '("foo-barr" "FOO-BARD").
  (cond
   ((null (cdr strs)) (list (car strs)))
   (t
    (let ((re (completion-pcm--pattern->regex pattern 'group))
          (ccs ()))                     ;Chopped completions.

      ;; First chop each string into the parts corresponding to each
      ;; non-constant element of `pattern', using regexp-matching.
      (let ((case-fold-search completion-ignore-case))
        (dolist (str strs)
          (unless (string-match re str)
            (error "Internal error: %s doesn't match %s" str re))
          (let ((chopped ())
                (last 0)
                (i 1)
                next)
            (while (setq next (match-end i))
              (push (substring str last next) chopped)
              (setq last next)
              (setq i (1+ i)))
            ;; Add the text corresponding to the implicit trailing `any'.
            (push (substring str last) chopped)
            (push (nreverse chopped) ccs))))

      ;; Then for each of those non-constant elements, extract the
      ;; commonality between them.
      (let ((res ())
            (fixed "")
            ;; Accumulate each stretch of wildcards, and process them as a unit.
            (wildcards ()))
        ;; Make the implicit trailing `any' explicit.
        (dolist (elem (append pattern '(any)))
          (if (stringp elem)
              (progn
                (setq fixed (concat fixed elem))
                (setq wildcards nil))
            (let ((comps ()))
              (push elem wildcards)
              (dolist (cc (prog1 ccs (setq ccs nil)))
                (push (car cc) comps)
                (push (cdr cc) ccs))
              ;; Might improve the likelihood to avoid choosing
              ;; different capitalizations in different parts.
              ;; In practice, it doesn't seem to make any difference.
              (setq ccs (nreverse ccs))
              (let* ((prefix (try-completion fixed comps))
                     (unique (or (and (eq prefix t) (setq prefix fixed))
                                 (and (stringp prefix)
                                      (eq t (try-completion prefix comps))))))
                ;; If there's only one completion, `elem' is not useful
                ;; any more: it can only match the empty string.
                ;; FIXME: in some cases, it may be necessary to turn an
                ;; `any' into a `star' because the surrounding context has
                ;; changed such that string->pattern wouldn't add an `any'
                ;; here any more.
                (if unique
                    ;; If the common prefix is unique, it also is a common
                    ;; suffix, so we should add it for `prefix' elements.
                    (push prefix res)
                  ;; `prefix' only wants to include the fixed part before the
                  ;; wildcard, not the result of growing that fixed part.
                  (when (seq-some (lambda (elem) (eq elem 'prefix)) wildcards)
                    (setq prefix fixed))
                  (push prefix res)
                  ;; Push all the wildcards in this stretch, to preserve `point' and
                  ;; `star' wildcards before ELEM.
                  (setq res (append wildcards res))
                  ;; Extract common suffix additionally to common prefix.
                  ;; Don't do it for `any' since it could lead to a merged
                  ;; completion that doesn't itself match the candidates.
                  (when (and (seq-some (lambda (elem) (memq elem '(star point prefix))) wildcards)
                             ;; If prefix is one of the completions, there's no
                             ;; suffix left to find.
                             (not (assoc-string prefix comps t)))
                    (let ((suffix
                           (completion--common-suffix
                            (if (zerop (length prefix)) comps
                              ;; Ignore the chars in the common prefix, so we
                              ;; don't merge '("abc" "abbc") as "ab*bc".
                              (let ((skip (length prefix)))
                                (mapcar (lambda (str) (substring str skip))
                                        comps))))))
                      (cl-assert (stringp suffix))
                      (unless (equal suffix "")
                        (push suffix res))))
                  ;; We pushed these wildcards on RES, so we're done with them.
                  (setq wildcards nil))
                (setq fixed "")))))
        ;; We return it in reverse order.
        res)))))

(defun completion-pcm--pattern->string (pattern)
  (mapconcat (lambda (x) (cond
                          ((stringp x) x)
                          ((eq x 'star) "*")
                          (t "")))           ;any, point, prefix.
             pattern
             ""))

;; We want to provide the functionality of `try', but we use `all'
;; and then merge it.  In most cases, this works perfectly, but
;; if the completion table doesn't consider the same completions in
;; `try' as in `all', then we have a problem.  The most common such
;; case is for filename completion where completion-ignored-extensions
;; is only obeyed by the `try' code.  We paper over the difference
;; here.  Note that it is not quite right either: if the completion
;; table uses completion-table-in-turn, this filtering may take place
;; too late to correctly fallback from the first to the
;; second alternative.
(defun completion-pcm--filename-try-filter (all)
  "Filter to adjust `all' file completion to the behavior of `try'."
  (when all
    (let ((try ())
          (re (concat "\\(?:\\`\\.\\.?/\\|"
                      (regexp-opt completion-ignored-extensions)
                      "\\)\\'")))
      (dolist (f all)
        (unless (string-match-p re f) (push f try)))
      (or (nreverse try) all))))


(defun completion-pcm--merge-try (pattern all prefix suffix)
  (cond
   ((not (consp all)) all)
   ((and (not (consp (cdr all)))        ;Only one completion.
         ;; Ignore completion-ignore-case here.
         (equal (completion-pcm--pattern->string pattern) (car all)))
    t)
   (t
    (let* ((mergedpat (completion-pcm--merge-completions all pattern))
           ;; `mergedpat' is in reverse order.  Place new point (by
           ;; order of preference) either at the old point, or at
           ;; the last place where there's something to choose, or
           ;; at the very end.
           (pointpat (or (memq 'point mergedpat)
                         (memq 'any   mergedpat)
                         (memq 'star  mergedpat)
                         ;; Not `prefix'.
                         mergedpat))
           ;; New pos from the start.
	   (newpos (length (completion-pcm--pattern->string pointpat)))
           ;; Do it afterwards because it changes `pointpat' by side effect.
           (merged (completion-pcm--pattern->string (nreverse mergedpat))))

      (setq suffix (completion--merge-suffix
                    ;; The second arg should ideally be "the position right
                    ;; after the last char of `merged' that comes from the text
                    ;; to be completed".  But completion-pcm--merge-completions
                    ;; currently doesn't give us that info.  So instead we just
                    ;; use the "last but one" position, which tends to work
                    ;; well in practice since `suffix' always starts
                    ;; with a boundary and we hence mostly/only care about
                    ;; merging this boundary (bug#15419).
                    merged (max 0 (1- (length merged))) suffix))
      (cons (concat prefix merged suffix) (+ newpos (length prefix)))))))

(defun completion-pcm-try-completion (string table pred point)
  (pcase-let ((`(,pattern ,all ,prefix ,suffix)
               (completion-pcm--find-all-completions
                string table pred point
                (if minibuffer-completing-file-name
                    'completion-pcm--filename-try-filter))))
    (completion-pcm--merge-try pattern all prefix suffix)))

;;; Substring completion
;; Mostly derived from the code of `basic' completion.

(defun completion-substring--all-completions
    (string table pred point &optional transform-pattern-fn)
  "Match the presumed substring STRING to the entries in TABLE.
Respect PRED and POINT.  The pattern used is a PCM-style
substring pattern, but it be massaged by TRANSFORM-PATTERN-FN, if
that is non-nil."
  (let* ((beforepoint (substring string 0 point))
         (afterpoint (substring string point))
         (bounds (completion-boundaries beforepoint table pred afterpoint))
         (suffix (substring afterpoint (cdr bounds)))
         (prefix (substring beforepoint 0 (car bounds)))
         (basic-pattern (completion-basic--pattern
                         beforepoint afterpoint bounds))
         (pattern (if (not (stringp (car basic-pattern)))
                      basic-pattern
                    (cons 'prefix basic-pattern)))
         (pattern (completion-pcm--optimize-pattern
                   (if transform-pattern-fn
                       (funcall transform-pattern-fn pattern)
                     pattern)))
         (all (completion-pcm--all-completions prefix pattern table pred)))
    (list all pattern prefix suffix (car bounds))))

(defun completion-substring-try-completion (string table pred point)
  (pcase-let ((`(,all ,pattern ,prefix ,suffix ,_carbounds)
               (completion-substring--all-completions
                string table pred point)))
    (if minibuffer-completing-file-name
        (setq all (completion-pcm--filename-try-filter all)))
    (completion-pcm--merge-try pattern all prefix suffix)))

(defun completion-substring-all-completions (string table pred point)
  (pcase-let ((`(,all ,pattern ,prefix ,_suffix ,_carbounds)
               (completion-substring--all-completions
                string table pred point)))
    (when all
      (nconc (completion-pcm--hilit-commonality pattern all)
             (length prefix)))))

;;; "flex" completion, also known as flx/fuzzy/scatter completion
;; Completes "foo" to "frodo" and "farfromsober"

(defcustom completion-flex-nospace nil
  "Non-nil if `flex' completion rejects spaces in search pattern."
  :version "27.1"
  :type 'boolean)

(put 'flex 'completion--adjust-metadata 'completion--flex-adjust-metadata)

(defun completion--flex-adjust-metadata (metadata)
  "If `flex' is actually doing filtering, adjust sorting."
  (let ((flex-is-filtering-p completion-pcm--regexp)
        (existing-dsf
         (completion-metadata-get metadata 'display-sort-function))
        (existing-csf
         (completion-metadata-get metadata 'cycle-sort-function)))
    (cl-flet
        ((compose-flex-sort-fn (existing-sort-fn)
           (lambda (completions)
             (let* ((sorted (sort
                             (mapcar
                              (lambda (str)
                                (cons
                                 (- (completion--flex-score
                                     (or (get-text-property
                                          0 'completion--unquoted str)
                                         str)
                                     completion-pcm--regexp))
                                 str))
                              (if existing-sort-fn
                                  (funcall existing-sort-fn completions)
                                completions))
                             #'car-less-than-car))
                    (cell sorted))
               ;; Reuse the list
               (while cell
                 (setcar cell (cdar cell))
                 (pop cell))
               sorted))))
      `(metadata
        ,@(and flex-is-filtering-p
               `((display-sort-function . ,(compose-flex-sort-fn existing-dsf))))
        ,@(and flex-is-filtering-p
               `((cycle-sort-function . ,(compose-flex-sort-fn existing-csf))))
        ,@(cdr metadata)))))

(defun completion-flex--make-flex-pattern (pattern)
  "Convert PCM-style PATTERN into PCM-style flex pattern.

This turns
    (prefix \"foo\" point)
into
    (prefix \"f\" any \"o\" any \"o\" any point)
which is at the core of flex logic.  The extra
`any' is optimized away later on."
  (mapcan (lambda (elem)
            (if (stringp elem)
                (mapcan (lambda (char)
                          (list (string char) 'any))
                        elem)
              (list elem)))
          pattern))

(defun completion-flex-try-completion (string table pred point)
  "Try to flex-complete STRING in TABLE given PRED and POINT."
  (unless (and completion-flex-nospace (string-search " " string))
    (pcase-let ((`(,all ,pattern ,prefix ,suffix ,_carbounds)
                 (completion-substring--all-completions
                  string table pred point
                  #'completion-flex--make-flex-pattern)))
      (if minibuffer-completing-file-name
          (setq all (completion-pcm--filename-try-filter all)))
      ;; Try some "merging", meaning add as much as possible to the
      ;; user's pattern without losing any possible matches in `all'.
      ;; i.e this will augment "cfi" to "config" if all candidates
      ;; contain the substring "config".  FIXME: this still won't
      ;; augment "foo" to "froo" when matching "frodo" and
      ;; "farfromsober".
      (completion-pcm--merge-try pattern all prefix suffix))))

(defun completion-flex-all-completions (string table pred point)
  "Get flex-completions of STRING in TABLE, given PRED and POINT."
  (unless (and completion-flex-nospace (string-search " " string))
    (pcase-let ((`(,all ,pattern ,prefix ,_suffix ,_carbounds)
                 (completion-substring--all-completions
                  string table pred point
                  #'completion-flex--make-flex-pattern)))
      (when all
        (nconc (completion-pcm--hilit-commonality pattern all)
               (length prefix))))))

;; Initials completion
;; Complete /ums to /usr/monnier/src or lch to list-command-history.

(defun completion-initials-expand (str table pred)
  (let ((bounds (completion-boundaries str table pred "")))
    (unless (or (zerop (length str))
                ;; Only check within the boundaries, since the
                ;; boundary char (e.g. /) might be in delim-regexp.
                (string-match completion-pcm--delim-wild-regex str
                              (car bounds)))
      (if (zerop (car bounds))
          ;; FIXME: Don't hardcode "-" (bug#17559).
          (mapconcat 'string str "-")
        ;; If there's a boundary, it's trickier.  The main use-case
        ;; we consider here is file-name completion.  We'd like
        ;; to expand ~/eee to ~/e/e/e and /eee to /e/e/e.
        ;; But at the same time, we don't want /usr/share/ae to expand
        ;; to /usr/share/a/e just because we mistyped "ae" for "ar",
        ;; so we probably don't want initials to touch anything that
        ;; looks like /usr/share/foo.  As a heuristic, we just check that
        ;; the text before the boundary char is at most 1 char.
        ;; This allows both ~/eee and /eee and not much more.
        ;; FIXME: It sadly also disallows the use of ~/eee when that's
        ;; embedded within something else (e.g. "(~/eee" in Info node
        ;; completion or "ancestor:/eee" in bzr-revision completion).
        (when (< (car bounds) 3)
          (let ((sep (substring str (1- (car bounds)) (car bounds))))
            ;; FIXME: the above string-match checks the whole string, whereas
            ;; we end up only caring about the after-boundary part.
            (concat (substring str 0 (car bounds))
                    (mapconcat 'string (substring str (car bounds)) sep))))))))

(defun completion-initials-all-completions (string table pred _point)
  (let ((newstr (completion-initials-expand string table pred)))
    (when newstr
      (completion-pcm-all-completions newstr table pred (length newstr)))))

(defun completion-initials-try-completion (string table pred _point)
  (let ((newstr (completion-initials-expand string table pred)))
    (when newstr
      (completion-pcm-try-completion newstr table pred (length newstr)))))

;; Shorthand completion
;;
;; Iff there is a (("x-" . "string-library-")) shorthand setup and
;; string-library-foo is in candidates, complete x-foo to it.

(defun completion-shorthand-try-completion (string table pred point)
  "Try completion with `read-symbol-shorthands' of original buffer."
  (cl-loop with expanded
           for (short . long) in
           (with-current-buffer minibuffer--original-buffer
             read-symbol-shorthands)
           for probe =
           (and (> point (length short))
                (string-prefix-p short string)
                (try-completion (setq expanded
                                      (concat long
                                              (substring
                                               string
                                               (length short))))
                                table pred))
           when probe
           do (message "Shorthand expansion")
           and return (cons expanded (max (length long)
                                          (+ (- point (length short))
                                             (length long))))))

(defun completion-shorthand-all-completions (_string _table _pred _point)
  ;; no-op: For now, we don't want shorthands to list all the possible
  ;; locally active longhands.  For the completion categories where
  ;; this style is active, it could hide other more interesting
  ;; matches from subsequent styles.
  nil)


(defvar completing-read-function #'completing-read-default
  "The function called by `completing-read' to do its work.
It should accept the same arguments as `completing-read'.")

(defun completing-read-default (prompt collection &optional predicate
                                       require-match initial-input
                                       hist def inherit-input-method)
  "Default method for reading from the minibuffer with completion.
See `completing-read' for the meaning of the arguments."

  (when (consp initial-input)
    (setq initial-input
          (cons (car initial-input)
                ;; `completing-read' uses 0-based index while
                ;; `read-from-minibuffer' uses 1-based index.
                (1+ (cdr initial-input)))))

  (let* ((base-keymap (if require-match
                         minibuffer-local-must-match-map
                        minibuffer-local-completion-map))
         (keymap (if (memq minibuffer-completing-file-name '(nil lambda))
                     base-keymap
                   ;; Layer minibuffer-local-filename-completion-map
                   ;; on top of the base map.
                   (make-composed-keymap
                    minibuffer-local-filename-completion-map
                    ;; Set base-keymap as the parent, so that nil bindings
                    ;; in minibuffer-local-filename-completion-map can
                    ;; override bindings in base-keymap.
                    base-keymap)))
         (keymap (if minibuffer-visible-completions
                     (make-composed-keymap
                      (list minibuffer-visible-completions-map
                            keymap))
                   keymap))
         (buffer (current-buffer))
         (c-i-c completion-ignore-case)
         (result
          (minibuffer-with-setup-hook
              (lambda ()
                (setq-local minibuffer-completion-table collection)
                (setq-local minibuffer-completion-predicate predicate)
                ;; FIXME: Remove/rename this var, see the next one.
                (setq-local minibuffer-completion-confirm
                            (unless (eq require-match t) require-match))
                (setq-local minibuffer--require-match require-match)
                (setq-local minibuffer--original-buffer buffer)
                ;; Copy the value from original buffer to the minibuffer.
                (setq-local completion-ignore-case c-i-c)
                ;; Show the completion help eagerly if
                ;; `completion-eager-display' is t or if eager display
                ;; has been requested by the completion table.
                (when completion-eager-display
                  (let* ((md (completion-metadata
                              (buffer-substring-no-properties
                               (minibuffer-prompt-end) (point))
                              collection predicate))
                         (fun (completion-metadata-get md 'eager-display)))
                    (when (or fun (eq completion-eager-display t))
                      (funcall (if (functionp fun)
                                   fun #'minibuffer-completion-help))))))
            (read-from-minibuffer prompt initial-input keymap
                                  nil hist def inherit-input-method))))
    (when (and (equal result "") def)
      (setq result (if (consp def) (car def) def)))
    result))

;; Miscellaneous

(defun minibuffer-insert-file-name-at-point ()
  "Get a file name at point in original buffer and insert it to minibuffer."
  (interactive)
  (let ((file-name-at-point
	 (with-current-buffer (window-buffer (minibuffer-selected-window))
	   (run-hook-with-args-until-success 'file-name-at-point-functions))))
    (when file-name-at-point
      (insert file-name-at-point))))

(defun minibuffer-beginning-of-buffer (&optional arg)
  "Move to the logical beginning of the minibuffer.
This command behaves like `beginning-of-buffer', but if point is
after the end of the prompt, move to the end of the prompt.
Otherwise move to the start of the buffer."
  (declare (interactive-only "use `(goto-char (point-min))' instead."))
  (interactive "^P")
  (or (consp arg)
      (region-active-p)
      (push-mark))
  (goto-char (cond
              ;; We want to go N/10th of the way from the beginning.
              ((and arg (not (consp arg)))
	       (+ (point-min) 1
		  (/ (* (- (point-max) (point-min))
                        (prefix-numeric-value arg))
                     10)))
              ;; Go to the start of the buffer.
              ((or (null minibuffer-beginning-of-buffer-movement)
                   (<= (point) (minibuffer-prompt-end)))
	       (point-min))
              ;; Go to the end of the minibuffer.
              (t
               (minibuffer-prompt-end))))
  (when (and arg (not (consp arg)))
    (forward-line 1)))

(defmacro with-minibuffer-selected-window (&rest body)
  "Execute the forms in BODY from the minibuffer in its original window.
When used in a minibuffer window, select the window selected just before
the minibuffer was activated, and execute the forms."
  (declare (indent 0) (debug t))
  `(let ((window (minibuffer-selected-window)))
     (when window
       (with-selected-window window
         ,@body))))

(defun minibuffer-recenter-top-bottom (&optional arg)
  "Run `recenter-top-bottom' from the minibuffer in its original window."
  (interactive "P")
  (with-minibuffer-selected-window
    (recenter-top-bottom arg)))

(defun minibuffer-scroll-up-command (&optional arg)
  "Run `scroll-up-command' from the minibuffer in its original window."
  (interactive "^P")
  (with-minibuffer-selected-window
    (scroll-up-command arg)))

(defun minibuffer-scroll-down-command (&optional arg)
  "Run `scroll-down-command' from the minibuffer in its original window."
  (interactive "^P")
  (with-minibuffer-selected-window
    (scroll-down-command arg)))

(defun minibuffer-scroll-other-window (&optional arg)
  "Run `scroll-other-window' from the minibuffer in its original window."
  (interactive "P")
  (with-minibuffer-selected-window
    (scroll-other-window arg)))

(defun minibuffer-scroll-other-window-down (&optional arg)
  "Run `scroll-other-window-down' from the minibuffer in its original window."
  (interactive "^P")
  (with-minibuffer-selected-window
    (scroll-other-window-down arg)))

(defmacro with-minibuffer-completions-window (&rest body)
  "Execute the forms in BODY from the minibuffer in its completions window.
When used in a minibuffer window, select the window with completions,
and execute the forms."
  (declare (indent 0) (debug t))
  `(let ((window (or (get-buffer-window "*Completions*" 0)
                     ;; Make sure we have a completions window.
                     (progn (minibuffer-completion-help)
                            (get-buffer-window "*Completions*" 0)))))
     (when window
       (with-selected-window window
         (completion--lazy-insert-strings)
         ,@body))))

(defcustom minibuffer-completion-auto-choose t
  "Non-nil means to automatically insert completions to the minibuffer.
When non-nil, then `minibuffer-next-completion' and
`minibuffer-previous-completion' will insert the completion
selected by these commands to the minibuffer."
  :type 'boolean
  :version "29.1")

(defun minibuffer-next-completion (&optional n vertical)
  "Move to the next item in its completions window from the minibuffer.
When the optional argument VERTICAL is non-nil, move vertically
to the next item on the next line using `next-line-completion'.
Otherwise, move to the next item horizontally using `next-completion'.
When `minibuffer-completion-auto-choose' is non-nil, then also
insert the selected completion candidate to the minibuffer."
  (interactive "p")
  (let ((auto-choose minibuffer-completion-auto-choose))
    (with-minibuffer-completions-window
      (if vertical
          (next-line-completion (or n 1))
        (next-completion (or n 1)))
      (when auto-choose
        (let ((completion-auto-deselect nil))
          (choose-completion nil t t))))))

(defun minibuffer-previous-completion (&optional n)
  "Move to the previous item in its completions window from the minibuffer.
When `minibuffer-completion-auto-choose' is non-nil, then also
insert the selected completion candidate to the minibuffer."
  (interactive "p")
  (minibuffer-next-completion (- (or n 1))))

(defun minibuffer-next-line-completion (&optional n)
  "Move to the next completion line from the minibuffer.
This means to move to the completion candidate on the next line
in the *Completions* buffer while point stays in the minibuffer.
When `minibuffer-completion-auto-choose' is non-nil, then also
insert the selected completion candidate to the minibuffer."
  (interactive "p")
  (minibuffer-next-completion (or n 1) t))

(defun minibuffer-previous-line-completion (&optional n)
  "Move to the previous completion line from the minibuffer.
This means to move to the completion candidate on the previous line
in the *Completions* buffer while point stays in the minibuffer.
When `minibuffer-completion-auto-choose' is non-nil, then also
insert the selected completion candidate to the minibuffer."
  (interactive "p")
  (minibuffer-next-completion (- (or n 1)) t))

(defun minibuffer-choose-completion (&optional no-exit no-quit)
  "Run `choose-completion' from the minibuffer in its completions window.
With prefix argument NO-EXIT, insert the completion candidate at point to
the minibuffer, but don't exit the minibuffer.  When the prefix argument
is not provided, then whether to exit the minibuffer depends on the value
of `completion-no-auto-exit'.
If NO-QUIT is non-nil, insert the completion candidate at point to the
minibuffer, but don't quit the completions window."
  (interactive "P")
  (with-minibuffer-completions-window
    (choose-completion nil no-exit no-quit)))

(defun minibuffer-choose-completion-or-exit (&optional no-exit no-quit)
  "Choose the completion from the minibuffer or exit the minibuffer.
When `minibuffer-choose-completion' can't find a completion candidate
in the completions window, then exit the minibuffer using its present
contents."
  (interactive "P")
  (condition-case nil
      (let ((choose-completion-deselect-if-after t))
        (minibuffer-choose-completion no-exit no-quit))
    (error (minibuffer-complete-and-exit))))

(defun minibuffer-complete-history ()
  "Complete as far as possible using the minibuffer history.
Like `minibuffer-complete' but completes using the history of minibuffer
inputs for the prompting command, instead of the default completion table."
  (interactive)
  (let* ((history (symbol-value minibuffer-history-variable))
         (completions
          (if (listp history)
              ;; Support e.g. `C-x ESC ESC TAB' as
              ;; a replacement of `list-command-history'
              (mapcar (lambda (h)
                        (if (stringp h) h (format "%S" h)))
                      history)
            (user-error "No history available"))))
    ;; FIXME: Can we make it work for CRM?
    (let ((completion-in-region-mode-predicate
           (lambda () (get-buffer-window "*Completions*" 0))))
      (completion-in-region
       (minibuffer--completion-prompt-end) (point-max)
       (completion-table-with-metadata
        completions '((display-sort-function . identity)
                      (cycle-sort-function . identity)))))))

(defun minibuffer-complete-defaults ()
  "Complete as far as possible using the minibuffer defaults.
Like `minibuffer-complete' but completes using the default items
provided by the prompting command, instead of the completion table."
  (interactive)
  (when (and (not minibuffer-default-add-done)
             (functionp minibuffer-default-add-function))
    (setq minibuffer-default-add-done t
          minibuffer-default (funcall minibuffer-default-add-function)))
  (let ((completions (ensure-list minibuffer-default))
        (completion-in-region-mode-predicate
         (lambda () (get-buffer-window "*Completions*" 0))))
    (completion-in-region
     (minibuffer--completion-prompt-end) (point-max)
     (completion-table-with-metadata
      completions '((display-sort-function . identity)
                    (cycle-sort-function . identity))))))

(define-key minibuffer-local-map [?\C-x up] 'minibuffer-complete-history)
(define-key minibuffer-local-map [?\C-x down] 'minibuffer-complete-defaults)

(defcustom minibuffer-default-prompt-format " (default %s)"
  "Format string used to output \"default\" values.
When prompting for input, there will often be a default value,
leading to prompts like \"Number of articles (default 50): \".
The \"default\" part of that prompt is controlled by this
variable, and can be set to, for instance, \" [%s]\" if you want
a shorter displayed prompt, or \"\", if you don't want to display
the default at all.

This variable is used by the `format-prompt' function."
  :version "28.1"
  :type 'string)

(defun format-prompt (prompt default &rest format-args)
  "Format PROMPT with DEFAULT according to `minibuffer-default-prompt-format'.
If FORMAT-ARGS is nil, PROMPT is used as a plain string.  If
FORMAT-ARGS is non-nil, PROMPT is used as a format control
string, and FORMAT-ARGS are the arguments to be substituted into
it.  See `format' for details.

Both PROMPT and `minibuffer-default-prompt-format' are run
through `substitute-command-keys' (which see).  In particular,
this means that single quotes may be displayed by equivalent
characters, according to the capabilities of the terminal.

If DEFAULT is a list, the first element is used as the default.
If not, the element is used as is.

If DEFAULT is nil or an empty string, no \"default value\" string
is included in the return value."
  (concat
   (if (null format-args)
       (substitute-command-keys prompt)
     (apply #'format (substitute-command-keys prompt) format-args))
   (and default
        (or (not (stringp default))
            (length> default 0))
        (format (substitute-command-keys minibuffer-default-prompt-format)
                (if (consp default)
                    (car default)
                  default)))
   ": "))


;;; On screen keyboard support.
;; Try to display the on screen keyboard whenever entering the
;; mini-buffer, and hide it whenever leaving.

(defvar minibuffer-on-screen-keyboard-timer nil
  "Timer run upon exiting the minibuffer.
It will hide the on screen keyboard when necessary.")

(defvar minibuffer-on-screen-keyboard-displayed nil
  "Whether or not the on-screen keyboard has been displayed.
Set inside `minibuffer-setup-on-screen-keyboard'.")

(defun minibuffer-setup-on-screen-keyboard ()
  "Maybe display the on-screen keyboard in the current frame.
Display the on-screen keyboard in the current frame if the
last device to have sent an input event is not a keyboard.
This is run upon minibuffer setup."
  ;; Don't hide the on screen keyboard later on.
  (when minibuffer-on-screen-keyboard-timer
    (cancel-timer minibuffer-on-screen-keyboard-timer)
    (setq minibuffer-on-screen-keyboard-timer nil))
  (setq minibuffer-on-screen-keyboard-displayed nil)
  (when (and (framep last-event-frame)
             (not (memq (device-class last-event-frame
                                      last-event-device)
                        '(keyboard core-keyboard))))
    (setq minibuffer-on-screen-keyboard-displayed
          (frame-toggle-on-screen-keyboard (selected-frame) nil))))

(defun minibuffer-exit-on-screen-keyboard ()
  "Hide the on-screen keyboard if it was displayed.
Hide the on-screen keyboard in a timer set to run in 0.1 seconds.
It will be canceled if the minibuffer is displayed again within
that timeframe.

Do not hide the on screen keyboard inside a recursive edit.
Likewise, do not hide the on screen keyboard if point in the
window that will be selected after exiting the minibuffer is not
on read-only text.

The latter is implemented in `touch-screen.el'."
  (unless (or (not minibuffer-on-screen-keyboard-displayed)
              (> (recursion-depth) 1))
    (when minibuffer-on-screen-keyboard-timer
      (cancel-timer minibuffer-on-screen-keyboard-timer))
    (setq minibuffer-on-screen-keyboard-timer
          (run-with-timer 0.1 nil #'frame-toggle-on-screen-keyboard
                          (selected-frame) t))))

(add-hook 'minibuffer-setup-hook #'minibuffer-setup-on-screen-keyboard)
(add-hook 'minibuffer-exit-hook #'minibuffer-exit-on-screen-keyboard)

(defvar minibuffer-regexp-mode)

(defun minibuffer--regexp-propertize ()
  "In current minibuffer propertize parens and slashes in regexps.
Put punctuation `syntax-table' property on selected paren and
backslash characters in current buffer to make `show-paren-mode'
and `blink-matching-paren' more user-friendly."
  (let (in-char-alt-p)
    (save-excursion
      (with-silent-modifications
        (remove-text-properties (point-min) (point-max) '(syntax-table nil))
        (goto-char (minibuffer-prompt-end))
        (while (re-search-forward
                (rx (| (group "\\\\")
                       (: "\\" (| (group (in "(){}"))
                                  (group "[")
                                  (group "]")))
                       (group "[:" (+ (in "A-Za-z")) ":]")
                       (group "[")
                       (group "]")
                       (group (in "(){}"))))
	        (point-max) 'noerror)
	  (cond
           ((match-beginning 1))                ; \\, skip
           ((match-beginning 2)			; \( \) \{ \}
            (if in-char-alt-p
	        ;; Within character alternative, set symbol syntax for
	        ;; paren only.
                (put-text-property (1- (point)) (point) 'syntax-table '(3))
	      ;; Not within character alternative, set symbol syntax for
	      ;; backslash only.
              (put-text-property (- (point) 2) (1- (point)) 'syntax-table '(3))))
	   ((match-beginning 3)			; \[
            (if in-char-alt-p
                (progn
	          ;; Set symbol syntax for backslash.
                  (put-text-property (- (point) 2) (1- (point)) 'syntax-table '(3))
                  ;; Re-read bracket we might be before a character class.
                  (backward-char))
	      ;; Set symbol syntax for bracket.
	      (put-text-property (1- (point)) (point) 'syntax-table '(3))))
	   ((match-beginning 4)			; \]
            (if in-char-alt-p
                (progn
                  ;; Within character alternative, set symbol syntax for
	          ;; backslash, exit alternative.
                  (put-text-property (- (point) 2) (1- (point)) 'syntax-table '(3))
	          (setq in-char-alt-p nil))
	      ;; Not within character alternative, set symbol syntax for
	      ;; bracket.
	      (put-text-property (1- (point)) (point) 'syntax-table '(3))))
	   ((match-beginning 5))         ; POSIX character class, skip
	   ((match-beginning 6)          ; [
	    (if in-char-alt-p
	        ;; Within character alternative, set symbol syntax.
	        (put-text-property (1- (point)) (point) 'syntax-table '(3))
	      ;; Start new character alternative.
	      (setq in-char-alt-p t)
              ;; Looking for immediately following non-closing ].
	      (when (looking-at "\\^?\\]")
	        ;; Non-special right bracket, set symbol syntax.
	        (goto-char (match-end 0))
	        (put-text-property (1- (point)) (point) 'syntax-table '(3)))))
	   ((match-beginning 7)			; ]
            (if in-char-alt-p
                (setq in-char-alt-p nil)
              ;; The only warning we can emit before RET.
	      (message "Not in character alternative")))
	   ((match-beginning 8)                 ; (){}
	    ;; Plain parenthesis or brace, set symbol syntax.
	    (put-text-property (1- (point)) (point) 'syntax-table '(3)))))))))

;; The following variable is set by 'minibuffer--regexp-before-change'.
;; If non-nil, either 'minibuffer--regexp-post-self-insert' or
;; 'minibuffer--regexp-after-change', whichever comes next, will
;; propertize the minibuffer via 'minibuffer--regexp-propertize' and
;; reset this variable to nil, avoiding to propertize the buffer twice.
(defvar-local minibuffer--regexp-primed nil
  "Non-nil when minibuffer contents change.")

(defun minibuffer--regexp-before-change (_a _b)
  "`minibuffer-regexp-mode' function on `before-change-functions'."
  (setq minibuffer--regexp-primed t))

(defun minibuffer--regexp-after-change (_a _b _c)
  "`minibuffer-regexp-mode' function on `after-change-functions'."
  (when minibuffer--regexp-primed
    (setq minibuffer--regexp-primed nil)
    (minibuffer--regexp-propertize)))

(defun minibuffer--regexp-post-self-insert ()
  "`minibuffer-regexp-mode' function on `post-self-insert-hook'."
  (when minibuffer--regexp-primed
    (setq minibuffer--regexp-primed nil)
    (minibuffer--regexp-propertize)))

(defvar minibuffer--regexp-prompt-regexp
  "\\(?:Posix search\\|RE search\\|Search for regexp\\|Query replace regexp\\)"
  "Regular expression compiled from `minibuffer-regexp-prompts'.")

(defcustom minibuffer-regexp-prompts
  '("Posix search" "RE search" "Search for regexp" "Query replace regexp")
  "List of regular expressions that trigger `minibuffer-regexp-mode' features.
The features of `minibuffer-regexp-mode' will be activated in a minibuffer
interaction if and only if a prompt matching some regexp in this list
appears at the beginning of the minibuffer."
  :type '(repeat (string :tag "Prompt"))
  :set (lambda (sym val)
	 (set-default sym val)
         (when val
           (setq minibuffer--regexp-prompt-regexp
                 (concat "\\(?:" (mapconcat 'regexp-quote val "\\|") "\\)"))))
  :version "30.1")

(defun minibuffer--regexp-setup ()
  "Function to activate`minibuffer-regexp-mode' in current buffer.
Run by `minibuffer-setup-hook'."
  (if (and minibuffer-regexp-mode
           (save-excursion
             (goto-char (point-min))
             (looking-at minibuffer--regexp-prompt-regexp)))
      (progn
        (setq-local parse-sexp-lookup-properties t)
        (add-hook 'before-change-functions #'minibuffer--regexp-before-change nil t)
        (add-hook 'after-change-functions #'minibuffer--regexp-after-change nil t)
        (add-hook 'post-self-insert-hook #'minibuffer--regexp-post-self-insert nil t))
    ;; Make sure.
    (minibuffer--regexp-exit)))

(defun minibuffer--regexp-exit ()
  "Function to deactivate `minibuffer-regexp-mode' in current buffer.
Run by `minibuffer-exit-hook'."
  (with-silent-modifications
    (remove-text-properties (point-min) (point-max) '(syntax-table nil)))
  (setq-local parse-sexp-lookup-properties nil)
  (remove-hook 'before-change-functions #'minibuffer--regexp-before-change t)
  (remove-hook 'after-change-functions #'minibuffer--regexp-after-change t)
  (remove-hook 'post-self-insert-hook #'minibuffer--regexp-post-self-insert t))

(define-minor-mode minibuffer-regexp-mode
  "Minor mode for editing regular expressions in the minibuffer.
Highlight parens via `show-paren-mode' and `blink-matching-paren'
in a user-friendly way, avoid reporting alleged paren mismatches
and make sexp navigation more intuitive.

The list of prompts activating this mode in specific minibuffer
interactions is customizable via `minibuffer-regexp-prompts'."
  :global t
  :initialize 'custom-initialize-delay
  :init-value t
  (if minibuffer-regexp-mode
      (progn
        (add-hook 'minibuffer-setup-hook #'minibuffer--regexp-setup)
        (add-hook 'minibuffer-exit-hook #'minibuffer--regexp-exit))
    ;; Clean up - why is Vminibuffer_list not available in Lisp?
    (dolist (buffer (buffer-list))
      (when (and (minibufferp)
                 parse-sexp-lookup-properties
                 (with-current-buffer buffer
                   (save-excursion
                     (goto-char (point-min))
                     (looking-at minibuffer--regexp-prompt-regexp))))
        (with-current-buffer buffer
          (with-silent-modifications
            (remove-text-properties
             (point-min) (point-max) '(syntax-table nil)))
          (setq-local parse-sexp-lookup-properties t))))
    (remove-hook 'minibuffer-setup-hook #'minibuffer--regexp-setup)
    (remove-hook 'minibuffer-exit-hook #'minibuffer--regexp-exit)))

(provide 'minibuffer)

;;; minibuffer.el ends here
