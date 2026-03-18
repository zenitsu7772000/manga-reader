# manga.el — Manga & Comic Reader for Emacs

> Read manga and comics without leaving Emacs. Local CBZ/CBR support with progress tracking.

![Version](https://img.shields.io/badge/version-1.1.0-blue)
![Emacs](https://img.shields.io/badge/Emacs-27.1+-7F5AB6?logo=gnuemacs)
![License](https://img.shields.io/badge/license-GPL--3.0-green)

---

## Features

| Feature | Details |
|---------|---------|
| Local files | CBZ, CBR, ZIP, and image folders |
| Image viewer | Fit-to-width, fit-to-height, zoom in/out |
| Progress tracking | Remembers chapter + page across sessions |
| Bookmarks | Bookmark any page in any manga |
| Library | Browse history, local files, reading status |
| Preloading | Background preloads next pages while you read |
| Concurrent downloads | 4 parallel page downloads (configurable) |
| Smart caching | LRU image cache + API response cache (5min TTL) |
| Mouse support | Mouse wheel navigation + click to navigate |
| Help overlay | Press `?` to view all keybindings |

---

## Dependencies

**Required:**
- `unzip` — for CBZ files (`sudo apt install unzip` / `brew install unzip`)

**Optional:**
- `unar` — for CBR/RAR files (`sudo apt install unar` / `brew install unar`)

**Emacs must be compiled with image support** (most standard builds are):
- Ubuntu: `sudo apt install emacs`
- Mac: `brew install emacs-plus`
- Check: `M-: (display-images-p)` should return `t`

---

## Installation

### Manual

```
manga-reader/
├── manga.el           ← load this one
├── manga-view.el
├── manga-local.el
└── manga-library.el
```

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/manga-reader/")
(require 'manga)
```

### use-package

```elisp
(use-package manga
  :load-path "~/.emacs.d/lisp/manga-reader/"
  :commands (manga manga-open-local manga-library)
  :custom
  (manga-library-dir    "~/manga/")
  (manga-download-dir   "~/manga-downloads/")
  (manga-image-fit      'width)
  (manga-preload-pages  3))
```

---

## Usage

| Command | Description |
|---|---|
| `M-x manga` | Open the dashboard |
| `M-x manga-open-local` | Open CBZ/CBR/folder |
| `M-x manga-library` | Reading history & bookmarks |
| `M-x manga-continue-reading` | Resume last read |

### Viewer keybindings

| Key | Action |
|---|---|
| `n` / `SPC` / `→` | Next page |
| `p` / `S-SPC` / `←` | Previous page |
| `g` | Jump to page number |
| `^` / `G` | First / last page |
| `]` / `[` | Next / previous chapter |
| `+` / `-` | Zoom in / out |
| `=` | Reset zoom |
| `w` / `h` / `a` | Fit to width / height / both |
| `W` | **Toggle webtoon mode (vertical scroll)** |
| `m` | Set bookmark |
| `i` | Toggle info bar |
| `l` | Open library |
| `q` | Quit viewer |

---

## Configuration

```elisp
;; Where your local manga collection lives
(setq manga-library-dir "~/manga/")

;; Where downloaded chapters get cached
(setq manga-download-dir "~/manga-downloads/")

;; Image scaling: 'width 'height 'both 'none
(setq manga-image-fit 'width)

;; Pages to preload ahead
(setq manga-preload-pages 3)

;; Reading direction: 'ltr (comics) or 'rtl (manga)
(setq manga-reading-direction 'rtl)

;; Where progress is saved
(setq manga-progress-file "~/.emacs.d/manga-progress.el")
```

---

## How it works

```
manga-open-local → unzip CBZ/CBR → collect images → manga-view
```

Downloaded chapters are cached in `manga-download-dir` — re-opening a chapter is instant.

---

## Support Development

If manga.el brings you joy, consider a small tip:

**Bitcoin (BTC):**
```
1Eu1bniUn1oot55RcRCj2q5QJwa4GtBkk7
```

**Ethereum (ETH):**
```
0xe1c6864fdddcef5b5c63b2ea62af91395b569e36
```

---

## Roadmap

### In Progress / Planned
- [ ] Two-page spread mode
- [ ] Reading statistics & time tracking
- [ ] Thumbnail browser
- [ ] MAL/AniList integration for ratings
- [ ] Download progress bar
- [ ] Chapter download queue manager
- [ ] Night mode / dark theme
- [ ] Fullscreen mode
- [ ] Session restore on Emacs restart
- [ ] Export reading list to CSV
- [ ] MELPA submission
- [ ] Unit tests (ERT)
- [ ] GitHub Actions CI

---

## License

GPL-3.0 — See [LICENSE](LICENSE) for full text.
