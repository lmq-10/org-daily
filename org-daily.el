;;; org-daily.el --- Plan and remember your days with Org mode -*- lexical-binding: t -*-

;; Copyright (C) 2025  Lucas Quintana

;; Author: Lucas Quintana <lmq10@protonmail.com>
;; Maintainer: Lucas Quintana <lmq10@protonmail.com>
;; URL: https://github.com/lmq-10/org-daily
;; Created: 2025-08-03
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1") (org "9.6") (transient "0.8"))

;; This file is not part of GNU Emacs.

;; This file is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the
;; Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This file is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides facilities for maintaining a file where you
;; write stuff about your days (regardless of whether they are in the
;; past, present or future).  You can use this for:
;;
;; - Journaling
;; - Day planning
;; - Reminding you about something
;;
;; And so on.
;;
;; This package uses the `org-datetree' library, which is the standard
;; way of creating date entries in Org mode.  The format is as
;; follows:
;;
;; -------------------------------------------------------------------
;; #+title: My journal
;;
;; * 2025
;; ** 2025-06 June
;; *** 2025-06-20 Tuesday
;; This is an amazing entry!
;; *** 2025-06-21 Saturday
;; This is another amazing entry!
;; -------------------------------------------------------------------
;;
;; You may be thinking this file would grow out of control and it
;; would thus become hard to manage or even slow to edit.  However,
;; Emacs comes with an amazing feature called narrowing, which means
;; focusing only in a specific part of a buffer, hiding everything
;; else.  So, when you jump to a day using `org-daily-jump-to-day',
;; only the entry for that specific day is displayed.  That way, as a
;; nice side effect, you also gain focus!
;;
;; The main point of entry is the `org-daily' command, which invokes a
;; transient from where you can access all the functionality offered
;; by the program.

;;; Code:

(require 'calendar)
(require 'org)
(require 'org-datetree)
(require 'org-element)
(require 'seq)
(require 'time-date)
(require 'transient)

;;;; User variables

(defgroup org-daily nil
  "An Org mode extension for journaling or managing your days in general."
  :tag "Org Daily"
  :group 'org)

(defcustom org-daily-file "~/Documents/journal.org"
  "Path to the single file where all days are stored.

If you plan to use multiple separate files, customize
`org-daily-all-files' instead.

If you intend to reference this variable in Lisp, use the function
`org-daily-file' instead."
  :type 'file
  :group 'org-daily)

(defcustom org-daily-all-files nil
  "List of all files where you plan to use Org Daily features.

Every element should be a cons cell whose `car' is a nickname for the
file (such as \"Journal\") and the `cdr' is the file path.

You can pick one of the files in this list on-demand for operations
performed from `org-daily' transient.

If this variable is not set, the file referenced in variable
`org-daily-file' is assumed to be the only file of interest, and
switching to another file from transient is disabled altogether."
  :type '(repeat (cons (string :tag "Short name") (file :tag "File path"))))

(defcustom org-daily-quick-actions
  '(("New heading" . org-daily-quick-new-heading)
    ("New task" . org-daily-quick-new-todo-heading))
  "List of custom actions for Org Daily.

These actions are offered in `org-daily' transient.  You can pick one of
them, and it will be called in the day you choose.  This allows you to
easily insert headings, tasks, or anything you want.

The `car' of each element is a description for the function (which will
appear in the transient) and the `cdr' is the function itself."
  :type '(repeat (cons (string :tag "Short name") (function :tag "Function")))
  :risky t)

(defcustom org-daily-custom-date-formats
  (cons "%Y %B"
        (if (boundp 'org-timestamp-custom-formats)
            (car org-timestamp-custom-formats)
          "%m/%d/%y %a"))
  "Custom formats for date headings.

By default, all dates are written following ISO 8601.  However, some
people don't like it, and so it is possible to overlay a custom format
on top to please such users.  Note that the underlying buffer is not
modified, the change is merely visual.

The `car' is used for month headings (YYYY-MM), the `cdr' for day
headings (YYYY-MM-DD).

See `format-time-string' for the syntax.

The change applies only when `org-daily-custom-date-formats-mode' is
enabled.  You can toggle it automatically by using e.g.:

\(add-hook \\='org-daily-after-jump-hook #\\='org-daily-custom-date-formats-mode)

See also `org-timestamp-custom-formats'."
  :type '(cons
          (string :tag "Format for month headings")
          (string :tag "Format for day headings")))


(defcustom org-daily-main-description-date-format "%F"
  "Custom format for the date displayed at the top of `org-daily' transient.

See `format-time-string' for the syntax."
  :type 'string)

(defcustom org-daily-today-indicator " [today]"
  "String appended to the heading for current date.

Only used when `org-daily-custom-date-formats-mode' is enabled."
  :type 'string)

