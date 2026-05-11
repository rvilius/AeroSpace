# AeroSpace (personal fork)

Fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace), an i3-like tiling WM for macOS. Upstream is Swift + SPM; the AeroSpace.app server runs via Xcode-built app bundle, the `aerospace` CLI is pure SPM.

## Why this fork exists

Adds `default-window-mode = 'tiling' | 'floating'` config option. When `'floating'`, new windows bind directly to the workspace instead of the tiling tree — avoids the tile-maximize flash on app launch for users who run AeroSpace as a pure workspace-switcher.

Full context (root cause, alternatives tried, install order with chezmoi, open questions): see [`PATCH-CONTEXT.md`](./PATCH-CONTEXT.md). **Read this before touching the patch.**

Patch touches three files:
- `Sources/AppBundle/config/Config.swift` — `DefaultWindowMode` enum + field
- `Sources/AppBundle/config/parseConfig.swift` — parser registration
- `Sources/AppBundle/tree/MacWindow.swift` — `unbindAndGetBindingDataForNewWindow`

## Build / test / lint

All entry-point scripts live at the **repo root**, not `script/`. The `script/` dir holds helpers invoked by the root scripts.

```bash
./build-debug.sh    # SPM debug build → .debug/aerospace + .debug/AeroSpaceApp (~65s on M-series)
./test.sh           # full check: build with -warnings-as-errors, swift-test, lint, generate
./swift-test.sh     # just the unit tests
./format.sh         # swiftformat + swiftlint --fix
./lint.sh           # periphery (unused code) — disabled on macOS 14
./run-debug.sh      # launch debug AeroSpace.app
./run-cli.sh <args> # forward args to .debug/aerospace
./generate.sh       # regenerate xcodeproj + *Generated.swift + shell parser + cmd-help
```

`./build-release.sh` uses Xcode (not SPM) and requires a self-signed `aerospace-codesign-certificate` in Keychain — see `dev-docs/development.md`.

## Source layout

- `Sources/AppBundle/` — server code (the `AeroSpace.app`). SPM library wrapped by `AeroSpace.xcodeproj` for the app bundle.
- `Sources/Cli/` — `aerospace` CLI client. Pure SPM.
- `Sources/Common/` — shared between server and CLI (mostly cmd args parsing).
- `Sources/AppBundleTests/` — tests.
- `Sources/AppBundle/{command,config,tree,layout}/` — main subsystems. Patch lives in `config/` and `tree/`.
- `docs/` — asciidoc sources for site + man pages.
- `grammar/commands-bnf-grammar.txt` — shell completion grammar; update when adding/changing commands.

Client/server talk over a UNIX socket. Args are parsed twice (once client-side for `-h`/errors, once server-side to run). See `dev-docs/architecture.md`.

## Gotchas

- **`build-debug.sh` is at the root, not in `script/`.** Easy mistake.
- **Debug server binary is `AeroSpaceApp`**, production is `AeroSpace`. If replacing the installed binary in place, copy with rename: `cp .debug/AeroSpaceApp /Applications/AeroSpace.app/Contents/MacOS/AeroSpace`.
- **Don't overwrite the brew cask binary at `/opt/homebrew/Caskroom/aerospace/...`** — brew reverts it on upgrade. Either side-by-side launch the debug build, or replace inside `/Applications/AeroSpace.app/Contents/MacOS/` (brew won't touch that unless reinstalled).
- **macOS re-prompts for Accessibility permission** on every unsigned debug rebuild unless you set Xcode's scheme Console to `Terminal` (per `dev-docs/development.md`).
- **`swiftly init` rewrites `.swift-version`** to whatever toolchain it installed (e.g. `6.3.0` → `6.3.1`). The file is tracked — `git checkout -- .swift-version` before committing.
- **Install patched binary BEFORE pushing config with `default-window-mode`**. Unpatched aerospace will fail to parse the new key.
- **Open `Package.swift` in Xcode, not `AeroSpace.xcodeproj`.** The xcodeproj is only for `*release*.sh` builds; SPM is more lightweight and is what LSP uses.

## Toolchain

- Swift version pinned by `.swift-version` (currently `6.3.0`). Managed by [swiftly](https://github.com/swiftlang/swiftly): `brew install swiftly && swiftly init`.
- Optional: `brew install xcbeautify` (readable Xcode logs), `brew install bash fish` + rust (shell completion), Ruby 3.x + `bundler install` (man pages).
- `script/clean-project.sh` when builds get weird.

## Conventions (from upstream CONTRIBUTING.md)

- Atomic commits: don't mix functional changes with refactoring.
- Match existing structure — no opportunistic refactoring in feature/fix PRs.
- Commit messages describe what, why, and how.
- For new commands, follow the checklist in `dev-docs/architecture.md` (docs in `docs/aerospace-*` + `commands.adoc`, shell completion grammar, `--window-id`/`--workspace` consideration).

## Useful local references

- `PATCH-CONTEXT.md` — full background on the fork's patch + install workflow with chezmoi.
- `dev-docs/development.md` — dependencies, codesign, Xcode setup, debugging tips.
- `dev-docs/architecture.md` — subsystems and client/server protocol.
- `axDumps/` — Accessibility API dumps for debugging window-handling issues.
