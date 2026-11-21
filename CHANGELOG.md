# Changelog

## 1.0.5 — 2026-11-21

- Browse the full release history in the new Changelog view. What's New shows the changes when you first open a new version.
- Safe Sweep selects rebuildable folders. Tool tasks require explicit confirmation, and Husk rechecks linked worktrees for local changes, untracked and ignored files, locks, and merge status before removing them.
- Cleanup checks each path component for symlinks and verifies that the target still matches the scan.
- Cleanup runs in the background. Tool commands have a time limit, and reports distinguish items moved to Trash from observed free space gained.
- In-app updates use HTTPS and verify a release signature before extracting the app.

## 1.0.4 — 2026-11-20

- Added the Worktrees view for linked Git checkouts, with merge, lock, and stale registration status.
- Added Git-native worktree removal and pruning, plus copyable commands for recreating branch-based worktrees.
- Avoided counting build artifacts twice when they are already included in a worktree's size.

## 1.0.3 — 2026-11-20

- Added a labeled storage bar that shows disk usage by category.
- Hover over a segment to see its size, or click it to filter the results.

## 1.0.2 — 2026-11-20

- Added one-click updates that download the release, replace the installed app, and relaunch Husk.
- Added update progress and release notes to Settings and the update banner.

## 1.0.1 — 2026-11-20

- Restored compatibility with macOS 14 and later on Apple Silicon.
- Refined borders, backgrounds, and controls across the workspace, Settings, menu bar, and cleanup preview.
- Added a reset option for preferences and a one-line Terminal installer.

## 1.0.0 — 2026-11-20

- First release of Husk for Apple Silicon Macs.
- Scans developer workspaces and caches, measures allocated disk space, and flags active Git projects and protected items.
- Added Safe Sweep, the cleanup preview, Trash and restore, cleanup history, and copyable rebuild commands.
- Added a menu bar disk monitor, keyboard shortcuts, workspace exclusions, and update checks.
