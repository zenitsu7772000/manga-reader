;;; manga-library.el --- Fast library and progress tracker for manga.el -*- lexical-binding: t; -*-
;;; Commentary:
;; Optimized rendering for reading history, bookmarks, and local library.
;;; Code:

(require 'cl-lib)
(require 'seq)

;;; ─── Forward Declarations ────────────────────────────────────────────────────

(declare-function manga--progress-load "manga.el")
(declare-function manga--progress-save "manga.el")
(declare-function manga--progress-get "manga.el")
(declare-function manga--progress-update "manga.el")
(declare-function manga--resume-reading "manga.el")
(declare-function manga-search "manga-mangadex.el")
(declare-function manga-open-local "manga-local.el")
(declare-function manga-local--scan-library "manga-local.el")

;;; ─── Library Mode ────────────────────────────────────────────────────────────

(defvar manga-library-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q")   #'quit-window)
    (define-key map (kbd "g")   #'manga-library)
    (define-key map (kbd "d")   #'manga-library--delete-entry-at-point)
    (define-key map (kbd "s")   #'manga-search)
    (define-key map (kbd "o")   #'manga-open-local)
    (define-key map (kbd "RET") #'push-button)
    map)
  "Keymap for `manga-library-mode'.")

(define-derived-mode manga-library-mode special-mode "Manga-Library"
  "Major mode for manga.el library and reading history."
  (setq buffer-read-only t
        truncate-lines   t)  ; Faster rendering
  (setq-local redisplay-dont-pause t))

;;; ─── Optimized Library View ─────────────────────────────────────────────────

;;;###autoload
(defun manga-library ()
  "Display the manga library, reading history, and bookmarks."
  (interactive)
  (manga--progress-load)
  (let ((buf (get-buffer-create "*manga-library*")))
    (switch-to-buffer buf)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (manga-library-mode)

      ;; Build content efficiently using with-temp-buffer
      (let ((entries (manga-library--collect-entries))
            (stats   (manga-library--compute-stats entries)))
        ;; Header
        (insert "============================================================\n")
        (insert "   MANGA LIBRARY\n")
        (insert "============================================================\n")
        (insert " [RET] Resume  [d] Delete entry  [s] Search  [o] Open local  [q] Quit\n\n")

        (if (null entries)
            (progn
              (insert " No reading history yet.\n")
              (insert " Press [s] to search MangaDex or [o] to open a local file.\n"))
          ;; Stats bar
          (insert (format " %d tracked  " (plist-get stats :total)))
          (insert (propertize (format "Reading: %d  " (plist-get stats :reading)) 'face 'manga-status-reading))
          (insert (propertize (format "Completed: %d\n\n" (plist-get stats :done)) 'face 'manga-status-completed))

          ;; Entry table header
          (insert (format " %-40s  %-8s  %-6s  %-6s  %s\n"
                          "Title" "Ch." "Page" "Status" "Last Read"))
          (insert (make-string 85 ?-) )
          (insert "\n")

          ;; Entries - optimized rendering
          (manga-library--render-entries entries)))

        ;; Local library section
        (insert "\n")
        (insert "  -- LOCAL LIBRARY ----------------------------------------------\n")
        (let ((local-files (manga-local--scan-library)))
          (if (null local-files)
              (insert (format " No files found in %s\n Set manga-library-dir to your manga folder.\n"
                              manga-library-dir))
            (manga-library--render-local-files local-files))))
    ;; Footer
    (insert "\n")
    (insert "  ------------------------------------------------------------\n")
    (insert "  Support manga.el:  BTC: 1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7\n")
    (insert "               ETH: 0xe1c6864fdddcef5b5c63b2ea62af91395b569e36\n")
    (insert "  ------------------------------------------------------------\n")
    (goto-char (point-min))))

(defun manga-library--collect-entries ()
  "Collect and sort all library entries by last-read date."
  (let ((entries '()))
    (maphash (lambda (id entry)
               (push (cons id entry) entries))
             manga--progress)
    (sort entries
          (lambda (a b)
            (string> (or (cdr (assoc 'last-read (cdr a))) "")
                     (or (cdr (assoc 'last-read (cdr b))) ""))))))

(defun manga-library--compute-stats (entries)
  "Compute stats from ENTRIES. Returns plist with :total, :reading, :done."
  (let ((reading 0)
        (done 0))
    (dolist (e entries)
      (let ((status (cdr (assoc 'status (cdr e)))))
        (cond
         ((equal status "reading") (cl-incf reading))
         ((equal status "completed") (cl-incf done)))))
    (list :total (length entries)
          :reading reading
          :done done)))

(defun manga-library--render-entries (entries)
  "Render library ENTRIES to current buffer."
  (dolist (entry entries)
    (let* ((id        (car entry))
           (data      (cdr entry))
           (title     (or (cdr (assoc 'title data)) id))
           (chapter   (or (cdr (assoc 'chapter data)) "?"))
           (page      (or (cdr (assoc 'page data)) 1))
           (total-p   (or (cdr (assoc 'total-pages data)) "?"))
           (status    (or (cdr (assoc 'status data)) "reading"))
           (last-read (or (cdr (assoc 'last-read data)) ""))
           (bookmarked (cdr (assoc 'bookmark-page data)))
           (date-str  (if (string-match "^\\([0-9-]+\\)T\\([0-9:]+\\)" last-read)
                          (format "%s %s"
                                  (match-string 1 last-read)
                                  (match-string 2 last-read))
                        last-read)))
      ;; Bookmark indicator
      (insert (if bookmarked " ★ " "   "))
      ;; Title button
      (insert-button
       (truncate-string-to-width title 38 nil nil "…")
       'action   (lambda (b) (manga--resume-reading (button-get b 'manga-id)))
       'manga-id id
       'face     'manga-title
       'follow-link t)
      (insert
       (format "  %-8s  %-6s  %-10s  %s\n"
               (propertize (format "Ch.%s" chapter) 'face 'manga-chapter)
               (format "p.%s/%s" page total-p)
               (propertize status
                           'face (if (equal status "completed")
                                     'manga-status-completed
                                   'manga-status-reading))
               (propertize date-str 'face 'manga-label))))))

(defun manga-library--render-local-files (files)
  "Render local library FILES to current buffer."
  (dolist (f files)
    (insert " ")
    (insert-button
     (truncate-string-to-width (file-name-nondirectory f) 55 nil nil "…")
     'action   (lambda (b) (manga-open-local (button-get b 'path)))
     'path     f
     'face     'manga-subtitle
     'follow-link t)
    (insert
     (propertize
      (format "  [%s]\n"
              (if (file-directory-p f) "folder"
                (file-name-extension f)))
      'face 'manga-label))))

;;; ─── Entry management ────────────────────────────────────────────────────────

(defun manga-library--delete-entry-at-point ()
  "Delete the library entry on the current line."
  (interactive)
  (let ((btn (button-at (point))))
    (if (and btn (button-get btn 'manga-id))
        (let ((id (button-get btn 'manga-id)))
          (when (yes-or-no-p (format "Delete history for \"%s\"? "
                                     (manga--progress-get id 'title)))
            (remhash id manga--progress)
            (manga--progress-save)
            (manga-library)
            (message "manga: entry deleted")))
      (message "manga: no entry at point (move cursor to a title)"))))

;;; ─── Status management ───────────────────────────────────────────────────────

(defun manga-mark-completed (manga-id)
  "Mark MANGA-ID as completed."
  (interactive
   (list (completing-read "Mark completed: "
                          (let (ids)
                            (maphash (lambda (k _) (push k ids)) manga--progress)
                            ids))))
  (manga--progress-update manga-id 'status "completed")
  (message "manga: marked %s as completed" (manga--progress-get manga-id 'title)))

(defun manga-mark-reading (manga-id)
  "Mark MANGA-ID as currently reading."
  (interactive
   (list (completing-read "Mark reading: "
                          (let (ids)
                            (maphash (lambda (k _) (push k ids)) manga--progress)
                            ids))))
  (manga--progress-update manga-id 'status "reading")
  (message "manga: marked %s as reading" (manga--progress-get manga-id 'title)))

(provide 'manga-library)
;;; manga-library.el ends here
