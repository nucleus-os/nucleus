#!/bin/bash

nucleus_apply_acl_batch() {
  local acl_entry="$1"
  shift

  [[ $# -gt 0 ]] || return 0
  if /bin/chmod -h +a "$acl_entry" "$@" 2>/dev/null; then
    return 0
  fi

  local acl_target
  for acl_target in "$@"; do
    if /bin/chmod -h +a "$acl_entry" "$acl_target"; then
      continue
    fi
    [[ ! -e "$acl_target" && ! -L "$acl_target" ]] || return 1
  done
}

nucleus_apply_acl_tree() {
  local acl_root="$1"
  local file_entry="$2"
  local directory_entry="$3"
  local acl_target
  local -a file_targets=()
  local -a directory_targets=()

  # Seed inheritance before walking so objects created during the traversal
  # receive the directory contract. chmod -h never follows a swapped symlink.
  nucleus_apply_acl_batch "$directory_entry" "$acl_root"
  while IFS= read -r -d '' acl_target; do
    if [[ -d "$acl_target" && ! -L "$acl_target" ]]; then
      directory_targets+=("$acl_target")
      if [[ ${#directory_targets[@]} -eq 256 ]]; then
        nucleus_apply_acl_batch "$directory_entry" "${directory_targets[@]}"
        directory_targets=()
      fi
    else
      file_targets+=("$acl_target")
      if [[ ${#file_targets[@]} -eq 256 ]]; then
        nucleus_apply_acl_batch "$file_entry" "${file_targets[@]}"
        file_targets=()
      fi
    fi
  done < <(/usr/bin/find -x "$acl_root" -mindepth 1 -print0)
  if [[ ${#directory_targets[@]} -gt 0 ]]; then
    nucleus_apply_acl_batch "$directory_entry" "${directory_targets[@]}"
  fi
  if [[ ${#file_targets[@]} -gt 0 ]]; then
    nucleus_apply_acl_batch "$file_entry" "${file_targets[@]}"
  fi
}
