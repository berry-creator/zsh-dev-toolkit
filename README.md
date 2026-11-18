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
`~/path` per line. Add zero or more `--exclude <glob>` options to omit matching
file names, extensions, or directories:

```text
"~/.codex with spaces" --exclude '*.log' --exclude plugins
```

Quote paths or patterns containing spaces using shell-style quotes. Patterns
use GNU tar's exclude glob behavior and apply recursively within that configured
path. Excluded files are not included in the backup. If you choose to overwrite
an existing target during restore, the entire target path is still replaced,
so excluded files in that target are not preserved.

Backups are temporarily stored in
`.devcontainer-state-backup` at the Git workspace root. Add this directory to
the workspace's `.gitignore` if you want to avoid seeing the temporary
untracked backup before restoring it. Each configured path is stored as a
compressed sparse tar archive; GNU tar is required.
Backups created by earlier versions remain restorable.

Paths over 100 MiB require interactive confirmation. When a restore target
already exists, choose to skip or overwrite that path; uppercase choices apply
to all remaining conflicts in the current restore run. Overwrite replaces the
entire target path. ACLs and extended attributes are included where supported.
Skipped backups remain available for a later restore.

The `runtime/` directory is intentionally self-contained so consumers can
copy it into a project-local shell configuration directory.
