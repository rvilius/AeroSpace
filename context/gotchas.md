# AeroSpace fork gotchas

Moved from Claude auto-memory on 2026-09-07; append new lessons under the matching heading with a date.
Build, install and focus-guard lessons live in the infra repo at `~/Sites/Personal/infra/context/gotchas.md` under "AeroSpace fork". This file holds command-semantics findings about the fork itself.

## Command semantics

- **`aerospace move-workspace-to-monitor --workspace X EM` is the wrong primitive for "show workspace X on monitor EM without disturbing focus".** For an empty or never-placed X, its `workspaceMonitor` falls back to `mainMonitor` (`Workspace.swift:112`), so the command treats the PRIMARY as X's previous monitor and evicts it with a stub workspace (`MoveWorkspaceToMonitorCommand.swift:19-21`). It also no-ops once X is already remembered on the target (`:15`). The command relocates a workspace's monitor binding; it cannot set monitor M to display workspace W side-effect free.
- **The working pattern is force-assignment plus a focus dance:** pin the workspace with `workspace-to-monitor-force-assignment` so `forceAssignedMonitor` wins and the `mainMonitor` fallback never applies, then run `['workspace X-2', 'workspace X']`, focusing the partner workspace (which renders it on its pinned monitor) and focusing back. It costs a brief focus flicker and only covers keybinding switches, not menu-bar clicks. This is how the secondary-monitor mirroring feature ships in `~/.aerospace.toml` (chezmoi source `dot_aerospace.toml.tmpl`).
