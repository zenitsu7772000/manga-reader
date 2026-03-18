;;; manga-local.el --- Local file reader for manga.el -*- lexical-binding: t; -*-
;;; Commentary:
;; Opens CBZ (ZIP), CBR (RAR), and plain image folders.
;; Requires: unzip (for CBZ), unar (optional, for CBR)
;;; Code:

(require 'cl-lib)

;;; ─── Forward Declarations ────────────────────────────────────────────────────

(declare-function manga--progress-get "manga.el")
(declare-function manga--progress-update "manga.el")
(declare-function manga-view-start-session "manga-view.el")

;;; ─── Supported image extensions ──────────────────────────────────────────────

(defconst manga-local--image-exts
  '("jpg" "jpeg" "png" "gif" "webp" "bmp")
  "Image file extensions recognized as comic pages.")

;;; ─── External tool checks ────────────────────────────────────────────────────

(defun manga-local--check-unzip ()
  "Return t if unzip is available, nil otherwise."
  (executable-find "unzip"))

(defun manga-local--check-unar ()
  "Return t if unar is available (for CBR/RAR), nil otherwise."
  (executable-find "unar"))

;;; ─── Extract & collect pages ─────────────────────────────────────────────────

(defun manga-local--extract-cbz (cbz-path dest-dir)
  "Extract CBZ-PATH into DEST-DIR. Return sorted list of image file paths."
  (unless (manga-local--check-unzip)
    (error "manga: 'unzip' not found. Install it: sudo apt install unzip  OR  brew install unzip"))
  (make-directory dest-dir t)
  (let ((exit-code (call-process "unzip" nil nil nil
                                 "-o"          ; overwrite
                                 "-q"          ; quiet
                                 cbz-path
                                 "-d" dest-dir)))
    (unless (= exit-code 0)
      (error "manga: unzip failed with exit code %d for %s" exit-code cbz-path)))
  (manga-local--collect-images dest-dir))

(defun manga-local--extract-cbr (cbr-path dest-dir)
  "Extract CBR-PATH into DEST-DIR using unar. Return sorted image paths."
  (unless (manga-local--check-unar)
    (error "manga: 'unar' not found. Install it: sudo apt install unar  OR  brew install unar"))
  (make-directory dest-dir t)
  (let ((exit-code (call-process "unar" nil nil nil
                                 "-o" dest-dir
                                 "-f"          ; force overwrite
                                 cbr-path)))
    (unless (= exit-code 0)
      (error "manga: unar failed with exit code %d for %s" exit-code cbr-path)))
  (manga-local--collect-images dest-dir))

(defun manga-local--collect-images (dir)
  "Recursively collect and sort image files from DIR."
  (let ((images '()))
    (dolist (file (directory-files-recursively dir "." nil))
      (when (member (downcase (file-name-extension file))
                    manga-local--image-exts)
        (push file images)))
    ;; Natural sort: handle "page1, page2, page10" correctly
    (manga-local--natural-sort images)))

(defun manga-local--natural-sort (files)
  "Sort FILES list naturally (page1 < page2 < page10)."
  (sort files
        (lambda (a b)
          (let ((na (file-name-nondirectory a))
                (nb (file-name-nondirectory b)))
            (manga-local--natural-string< na nb)))))

(defun manga-local--natural-string< (a b)
  "Compare strings A and B naturally (numeric segments compared as numbers)."
  (let ((i 0) (j 0)
        (la (length a)) (lb (length b))
        result done)
    (while (and (not done) (< i la) (< j lb))
      (let ((ca (aref a i)) (cb (aref b j)))
        (cond
         ;; Both are digits — compare the full number
         ((and (>= ca ?0) (<= ca ?9) (>= cb ?0) (<= cb ?9))
          (let ((na (string-to-number (substring a i (or (string-match "[^0-9]" a i) la))))
                (nb (string-to-number (substring b j (or (string-match "[^0-9]" b j) lb)))))
            (cond
             ((< na nb) (setq result t done t))
             ((> na nb) (setq result nil done t))
             (t
              ;; Advance past the number
              (while (and (< i la) (>= (aref a i) ?0) (<= (aref a i) ?9)) (cl-incf i))
              (while (and (< j lb) (>= (aref b j) ?0) (<= (aref b j) ?9)) (cl-incf j))))))
         ;; Regular char compare
         ((< ca cb) (setq result t done t))
         ((> ca cb) (setq result nil done t))
         (t (cl-incf i) (cl-incf j)))))
    (if done result (< la lb))))

;;; ─── Temp directory management ───────────────────────────────────────────────

(defvar manga-local--temp-dirs '()
  "List of temp directories created for extraction; cleaned up on quit.")

(defun manga-local--make-temp-dir (label)
  "Create a temp directory for LABEL and register it for cleanup."
  (let ((dir (make-temp-file "manga-" t)))
    (push dir manga-local--temp-dirs)
    dir))

(defun manga-local--cleanup-temp-dirs ()
  "Delete all temp extraction directories."
  (dolist (dir manga-local--temp-dirs)
    (when (file-directory-p dir)
      (delete-directory dir t)))
  (setq manga-local--temp-dirs nil))

;;; ─── Main entry points ───────────────────────────────────────────────────────

;;;###autoload
(defun manga-open-local (&optional path)
  "Open a local manga file or directory.
Supports CBZ (.cbz, .zip), CBR (.cbr, .rar), and image folders.
If PATH is not given, prompt with file/directory picker."
  (interactive)
  (let* ((chosen (or path
                     (read-file-name "Open manga file or folder: "
                                     (expand-file-name manga-library-dir)
                                     nil t)))
         (chosen (expand-file-name chosen)))
    (cond
     ;; Directory of images
     ((file-directory-p chosen)
      (manga-local--open-directory chosen))
     ;; CBZ / ZIP
     ((member (downcase (file-name-extension chosen)) '("cbz" "zip"))
      (manga-local--open-cbz chosen))
     ;; CBR / RAR
     ((member (downcase (file-name-extension chosen)) '("cbr" "rar"))
      (manga-local--open-cbr chosen))
     (t
      (error "manga: unsupported file type '%s'. Supported: .cbz .zip .cbr .rar or a folder"
             (file-name-extension chosen))))))

(defun manga-local--open-directory (dir)
  "Open image folder DIR as a manga."
  (message "manga: scanning folder %s..." dir)
  (let* ((pages    (manga-local--collect-images dir))
         (title    (file-name-nondirectory (directory-file-name dir)))
         (manga-id (concat "local:" (md5 dir))))
    (if (null pages)
        (error "manga: no images found in %s" dir)
      (message "manga: found %d pages" (length pages))
      ;; Save path and source in progress
      (manga--progress-update manga-id 'path dir 'title title 'source "local")
      ;; Start viewer
      (manga-view-start-session
       pages manga-id title "1" "local-folder" "local"
       (or (manga--progress-get manga-id 'page) 1)))))

(defun manga-local--open-cbz (cbz-path)
  "Extract and open CBZ-PATH."
  (message "manga: extracting %s..." (file-name-nondirectory cbz-path))
  (let* ((title    (file-name-base cbz-path))
         (manga-id (concat "local:" (md5 cbz-path)))
         (dest     (manga-local--make-temp-dir title)))
    (condition-case err
        (let ((pages (manga-local--extract-cbz cbz-path dest)))
          (if (null pages)
              (error "manga: no images found in %s" cbz-path)
            (message "manga: loaded %d pages from %s" (length pages) (file-name-nondirectory cbz-path))
            (manga--progress-update manga-id 'path cbz-path 'title title 'source "local")
            (manga-view-start-session
             pages manga-id title "1" "local-cbz" "local"
             (or (manga--progress-get manga-id 'page) 1))))
      (error
       (manga-local--cleanup-temp-dirs)
       (signal (car err) (cdr err))))))

(defun manga-local--open-cbr (cbr-path)
  "Extract and open CBR-PATH."
  (message "manga: extracting %s..." (file-name-nondirectory cbr-path))
  (let* ((title    (file-name-base cbr-path))
         (manga-id (concat "local:" (md5 cbr-path)))
         (dest     (manga-local--make-temp-dir title)))
    (condition-case err
        (let ((pages (manga-local--extract-cbr cbr-path dest)))
          (if (null pages)
              (error "manga: no images found in %s" cbr-path)
            (message "manga: loaded %d pages from %s" (length pages) (file-name-nondirectory cbr-path))
            (manga--progress-update manga-id 'path cbr-path 'title title 'source "local")
            (manga-view-start-session
             pages manga-id title "1" "local-cbr" "local"
             (or (manga--progress-get manga-id 'page) 1))))
      (error
       (manga-local--cleanup-temp-dirs)
       (signal (car err) (cdr err))))))

;;; ─── Library scan ────────────────────────────────────────────────────────────

(defun manga-local--scan-library ()
  "Scan `manga-library-dir' and return a list of found files/folders."
  (when (file-directory-p manga-library-dir)
    (let ((results '()))
      ;; Direct subdirectories
      (dolist (entry (directory-files manga-library-dir t "^[^.]"))
        (when (or (file-directory-p entry)
                  (member (downcase (file-name-extension entry))
                          '("cbz" "cbr" "zip" "rar")))
          (push entry results)))
      (nreverse results))))

(provide 'manga-local)
;;; manga-local.el ends here
