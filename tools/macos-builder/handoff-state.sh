#!/bin/bash

nucleus_handoff_local_state() {
  case "$1:$2" in
    absent:absent) printf '%s\n' fresh ;;
    present:present) printf '%s\n' complete ;;
    *) printf '%s\n' inconsistent ;;
  esac
}

nucleus_handoff_runner_state() {
  local runner_names="$1"
  local expected_name="$2"
  if [[ -z "$runner_names" ]]; then
    printf '%s\n' fresh
  elif [[ "$runner_names" == "$expected_name" ]]; then
    printf '%s\n' complete
  else
    printf '%s\n' inconsistent
  fi
}

nucleus_handoff_action() {
  case "$1:$2" in
    fresh:fresh) printf '%s\n' provision ;;
    complete:complete) printf '%s\n' verify ;;
    *) printf '%s\n' inconsistent ;;
  esac
}
