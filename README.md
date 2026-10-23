# Git Extensions for macOS (GitExMac)

A personal, native SwiftUI take on [Git Extensions](https://gitextensions.github.io). Like the original, it drives the `git` CLI.

## Build & run

```bash
scripts/bundle.sh             # builds build/GitExMac.app
scripts/bundle.sh --install   # also copies it to /Applications
swift scripts/make-icon.swift  # re-renders Resources/AppIcon.icns
swift test                    # line staging, status/log parsing, graph layout
```

Repositories open as tabs in one window (⌘T / ⌘O to add, ⌘W to close, ⌃Tab / ⌘1…9 to switch).
Each tab shows the current branch and the number of changed files; open tabs are restored on launch.
From the terminal (or by dropping a folder on the Dock icon):

```bash
open -a GitExMac /path/to/repo
```

## Features

- Revision graph with branch/tag badges and an "Uncommitted changes" row, filter box, keyboard navigation
- Bottom pane: changed files + diff (parent picker for merges), commit info tab
- Sidebar: local branches, remotes, tags (double-click to checkout, context menu)
- Commit dialog (⌘K): stage/unstage/discard files, select lines or hunks in the diff to stage/unstage/discard, amend, push after commit
- Commit context menu: checkout, create branch/tag, merge, rebase, cherry-pick, revert, reset (soft/mixed/hard), delete branch/tag, copy SHA
- Dark mode by default (toggle in View → Dark Mode, ⇧⌘D)
- Fetch (⇧⌘F), pull merge/rebase (⇧⌘L), push / force-with-lease (⇧⌘P), banner to continue/abort a merge/rebase in progress

## Layout

- `Sources/GitExMac/Git` — git process runner, command wrappers, diff parsing + partial patches
- `Sources/GitExMac/Graph` — lane layout and drawing
- `Sources/GitExMac/Views` — SwiftUI windows and dialogs

Dev helpers: `GITEXMAC_SNAPSHOT=/tmp/shot` saves window PNGs after 4s; `GITEXMAC_OPEN_COMMIT=1` opens the commit dialog on launch.
