#!/usr/bin/env bash

# Generic patch-stack primitives shared by CEF and the Chromium browser.
# Callers own source preparation and the ordering of the cumulative layers.

nucleus_reverse_patch_stack() {
  local repository="$1"
  local patch_dir="$2"
  local applied_patch_dir="$3"
  local stack_name="$4"
  local patch_file
  local patches=("$patch_dir"/*.patch)
  local applied_patches=("$applied_patch_dir"/*.patch)
  local patch_index

  if ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
    return
  fi

  # During source work the checkout may already contain the edited current
  # patch, while the generated copy still records the previous version.
  # Reverse whichever form is present, newest first. The second pass is what
  # removes renamed, merged, or deleted patches from the prior stack.
  for ((patch_index=${#patches[@]} - 1; patch_index >= 0; patch_index--)); do
    patch_file="${patches[$patch_index]}"
    if [[ -f "$patch_file" ]] &&
       git -C "$repository" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
      echo "-- refreshing $stack_name patch: $(basename "$patch_file")"
      git -C "$repository" apply --reverse "$patch_file"
    fi
  done
  if [[ -d "$applied_patch_dir" ]]; then
    for ((patch_index=${#applied_patches[@]} - 1; patch_index >= 0; patch_index--)); do
      patch_file="${applied_patches[$patch_index]}"
      if [[ -f "$patch_file" ]] &&
         git -C "$repository" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        echo "-- removing previous $stack_name patch: $(basename "$patch_file")"
        git -C "$repository" apply --reverse "$patch_file"
      fi
    done
  fi
}

nucleus_apply_patch_stack() {
  local repository="$1"
  local patch_dir="$2"
  local applied_patch_dir="$3"
  local stack_name="$4"
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

  mkdir -p "$applied_patch_dir"
  find "$applied_patch_dir" -mindepth 1 -maxdepth 1 -type f -name '*.patch' -delete
  for patch_file in "${patches[@]}"; do
    if [[ -f "$patch_file" ]]; then
      cp "$patch_file" "$applied_patch_dir/"
    fi
  done
}
