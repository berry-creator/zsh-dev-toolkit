# zsh-dev-toolkit

Reusable Zsh helpers for Git-based development workflows.

## Runtime

Source `runtime/init.zsh` to load all functions:

```zsh
source /path/to/zsh-dev-toolkit/runtime/init.zsh
```

The runtime includes helpers for Git worktrees, submodules, refs, branch and
tag synchronization, rebasing, Dev Container state backup and restore,
logging, and optional Codex configuration.

## Dev Container state

Before rebuilding a Dev Container, run:

```zsh
zsh /path/to/zsh-dev-toolkit/runtime/devcontainer_state.zsh backup
```

If a backup already exists, use `backup --recreate` to create a fresh backup
and replace the previous one after the new backup has been prepared.

After rebuilding, run:

```zsh
zsh /path/to/zsh-dev-toolkit/runtime/devcontainer_state.zsh restore
```

Configure paths in `runtime/devcontainer_state.conf`, one absolute path or
`~/path` per line. Backups are temporarily stored in
`.devcontainer-state-backup` at the Git workspace root. Add this directory to
the workspace's `.gitignore` if you want to avoid seeing the temporary
untracked backup before restoring it.

Paths over 100 MiB require interactive confirmation. When a restore target
already exists, choose to skip or overwrite that path; uppercase choices apply
to all remaining conflicts in the current restore run. Overwrite replaces the
entire target path. Skipped backups remain available for a later restore.

The `runtime/` directory is intentionally self-contained so consumers can
copy it into a project-local shell configuration directory.
