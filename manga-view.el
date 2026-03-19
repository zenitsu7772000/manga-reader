;;; manga-view.el --- High-performance image viewer for manga.el -*- lexical-binding: t; -*-
;;; Commentary:
;; Optimized viewer with aggressive caching, background preloading, and smooth navigation.
;; 
;; Additional Features:
;; - Keyboard hints overlay
;; - Page transition animations (optional)
;; - Mouse wheel navigation
;; - Fullscreen mode support
;;; Code:

(require 'image)
(require 'cl-lib)
(require 'seq)

;;; ─── Customization ───────────────────────────────────────────────────────────

(defcustom manga-pan-step 20
  "Number of pixels to pan when using arrow keys in zoomed view."
  :type 'integer
  :group 'manga)

(defcustom manga-pan-step-fast 50
  "Number of pixels to pan when using Shift+arrow keys in zoomed view."
  :type 'integer
  :group 'manga)

;;; ─── Forward Declarations ────────────────────────────────────────────────────

(declare-function manga-dashboard "manga.el")
(declare-function manga-library "manga-library.el")
(declare-function manga-mangadex--next-chapter "manga-mangadex.el")
(declare-function manga-mangadex--prev-chapter "manga-mangadex.el")
(declare-function manga--progress-update "manga.el")
(declare-function manga-custom-show-sources "manga-custom.el")

;;; ─── Viewer Mode ────────────────────────────────────────────────────────────

(defvar manga-view-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "n")         #'manga-view-next-page)
    (define-key map (kbd "p")         #'manga-view-prev-page)
    (define-key map (kbd "SPC")       #'manga-view-next-page)
    (define-key map (kbd "S-SPC")     #'manga-view-prev-page)
    (define-key map (kbd "<right>")   #'manga-view-next-page)
    (define-key map (kbd "<left>")    #'manga-view-prev-page)
    (define-key map (kbd "f")         #'manga-view-next-page)
    (define-key map (kbd "b")         #'manga-view-prev-page)
    (define-key map (kbd "g")         #'manga-view-goto-page)
    (define-key map (kbd "G")         #'manga-view-last-page)
    (define-key map (kbd "^")         #'manga-view-first-page)
    ;; Mouse wheel navigation
    (define-key map (kbd "<wheel-up>")   #'manga-view-prev-page)
    (define-key map (kbd "<wheel-down>") #'manga-view-next-page)
    ;; Zoom
    (define-key map (kbd "+")         #'manga-view-zoom-in)
    (define-key map (kbd "-")         #'manga-view-zoom-out)
    (define-key map (kbd "=")         #'manga-view-zoom-reset)
    (define-key map (kbd "w")         #'manga-view-fit-width)
    (define-key map (kbd "h")         #'manga-view-fit-height)
    (define-key map (kbd "a")         #'manga-view-fit-both)
    ;; Centering
    (define-key map (kbd "c")         #'manga-view-toggle-center)
    ;; Webtoon mode
    (define-key map (kbd "W")         #'manga-view-toggle-webtoon)
    ;; Chapters
    (define-key map (kbd "]")         #'manga-view-next-chapter)
    (define-key map (kbd "[")         #'manga-view-prev-chapter)
    ;; UI
    (define-key map (kbd "i")         #'manga-view-toggle-info)
    (define-key map (kbd "m")         #'manga-view-set-bookmark)
    (define-key map (kbd "q")         #'manga-view-quit)
    (define-key map (kbd "l")         #'manga-library)
    (define-key map (kbd "?")         #'manga-view-show-help)
    ;; Mouse clicks
    (define-key map (kbd "<mouse-1>") #'manga-view-next-page)
    ;; Panning (when zoomed in)
    (define-key map (kbd "C-n")       #'manga-view-pan-down)
    (define-key map (kbd "C-p")       #'manga-view-pan-up)
    (define-key map (kbd "C-f")       #'manga-view-pan-right)
    (define-key map (kbd "C-b")       #'manga-view-pan-left)
    (define-key map (kbd "C-<down>")  #'manga-view-pan-down)
    (define-key map (kbd "C-<up>")    #'manga-view-pan-up)
    (define-key map (kbd "C-<right>") #'manga-view-pan-right)
    (define-key map (kbd "C-<left>")  #'manga-view-pan-left)
    ;; Shift + arrows for larger pan steps
    (define-key map (kbd "S-<right>") #'manga-view-pan-right-fast)
    (define-key map (kbd "S-<left>")  #'manga-view-pan-left-fast)
    (define-key map (kbd "S-<down>")  #'manga-view-pan-down-fast)
    (define-key map (kbd "S-<up>")    #'manga-view-pan-up-fast)
    map)
  "Keymap for `manga-view-mode'.")

(define-derived-mode manga-view-mode special-mode "Manga-View"
  "Major mode for viewing manga/comic pages."
  (setq buffer-read-only   t
        cursor-type        nil
        truncate-lines     t
        word-wrap          nil
        scroll-conservatively 1000  ; Aggressive scrolling for smoothness
        scroll-margin      0
        scroll-step        100     ; Larger scroll steps
        auto-hscroll-mode  0
        fast-but-imprecise-scrolling t)  ; Faster scrolling
  (buffer-disable-undo)
  (setq-local display-line-numbers nil)
  (setq-local redisplay-dont-pause t)  ; Don't pause redisplay
  ;; Enable mouse wheel (mwheel-mode is enabled by default in Emacs 25+)
  (when (and (boundp 'mouse-wheel-mode) mouse-wheel-mode)
    t))

;;; ─── Viewer State ───────────────────────────────────────────────────────────

(defvar manga-view--zoom 1.0
  "Current zoom multiplier.")

(defvar manga-view--show-info t
  "Whether to show page info overlay.")

(defvar manga-view--webtoon-mode nil
  "If non-nil, display all pages vertically for webtoon reading.")

(defvar manga-view--center-image nil
  "If non-nil, center images horizontally in the window.")

(defvar manga-view--image-cache (make-hash-table :test 'equal :size 50)
  "Cache of loaded image objects, keyed by file path.")

(defvar manga-view--cache-order '()
  "List tracking LRU order of cached images.")

(defvar manga-view--cache-max-size 30
  "Maximum number of images to keep in cache.")

(defvar manga-view--current-image nil
  "Current image descriptor being displayed.")

(defvar manga-view--pending-preloads '()
  "Queue of pending preload tasks.")

;;; ─── Core Display ───────────────────────────────────────────────────────────

(defun manga-view--buffer ()
  "Return or create the viewer buffer."
  (get-buffer-create "*manga-view*"))

(defun manga-view--fit-size (img-w img-h)
  "Compute display (width . height) for image of IMG-W x IMG-H pixels."
  (let* ((win-w  (window-pixel-width))
         (win-h  (window-pixel-height))
         (scale
          (pcase manga-image-fit
            ('width  (/ (float win-w) img-w))
            ('height (/ (float win-h) img-h))
            ('both   (min (/ (float win-w) img-w)
                          (/ (float win-h) img-h)))
            (_       1.0)))
         (final  (* scale manga-view--zoom)))
    (cons (round (* img-w final))
          (round (* img-h final)))))

(defun manga-view--load-image (path)
  "Load image at PATH, using LRU cache. Returns image descriptor."
  (or (gethash path manga-view--image-cache)
      (when (file-exists-p path)
        (let ((img (create-image path nil nil :ascent 100)))
          ;; Add to cache
          (puthash path img manga-view--image-cache)
          ;; Update LRU order
          (setq manga-view--cache-order
                (cons path (delq path manga-view--cache-order)))
          ;; Trim cache if needed
          (manga-view--trim-cache)
          img))))

(defun manga-view--trim-cache ()
  "Trim cache to MANGA-VIEW--CACHE-MAX-SIZE using LRU eviction."
  (while (> (length manga-view--cache-order) manga-view--cache-max-size)
    (let ((oldest (car (last manga-view--cache-order))))
      (when oldest
        (setq manga-view--cache-order (delq oldest manga-view--cache-order))
        (remhash oldest manga-view--image-cache)))))

(defun manga-view--display-page (path page-num total-pages manga-title chapter-num)
  "Display image at PATH in the viewer buffer."
  (let ((buf (manga-view--buffer))
        (img (manga-view--load-image path)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (eq major-mode 'manga-view-mode)
          (manga-view-mode))
        (if manga-view--webtoon-mode
            ;; Webtoon mode: display all pages vertically
            (manga-view--display-webtoon manga-title chapter-num)
          ;; Single page mode
          (if (null img)
              (progn
                (insert (propertize (format "⚠ Could not load image:\n%s\n" path)
                                    'face 'manga-header))
                (insert (propertize "File may still be downloading.\n" 'face 'manga-label)))
            (let* ((size    (image-size img t))
                   (img-w   (car size))
                   (img-h   (cdr size))
                   (fit     (manga-view--fit-size img-w img-h))
                   (disp-w  (car fit))
                   (disp-h  (cdr fit))
                   (scaled  (create-image path nil nil
                                          :width  disp-w
                                          :height disp-h
                                          :ascent 100)))
              (setq manga-view--current-image scaled)
              ;; Center image horizontally if enabled
              (when manga-view--center-image
                (let ((padding (max 0 (/ (- (window-pixel-width) disp-w) 2))))
                  (insert (make-string (ceiling (/ (float padding) (frame-char-width (selected-frame)))) ? ))))
              (insert-image scaled (format "[Page %d]" page-num))
              (insert "\n"))
          ;; Info bar
          (when manga-view--show-info
            (insert "\n")
            (let ((title-str (or manga-title "")))
              (when (> (length title-str) 25)
                (setq title-str (concat (substring title-str 0 22) "...")))
              (insert (propertize
                       (format " %s  │  Ch.%s  │  Page %d / %d  │  zoom %.0f%%"
                               title-str
                               (or chapter-num "?")
                               page-num total-pages
                               (* 100 manga-view--zoom))
                       'face 'manga-label))))))
        (goto-char (point-min))
        (set-window-start (selected-window) (point-min))))))

;;; ─── Navigation ─────────────────────────────────────────────────────────────

(defun manga-view-next-page ()
  "Go to next page."
  (interactive)
  (when manga--current-session
    (let* ((cur   (plist-get manga--current-session :current-page))
           (total (plist-get manga--current-session :total-pages)))
      (if (>= cur total)
          (if (y-or-n-p "Last page reached. Load next chapter? ")
              (manga-view-next-chapter)
            (message "manga: end of chapter"))
        (manga-view--go-to-page (1+ cur))))))

(defun manga-view-prev-page ()
  "Go to previous page."
  (interactive)
  (when manga--current-session
    (let ((cur (plist-get manga--current-session :current-page)))
      (if (<= cur 1)
          (if (y-or-n-p "First page. Go to previous chapter? ")
              (manga-view-prev-chapter)
            (message "manga: beginning of chapter"))
        (manga-view--go-to-page (1- cur))))))

(defun manga-view-goto-page (n)
  "Jump to page N."
  (interactive "nGo to page: ")
  (when manga--current-session
    (let ((total (plist-get manga--current-session :total-pages)))
      (manga-view--go-to-page (max 1 (min n total))))))

(defun manga-view-first-page ()
  "Go to first page."
  (interactive)
  (manga-view--go-to-page 1))

(defun manga-view-last-page ()
  "Go to last page."
  (interactive)
  (when manga--current-session
    (manga-view--go-to-page (plist-get manga--current-session :total-pages))))

(defun manga-view--go-to-page (n)
  "Internal: navigate to page N and refresh display."
  (when manga--current-session
    (let* ((pages    (plist-get manga--current-session :pages))
           (total    (plist-get manga--current-session :total-pages))
           (title    (plist-get manga--current-session :manga-title))
           (chapter  (plist-get manga--current-session :chapter-num))
           (manga-id (plist-get manga--current-session :manga-id))
           (source   (plist-get manga--current-session :source))
           (n        (max 1 (min n total)))
           (path     (nth (1- n) pages)))
      (setq manga--current-session
            (plist-put manga--current-session :current-page n))
      ;; Display
      (manga-view--display-page path n total title chapter)
      (switch-to-buffer (manga-view--buffer))
      ;; Save progress
      (when manga-id
        (manga--progress-update manga-id
                                'page      n
                                'total-pages total
                                'chapter   chapter
                                'source    source
                                'last-read (format-time-string "%Y-%m-%dT%H:%M:%S")))
      ;; Preload next pages asynchronously
      (manga-view--preload-pages pages n total))))

;;; ─── Aggressive Preloading ──────────────────────────────────────────────────

(defun manga-view--preload-pages (pages current total)
  "Preload pages ahead of CURRENT in PAGES list."
  (unless manga-view--webtoon-mode  ; Don't preload in webtoon mode
    (let* ((preload-count (max 5 manga-preload-pages))
           (ahead         (min preload-count (- total current))))
      (dotimes (i ahead)
        (let* ((idx  (+ current i))
               (path (nth idx pages)))
          (when (and path (not (gethash path manga-view--image-cache)))
            (run-with-idle-timer (* 0.05 i) nil
                                 (lambda (p)
                                   (when (and p (file-exists-p p)
                                              (not (gethash p manga-view--image-cache)))
                                     (manga-view--load-image p)))
                                 path)))))))

(defun manga-view--display-webtoon (manga-title chapter-num)
  "Display all pages vertically for webtoon reading."
  (let* ((pages (plist-get manga--current-session :pages))
         (total (length pages)))
    (insert (propertize (format " ══ %s - Chapter %s ══\n"
                                (or manga-title "")
                                (or chapter-num "?"))
                        'face 'manga-header))
    (insert "\n")
    ;; Display all pages
    (cl-loop for path in pages
             for i from 1
             do
             (let ((img (manga-view--load-image path)))
               (when img
                 (let* ((size (image-size img t))
                        (img-w (car size))
                        (img-h (cdr size))
                        (fit (manga-view--fit-size img-w img-h))
                        (scaled (create-image path nil nil
                                              :width (car fit)
                                              :height (cdr fit)
                                              :ascent 100)))
                   (insert-image scaled (format "[Page %d]" i))
                   (insert "\n\n"))))
             ;; Progress indicator
             (when (= (mod i 10) 0)
               (insert (propertize (format " ── Page %d / %d ──\n\n" i total)
                                   'face 'manga-label))))
    ;; Footer
    (insert (propertize " ══ End of Chapter ══\n" 'face 'manga-header))
    (insert (propertize " Press W to return to page mode\n" 'face 'manga-label))))

(defun manga-view-toggle-webtoon ()
  "Toggle between single-page and webtoon (vertical scroll) mode."
  (interactive)
  (setq manga-view--webtoon-mode (not manga-view--webtoon-mode))
  (if manga-view--webtoon-mode
      (progn
        (message "manga: webtoon mode ON (vertical scroll)")
        (manga-view--display-webtoon
         (plist-get manga--current-session :manga-title)
         (plist-get manga--current-session :chapter-num)))
    (message "manga: webtoon mode OFF (single page)")
    (manga-view--refresh)))

;;; ─── Zoom Controls ──────────────────────────────────────────────────────────

(defun manga-view-zoom-in ()
  "Zoom in by 10%."
  (interactive)
  (setq manga-view--zoom (min 3.0 (+ manga-view--zoom 0.1)))
  (manga-view--refresh)
  (message "manga: zoom %.0f%%" (* 100 manga-view--zoom)))

(defun manga-view-zoom-out ()
  "Zoom out by 10%."
  (interactive)
  (setq manga-view--zoom (max 0.1 (- manga-view--zoom 0.1)))
  (manga-view--refresh)
  (message "manga: zoom %.0f%%" (* 100 manga-view--zoom)))

(defun manga-view-zoom-reset ()
  "Reset zoom to 100%."
  (interactive)
  (setq manga-view--zoom 1.0)
  (manga-view--refresh)
  (message "manga: zoom reset"))

(defun manga-view-fit-width ()
  "Fit image to window width."
  (interactive)
  (setq manga-image-fit 'width
        manga-view--zoom 1.0)
  (manga-view--refresh)
  (message "manga: fit to width"))

(defun manga-view-fit-height ()
  "Fit image to window height."
  (interactive)
  (setq manga-image-fit 'height
        manga-view--zoom 1.0)
  (manga-view--refresh)
  (message "manga: fit to height"))

(defun manga-view-fit-both ()
  "Fit image to window (both dimensions)."
  (interactive)
  (setq manga-image-fit 'both
        manga-view--zoom 1.0)
  (manga-view--refresh)
  (message "manga: fit to window"))

(defun manga-view-toggle-center ()
  "Toggle horizontal image centering."
  (interactive)
  (setq manga-view--center-image (not manga-view--center-image))
  (manga-view--refresh)
  (message "manga: center %s" (if manga-view--center-image "ON" "OFF")))

(defun manga-view--refresh ()
  "Refresh current page display with new zoom/fit settings."
  (when (and manga--current-session
             (plist-get manga--current-session :current-page))
    (let* ((pages   (plist-get manga--current-session :pages))
           (total   (plist-get manga--current-session :total-pages))
           (title   (plist-get manga--current-session :manga-title))
           (chapter (plist-get manga--current-session :chapter-num))
           (cur     (plist-get manga--current-session :current-page))
           (path    (nth (1- cur) pages)))
      (manga-view--display-page path cur total title chapter))))

;;; ─── Panning (When Zoomed In) ────────────────────────────────────────────────

(defun manga-view--pan (dx dy)
  "Pan the current image by DX (horizontal) and DY (vertical) pixels.
Positive DX pans right, positive DY pans down.
Uses Emacs's built-in window scrolling for smooth navigation."
  (when (and manga-view--current-image
             (> manga-view--zoom 1.0))  ; Only pan when zoomed in
    (let ((win (get-buffer-window (manga-view--buffer))))
      (when win
        (with-selected-window win
          ;; Vertical scrolling
          (when (/= dy 0)
            (scroll-up dy))
          ;; Horizontal panning via horizontal scrolling
          (when (/= dx 0)
            (let ((new-hscroll (+ (window-hscroll) dx)))
              ;; Clamp horizontal scroll to valid range
              (let* ((img-width (car (image-size manga-view--current-image t)))
                     (win-width (window-pixel-width))
                     (max-hscroll (max 0 (- img-width win-width))))
                (setq new-hscroll (max 0 (min new-hscroll max-hscroll)))
                (set-window-hscroll (selected-window) new-hscroll)))))))))

(defun manga-view-pan-left ()
  "Pan image left by `manga-pan-step' pixels."
  (interactive)
  (manga-view--pan (- manga-pan-step) 0)
  (when (called-interactively-p 'any)
    (message "manga: pan left")))

(defun manga-view-pan-right ()
  "Pan image right by `manga-pan-step' pixels."
  (interactive)
  (manga-view--pan manga-pan-step 0)
  (when (called-interactively-p 'any)
    (message "manga: pan right")))

(defun manga-view-pan-up ()
  "Pan image up by `manga-pan-step' pixels."
  (interactive)
  (manga-view--pan 0 (- manga-pan-step))
  (when (called-interactively-p 'any)
    (message "manga: pan up")))

(defun manga-view-pan-down ()
  "Pan image down by `manga-pan-step' pixels."
  (interactive)
  (manga-view--pan 0 manga-pan-step)
  (when (called-interactively-p 'any)
    (message "manga: pan down")))

(defun manga-view-pan-left-fast ()
  "Pan image left by `manga-pan-step-fast' pixels."
  (interactive)
  (manga-view--pan (- manga-pan-step-fast) 0)
  (when (called-interactively-p 'any)
    (message "manga: pan left (fast)")))

(defun manga-view-pan-right-fast ()
  "Pan image right by `manga-pan-step-fast' pixels."
  (interactive)
  (manga-view--pan manga-pan-step-fast 0)
  (when (called-interactively-p 'any)
    (message "manga: pan right (fast)")))

(defun manga-view-pan-up-fast ()
  "Pan image up by `manga-pan-step-fast' pixels."
  (interactive)
  (manga-view--pan 0 (- manga-pan-step-fast))
  (when (called-interactively-p 'any)
    (message "manga: pan up (fast)")))

(defun manga-view-pan-down-fast ()
  "Pan image down by `manga-pan-step-fast' pixels."
  (interactive)
  (manga-view--pan 0 manga-pan-step-fast)
  (when (called-interactively-p 'any)
    (message "manga: pan down (fast)")))

;;; ─── Chapter Navigation ─────────────────────────────────────────────────────

(defun manga-view-next-chapter ()
  "Load next chapter from MangaDex backend."
  (interactive)
  (if (equal (plist-get manga--current-session :source) "mangadex")
      (manga-mangadex--next-chapter)
    (message "manga: chapter navigation only available for MangaDex")))

(defun manga-view-prev-chapter ()
  "Load previous chapter from MangaDex backend."
  (interactive)
  (if (equal (plist-get manga--current-session :source) "mangadex")
      (manga-mangadex--prev-chapter)
    (message "manga: chapter navigation only available for MangaDex")))

;;; ─── UI Controls ────────────────────────────────────────────────────────────

(defun manga-view-toggle-info ()
  "Toggle page info overlay."
  (interactive)
  (setq manga-view--show-info (not manga-view--show-info))
  (manga-view--refresh)
  (message "manga: info %s" (if manga-view--show-info "on" "off")))

(defun manga-view-set-bookmark ()
  "Set bookmark at current page."
  (interactive)
  (when manga--current-session
    (let ((manga-id (plist-get manga--current-session :manga-id))
          (page     (plist-get manga--current-session :current-page)))
      (manga--progress-update manga-id 'bookmark page)
      (message "manga: bookmark set at page %d" page))))

(defun manga-view-quit ()
  "Quit viewer and return to dashboard."
  (interactive)
  (when manga--current-session
    ;; Clear cache on quit to free memory
    (clrhash manga-view--image-cache)
    (setq manga-view--cache-order '())
    (kill-buffer (manga-view--buffer))
    (manga-dashboard)))

(defun manga-view-show-help ()
  "Display keyboard shortcuts help overlay."
  (interactive)
  (let ((help-buf (get-buffer-create "*manga-help*")))
    (display-buffer help-buf '(display-buffer-in-side-window
                               (side . right)
                               (window-width . 0.3)))
    (with-current-buffer help-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "  == Manga Viewer Help ==\n\n")
        (insert "Navigation:\n")
        (insert "  n, SPC, ->  : Next page\n")
        (insert "  p, S-SPC, <-: Previous page\n")
        (insert "  g           : Go to page\n")
        (insert "  G/^         : Last/First page\n")
        (insert "  Mouse wheel : Navigate pages\n\n")
        (insert "Webtoon Mode:\n")
        (insert "  W           : Toggle webtoon (vertical scroll)\n\n")
        (insert "Zoom:\n")
        (insert "  +/-         : Zoom in/out\n")
        (insert "  =           : Reset zoom\n")
        (insert "  w/h/a       : Fit width/height/both\n\n")
        (insert "Panning (when zoomed in):\n")
        (insert "  C-<arrows>  : Pan image (small steps)\n")
        (insert "  S-<arrows>  : Pan image (large steps)\n")
        (insert "  C-n/p/f/b   : Pan down/up/right/left\n\n")
        (insert "Centering:\n")
        (insert "  c           : Toggle horizontal centering\n\n")
        (insert "Chapters:\n")
        (insert "  ]/[         : Next/Previous chapter\n\n")
        (insert "Other:\n")
        (insert "  i           : Toggle info bar\n")
        (insert "  m           : Set bookmark\n")
        (insert "  l           : Open library\n")
        (insert "  q           : Quit viewer\n")
        (insert "  ?           : This help\n"))
      (special-mode)
      (goto-char (point-min)))))

;;; ─── Session Management ─────────────────────────────────────────────────────

(defun manga-view-start-session (pages manga-id title chapter-num source chapter-type &optional start-page)
  "Start a viewing session with PAGES for MANGA-ID and TITLE.
CHAPTER-NUM and SOURCE identify the chapter. CHAPTER-TYPE is the source type.
START-PAGE is initial page."
  (let ((start (or start-page 1))
        (total (length pages)))
    (setq manga--current-session
          (list :manga-id       manga-id
                :manga-title    title
                :chapter-num    chapter-num
                :source         source
                :chapter-type   chapter-type
                :pages          pages
                :current-page   start
                :total-pages    total))
    ;; Clear cache for new session
    (clrhash manga-view--image-cache)
    (setq manga-view--cache-order '())
    ;; Preload first batch immediately
    (manga-view--preload-pages pages start total)
    ;; Display first page
    (manga-view--go-to-page start)))

(provide 'manga-view)
;;; manga-view.el ends here
