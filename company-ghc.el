;;; company-ghc.el --- company-mode ghc-mod backend -*- lexical-binding: t -*-

;; Copyright (C) 2014 by Iku Iwasa

;; Author:    Iku Iwasa <iku.iwasa@gmail.com>
;; URL:       https://github.com/iquiw/company-ghc
;; Version:   0.1.0
;; Package-Requires: ((cl-lib "0.5") (company "0.8.0") (ghc "4.1.1") (emacs "24"))
;; Keywords:  haskell, completion
;; Stability: experimental

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `company-mode' back-end for `haskell-mode' via `ghc-mod'.
;;
;; Provide context sensitive completion by using information from `ghc-mod'.
;; Add `company-ghc' to `company-mode' back-ends list.
;;
;;     (add-to-list 'company-backends 'company-ghc)
;;
;; or grouped with other back-ends.
;;
;;     (add-to-list 'company-backends '(company-ghc :with company-dabbrev))

;;; Code:

(require 'cl-lib)
(require 'company)
(require 'ghc)

(defgroup company-ghc nil
  "company-mode back-end for haskell-mode."
  :group 'company)

(defcustom company-ghc-show-info 'nomodule
  "Specify how to show type info in minibuffer."
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Show raw output" t)
                 (const :tag "Show in oneline" oneline)
                 (const :tag "Show without module" nomodule)))

(defcustom company-ghc-show-module t
  "Non-nil to show module name as annotation."
  :type 'boolean)

(defcustom company-ghc-hoogle-command (or (and (boundp 'haskell-hoogle-command)
                                               haskell-hoogle-command)
                                          "hoogle")
  "Specify hoogle command name, default is the value of `haskell-hoogle-command'"
  :type 'string)

(defconst company-ghc-pragma-regexp "{-#[[:space:]]+\\([[:upper:]]+\\>\\|\\)")

(defconst company-ghc-langopt-regexp
  (concat "{-#[[:space:]\n]+\\(LANGUAGE\\|OPTIONS_GHC\\)[[:space:]\n]+"
          "\\(?:[^[:space:]]+,[[:space:]\n]*\\)*"
          "\\([^[:space:]]+\\_>\\|\\)"))

(defconst company-ghc-import-regexp
  (concat "import[[:space:]\n]+"
          "\\(?:safe[[:space:]\n]+\\)?"
          "\\(?:qualified[[:space:]\n]+\\)?"
          "\\(?:\"[^\"]+\"[[:space:]\n]+\\)?"
          "\\([[:word:].]+\\_>\\|\\)"))

(defconst company-ghc-impdecl-regexp
  (concat company-ghc-import-regexp
          "\\(?:[[:space:]\n]+as[[:space:]\n]+\\w+\\)?"
          "[[:space:]\n]*\\(?:hiding[[:space:]\n]\\)*("
          "\\(?:[[:space:]\n]*[[:word:]]+[[:space:]\n]*,\\)*"
          "[[:space:]\n]*\\([[:word:]]+\\_>\\|\\)"))

(defconst company-ghc-module-regexp
  "module[[:space:]]*\\([[:word:].]+\\_>\\|\\)")

(defconst company-ghc-qualified-keyword-regexp
  (concat
   "\\_<\\([[:upper:]][[:alnum:].]*\\)\\."
   "\\([[:word:]]+\\_>\\|\\)"))

(defvar company-ghc--propertized-modules '())
(defvar company-ghc--imported-modules '())
(make-variable-buffer-local 'company-ghc--imported-modules)

(defvar company-ghc--prefix-attr)
(defun company-ghc--set-prefix-attr (candtype &optional index)
  "Set `company-ghc--prefix-attr' to CANDTYPE and optional match string.
If INDEX is non-nil, matched group of the index is returned as cdr."
  (setq company-ghc--prefix-attr
        (cons candtype (when index (match-string-no-properties index)))))

(defun company-ghc-prefix ()
  "Provide completion prefix at the current point."
  (let ((ppss (syntax-ppss)))
    (cond
     ((nth 3 ppss) 'stop)
     ((nth 4 ppss)
      (cond
       ((company-grab company-ghc-pragma-regexp)
        (company-ghc--set-prefix-attr 'pragma)
        (match-string-no-properties 1))
       ((company-grab company-ghc-langopt-regexp)
        (company-ghc--set-prefix-attr 'langopt 1)
        (match-string-no-properties 2))))

     ((looking-back "^[^[:space:]]*") nil)

     ((company-grab company-ghc-impdecl-regexp)
      (company-ghc--set-prefix-attr 'impspec 1)
      (match-string-no-properties 2))

     ((company-grab company-ghc-import-regexp)
      (company-ghc--set-prefix-attr 'module)
      (match-string-no-properties 1))

     ((company-grab company-ghc-module-regexp)
      (company-ghc--set-prefix-attr 'module)
      (match-string-no-properties 1))

     ((let ((case-fold-search nil))
        (looking-back company-ghc-qualified-keyword-regexp))
      (company-ghc--set-prefix-attr 'qualified 1)
      (cons (match-string-no-properties 2) t))

     (t (company-ghc--set-prefix-attr 'keyword)
        (company-grab-symbol)))))

(defun company-ghc-candidates (prefix)
  "Provide completion candidates for the given PREFIX."
  (let ((attr company-ghc--prefix-attr))
    (setq company-ghc--prefix-attr nil)
    (pcase attr
      (`(pragma) (all-completions prefix ghc-pragma-names))
      (`(langopt . "LANGUAGE") (all-completions prefix ghc-language-extensions))
      (`(langopt . "OPTIONS_GHC") (all-completions prefix ghc-option-flags))
      (`(impspec . ,mod)
       (all-completions prefix (company-ghc--get-module-keywords mod)))
      (`(module) (all-completions prefix ghc-module-names))
      (`(qualified . ,alias)
       (let ((mods (company-ghc--list-modules-by-alias alias)))
         (company-ghc--gather-candidates prefix mods)))
      (_ (company-ghc--gather-candidates
          prefix
          (mapcar 'car company-ghc--imported-modules))))))

(defun company-ghc-meta (candidate)
  "Show type info for the given CANDIDATE."
  (let* ((mod (company-ghc--get-module candidate))
         (pair (and mod (assoc-string mod company-ghc--imported-modules)))
         (qualifier (or (and pair (cdr pair)) mod)))
    (when qualifier
      (let ((info (ghc-get-info (concat qualifier "." candidate))))
        (pcase company-ghc-show-info
          (`t info)
          (`oneline (replace-regexp-in-string "\n" "" info))
          (`nomodule
           (when (string-match "\\(?:[^[:space:]]+\\.\\)?\\([^\t]+\\)\t" info)
             (replace-regexp-in-string
              "\n" "" (match-string-no-properties 1 info)))))))))

(defun company-ghc-doc-buffer (candidate)
  "Display documentation in the docbuffer for the given CANDIDATE."
  (with-temp-buffer
    (erase-buffer)
    (let ((mod (company-ghc--get-module candidate)))
      (call-process company-ghc-hoogle-command nil t nil "search" "--info"
                    (if mod (concat mod "." candidate) candidate)))
    (company-doc-buffer
     (buffer-substring-no-properties (point-min) (point-max)))))

(defun company-ghc-annotation (candidate)
  "Show module name as annotation where the given CANDIDATE is defined."
  (when company-ghc-show-module
    (concat " " (company-ghc--get-module candidate))))

(defun company-ghc--gather-candidates (prefix mods)
  "Gather all candidates from the keywords in MODS and return them sorted."
  (when mods
    (sort (cl-mapcan
           (lambda (mod)
             (all-completions
              prefix (company-ghc--get-module-keywords mod)))
           mods)
          'string<)))

(defun company-ghc--get-module-keywords (mod)
  "Get defined keywords in the specified module MOD."
  (let ((sym (ghc-module-symbol mod)))
    (unless (boundp sym)
      (ghc-load-merge-modules (list mod)))
    (when (boundp sym)
      (if (member mod company-ghc--propertized-modules)
          (ghc-module-keyword mod)
        (push mod company-ghc--propertized-modules)
        (mapcar (lambda (k) (company-ghc--set-module k mod))
                (ghc-module-keyword mod))))))

(defun company-ghc--get-module (s)
  "Get module name from the keyword S."
  (get-text-property 0 'company-ghc-module s))

(defun company-ghc--set-module (s mod)
  "Set module name of the keywork S to the module MOD."
  (put-text-property 0 (length s) 'company-ghc-module mod s)
  s)

(defun company-ghc-scan-modules ()
  "Scan imported modules in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let (mod (mod-alist '(("Prelude"))))
      (while (setq mod (company-ghc--scan-impdecl))
        (when (consp mod)
          (setq mod-alist
                (cons
                 mod
                 (if (and (assoc-string (car mod) mod-alist) (cdr mod))
                     (delete (assoc-string (car mod) mod-alist) mod-alist)
                   mod-alist)))))
      (setq company-ghc--imported-modules mod-alist))))

(defun company-ghc--scan-impdecl ()
  "Scan one import spec and return module alias cons.
If proper import spec is not found, return boolean value whether import spec
continues or not."
  (let* ((beg (company-ghc--search-import-start))
         (end (and beg (company-ghc--search-import-end (cdr beg)))))
    (when end
      (save-restriction
        (narrow-to-region (car beg) (car end))
        (goto-char (point-min))
        (let (chunk prev-chunk attrs mod)
          (while (setq chunk (company-ghc--next-import-chunk))
            (cond
             ((string= chunk "qualified") (push 'qualified attrs))
             ((string= chunk "safe") (push 'safe attrs))
             ((let ((case-fold-search nil))
                (string-match-p "^[[:upper:]]" chunk))
              (cond
               ((not mod) (setq mod (if (memq 'qualified attrs)
                                        (cons chunk chunk)
                                      (cons chunk nil))))
               ((string= prev-chunk "as") (setcdr mod chunk)))))
            (setq prev-chunk chunk))
          (or mod
              (string= (cdr end) "import")))))))

(defun company-ghc--search-import-start ()
  "Search start of import decl and return the point after import and offset."
  (catch 'result
    (while (re-search-forward "^\\([[:space:]]*\\)import\\>" nil t)
      (unless (company-ghc--in-comment-p)
        (throw 'result
               (cons (match-end 0)
                     (string-width (match-string-no-properties 1))))))))

(defun company-ghc--search-import-end (offset)
  "Search end of import decl and return the end point and next token.
If the line is less offset than OFFSET, it finishes the search."
  (forward-line)
  (catch 'result
    (let ((p (point)))
      (while (not (eobp))
        (cond
         ((company-ghc--in-comment-p) nil)
         ((looking-at "^[[:space:]]*$") nil)
         ((looking-at "^#") nil)
         ((not (and (looking-at "^\\([[:space:]]*\\)\\([^[:space:]\n]*\\)")
                    (< offset (string-width (match-string-no-properties 1)))))
          (throw 'result (cons p (match-string-no-properties 2)))))
        (forward-line)
        (setq p (point))))))

(defun company-ghc--next-import-chunk ()
  "Return next chunk in the current import spec."
  (catch 'result
    (while (and (skip-chars-forward " \t\n") (not (eobp)))
      (cond
       ((or (looking-at-p "{-") (looking-at-p "--"))
        (forward-comment 1))
       ((looking-at-p "(")
        (throw 'result (buffer-substring-no-properties
                        (point) (progn (forward-sexp) (point)))))
       ((looking-at-p "\"")
        (re-search-forward "\"\\([^\"]\\|\\\\\"\\)*\"")
        (throw 'result (match-string-no-properties 0)))
       ((re-search-forward "\\=.[[:alnum:].]*\\_>" nil t)
        (throw 'result (match-string-no-properties 0)))
       (t (throw 'result nil))))))

(defun company-ghc--in-comment-p ()
  "Return whether the point is in comment or not."
  (let ((ppss (syntax-ppss))) (nth 4 ppss)))

(defun company-ghc--list-modules-by-alias (alias)
  "Return list of imported modules that have ALIAS."
  (let (mods)
    (cl-dolist (pair company-ghc--imported-modules mods)
      (when (string= (cdr pair) alias)
        (setq mods (cons (car pair) mods))))))

;;;###autoload
(defun company-ghc (command &optional arg &rest ignored)
  "`company-mode' completion back-end for `haskell-mode' via ghc-mod.
Provide completion info according to COMMAND and ARG.  IGNORED, not used."
  (interactive (list 'interactive))
  (cl-case command
    (init (when (derived-mode-p 'haskell-mode)
            (company-ghc-scan-modules)
            (add-hook 'after-save-hook 'company-ghc-scan-modules nil t)))
    (interactive (company-begin-backend 'company-ghc))
    (prefix (and (derived-mode-p 'haskell-mode)
                 (company-ghc-prefix)))
    (candidates (company-ghc-candidates arg))
    (meta (company-ghc-meta arg))
    (doc-buffer (company-ghc-doc-buffer arg))
    (annotation (company-ghc-annotation arg))
    (sorted t)))

(provide 'company-ghc)
;;; company-ghc.el ends here
