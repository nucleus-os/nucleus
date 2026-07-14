#!/usr/bin/env bash
#
# Capture nucleus-compositor backtraces during a hard freeze (e.g. the stall when
# launching Chrome on the Swift-native xdg path).
#
# Run this from a terminal *inside* the running nucleus session (the kitty window).
# When the compositor's main thread hangs, its *display* freezes — but this script
# is a child of the shell, not of the compositor, so the kernel keeps scheduling
# it. It samples the compositor's stack with gdb (which can halt even a spinning
# or blocked process), writing to a file you read after you recover the session.
#
# Usage:
#   tools/capture-compositor-freeze.sh [trigger-command ...]
#
#   # launch the trigger for you:
#   tools/capture-compositor-freeze.sh google-chrome
#   tools/capture-compositor-freeze.sh google-chrome-stable --new-window
#
#   # or sample only, and you launch Chrome yourself:
#   tools/capture-compositor-freeze.sh
#
# Output: /tmp/nucleus-bt.txt   (copy it into the repo or paste it back)

set -u

OUT=/tmp/nucleus-bt.txt
SAMPLES=12        # number of backtrace samples
INTERVAL=3        # seconds between samples
GDB_TIMEOUT=15    # kill a single gdb attach if it wedges (uninterruptible state)

# --- locate the compositor -------------------------------------------------
# Process `comm` is truncated to 15 chars, and may not even derive from the
# binary name (launchers/wrappers can rename it), so we match the full command
# line (-f). This script's own command line does not match "NucleusCompositor"
# (it's "...capture-compositor-freeze.sh"), so there's no self-match, and pgrep
# always excludes its own pid. `-n` prefers the newest match (the compositor
# child over any launcher parent). Override with COMPOSITOR_PID=<pid>.
PID="${COMPOSITOR_PID:-}"
if [ -z "${PID}" ]; then
    PID=$(pgrep -nf 'NucleusCompositor|nucleus-compositor' 2>/dev/null | head -n1 || true)
    [ -z "${PID}" ] && PID=$(pgrep -n 'NucleusComposi' 2>/dev/null | head -n1 || true)
fi
if [ -z "${PID}" ]; then
    echo "error: couldn't auto-find the compositor." >&2
    echo "       processes mentioning 'nucleus' (pid + full command line):" >&2
    pgrep -af nucleus 2>/dev/null | sed 's/^/         /' >&2 \
        || ps -eo pid,args 2>/dev/null | grep -i nucleus | grep -vi grep | sed 's/^/         /' >&2 \
        || echo "         (none found — is the compositor running?)" >&2
    echo "       then re-run with that pid:" >&2
    echo "         COMPOSITOR_PID=<pid> tools/capture-compositor-freeze.sh google-chrome" >&2
    exit 1
fi
echo "matched process:"
ps -p "${PID}" -o pid,comm,args 2>/dev/null | sed 's/^/    /' || true

# --- check gdb -------------------------------------------------------------
if ! command -v gdb >/dev/null 2>&1; then
    echo "error: gdb is not installed." >&2
    echo "       Ubuntu: sudo apt install gdb        (then re-run this script)" >&2
    echo "       distro: install your 'gdb' package." >&2
    exit 1
fi

# --- probe ptrace permission (a quick attach/detach before the freeze) ------
if ! timeout "${GDB_TIMEOUT}" gdb -p "${PID}" -batch -ex 'detach' -ex 'quit' >/dev/null 2>&1; then
    echo "warning: gdb could not attach to pid ${PID} (ptrace likely blocked)." >&2
    echo "         run once:   echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope" >&2
    echo "         or run this script under sudo. Continuing; samples may be empty." >&2
fi

: > "${OUT}"
{
    echo "nucleus-compositor pid=${PID}"
    echo "samples=${SAMPLES} interval=${INTERVAL}s started=$(date '+%F %T')"
    echo
} | tee "${OUT}"

# --- background sampler -----------------------------------------------------
(
    for i in $(seq "${SAMPLES}"); do
        sleep "${INTERVAL}"
        if ! kill -0 "${PID}" 2>/dev/null; then
            echo "===== sample ${i}: pid ${PID} gone (you recovered) — stopping =====" >> "${OUT}"
            break
        fi
        echo "===== sample ${i}  $(date '+%H:%M:%S') =====" >> "${OUT}"
        if ! timeout "${GDB_TIMEOUT}" gdb -p "${PID}" -batch \
                -ex 'thread apply all bt' >> "${OUT}" 2>&1; then
            echo "(gdb attach timed out/failed for sample ${i})" >> "${OUT}"
        fi
        echo >> "${OUT}"
    done
    echo "===== sampling done =====" >> "${OUT}"
) &
SAMPLER=$!

echo "sampler running in background (pid ${SAMPLER}); writing ${OUT}"

# --- launch the trigger, if one was given ----------------------------------
if [ "$#" -gt 0 ]; then
    echo "launching trigger: $*"
    "$@" >/tmp/nucleus-trigger.log 2>&1 &
    echo "trigger launched (pid $!). Now wait for the freeze."
else
    echo
    echo ">>> Now launch Chrome (or whatever triggers the freeze)."
fi

echo
echo "After it freezes and you recover the session, read the backtrace with:"
echo "    cat ${OUT}"
echo "(or copy it into the repo so it can be read directly:  cp ${OUT} \"$(pwd)\"/ )"
