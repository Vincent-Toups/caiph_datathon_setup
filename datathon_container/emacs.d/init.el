;; Basic UI cleanup
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(setq inhibit-startup-screen t)
(global-display-line-numbers-mode t)

;; Helper utilities for idempotent configuration
(defun my/add-hook-once (hook func &optional depth local)
  "Add FUNC to HOOK unless it's already present.
DEPTH and LOCAL are passed through to `add-hook'."
  (let* ((hook-var (and (boundp hook) (symbol-value hook))))
    (unless (member func hook-var)
      (add-hook hook func depth local))))

(defun my/add-auto-mode-once (mode &rest patterns)
  "Associate each of PATTERNS with MODE in `auto-mode-alist' once."
  (dolist (pattern patterns)
    (unless (assoc pattern auto-mode-alist)
      (add-to-list 'auto-mode-alist (cons pattern mode)))))

;; Package setup
(require 'package)
(setq package-enable-at-startup nil)
(setq package-archives
      '(("melpa" . "https://melpa.org/packages/")
        ("gnu"   . "https://elpa.gnu.org/packages/")
        ("org"   . "https://orgmode.org/elpa/")))
(package-initialize)

;; Bootstrap use-package
(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))
(eval-when-compile (require 'use-package))

(setq use-package-always-ensure t)

;; Theme
(use-package modus-themes
  :init (load-theme 'modus-operandi t))

;; Completion and UI
(use-package vertico
  :init (vertico-mode))

(use-package orderless
  :custom (completion-styles '(orderless)))

(use-package marginalia
  :init (marginalia-mode))

(use-package which-key
  :init (which-key-mode))

;; R: ESS
(use-package ess
  :init
  (require 'ess-site)
  )

(defun my/ess-r-setup ()
  (setq ess-use-flymake nil)
  (ess-set-style 'RStudio))

(my/add-hook-once 'ess-r-mode-hook #'my/ess-r-setup)

;; Python: LSP + formatting
(use-package python
  :hook (python-mode . lsp-deferred))

(use-package lsp-mode
  :commands lsp lsp-deferred
  :custom
  (lsp-enable-symbol-highlighting nil)
  (lsp-pylsp-plugins-pylint-enabled nil)
  (lsp-pylsp-plugins-flake8-enabled t)
  (lsp-pylsp-plugins-autopep8-enabled nil))

(use-package lsp-ui
  :commands lsp-ui-mode)

;; Dockerfile editing
(use-package dockerfile-mode)

;; Terminal
(use-package vterm
  :commands vterm)

;; Shell scripts
(my/add-auto-mode-once 'sh-mode "\\.sh\\'")

;; YAML (useful for Docker, configs)
(use-package yaml-mode)

;; Org-mode for literate data science
(use-package org
  :config
  (setq org-confirm-babel-evaluate nil)
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((python . t)
     (R . t)
     (shell . t))))

;; Save backups to ~/.emacs.d/backups
(setq backup-directory-alist `(("." . "~/.emacs.d/backups")))

;; Optional: nicer modeline
(use-package doom-modeline
  :init (doom-modeline-mode 1))

;; Optional: project management
(use-package projectile
  :init (projectile-mode)
  :bind-keymap ("C-c p" . projectile-command-map))

;; Optional: Git integration
(use-package magit
  :commands magit-status)

;; UTF-8 default
(set-language-environment "UTF-8")

(global-auto-revert-mode t)

;; Enable syntax highlighting for code blocks in markdown-mode
(use-package markdown-mode
  :ensure t
  :config
  ;; Enable code block language support
  (setq markdown-fontify-code-blocks-natively t)
  )

(defun my/markdown-common-setup ()
  (setq-local comment-start "# ")
  (setq-local comment-end   ""))

(my/add-hook-once 'markdown-mode-hook #'my/markdown-common-setup)
(my/add-hook-once 'poly-markdown-mode-hook #'my/markdown-common-setup)

;; Ensure major modes for languages used in fenced code blocks are loaded
(use-package sh-script   :ensure t)  ;; for bash

;; Optional: customize the list of languages for which markdown-mode should auto-fontify blocks
(setq markdown-code-lang-modes
      '(("python" . python-mode)
        ("bash"   . sh-mode)
        ("sh"     . sh-mode)
        ("r"      . ess-r-mode)
        ("R"      . ess-r-mode)))

;; Polymode for Markdown with fenced code blocks
;; Provides true multi-major-mode editing so R/Python blocks behave natively
(use-package polymode :ensure t)
(use-package poly-markdown
  :ensure t)
(use-package poly-R :ensure t)   ;; ensure good R chunk integration via ESS

;; File associations (idempotent)
(my/add-auto-mode-once 'poly-markdown-mode "\\.md\\'")
(my/add-auto-mode-once 'dockerfile-mode "Dockerfile\\'")
(my/add-auto-mode-once 'yaml-mode "\\.ya?ml\\'")
(my/add-auto-mode-once 'ess-r-mode "\\.R\\'" "\\.r\\'")

;; LLM integration
(use-package llm :ensure t)

;; (use-package ellama
;;   :ensure t
;;   :bind ("C-c e" . ellama)
;;   :hook (org-ctrl-c-ctrl-c-final . ellama-chat-send-last-message)
;;   :init (setopt ellama-auto-scroll t)
;;   (require 'llm-openai)
;;   (setopt ellama-provider
;;           (make-llm-openai-compatible []
;;            :chat-model "qwen"
;;            :key "nonsense"
;;            :url "http://localhost:7860/v1"))
;;   :config
;;   (ellama-context-header-line-global-mode +1)
;;   (ellama-session-header-line-global-mode +1))

(setq warning-minimum-level :error)

(defvar my/org-ai-model-list '("huihui_ai/qwen2.5-1m-abliterated:14b" "qwen3:30b" "fg:latest" "hf.co/bartowski/NemoReRemix-12B-GGUF:latest" "cyd" "qwen" "gemma3:12b"))
(defun my/select-org-ai-model ()
  (interactive)
  (let ((model (ido-completing-read "Select: " my/org-ai-model-list t)))
    (setq org-ai-default-chat-model model)))

(defvar my/org-ai-port-list '("11435" "11434" "7860" "7861"))
(defun my/select-org-ai-port ()
  (interactive)
  (let ((port (ido-completing-read "Select: " my/org-ai-port-list t)))
    (setq org-ai-openai-chat-endpoint (format "http://localhost:%s/v1/chat/completions" port))
    (setq org-ai-openai-completion-endpoint (format "http://localhost:%s/v1/completions" port))))


(use-package org-ai
  :ensure t
  :commands (org-ai-mode
             org-ai-global-mode)
  :init
  (add-hook 'org-mode-hook #'org-ai-mode) ; enable org-ai in org-mode
  (org-ai-global-mode)	      ; installs global keybindings on C-c M-a
  :config
  (setq org-ai-default-chat-model "huihui_ai/qwen2.5-1m-abliterated:14b")
  (setq org-ai-openai-api-token "none")
  (setq org-ai-openai-chat-endpoint "http://localhost:11435/v1/chat/completions")
  (setq org-ai-openai-completion-endpoint "http://localhost:11435/v1/completions"))


(use-package visual-fill-column
  :ensure t)



(defun enable-visual-wordwrap ()
	    (interactive)
	    (setq-local fill-column 80)
            (setq-local visual-fill-column-width fill-column)
            (setq-local word-wrap t)                  ;; wrap on word boundaries
            (visual-line-mode 1)
            (visual-fill-column-mode 1))

;; Use /bin/bash for M-x shell
(setq shell-file-name            "/bin/bash")

;; Labradore markdown mode: ensure it's on the load-path and preferred for .md
(when load-file-name
  (let ((dir (file-name-directory load-file-name)))
    (unless (member dir load-path)
      (add-to-list 'load-path dir))))
;; Prefer Labradore mode for .md files; autoload the mode if needed
(autoload 'labradore-markdown-mode "labradore-markdown-mode" nil t)
(my/add-auto-mode-once 'labradore-markdown-mode "\\.md\\'")

;; If markdown-mode is loaded and re-adds its mapping, override it afterwards too.
(with-eval-after-load 'markdown-mode
  (require 'labradore-markdown-mode)
  (my/add-auto-mode-once 'labradore-markdown-mode "\\.md\\'"))

(setenv "SHELL" shell-file-name)

(ffap-bindings)

(defun my/diff-replace-buffer (new-text)
  "Compare NEW-TEXT against the current buffer and show an editable diff.
Creates a temporary buffer holding NEW-TEXT, then computes a unified diff
against the current buffer.  Displays the diff in a new buffer with a
\"C-c C-c\" binding to apply the patch back to the original buffer."
  (interactive "sNew text: ")
  (let* ((orig-buf (current-buffer))
         (orig-dir default-directory)
         ;; prepare temp buffer with NEW-TEXT
         (temp-buf (get-buffer-create "*my-diff-replace-temp*"))
         ;; compute diff
         (diff-buf (diff-no-select orig-buf temp-buf
                                   (buffer-name orig-buf)
                                   (buffer-name temp-buf)
                                   "-u")))
    (with-current-buffer temp-buf
      (erase-buffer)
      (insert new-text)
      (setq default-directory orig-dir))
    (with-current-buffer diff-buf
      ;; store references for later
      (setq-local my/diff-orig-buffer orig-buf)
      (setq-local my/diff-orig-directory orig-dir)
      ;; bind C-c C-c in diff buffer
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map diff-mode-map)
        (define-key map (kbd "C-c C-c") #'my/diff-apply-and-close)
        (use-local-map map)))
    (switch-to-buffer diff-buf)))

(defun my/diff-apply-and-close ()
  "Apply the edited diff in this buffer to its saved original buffer."
  (interactive)
  (let* ((patch-text (buffer-string))
         (orig-buf (buffer-local-value 'my/diff-orig-buffer (current-buffer)))
         (orig-dir (buffer-local-value 'my/diff-orig-directory (current-buffer)))
         (tmpfile (make-temp-file "emacs-patch-" nil ".diff")))
    ;; write patch
    (with-temp-file tmpfile
      (insert patch-text))
    ;; apply via external patch
    (let ((default-directory orig-dir))
      (with-current-buffer orig-buf
        (save-restriction
          (widen)
          (let ((exit-code
                 (call-process "patch" nil nil nil "-p0" "--silent" "--input" tmpfile)))
            (unless (zerop exit-code)
              (error "Patch failed (code %d)" exit-code))
            ;; reload buffer from file
            (when (buffer-file-name)
              (revert-buffer t t t))))))
    ;; cleanup
    (kill-buffer)
    (delete-file tmpfile)))

(xterm-mouse-mode t)
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(company csv-mode dockerfile-mode doom-modeline ess fold-this llm
	     lsp-ui magit marginalia modus-themes orderless org-ai
	     paredit projectile python-mode vertico visual-fill-column
	     vterm yaml-mode)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )

;;; --- R Paredit / ESS custom configuration -------------------------------

;; Break region on a given string and re-indent
(defun break-region-on-string (string)
  "Break the active region on STRING and indent the result.
For each occurrence of STRING in the region, insert a newline
immediately after it, then run `indent-region' on the modified region."
  (interactive "sBreak region on string: ")
  (unless (use-region-p)
    (error "No active region"))
  (let ((beg (region-beginning))
        (end (copy-marker (region-end)))) ;; marker so edits don’t shift end
    (save-excursion
      (goto-char beg)
      (while (search-forward string end t)
        (insert "\n")))
    (indent-region beg end)))

;; -------------------------------------------------------------------------

(defun my-r-paredit-setup ()
  "Tweak paredit for R: never insert space before delimiters."
  (setq-local paredit-space-for-delimiter-predicates
              (list (lambda (_endp _delim) nil))))

;; --- Percent pairing/deletion helpers -------------------------------------

(defun r--in-string-p ()
  "Non-nil if point is in a string (per `syntax-ppss')."
  (nth 3 (syntax-ppss)))

(defun r--two-percents-before-point-p ()
  "Non-nil if the two chars immediately before point are %%."
  (and (>= (point) (+ (point-min) 2))
       (eq (char-before) ?%)
       (eq (char-before (1- (point))) ?%)))

(defun r--two-percents-at-point-p ()
  "Non-nil if the two chars starting at point are %%."
  (and (eq (char-after) ?%)
       (eq (char-after (1+ (point))) ?%)))

;; --- Deletion commands ----------------------------------------------------

(defun r-percent-forward-delete ()
  "Structural forward delete for %% pairs, but behave normally in strings.
If at the first % of a %% pair (and not in a string), delete both; else delete one."
  (interactive)
  (if (r--in-string-p)
      (delete-char 1)
    (if (r--two-percents-at-point-p)
        (delete-char 2)
      (delete-char 1))))

(defun r-percent-backward-delete ()
  "Structural backward delete for %% pairs, but behave normally in strings.
If just after %% (%%|) and not in a string, move point left one char; else delete one."
  (interactive)
  (if (r--in-string-p)
      (backward-delete-char-untabify 1)
    (if (r--two-percents-before-point-p)
        (backward-char 1) ;; %%| -> %|%
      (backward-delete-char-untabify 1))))

;; --- Minor mode -----------------------------------------------------------

(defvar r-percent-pair-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "DEL")        #'r-percent-backward-delete)
    (define-key m [backspace]        #'r-percent-backward-delete)
    (define-key m (kbd "C-d")        #'r-percent-forward-delete)
    m)
  "Keymap for `r-percent-pair-mode'.")

(defvar-local r--saved-electric-pair-inhibit-pred nil)

(defun r--electric-pair-inhibit (char)
  "Inhibit pairing of % inside strings; otherwise defer to saved predicate."
  (or (and (eq char ?%) (r--in-string-p))
      (and r--saved-electric-pair-inhibit-pred
           (funcall r--saved-electric-pair-inhibit-pred char))))

(define-minor-mode r-percent-pair-mode
  "Treat % as a paired delimiter for R/ESS outside strings.
- Typing % inserts a matching % in code (not in strings).
- Backspace just after %% moves point left (no deletion) in code.
- Deleting the opening % of %% (C-d at |%%) removes both in code.
Inside strings, % behaves normally (no pairing; free deletion)."
  :lighter " %²"
  :keymap r-percent-pair-mode-map
  (if r-percent-pair-mode
      (progn
        (electric-pair-local-mode 1)
        ;; Pair % with itself OUTSIDE strings
        (setq-local electric-pair-pairs
                    (cons (cons ?% ?%) electric-pair-pairs))
        ;; Inhibit pairing inside strings
        (setq r--saved-electric-pair-inhibit-pred electric-pair-inhibit-predicate)
        (setq-local electric-pair-inhibit-predicate #'r--electric-pair-inhibit)
        (setq-local electric-pair-skip-self t))
    ;; teardown
    (when (eq electric-pair-inhibit-predicate #'r--electric-pair-inhibit)
      (setq-local electric-pair-inhibit-predicate r--saved-electric-pair-inhibit-pred))
    (setq r--saved-electric-pair-inhibit-pred nil)))

;; --- ESS indentation tweaks ------------------------------------------------

(defun my-r-indent-setup ()
  "Use 2-space indentation after { in R buffers."
  (setq-local ess-indent-offset 2)
  (setq-local ess-offset-continued 2))

;; --- Activate everything in ESS R mode ------------------------------------

(defun my/ess-r-extras ()
  (paredit-mode 1)
  (my-r-paredit-setup)
  (r-percent-pair-mode 1)
  (my-r-indent-setup))

(my/add-hook-once 'ess-r-mode-hook #'my/ess-r-extras)



;;;;;

;;; fence-transclude.el --- Writable transclusion + multi-major blocks -*- lexical-binding:t; -*-

;; Fences:
;; ```LANG file=path/to/file
;; …(edited in place; highlighted as LANG or by file extension)…
;; ```

(require 'cl-lib)

(defgroup fence-transclude nil
  "Writable transclusion fences with optional multi-major highlighting."
  :group 'editing)

(defface fence-transclude-header
  '((t :inherit font-lock-comment-face :underline t))
  "Face for fence headers."
  :group 'fence-transclude)

(defcustom fence-transclude-lang->mode
  '(("r"       . R-mode)         ;; or ess-r-mode if you use ESS
    ("R"       . R-mode)
    ("python"  . python-mode)
    ("py"      . python-mode)
    ("elisp"   . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode)
    ("shell"   . sh-mode)
    ("bash"    . sh-mode)
    ("sh"      . sh-mode)
    ("js"      . js-mode)
    ("json"    . json-mode)
    ("yaml"    . yaml-mode)
    ("org"     . org-mode)
    ("markdown". markdown-mode))
  "Map fence LANG to a major mode symbol."
  :type '(alist :key-type string :value-type symbol)
  :group 'fence-transclude)

(defvar fence-transclude--overlay-category 'fence-transclude)
(defvar-local fence-transclude--overlays nil)

;; Opening fence: captures LANG (grp 1, optional) and PATH (grp 2, required).
(defconst fence-transclude--open-regex
  (rx line-start "```"
      (? (group (+ (any "[:alnum:]" "-" "+" "#")))) ; LANG
      (* space) "file=" (group (+ (not (any "\n")))) ; PATH
      (* space) line-end))

(defconst fence-transclude--close-regex
  (rx line-start "```" (* space) line-end))

(defun fence-transclude--abs-path (path)
  (let* ((base (or (and (buffer-file-name) (file-name-directory (buffer-file-name)))
                   default-directory)))
    (expand-file-name path base)))

(defun fence-transclude--scan-fences ()
  "Return plist list describing all fences in current buffer."
  (save-excursion
    (save-restriction
      (widen) (goto-char (point-min))
      (let (out)
        (while (re-search-forward fence-transclude--open-regex nil t)
          (let* ((open-beg (line-beginning-position))
                 (open-end (line-end-position))
                 (lang (or (match-string 1) ""))
                 (path (match-string 2))
                 close-beg close-end)
            (forward-line 1)
            (unless (re-search-forward fence-transclude--close-regex nil t)
              (user-error "Unclosed fence starting at %d" open-beg))
            (setq close-beg (line-beginning-position)
                  close-end (line-end-position))
            (push (list :lang lang :path path
                        :open-beg open-beg :open-end open-end
                        :close-beg close-beg :close-end close-end)
                  out)))
        (nreverse out)))))

(defun fence-transclude--make-overlay (beg end &rest props)
  (let ((ov (make-overlay beg end nil t t)))
    (overlay-put ov 'category fence-transclude--overlay-category)
    (while props (overlay-put ov (pop props) (pop props)))
    ov))

(defun fence-transclude--expand-one (f)
  "Expand one fence F (plist)."
  (let* ((open-end (plist-get f :open-end))
         (close-beg (plist-get f :close-beg))
         (lang (plist-get f :lang))
         (path (plist-get f :path))
         (abs  (fence-transclude--abs-path path))
         (content (when (file-exists-p abs)
                    (with-temp-buffer
                      (insert-file-contents abs)
                      (buffer-string)))))
    (when (<= close-beg open-end)              ; ensure at least one newline
      (goto-char open-end) (insert "\n")
      (setq close-beg (1+ open-end)))
    (let ((inhibit-read-only t))
      (delete-region open-end close-beg)
      (goto-char open-end)
      (insert (or content "")))
    (let* ((body-beg open-end)
           (body-end (save-excursion (goto-char (plist-get f :close-beg)) (point)))
           (hdr-ov (fence-transclude--make-overlay
                    (plist-get f :open-beg) (plist-get f :open-end)
                    'face 'fence-transclude-header
                    'after-string
                    (propertize
                     (format "   ↔ %s%s\n"
                             (if (and lang (not (string-empty-p lang)))
                                 (concat lang ":") "")
                             (file-relative-name
                              abs
                              (or (and (buffer-file-name)
                                       (file-name-directory (buffer-file-name)))
                                  default-directory)))
                     'face 'shadow)))
           (body-ov (fence-transclude--make-overlay
                     body-beg body-end
                     'ft/path abs 'ft/lang lang
                     'modification-hooks (list #'fence-transclude--mark-dirty)))
           (tail-ov (fence-transclude--make-overlay
                     (plist-get f :close-beg) (plist-get f :close-end)
                     'face 'fence-transclude-header)))
      (add-to-list 'fence-transclude--overlays (list hdr-ov body-ov tail-ov)))))

(defun fence-transclude--clear-overlays ()
  (mapc (lambda (triple) (mapc #'delete-overlay triple))
        fence-transclude--overlays)
  (setq fence-transclude--overlays nil))

(defun fence-transclude--expand-all ()
  (interactive)
  (save-excursion
    (fence-transclude--clear-overlays)
    (mapc #'fence-transclude--expand-one (fence-transclude--scan-fences)))
  (when (bound-and-true-p fence-transclude--mmm-enabled)
    (fence-transclude--mmm-setup-or-refresh)))

(defun fence-transclude--for-each-body (fn)
  (save-excursion
    (dolist (triple fence-transclude--overlays)
      (let* ((ov (nth 1 triple))
             (beg (overlay-start ov))
             (end (overlay-end ov))
             (path (overlay-get ov 'ft/path))
             (lang (overlay-get ov 'ft/lang)))
        (funcall fn beg end path lang)))))

(defun fence-transclude--collapse-and-write ()
  "Write body to files, collapse to empty fences."
  (interactive)
  (fence-transclude--for-each-body
   (lambda (beg end path _lang)
     (make-directory (file-name-directory path) t)
     (write-region beg end path nil 'silent)
     (let ((inhibit-read-only t))
       (delete-region beg end))))
  (fence-transclude--clear-overlays)
  (set-buffer-modified-p t))

(defun fence-transclude--after-save-reexpand ()
  (let ((inhibit-message t) (was-mod (buffer-modified-p)))
    (fence-transclude--expand-all)
    (unless was-mod (set-buffer-modified-p nil))))

(defun fence-transclude--before-save ()
  (when fence-transclude-mode
    (fence-transclude--collapse-and-write)))

(defun fence-transclude--mark-dirty (_ov _beg _end &rest _) nil)

;;; ---------- mmm-mode integration (optional) ----------
(defvar fence-transclude--mmm-enabled nil)
(defvar-local fence-transclude--mmm-classes-set nil)

(defun fence-transclude--resolve-mode (lang path)
  "Return a major mode symbol for LANG or PATH."
  (let* ((lang (or lang ""))
         (by-lang (cdr (assoc lang fence-transclude-lang->mode))))
    (or by-lang
        ;; By file extension via auto-mode-alist
        (let* ((mode (cdr (assoc-default path auto-mode-alist #'string-match))))
          (cond
           ((functionp mode) mode)
           ((and (listp mode) (functionp (car mode))) (car mode))
           (t nil)))
        ;; Fall back to fundamental
        'fundamental-mode)))

(defun fence-transclude--mmm-submode ()
  "Compute submode from current fence front match."
  ;; Assumes the front regex is fence-transclude--open-regex.
  (let* ((lang (match-string-no-properties 1))
         (path (match-string-no-properties 2)))
    (fence-transclude--resolve-mode lang (fence-transclude--abs-path path))))

(defun fence-transclude--mmm-ensure ()
  "Define and enable an mmm class that targets our fences."
  (when (require 'mmm-mode nil t)
    ;; Define class once per session.
    (unless (get 'fence-transclude--mmm-defined 'class)
      (mmm-add-classes
       '((fence-transclude
          :match-submode fence-transclude--mmm-submode
          :front fence-transclude--open-regex
          :back  fence-transclude--close-regex
          :include-front nil    ;; highlight only body
          :include-back  nil
          :match-name (lambda ()
                        (let ((l (match-string-no-properties 1))
                              (p (match-string-no-properties 2)))
                          (format "ft:%s:%s" (or l "") (file-name-nondirectory p))))
          :face mmm-code-submode-face)))
      (put 'fence-transclude--mmm-defined 'class t))
    (setq-local mmm-classes (cl-remove-duplicates
                             (append '(fence-transclude) mmm-classes)))
    (unless (bound-and-true-p mmm-mode) (mmm-mode 1))
    (setq fence-transclude--mmm-enabled t)
    (setq fence-transclude--mmm-classes-set t)
    (mmm-parse-buffer)))

(defun fence-transclude--mmm-setup-or-refresh ()
  (when (require 'mmm-mode nil t)
    (fence-transclude--mmm-ensure)
    (mmm-parse-buffer)))

;;; ---------- Minor mode ----------
;;;###autoload
(define-minor-mode fence-transclude-mode
  "Editable file-transclusion fences with optional multi-major highlighting."
  :lighter " FT"
  (if fence-transclude-mode
      (progn
        (fence-transclude--expand-all)
        (add-hook 'before-save-hook #'fence-transclude--before-save nil t)
        (add-hook 'after-save-hook  #'fence-transclude--after-save-reexpand nil t)
        ;; Try to enable mmm if available
        (fence-transclude--mmm-ensure))
    (remove-hook 'before-save-hook #'fence-transclude--before-save t)
    (remove-hook 'after-save-hook  #'fence-transclude--after-save-reexpand t)
    (when (and (bound-and-true-p mmm-mode) fence-transclude--mmm-classes-set)
      (setq-local mmm-classes (remove 'fence-transclude mmm-classes))
      (mmm-parse-buffer))
    (setq fence-transclude--mmm-enabled nil)
    (fence-transclude--clear-overlays)))

(provide 'fence-transclude)
;;; fence-transclude.el ends here


;;;;;
