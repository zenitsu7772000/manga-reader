;;; manga.el --- Manga & Comic reader for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: You <your@email.com>
;; Version: 1.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: manga, comic, reader, entertainment
;; URL: https://github.com/yourusername/manga.el
;;
;; Support development:
;; BTC: 1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7
;; ETH: 0xe1c6864fdddcef5b5c63b2ea62af91395b569e36
;;
;;; Commentary:
;;
;; manga.el is a full-featured manga and comic reader for Emacs.
;;
;; Features:
;;   - MangaDex online reader (search, browse, read)
;;   - Local CBZ/CBR/ZIP/folder reader
;;   - Reading progress tracking (persistent)
;;   - Bookmarks and library management
;;   - Fit-to-width / fit-to-height / zoom image display
;;
;; Dependencies (external):
;;   - unzip  (for CBZ files)
;;   - unar   (for CBR/RAR files, optional)
;;   - curl   (for downloading chapters)
;;
;; Usage:
;;   M-x manga              → open the dashboard
;;   M-x manga-search       → search MangaDex
;;   M-x manga-open-local   → open a local CBZ/CBR/folder
;;   M-x manga-library      → view reading history & bookmarks
;;
;;; Code:

(require 'url)
(require 'json)
(require 'cl-lib)
(require 'image)
(require 'seq)

;;; ─── Forward Declarations ────────────────────────────────────────────────────

(declare-function manga-view-start-session "manga-view.el")
(declare-function manga-dashboard "manga.el")
(declare-function manga-open-local "manga-local.el")
(declare-function manga-library "manga-library.el")
(declare-function manga--resume-reading "manga.el")

;;; ─── Load submodules ─────────────────────────────────────────────────────────

(defvar manga--load-dir (file-name-directory (or load-file-name buffer-file-name))
  "Directory where manga.el lives.")

(defun manga--require-submodule (name)
  "Load submodule NAME from the same directory as manga.el."
  (let ((path (expand-file-name (concat name ".el") manga--load-dir)))
    (if (file-exists-p path)
        (load path nil t)
      (message "manga.el: submodule %s not found at %s" name path))))

;;; ─── Customization ───────────────────────────────────────────────────────────

(defgroup manga nil
  "Manga and comic reader for Emacs."
  :group 'applications
  :prefix "manga-")

(defcustom manga-download-dir (expand-file-name "~/manga-downloads/")
  "Directory where downloaded chapters are cached."
  :type 'directory
  :group 'manga)

(defcustom manga-library-dir (expand-file-name "~/manga/")
  "Directory where local manga/comics are stored."
  :type 'directory
  :group 'manga)

(defcustom manga-progress-file (expand-file-name "~/.emacs.d/manga-progress.el")
  "File to persist reading progress and bookmarks."
  :type 'file
  :group 'manga)

(defcustom manga-image-fit 'width
  "How to fit images in the viewer window.
Options: `width' (fit to window width), `height' (fit to window height),
`both' (fit to window), `none' (original size)."
  :type '(choice (const :tag "Fit to width"  width)
                 (const :tag "Fit to height" height)
                 (const :tag "Fit to window" both)
                 (const :tag "Original size" none))
  :group 'manga)

(defcustom manga-preload-pages 2
  "Number of pages to preload ahead while reading."
  :type 'integer
  :group 'manga)

(defcustom manga-reading-direction 'ltr
  "Reading direction: `ltr' (left-to-right) or `rtl' (right-to-left, manga style)."
  :type '(choice (const :tag "Left to right (comics)" ltr)
                 (const :tag "Right to left (manga)"  rtl))
  :group 'manga)

(defcustom manga-language "en"
  "Preferred language code for MangaDex chapters (en, ja, es, fr, etc.)."
  :type 'string
  :group 'manga)

(defcustom manga-concurrent-downloads 4
  "Number of concurrent page downloads (2-6 recommended).
Higher values = faster downloads but more server load."
  :type 'integer
  :group 'manga)

(defcustom manga-aggressive-preload t
  "If non-nil, preload more pages aggressively for smoother reading."
  :type 'boolean
  :group 'manga)

;;; ─── Faces ───────────────────────────────────────────────────────────────────

(defface manga-header
  '((t :foreground "#ff6b9d" :weight bold))
  "Face for dashboard headers.")

(defface manga-title
  '((t :foreground "#c9b1ff" :weight bold))
  "Face for manga titles.")

(defface manga-subtitle
  '((t :foreground "#88aaff"))
  "Face for manga subtitles and metadata.")

(defface manga-separator
  '((t :foreground "#334455"))
  "Face for separators.")

(defface manga-label
  '((t :foreground "#778899"))
  "Face for labels.")

(defface manga-progress
  '((t :foreground "#00ff88" :weight bold))
  "Face for reading progress.")

(defface manga-chapter
  '((t :foreground "#ffcc44"))
  "Face for chapter numbers.")

(defface manga-tag
  '((t :foreground "#ff9955" :slant italic))
  "Face for genre tags.")

(defface manga-status-reading
  '((t :foreground "#00ff88" :weight bold))
  "Face for 'reading' status.")

(defface manga-status-completed
  '((t :foreground "#aaaaaa"))
  "Face for 'completed' status.")

(defface manga-donation
  '((t :foreground "#ffaa00" :slant italic))
  "Face for donation text.")

(defface manga-key
  '((t :foreground "#55ccff" :weight bold))
  "Face for keybinding hints.")

;;; ─── Global State ────────────────────────────────────────────────────────────

(defvar manga--progress (make-hash-table :test 'equal)
  "Hash table: manga-id → alist with keys: title, chapter, page, status, bookmark.")

(defvar manga--current-session nil
  "Plist describing the currently open manga/chapter session.
Keys: :source :manga-id :manga-title :chapter-id :chapter-num
      :pages :current-page :total-pages :images")

;;; ─── Progress Persistence ────────────────────────────────────────────────────

(defun manga--progress-load ()
  "Load reading progress from `manga-progress-file'."
  (when (file-exists-p manga-progress-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents manga-progress-file)
          (goto-char (point-min))
          (let ((data (read (current-buffer))))
            (when (hash-table-p data)
              (setq manga--progress data))))
      (error (message "manga.el: could not load progress: %s" err)))))

(defun manga--progress-save ()
  "Save reading progress to `manga-progress-file'."
  (condition-case err
      (with-temp-file manga-progress-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 manga--progress (current-buffer))))
    (error (message "manga.el: could not save progress: %s" err))))

(defun manga--progress-update (manga-id &rest kvs)
  "Update progress for MANGA-ID with key-value pairs KVS."
  (let ((entry (or (gethash manga-id manga--progress) '())))
    (while kvs
      (setq entry (cons (cons (pop kvs) (pop kvs))
                        (assq-delete-all (car kvs) entry))))
    (puthash manga-id entry manga--progress)
    (manga--progress-save)))

(defun manga--progress-get (manga-id key)
  "Get KEY from progress entry for MANGA-ID."
  (cdr (assoc key (gethash manga-id manga--progress))))

;;; ─── Dashboard ───────────────────────────────────────────────────────────────

(defvar manga-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o")   #'manga-open-local)
    (define-key map (kbd "l")   #'manga-library)
    (define-key map (kbd "r")   #'manga-continue-reading)
    (define-key map (kbd "g")   #'manga-dashboard)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "RET") #'manga--dashboard-action)
    map)
  "Keymap for the manga dashboard.")

(define-derived-mode manga-dashboard-mode special-mode "Manga"
  "Major mode for the manga.el dashboard."
  (setq buffer-read-only t))

(defun manga--dashboard-buffer ()
  "Return or create the manga dashboard buffer."
  (get-buffer-create "*manga*"))

;;;###autoload
(defun manga-dashboard ()
  "Open the manga.el dashboard."
  (interactive)
  (manga--progress-load)
  (switch-to-buffer (manga--dashboard-buffer))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (manga-dashboard-mode)
    ;; Header
    (insert "============================================================\n")
    (insert "   MANGA.EL - Manga & Comic Reader for Emacs\n")
    (insert "============================================================\n")
    (insert "\n")
    ;; Key hints
    (dolist (hint '(("[o] Open local file"        . manga-open-local)
                    ("[l] Library & history"      . manga-library)
                    ("[r] Continue reading"       . manga-continue-reading)))
      (insert "  ")
      (insert-button (car hint)
                     'action (lambda (b) (call-interactively (button-get b 'cmd)))
                     'cmd (cdr hint)
                     'face 'manga-key
                     'follow-link t)
      (insert "\n"))
    (insert "\n")
    ;; Recent reading
    (insert "  -- CONTINUE READING -----------------------------------------\n")
    (let ((recent '()))
      (maphash (lambda (id entry)
                 (when (assoc 'last-read entry)
                   (push (cons id entry) recent)))
               manga--progress)
      (setq recent (seq-take
                    (sort recent (lambda (a b)
                                   (string> (or (cdr (assoc 'last-read (cdr a))) "")
                                            (or (cdr (assoc 'last-read (cdr b))) ""))))
                    5))
      (if (null recent)
          (insert "  No reading history yet. Press [o] to open a local file.\n")
        (dolist (item recent)
          (let* ((id      (car item))
                 (entry   (cdr item))
                 (title   (or (cdr (assoc 'title entry)) id))
                 (chapter (cdr (assoc 'chapter entry)))
                 (page    (cdr (assoc 'page entry)))
                 (total   (cdr (assoc 'total-pages entry))))
            (insert "  ")
            (insert-button
             (format "%-35s" (truncate-string-to-width title 35 nil nil "…"))
             'action (lambda (b)
                       (manga--resume-reading (button-get b 'manga-id)))
             'manga-id id
             'face 'manga-title
             'follow-link t)
            (insert " ")
            (insert (propertize
                     (format "Ch.%-4s" (or chapter "?"))
                     'face 'manga-chapter))
            (insert " ")
            (insert (propertize
                     (if (and page total)
                         (format "p.%d/%d" page total)
                       "")
                     'face 'manga-progress))
            (insert "\n")))))
    (insert "\n")
    ;; Library stats
    (insert "  -- LIBRARY ---------------------------------------------------\n")
    (let ((total    (hash-table-count manga--progress))
          (reading  0)
          (done     0))
      (maphash (lambda (_ e)
                 (pcase (cdr (assoc 'status e))
                   ("reading"   (cl-incf reading))
                   ("completed" (cl-incf done))))
               manga--progress)
      (insert (format "  Total tracked: %d   " total))
      (insert (propertize (format "Reading: %d  " reading) 'face 'manga-status-reading))
      (insert (propertize (format "Completed: %d\n" done)  'face 'manga-status-completed)))
    (insert "\n")
    ;; Donation footer
    (insert "  ------------------------------------------------------------\n")
    (insert "  Support manga.el:  ")
    (insert (propertize "BTC: 1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7\n" 'face 'manga-donation))
    (insert (propertize "               ETH: 0xe1c6864fdddcef5b5c63b2ea62af91395b569e36\n" 'face 'manga-donation))
    (insert "  ------------------------------------------------------------\n")))

(defun manga--dashboard-action ()
  "Activate button at point or fallback."
  (interactive)
  (if (button-at (point))
      (push-button)
    (message "manga: press s=search, o=open local, l=library")))

(defun manga--resume-reading (manga-id)
  "Resume reading MANGA-ID from saved progress."
  (let ((source  (manga--progress-get manga-id 'source))
        (path    (manga--progress-get manga-id 'path)))
    (cond
     ((or (equal source "local") path)
      ;; Local file - try to open it
      (if path
          (manga-open-local path)
        (message "manga: local file path not found in progress")))
     (t (message "manga: unknown source for %s (no path saved)" manga-id)))))

;;; ─── Public Entry Points ─────────────────────────────────────────────────────

;;;###autoload
(defun manga ()
  "Open the manga.el dashboard."
  (interactive)
  (manga-dashboard))

;;;###autoload
(defun manga-continue-reading ()
  "Continue the most recently read manga."
  (interactive)
  (manga--progress-load)
  (let ((recent nil)
        (latest-time ""))
    (maphash (lambda (id entry)
               (let ((t2 (or (cdr (assoc 'last-read entry)) "")))
                 (when (string> t2 latest-time)
                   (setq latest-time t2
                         recent id))))
             manga--progress)
    (if recent
        (manga--resume-reading recent)
      (message "manga: no reading history found — use M-x manga-search or M-x manga-open-local"))))

;;; ─── Init ────────────────────────────────────────────────────────────────────

;; Load submodules
(manga--require-submodule "manga-view")
(manga--require-submodule "manga-local")
(manga--require-submodule "manga-library")

;; Load progress on startup
(manga--progress-load)

(provide 'manga)
;;; manga.el ends here
