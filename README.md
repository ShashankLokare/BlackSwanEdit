# BlackSwanEdit (macOS)

BlackSwanEdit is a lightweight macOS text editor (Notepad/UltraEdit-style) built with SwiftUI + AppKit, using a custom CoreText renderer and a piece-chain text buffer for fast editing.

## Features

- File/workspace
  - New File, Open, Open Folder (workspace), Save, Save As, Save All, Close, Close All
  - Unsaved-changes prompts on close and app quit
  - Autosave + recovery on next launch (best-effort)
- Editing
  - Typing, selection, caret movement, copy/cut/paste, select-all
  - Undo/redo (document-local snapshot stack)
- Find
  - Find / Replace (current file)
  - Find in Files (workspace folder), results sidebar, click-to-open + select match
- Syntax highlighting + language control
  - Auto-detect by file extension / shebang
  - Manual per-document override via Language menu
  - Bundled languages: Swift, Python, Shell Script, JavaScript, TypeScript, JavaScript (JSX), JSON, XML, YAML, Ruby, Markdown, TOML, Mermaid, Plain Text
- Formatting
  - Built-in: JSON pretty-print, XML pretty-print
  - External (optional): Python (black), Shell (shfmt), Web/JS/TS/JSX/JSONC/YAML/HTML/CSS/Markdown (prettier), TOML (taplo)
- Reading / previews (offline)
  - Mermaid preview window (renders `.mmd`/`.mermaid` and Markdown ```mermaid blocks)
  - JSX preview window (renders `.jsx` and Markdown ```jsx blocks) using bundled React/ReactDOM/Babel
- Extras
  - Source Control sidebar (git status)
  - Hex mode view for documents

## Keyboard Shortcuts

- File
  - New: `Cmd+N`
  - Open: `Cmd+O`
  - Open Folder: `Cmd+Shift+O`
  - Save: `Cmd+S`
  - Save As: `Cmd+Shift+S`
  - Save All: `Cmd+Option+S`
  - Close: `Cmd+W`
  - Close All: `Cmd+Option+W`
- Find
  - Find: `Cmd+F`
  - Find in Files: `Cmd+Shift+F`
  - Find Next: `Cmd+G`
  - Find Previous: `Cmd+Shift+G`
  - Replace: `Cmd+Option+F`
- Transform
  - Format Document: `Cmd+Option+L`
- View
  - Mermaid Preview: `Cmd+Option+P`
  - JSX Preview: `Cmd+Option+J`

## Build and Run

From this directory:

```sh
swift build
swift run BlackSwanEditApp
```

Core tests are run via the included runner:

```sh
swift run BlackSwanEditCoreTestRunner
```

Note: `swift test` may not work on machines that only have Command Line Tools installed (XCTest framework is typically provided by full Xcode).

## Optional Formatter Dependencies

Formatting integrates with external tools if they are installed and available on `PATH`:

- `black` (Python)
- `shfmt` (shell)
- `prettier` (JS/TS/JSX/JSONC/YAML/HTML/CSS/MD)
- `taplo` (TOML)

If a tool is missing, Format Document will report that the formatter is not installed.

## Known Limitations (Current)

- Syntax highlighting uses simple regex token rules (not full parsers), and tokenization is line-based.
- JSX preview module support is intentionally limited:
  - Supports relative imports (`./`, `../`) for `.js`/`.jsx` files on disk (and `index.js`/`index.jsx`)
  - Does not resolve `node_modules` packages (except a small built-in externals mapping for React runtimes)
- Find in Files currently caps the number of scanned files for responsiveness.

