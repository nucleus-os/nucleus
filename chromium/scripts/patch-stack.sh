#!/usr/bin/env bash

# Generic patch-stack primitive used only while constructing a new immutable
# source generation. Prepared generations are never reversed or refreshed.

nucleus_apply_patch_stack() {
  local repository="$1"
  local patch_dir="$2"
  local stack_name="$3"
  local patch_file
  local patches=("$patch_dir"/*.patch)

  if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
    echo "!! $stack_name checkout is missing: $repository" >&2
    return 1
  fi

  for patch_file in "${patches[@]}"; do
    if [[ ! -f "$patch_file" ]]; then
      continue
    fi
    if git -C "$repository" apply --check "$patch_file"; then
      echo "-- applying $stack_name patch: $(basename "$patch_file")"
      git -C "$repository" apply "$patch_file"
    else
      echo "!! $stack_name source patch no longer applies: $patch_file" >&2
      return 1
    fi
  done
}
