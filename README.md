# zsh-dev-toolkit

Reusable Zsh helpers for Git-based development workflows.

## Runtime

Source `runtime/init.zsh` to load all functions:

```zsh
source /path/to/zsh-dev-toolkit/runtime/init.zsh
```

The runtime includes helpers for Git worktrees, submodules, refs, branch and
tag synchronization, rebasing, logging, and optional Codex configuration.

The `runtime/` directory is intentionally self-contained so consumers can
copy it into a project-local shell configuration directory.
