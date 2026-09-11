#!/usr/bin/env bash
# The shell must not spawn a second Quickshell to talk to itself.
#
# `Quickshell.execDetached(["qs", ..., "ipc", "call", ...])` from inside the
# shell, or Hyprland chaining `qs ... ipc call` after every clipboard store,
# starts a whole Qt process (77 ms on a fast machine, a fork of the shell's
# address space) to deliver one call back into the process that spawned it.
# In-process callers use GlobalStates.regionRequested / a resident watcher.
# LINT_ROOT points the check at another tree (the failure demonstration).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
status=0

hits=$(grep -rn --include='*.qml' -E 'execDetached\(\["qs", .*"ipc", "call"' "$ROOT/modules" "$ROOT/services" 2>/dev/null)
if [[ -n "$hits" ]]; then
    echo "No-self-IPC lint FAILED: the shell spawns qs to call its own IPC:" >&2
    echo "$hits" >&2
    status=1
fi

EXECS="$ROOT/../../hypr/hyprland/execs.lua"
if [[ -f "$EXECS" ]] && grep -v '^\s*--' "$EXECS" | grep -q 'ipc call cliphistService'; then
    echo "No-self-IPC lint FAILED: execs.lua still spawns qs after every clipboard store" >&2
    status=1
fi

if [[ $status -eq 0 ]]; then
    echo "No-self-IPC lint passed: no in-shell qs spawns, clipboard watched in-process"
fi
exit $status
