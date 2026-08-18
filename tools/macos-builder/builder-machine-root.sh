#!/bin/bash

# Retirement removes a machine-wide builder root recursively, so both of these
# predicates must hold before anything is deleted. They are separate because
# the first constrains where a machine root may live and the second constrains
# what a machine root may contain.

# The system Library is the only supported location for machine-wide builder
# state. `/Library` itself never qualifies.
nucleus_supported_machine_root_path() {
  [[ "$1" == /Library/?* ]]
}

# A machine root holds only the two subtrees this provisioning creates. Any
# other entry means the path is shared with something else, and retirement
# stops instead of widening the removal.
nucleus_machine_root_holds_only_builder_state() {
  local candidate="$1"
  local entry

  [[ ! -L "$candidate" && -d "$candidate" ]] || return 1
  while IFS= read -r -d '' entry; do
    case "${entry##*/}" in
      GitHubActionsRunner | Builder) ;;
      *) return 1 ;;
    esac
  done < <(/usr/bin/find "$candidate" -mindepth 1 -maxdepth 1 -print0)
}