(defcustom org-daily-transient-include-yesterday nil
  "Non-nil if `org-daily' transient should include a target for yesterday."
  :type 'boolean)

(defcustom org-daily-refile-should-schedule 'ask
  "Whether `org-daily-refile' should also schedule the headings it moves.

When t, heading is scheduled for the day it is moved to.

When nil, nothing is done.

When set to the symbol `ask', prompt every time.

This option only takes effect if `org-daily-refile-maybe-schedule' is
included in `org-daily-after-refile-functions' (it is by default)."
  :type '(choice
          (const :tag "Always" t)
          (const :tag "Never" nil)
          (const :tag "Ask every time" ask)))

(defcustom org-daily-refile-should-keep-original 'ask
  "Whether `org-daily-refile' should copy headings instead of moving them.

When t, the original heading is kept.

When nil, the original heading is deleted.

When set to the symbol `ask', prompt every time."
  :type '(choice
          (const :tag "Always" t)
          (const :tag "Never" nil)
          (const :tag "Ask every time" ask)))

(defcustom org-daily-refile-landing-pos 'old
  "Where to put point after finishing `org-daily-refile'.

When set to the symbol `old', keep it in the original position.

When set to the symbol `new', move it to the target date.

Arbitrarily, nil is the same as `old' and t is the same as `new'.

This setting is not followed by `org-daily-refile-to-dates', which
always keeps point at original position."
  :type '(choice
          (const :tag "Stay at original position" old)
          (const :tag "Move to the target date" new)))

(defcustom org-daily-after-jump-hook nil
  "Normal hook run after calling `org-daily-jump-to-day'."
  :type 'hook)

(defcustom org-daily-before-refile-hook nil
  "Normal hook run before calling `org-daily-refile'."
  :type 'hook)

(defcustom org-daily-after-refile-functions '(org-daily-refile-maybe-schedule)
  "Abnormal hook run after refiling a heading with `org-daily-refile'.

Every function is called with a single argument, the date where the
heading has been refiled to (as an ISO 8601 date string).

Mainly useful for changing TODO keyword, adding or removing tags, and so
on."
  :type 'hook)

;;;; Special variables

(defvar org-daily-overriding-file nil
  "Overriding value for the file returned by function `org-daily-file'.

If set, it is returned unconditionally by the function `org-daily-file'.

Only ever let-bind this.")

(defvar org-daily-this-quick-action nil
  "Quick action to run in the next call to `org-daily-jump-to-day'.

It should be a cons cell whose `car' serves as a description and whose
`cdr' is the actual function to run.

Such cons cell normally is one of the elements from
`org-daily-quick-actions', but it doesn't need to be so if you are just
let-binding it in your own commands.  In that case, the description can
be nil, because it is only used by `org-daily' transient.

Only ever let-bind this.")

(put 'org-daily-this-quick-action 'risky-local-variable t)

;;;; Constants

(defconst org-daily-iso-date-regexp
  (rx (group (= 4 digit)) "-"
      (group (= 2 digit)) "-"
      (group (= 2 digit)))
  "Regexp matching an ISO 8601 date string.
That means a date formatted as YYYY-MM-DD.

The year, month and day are captured.")

(defconst org-daily-year-month-regexp
  (rx (group (= 4 digit)) "-" (group (= 2 digit)))
  "Regexp matching a partial ISO 8601 date string (year and month).
That means a date formatted as YYYY-MM.

The year and month are captured.")

(defconst org-daily-year-heading-regexp
  (rx bol "* "
      ;; Org docs say priorities and TODO keywords are allowed in a
      ;; date tree structure.  I never used them, nor I see how they
      ;; could be useful there, but we support it anyway.
      (optional (one-or-more printing))
      (group (= 4 digit))
      ;; We support tags too (it makes the regexp harder, but with rx
      ;; being so good, that doesn't really matter)
      (optional (seq " " (one-or-more printing)))
      eol)
  "Regexp matching a year heading.
The year is captured.")

(defconst org-daily-month-heading-regexp
  (rx bol "** "
      ;; See above
      (optional (one-or-more printing))
      (group (group (regexp org-daily-year-month-regexp)) (one-or-more printing)))
  "Regexp matching a month heading.
First group contains the heading sans stars, the second only the date.")

(defconst org-daily-day-heading-regexp
  (rx bol "*** "
      ;; See above
      (optional (one-or-more printing))
      (group (group (regexp org-daily-iso-date-regexp)) (one-or-more printing)))
  "Regexp matching a day heading.
First group contains the heading sans stars, the second only the date.")

;;;; Helper macros

(defmacro org-daily-run-in-daily-buffer-and-widen (&rest body)
  "Run BODY in a buffer visiting file returned by function `org-daily-file'.

The buffer is widened prior to running BODY, and stays that way.
However, if BODY does not complete succesfully (for instance, if there
is an error or the user quits a prompt), then original restrictions and
point position are restored afterwards."
  (declare (debug (body)) (indent defun))
  `(let ((buffer (find-file-noselect (org-daily-file)))
         new-point)
     (condition-case nil
         (with-current-buffer buffer
           (save-excursion
             (save-restriction
               (widen)
               ,@body
               (setq new-point (point)))))
       (:success
        (with-current-buffer buffer
          (widen)
          (goto-char new-point))))))

(defmacro org-daily-define-command-with-overriding-date (name)
  "Define a command with an overriding defult date.
NAME determines the command to call.

In short, the new command, named org-daily-NAME, will call org-NAME with
`org-overriding-default-time' set to `org-daily-day-at-point-as-ts', if
that returns a non-nil value.  This is so `org-read-date' prompt
defaults to the date for the entry."
  `(defun ,(intern (format "org-daily-%s" name)) ()
     ,(format
       "Call `org-%s' with date defaulting to the one for this entry."
       name)
     (interactive)
     (let ((org-overriding-default-time (org-daily-day-at-point-as-ts)))
       (call-interactively #',(intern (format "org-%s" name))))))

;;;; Main functions

(defun org-daily-file ()
  "Return absolute path to the file where days are stored.

This normally returns the value of variable `org-daily-file', unless
`org-daily-all-files' is set.  In that case, the function checks if
current file is included in that variable, and returns it if so.  If it
is not, then it just returns the first file in `org-daily-all-files'.

Additionally, if `org-daily-overriding-file' is set, then it returns
that no matter what."
  (cond (org-daily-overriding-file org-daily-overriding-file)
        ((not org-daily-all-files)
         (expand-file-name org-daily-file))
        (t
         (if-let* ((this-file buffer-file-name)
                   (files (mapcar #'cdr org-daily-all-files))
                   (_ (seq-find (lambda (f) (equal (expand-file-name f) this-file)) files)))
             this-file
           (expand-file-name (or (cdr-safe (car org-daily-all-files)) org-daily-file))))))

(defun org-daily-day-at-point ()
  "Return date for subtree at point, as an ISO 8601 date string."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (when-let* ((path (and (not (org-before-first-heading-p))
                             (org-get-outline-path :with-self)))
                  (date (nth 2 path))
                  (_ (string-match org-daily-iso-date-regexp date)))
        (match-string 0 date)))))

(defun org-daily-day-at-point-as-ts ()
  "Return `org-daily-day-at-point' as an Emacs timestamp."
  (when-let* ((day (org-daily-day-at-point)))
    (org-daily-iso-to-internal day)))

(defun org-daily-focus-heading ()
  "Reveal current heading and narrow to it."
  (when (org-at-heading-p)
    (org-fold-show-entry)
    (org-fold-show-children))
  (org-narrow-to-subtree))

(defun org-daily-visiting-days-file-p ()
  "Return non-nil if current buffer is visiting Org Daily file."
  (equal buffer-file-name (org-daily-file)))

(defun org-daily-on-current-day-p ()
  "Return non-nil if the entry for current day is focused."
  (and (org-daily-visiting-days-file-p)
       (buffer-narrowed-p)
       (equal (org-daily-day-at-point) (format-time-string "%F"))))

(defun org-daily-on-tomorrow-p ()
  "Return non-nil if the entry for tomorrow is focused."
  (and (org-daily-visiting-days-file-p)
       (buffer-narrowed-p)
       (equal (org-daily-day-at-point) (org-daily-return-iso-date :day +1))))

(defun org-daily-in-date-heading ()
  "Return non-nil if current heading refers to a year, month or day.

This function returns non-nil when point is inside or immediately after
a heading created by `org-datetree'."
  (when (and (derived-mode-p 'org-mode) (org-daily-visiting-days-file-p))
    (save-excursion
      (when (and (not (org-before-first-heading-p)) (org-back-to-heading t))
        (or (looking-at org-daily-day-heading-regexp)
            (looking-at org-daily-month-heading-regexp)
            (looking-at org-daily-year-heading-regexp))))))

;;;; ISO Date utils

;; I made these available as a separate library too.
;;
;; https://github.com/lmq-10/iso-date

(defun org-daily-iso-to-calendar (date)
  "Convert an ISO 8601 DATE to calendar internal format."
  (when (string-match org-daily-iso-date-regexp date)
    (let ((day   (match-string 3 date))
          (month (match-string 2 date))
          (year  (match-string 1 date)))
      (mapcar #'string-to-number (list month day year)))))

(defun org-daily-iso-to-internal (date)
  "Convert an ISO 8601 DATE string to an Emacs timestamp."
  (when (string-match-p org-daily-iso-date-regexp date)
    (date-to-time date)))

(defun org-daily-calendar-to-iso (date)
  "Convert DATE from calendar internal format to ISO 8601 format."
  (let ((day   (number-to-string (nth 1 date)))
        (month (number-to-string (nth 0 date)))
        (year  (number-to-string (nth 2 date))))
    (concat year "-" (string-pad month 2 ?0 t) "-" (string-pad day 2 ?0 t))))

(defun org-daily-return-iso-date (&rest keywords)
  "Return an ISO 8601 date string for current day.

KEYWORDS allow to modify the date returned.  They are passed to
`make-decoded-time'.  For instance, the following returns a date string
for yesterday:

\(org-daily-return-iso-date :day -1)

A special keyword named START-DATE allows to set the starting day which
will be modified by the rest of KEYWORDS.  It should be an ISO 8601 date
string.  For instance, to add a month to a specific date:

\(org-daily-return-iso-date :start-date \"2000-12-18\" :month +1)"
  (format-time-string
   "%F"
   (when keywords
     (encode-time
      (decoded-time-add
       (if-let* ((date (plist-get keywords :start-date)))
           (progn
             (setq keywords (remove :start-date (remove date keywords)))
             (parse-time-string date))
         (decode-time))
       (apply #'make-decoded-time keywords))))))

(defun org-daily-do-time-shift (shift date-start)
  "Apply SHIFT to DATE-START, return result.

SHIFT is a string in the form [NUMBER][PERIOD] such as 2w.  Available
periods are d (day), w (week), m (month) and y (year).

DATE-START should be an ISO 8601 date string.  Returned date is also in
that format."
  (when (string-match
         (rx
          (group (optional (or "+" "-")) (one-or-more digit))
          (group (any letter)))
         shift)
    (let ((num (string-to-number (match-string 1 shift)))
          (unit (match-string 2 shift)))
      (org-daily-return-iso-date
       :start-date date-start
       (pcase unit
         ("d" :day)
         ("w" (and (setq num (* 7 num)) :day))
         ("m" :month)
         ("y" :year)
         (_ (error "Unsupported time unit")))
       num))))

(defun org-daily-list-days-between (start end)
  "Return a list with all dates between START and END.
START and END should be ISO 8601 date strings.

Returned dates are also in that format."
  (let* ((time1 (org-daily-iso-to-internal start))
         (time2 (org-daily-iso-to-internal end))
         (pointer time1)
         (one-day (make-decoded-time :day 1))
         dates)
    (while (not (equal pointer time2))
      (push (format-time-string "%F" pointer) dates)
      (setq pointer (encode-time (decoded-time-add (decode-time pointer) one-day))))
    (push (format-time-string "%F" time2) dates)
    (reverse dates)))

;;;; Refiling

(defun org-daily--refile-subr (date &optional keep)
  "Refile current subtree to DATE in Org Daily file.
When KEEP is non-nil, don't delete original subtree.

The normal hook `org-daily-before-refile-hook' is called before doing
anything else.

The abnormal hook `org-daily-after-refile-functions' is called after the
subtree is pasted at DATE."
  (run-hooks 'org-daily-before-refile-hook)
  (org-with-wide-buffer ; if we don't widen, deletion could fail
   (when-let* ((element
                (unless (org-before-first-heading-p)
                  (org-back-to-heading)
                  (org-element-at-point)))
               (txt
                (buffer-substring
                 (org-element-begin element)
                 (org-element-end element))))
     (and (not keep) (org-cut-subtree))
     (with-current-buffer (find-file-noselect (org-daily-file))
       (org-with-wide-buffer
        (org-datetree-file-entry-under txt (org-daily-iso-to-calendar date))
        (run-hook-with-args 'org-daily-after-refile-functions date))))))

(defun org-daily--catch-invalid-refile ()
  "Error out if refile should not be performed."
  (cond ((not (derived-mode-p 'org-mode))
         (user-error "Can't refile from a non-Org buffer"))
        ((org-daily-in-date-heading)
         (user-error "Refusing to refile a date heading"))))

;;;; Miscellanous helper functions

(defun org-daily--maybe-welcome ()
  "Maybe display a welcome message."
  (when (and (not org-daily-all-files) (not (file-exists-p buffer-file-name)))
    (save-buffer)
    (message
     (substitute-command-keys
      (concat "Welcome to Org Daily."
              "  Don't panic!"
              "  You're seeing just part of the buffer; widen with \\[widen]."
              "  Have fun!")))))

(defun org-daily-demote-if-colliding-with-date ()
  "Demote current subtree, if it is of the same level as a date.

This is intended to be used by functions in `org-daily-quick-actions',
after they insert a heading which could collide with a date."
  (save-excursion
    (beginning-of-line)
    (when (looking-at (rx (= 3 "*") " "))
      (insert "*"))))

(defun org-daily-quick-new-heading ()
  "Go to `point-max' and insert a new Org heading."
  (goto-char (point-max))
  (org-insert-heading)
  (org-daily-demote-if-colliding-with-date)
  (recenter))

(defun org-daily-quick-new-todo-heading ()
  "Go to `point-max' and insert a new Org heading with a TODO keyword."
  (goto-char (point-max))
  (org-insert-todo-heading nil :force-heading)
  (org-daily-demote-if-colliding-with-date)
  (recenter))

(defun org-daily-refile-maybe-schedule (date)
  "Maybe schedule current item to DATE.

See `org-daily-refile-should-schedule' for details."
  (save-restriction
    (save-excursion
      (when-let* ((_ (if (eq org-daily-refile-should-schedule 'ask)
                         (save-excursion
                           (re-search-backward (rx bol (= 3 "*") " "))
                           (org-daily-focus-heading)
                           (y-or-n-p "Schedule to this day?"))
                       org-daily-refile-should-schedule))
                  (org-overriding-default-time (org-daily-iso-to-internal date)))
        (org-schedule nil date)))))

(defun org-daily-annotate-file (name)
  "Annotate NAME with its file according to `org-daily-all-files'."
  (when-let* ((file (cdr (assoc name org-daily-all-files))))
    (format "%s %s"
            (propertize " " 'display '(space :align-to 20))
            (propertize file 'face 'completions-annotations))))

;;;; Date overlays

(defun org-daily--add-date-overlay (beg end date format &optional add-indicator)
  "Add an overlay for DATE between BEG and END, with FORMAT.

FORMAT works just as in `format-time-string'.

If ADD-INDICATOR is non-nil, also append the indicator set in
`org-daily-today-indicator' if DATE corresponds to current date."
  ;; Based on `org-toggle-timestamp-overlays' and related
  (org-remove-flyspell-overlays-in beg end)
  (org-rear-nonsticky-at end)
  (put-text-property beg end 'date-heading t)
  (put-text-property
   beg end 'display
   (concat
    (format-time-string
     format
     (org-daily-iso-to-internal date))
    (if (and add-indicator
             org-daily-today-indicator
             (equal date (format-time-string "%F")))
        org-daily-today-indicator
      ""))))

(defun org-daily--add-day-overlays (limit)
  "Overlay a custom date format in day headings.

Intended to be added to `font-lock-keywords' by
`org-daily-custom-date-formats-mode'.

LIMIT is required by font lock."
  (when (re-search-forward org-daily-day-heading-regexp limit t)
    (let* ((beg (match-beginning 1))
           (end (match-end 1))
           (date (match-string-no-properties 2)))
      (org-daily--add-date-overlay
       beg end date (cdr org-daily-custom-date-formats) :add-indicator))
    t))

(defun org-daily--add-month-overlays (limit)
  "Overlay a custom date format in month headings.

Intended to be added to `font-lock-keywords' by
`org-daily-custom-date-formats-mode'.

LIMIT is required by font lock."
  (when (re-search-forward org-daily-month-heading-regexp limit t)
    (let ((beg (match-beginning 1))
          (end (match-end 1))
          (date (concat (match-string-no-properties 2) "-01")))
      (org-daily--add-date-overlay beg end date (car org-daily-custom-date-formats)))
    t))

;;;; For transient

(defun org-daily--transient-restore-overriding-file-value ()
  "Restore regular value of `org-daily-overriding-file'."
  (setq org-daily-overriding-file nil)
  (remove-hook 'transient-exit-hook #'org-daily--transient-restore-overriding-file-value))

(defun org-daily--transient-restore-default-quick-action ()
  "Restore regular value of `org-daily-this-quick-action'."
  (setq org-daily-this-quick-action nil)
  (remove-hook 'transient-exit-hook #'org-daily--transient-restore-default-quick-action))

(defun org-daily--multi-file-p ()
  "Return non-nil if `org-daily-all-files' is set."
  org-daily-all-files)

(defun org-daily--quick-actions-p ()
  "Return non-nil if `org-daily-quick-actions' is set."
  org-daily-quick-actions)

(defun org-daily--quick-action-set-p ()
  "Return non-nil if `org-daily-this-quick-action' is set."
  org-daily-this-quick-action)

(defun org-daily--include-yesterday-p ()
  "Return non-nil if `org-daily-transient-include-yesterday' is set."
  org-daily-transient-include-yesterday)

(defun org-daily--transient-main-description ()
  "Return main description for `org-daily' transient."
  (format
   "Org Daily ― Today is %s%s"
   (format-time-string org-daily-main-description-date-format)
   (if (org-daily-on-current-day-p) " [shown]" "")))

(defun org-daily--transient-switch-file-description ()
  "Return description for `org-daily-transient-switch-file'."
  (format
   "switch file (now: %s)"
   (propertize
    (car (seq-find
          (lambda (f) (equal (expand-file-name (cdr f)) (org-daily-file)))
          org-daily-all-files))
    'face 'transient-argument)))

(defun org-daily--transient-at-actionable-heading-p ()
  "Return non-nil if an actionable heading can be found near point."
  (and (derived-mode-p 'org-mode)
       (not (org-before-first-heading-p))
       (not (org-daily-in-date-heading))))

(defun org-daily--transient-quick-action-description ()
  "Return description for `org-daily-transient-set-quick-action'."
  (let (actions-string)
    (dolist (action org-daily-quick-actions)
      (push
       (if (equal action org-daily-this-quick-action)
           (propertize (car action) 'face 'transient-enabled-suffix)
         (car action))
       actions-string))
    (format
     "action (pick: %s)"
     (string-join (reverse actions-string) " | "))))

;;;; User-facing commands

(defun org-daily-jump-to-day (date)
  "Jump to DATE heading in Org Daily file.
Create it if it doesn't exist.

\"Org Daily file\" is understood as the file returned by the function
`org-daily-file'.

DATE must be a string in ISO format.  Interactively, it is read using
`org-read-date'."
  (interactive (list (org-read-date)))
  (if-let* ((cal-date (org-daily-iso-to-calendar date)))
      (progn
        (pop-to-buffer-same-window (find-file-noselect (org-daily-file)))
        (widen)
        (org-datetree-find-date-create cal-date)
        (org-daily-focus-heading)
        (org-daily--maybe-welcome)
        (when-let* ((action (cdr-safe org-daily-this-quick-action)))
          (funcall action))
        (run-hooks 'org-daily-after-jump-hook))
    (user-error "Date can't be recognized")))

(defun org-daily-today ()
  "Jump to today entry in Org Daily file.
Create it if it doesn't exist."
  (interactive)
  (org-daily-jump-to-day (org-daily-return-iso-date)))

(defun org-daily-tomorrow ()
  "Jump to tomorrow entry in Org Daily file.
Create it if it doesn't exist."
  (interactive)
  (org-daily-jump-to-day (org-daily-return-iso-date :day +1)))

(defun org-daily-yesterday ()
  "Jump to yesterday entry in Org Daily file.
Create it if it doesn't exist."
  (interactive)
  (org-daily-jump-to-day (org-daily-return-iso-date :day -1)))

(defun org-daily-show-range (start end)
  "Narrow to days between START and END.
This means every entry from START to END (both inclusive) is displayed.

Interactively, START and END are picked using `org-read-date'."
  (interactive (list
                (org-read-date nil nil nil "{Start}")
                (org-read-date nil nil nil "{End}")))
  (let ((days (org-daily-list-days-between start end))
        (buffer (find-file-noselect (org-daily-file)))
        beacon)
    (with-current-buffer buffer
      (widen)
      (dolist (day days)
        (org-datetree-find-date-create (org-daily-iso-to-calendar day))
        (when (equal day (car days))
          (setq beacon (point))))
      (org-end-of-subtree t t)
      (narrow-to-region beacon (point))
      (goto-char beacon)
      ;; Narrowing can break trees very badly, so just unfold
      (org-fold-region (point-min) (point-max) nil 'outline))
    (pop-to-buffer-same-window buffer)
    (message "Narrowed between %s and %s" (car days) (car (last days)))))

(defun org-daily-next-day ()
  "Go to the entry for next day in Org Daily file (probably this file)."
  (interactive)
  (when-let* ((day (org-daily-day-at-point)))
    (org-daily-jump-to-day (org-daily-return-iso-date :start-date day :day +1))))

(defun org-daily-previous-day ()
  "Go to the entry for previous day in Org Daily file (probably this file)."
  (interactive)
  (when-let* ((day (org-daily-day-at-point)))
    (org-daily-jump-to-day (org-daily-return-iso-date :start-date day :day -1))))

(defun org-daily-show-week ()
  "Narrow to dates for current week in Org Daily file."
  (interactive)
  (let* ((index-today (calendar-day-of-week (calendar-current-date)))
         (date-start (org-daily-return-iso-date :day (- (- index-today calendar-week-start-day))))
         (date-end (org-daily-return-iso-date :start-date date-start :day +6)))
    (org-daily-show-range date-start date-end)))

(defun org-daily-show-month ()
  "Narrow to dates for current month in Org Daily file."
  (interactive)
  (let ((buffer (find-file-noselect (org-daily-file))))
    (with-current-buffer buffer
      (widen)
      (org-datetree-find-month-create (calendar-current-date))
      (org-narrow-to-subtree)
      ;; Narrowing can break trees very badly, so just unfold
      (org-fold-region (point-min) (point-max) nil 'outline))
    (pop-to-buffer-same-window buffer)
    (message "Narrowed to current month")))

(defun org-daily-refile (date)
  "Move this subtree to DATE entry.

See the user variables `org-daily-refile-should-schedule',
`org-daily-refile-should-keep-original' and
`org-daily-refile-landing-pos' for customizing the behavior of the
command."
  (interactive (list (org-read-date nil nil nil "Refile to")))
  (org-daily--catch-invalid-refile)
  (let ((org-overriding-default-time (org-daily-day-at-point-as-ts))
        (should-move (or (eq org-daily-refile-landing-pos 'new)
                         (eq org-daily-refile-landing-pos t)))
        (should-keep (if (eq org-daily-refile-should-keep-original 'ask)
                         (y-or-n-p "Preserve original?")
                       org-daily-refile-should-keep-original)))
    (org-daily--refile-subr date should-keep)
    (when should-move
      (push-mark)
      (org-daily-jump-to-day date))
    ;; End
    (message "Succesfully %s subtree to %s%s!"
             (if should-keep "copied" "moved") date
             (if org-daily-all-files
                 (format " in file %s" (car (rassoc (org-daily-file) org-daily-all-files)))
               ""))))

(defun org-daily-refile-to-dates (starting-date end-at span)
  "Copy current heading to multiple dates, starting at STARTING-DATE.

Heading is copied to STARTING-DATE, and then to every date following
SPAN until END-AT.

SPAN is a string in the form [NUMBER][PERIOD] such as 2w (for copying
it every two weeks) or 1d (for copying every day).  See
`org-daily-do-time-shift'.

With a prefix argument, instead of prompting for a date for END-AT,
prompt for a number: the command will create that many copies.

When called from Lisp, END-AT can be a number or a date string."
  (interactive
   (let* ((start (org-read-date nil nil nil "Start refiling at"))
          (org-overriding-default-time (org-daily-iso-to-internal start)))
     (list
      start
      (if current-prefix-arg
          (read-number "Number of copies: ")
        (org-read-date nil nil nil "End refiling at"))
      (read-from-minibuffer "Refile every... (e.g. 2d to refile every two days): "))))
  (org-daily--catch-invalid-refile)
  (when (equal starting-date (org-daily-day-at-point))
    (setq starting-date (org-daily-do-time-shift span starting-date)))
  (let ((this-date starting-date)
        (should-keep (if (eq org-daily-refile-should-keep-original 'ask)
                         (y-or-n-p "Preserve original?")
                       org-daily-refile-should-keep-original))
        (org-daily-refile-should-schedule
         (when (memq 'org-daily-refile-maybe-schedule org-daily-after-refile-functions)
           ;; Ensure we don't ask a ton of questions
           (if (eq org-daily-refile-should-schedule 'ask)
               (y-or-n-p "Schedule every heading to its day?")
             org-daily-refile-should-schedule)))
        (n 0))
    (catch :done
      (while t
        (org-daily--refile-subr this-date :keep)
        (setq this-date (org-daily-do-time-shift span this-date))
        (setq n (1+ n))
        (cond ((numberp end-at)
               (when (>= n end-at)
                 (throw :done t)))
              (t
               (when (string-lessp end-at this-date)
                 (throw :done t))))))
    (and (not should-keep) (org-cut-subtree))
    (message "Succesfully copied subtree to %d locations%s!"
             n (if org-daily-all-files
                   (format " in file %s" (car (rassoc (org-daily-file) org-daily-all-files)))
                 ""))))

(define-minor-mode org-daily-custom-date-formats-mode
  "Overlay custom date formats in headings.

Date format is defined by `org-daily-custom-date-formats'."
  :global nil
  (if org-daily-custom-date-formats-mode
      (when (derived-mode-p 'org-mode)
        (font-lock-add-keywords nil '((org-daily--add-day-overlays) (org-daily--add-month-overlays)))
        (org-restart-font-lock))
    (font-lock-remove-keywords nil '((org-daily--add-day-overlays) (org-daily--add-month-overlays)))
    (org-with-wide-buffer
     (let ((p (point-min)) (bmp (buffer-modified-p)))
       (while (setq p (next-single-property-change p 'display))
         (when (and (get-text-property p 'display)
                    (get-text-property p 'date-heading))
           (remove-text-properties
            p (setq p (next-single-property-change p 'display))
            '(display t))))
       (set-buffer-modified-p bmp)))))

(org-daily-define-command-with-overriding-date deadline)
(org-daily-define-command-with-overriding-date schedule)
(org-daily-define-command-with-overriding-date timestamp)
(org-daily-define-command-with-overriding-date timestamp-inactive)

(defvar-keymap org-daily-override-date-mode-map
  :doc "Keymap for `org-daily-override-date-mode'."
  "C-c C-d" #'org-daily-deadline
  "C-c C-s" #'org-daily-schedule
  "C-c ." #'org-daily-timestamp
  "C-c !" #'org-daily-timestamp-inactive)

(define-minor-mode org-daily-override-date-mode
  "Minor mode for using current entry date as default for date prompts."
  :global nil)

(defun org-daily-jump-from-calendar ()
  "Jump to the entry for date at point in calendar buffer."
  (interactive)
  (unless (derived-mode-p 'calendar-mode)
    (user-error "Not in calendar buffer"))
  (let ((date (org-daily-calendar-to-iso (calendar-cursor-to-date t))))
    (with-selected-window (previous-window)
      (org-daily-jump-to-day date))))

(defun org-daily-occur ()
  "Run `occur' in Org Daily file."
  (interactive)
  (org-daily-run-in-daily-buffer-and-widen
    (call-interactively #'occur)))

(defun org-daily-occur-display-date ()
  "Echo the date for this occur match.

Date format is given by `org-daily-custom-date-formats'."
  (interactive)
  (when-let* (((derived-mode-p 'occur-mode))
              (marker (caar (get-text-property (point) 'occur-target))))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (when-let* ((date (org-daily-day-at-point)))
         (message
          (concat
           (format-time-string
            (cdr org-daily-custom-date-formats)
            (org-daily-iso-to-internal date))
           (if (equal date (format-time-string "%F"))
               org-daily-today-indicator
             ""))))))))

(defun org-daily-sparse-tree ()
  "Run `org-sparse-tree' in Org Daily file."
  (interactive)
  (let ((buffer (find-file-noselect (org-daily-file))))
    (org-daily-run-in-daily-buffer-and-widen
      (call-interactively #'org-sparse-tree))
    (unless (equal buffer (current-buffer))
      (pop-to-buffer-same-window buffer)
      ;; This function doesn't work when window is not focused
      (when (memq 'org-first-headline-recenter org-occur-hook)
        (org-first-headline-recenter)))))

(defun org-daily-transient-switch-file ()
  "Interactively change the value of `org-daily-overriding-file'.

The user is prompted to choose a value from `org-daily-all-files'.

This function effectively allows the user to run a command in a custom
file, different from that returned normally by the function
`org-daily-file'.

The change can be undone by
`org-daily--transient-restore-overriding-file-value'.

Useful only inside `org-daily' transient."
  (declare (interactive-only "let-bind `org-daily-overriding-file' instead."))
  (interactive)
  (let* ((completion-extra-properties
          (list :annotation-function #'org-daily-annotate-file))
         (chosen-file
          (completing-read "Pick file: " org-daily-all-files nil :require-match)))
    (setq org-daily-overriding-file (cdr (assoc chosen-file org-daily-all-files)))
    (add-hook 'transient-exit-hook #'org-daily--transient-restore-overriding-file-value)))

(defun org-daily-transient-set-quick-action ()
  "Interactively change the value of `org-daily-this-quick-action'.

There is no feedback.

The change can be undone by
`org-daily--transient-restore-default-quick-action'.

Useful only inside `org-daily' transient."
  (declare (interactive-only "let-bind `org-daily-this-quick-action' instead."))
  (interactive)
  (setq org-daily-this-quick-action
        (cond ((or (not org-daily-this-quick-action)
                   (not (member org-daily-this-quick-action org-daily-quick-actions)))
               (car org-daily-quick-actions))
              ((length=
                org-daily-quick-actions
                (1+ (seq-position org-daily-quick-actions org-daily-this-quick-action)))
               nil)
              (t
               (nth
                (1+ (seq-position org-daily-quick-actions org-daily-this-quick-action))
                org-daily-quick-actions))))
  (add-hook 'transient-exit-hook #'org-daily--transient-restore-default-quick-action))

;;;###autoload
(transient-define-prefix org-daily ()
  "Main point of entry for the Org Daily package."
  :refresh-suffixes t
  [:description org-daily--transient-main-description ""]
  [("f" org-daily-transient-switch-file
    :if org-daily--multi-file-p
    :description org-daily--transient-switch-file-description
    :transient t)
   ("a" org-daily-transient-set-quick-action
    :description org-daily--transient-quick-action-description
    :if org-daily--quick-actions-p
    :transient t)]
  [[("." "jump to today" org-daily-today)
    ("y" "jump to yesterday" org-daily-yesterday :if org-daily--include-yesterday-p)
    ("t" "jump to tomorrow" org-daily-tomorrow)
    ("d" "jump to day..." org-daily-jump-to-day)]
   [:inapt-if org-daily--quick-action-set-p
    ("k" "show this week" org-daily-show-week)
    ("m" "show this month" org-daily-show-month)
    ("r" "show range..." org-daily-show-range)]]
  [:class transient-row :description "Refile this subtree to..."
   :if org-daily--transient-at-actionable-heading-p
   :inapt-if org-daily--quick-action-set-p
   ("w" "one day...     " org-daily-refile)
   ("W" "several days..." org-daily-refile-to-dates)]
  [:class transient-row :description "Search"
   :inapt-if org-daily--quick-action-set-p
   ("o" "occur          " org-daily-occur)
   ("/" "sparse tree" org-daily-sparse-tree)]
  [:class transient-row :description "Move" :if org-daily-visiting-days-file-p
   :inapt-if org-daily--quick-action-set-p
   ("p" "previous day   " org-daily-previous-day :transient t)
   ("n" "next day" org-daily-next-day :transient t)]
  [:class transient-row
   ("q" "quit" transient-quit-all
    ;; Bind it only if the user does not already use `transient-bind-q-to-quit'
    :if-not (lambda () (eq (lookup-key transient-base-map "q") 'transient-quit-one)))])

(provide 'org-daily)
;;; org-daily.el ends here
