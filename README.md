# Husk — Minimal Native macOS Developer Disk & Cache Cleaner

**Husk** strips away heavy outer build husks (`node_modules`, Rust `target/`, Swift `.build/`, Python `.venv`, `.next`, `.gradle`), global package manager caches (`bun`, `pnpm`, `npm`, `yarn`, `cargo`, `uv`, `pip`, `Homebrew`), Xcode clutter (`DerivedData`, `DeviceSupport`, Simulator caches, `Archives`), and container/AI model caches (`HuggingFace Hub`, `Ollama`, `PyTorch`, `Docker`) — while keeping the seed (your source code) completely untouched.

## Features

- **Minimalist macOS 26+ Liquid Glass UI**: Built with native SwiftUI `.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, and a desktop-blending `NSVisualEffectView` backdrop.
- **5-Layer Safety Engine**:
  1. **Boundary & Symlink Guard**: Rejects symbolic links and blocks `/System`, `/Library`, `/Applications`, and personal directories (`~/.ssh`, `~/Documents`, `~/Desktop`, etc.).
  2. **Parent-Manifest Verification**: Only flags build directories (`target`, `build`, `.build`, `node_modules`) when paired with their sibling manifest (`Cargo.toml`, `build.gradle`, `Package.swift`, `package.json`, `pyproject.toml`).
  3. **Active-Project Shield**: Inspects `.git` activity, dirty tracked worktree state (`git status --porcelain`), and active lockfiles. Active repositories are badged **Active** and excluded from automatic selection.
  4. **Regenerability Tiers**: Separates 100% rebuildable local artifacts from downloadable global caches and protected archives/AI weights.
  5. **Trash-First & 1-Click Undo**: Relocates items to macOS Trash by default and logs every session in `~/Library/Application Support/Husk/audit-logs/` with 1-click restoration.
- **Smart Views**:
  - **1-Click Safe Sweep**: Selects only Tier 1 rebuildable artifacts untouched for 30+ days in clean repositories.
  - **Dormant & Read-Only Clones**: Identifies repositories cloned once with `0` local commits or untouched for `120+ days`.
  - **Native Tool Subcommand Tasks**: Non-destructively compacts `.git/objects` packfiles (`git gc --prune=now`), deletes dead simulators (`xcrun simctl delete unavailable`), and prunes Homebrew caches (`brew cleanup --prune=all -s`).
  - **Context-Aware Rebuild Commands & Scripts**: Infers lockfile-specific rebuild commands (`bun install`, `pnpm install`, `cargo build`, `swift build`, `uv sync`) per project and generates a session-wide re-bootstrap script.
- **Full Settings Panel (`⌘,`) & Built-In Updater**:
  - Configure safety windows, scan depth, excluded/pinned project folders, menu bar alert thresholds, and Launch at Login (`SMAppService`).
  - Built-in **Check for Updates…** supporting both **GitHub Releases API** (`owner/repo`) and a **Website JSON Manifest** (`https://your-site.com/latest.json`).

## Build, Test & Package Release

```zsh
# Build and launch Husk.app
./scripts/build-app.sh --debug --run

# Run automated safety, scanner, and updater test suite (8 tests)
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache swift test --enable-swift-testing --disable-xctest --disable-sandbox --cache-path /tmp/swiftpm-cache -Xswiftc -module-cache-path -Xswiftc /tmp/clang-module-cache -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

# Package release artifacts (Husk.app, .dmg, .zip, latest.json, SHA256SUMS.txt)
./scripts/package-release.sh --release
```

## Publishing Releases (GitHub & Website)

1. **GitHub Releases**: Push a version tag (`git tag v1.0.0 && git push origin v1.0.0`). The workflow in [`.github/workflows/release.yml`](file:///Users/stabil/Projects/dev-cleaner/.github/workflows/release.yml) runs the test suite, packages `Husk.app`, `.dmg`, `.zip`, `latest.json`, and `SHA256SUMS.txt`, and publishes the GitHub Release.
2. **Website Updates**: Upload `dist/latest.json` and the `.dmg`/`.zip` archive to your website, or point Husk's **Update Feed** setting to your GitHub `owner/repo` slug.
