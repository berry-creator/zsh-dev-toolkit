#!/usr/bin/env zsh

_init_script_dir="${${(%):-%N}:A:h}"

. "${_init_script_dir}/logging.zsh"
. "${_init_script_dir}/base.zsh"
. "${_init_script_dir}/codex_tools.zsh"
. "${_init_script_dir}/submodule.zsh"
. "${_init_script_dir}/worktree.zsh"
. "${_init_script_dir}/grefs.zsh"
. "${_init_script_dir}/sync_remote_tags.zsh"
. "${_init_script_dir}/sync_remote_branches.zsh"
. "${_init_script_dir}/rebase_branches.zsh"

unset _init_script_dir
