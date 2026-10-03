# EasyMarkdown

A lightweight native macOS markdown editor/previewer. Plain-text editor on the left, rendered
preview on the right (or either one alone), live reload when the file changes on disk, scroll
sync, math, Mermaid diagrams, themes, and PDF export.

## Install

Requires macOS 13+ and the Xcode Command Line Tools (full Xcode not needed).

```sh
./install.sh                         # app → /Applications, `easymd` → ~/.local/bin
APP_DIR=~/Applications ./install.sh  # or pick locations (BIN_DIR too)
```

`./build.sh` alone produces `build/EasyMarkdown.app` without installing.

## Usage

```sh
easymd notes.md                 # open (creates the file if missing)
easymd a.md b.md                # multiple files, as tabs
easymd -p notes.md              # preview only (-e editor only, -s split)
easymd --pdf notes.md           # headless export → notes.pdf
easymd --pdf notes.md out.pdf
```

Documents open as tabs in the frontmost window, including files passed to `easymd` while the
app is already running. ⌘N and ⌘O (or the tab bar's + button) also open into a new tab; ⌥⌘N
starts a separate window, and tabs can be dragged out or merged back (Window menu).

Launching the app without a file (Dock, Spotlight, Finder) shows a welcome window with New,
Open and your recent files; you can also drop a markdown file onto it. ⇧⌘0 brings it back.

Edit in Neovim (or anything else) and save — the app reloads instantly. Atomic saves
(write-temp-then-rename) are handled. If you also have unsaved edits in the app, you're
asked which version to keep.

| Shortcut | Action |
|---|---|
| ⌘1 / ⌘2 / ⌘3 | Editor only / split / preview only (also in the toolbar) |
| ⌥⌘L | Toggle scroll sync |
| ⌘N, ⌥⌘N | New tab, new window |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘S, ⇧⌘S | Save, Save As |
| ⇧⌘E | Export as PDF |
| ⌘+ / ⌘- / ⌘0 | Font size (editor + preview) |
| ⌘F | Find |

## Rendering

[markdown-it](https://github.com/markdown-it/markdown-it) (CommonMark + GFM tables,
strikethrough, autolinks, task lists), [highlight.js](https://highlightjs.org) for code,
[KaTeX](https://katex.org) for `$inline$`, `$$display$$` and ```` ```math ```` blocks, and
[Mermaid](https://mermaid.js.org) for ```` ```mermaid ```` blocks — all bundled offline in
`Resources/web` (Mermaid is only loaded when a document uses it).

Themes live under View (or the palette button in the toolbar): Appearance (System/Light/Dark),
Preview Theme (GitHub, Paper, Nord, Solarized, Gruvbox, Tokyo Night) and Code Theme (match the
preview theme, or pick one of nine). The editor picks up the preview theme's colours.

Relative images resolve against the document's folder, heading anchors work, YAML front matter
is hidden, and PDFs always use the light variant of the current theme. Raw HTML is allowed, but scripts are blocked by a CSP.

## Layout

```
Sources/EasyMarkdown/   AppKit app (editor, preview, FSEvents watcher, PDF export)
Resources/web/          preview shell, CSS, vendored JS
Resources/icon/         app icon (SVG source + make-icon.sh → AppIcon.icns)
bin/easymd              CLI, bundled into the app
```
