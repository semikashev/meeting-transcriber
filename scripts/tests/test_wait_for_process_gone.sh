#!/bin/bash
# Regression test for `wait_for_process_gone`, the verdict the crash-recovery
# lane's kill was missing. Why an unverified kill let that lane pass while
# testing nothing is written out once, at the helper itself in
# scripts/lib/e2e-helpers.sh.
#
# What falsifies a broken helper here are the two cases that expect `gone`: a
# helper that is missing, erroring or always-alive can never produce it. See
# the note above the first case for why that one is weaker than its name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

PASSED=0
ALIVE_PID=""

# `wait` after the kill reaps the job, which is what stops bash from printing
# its own "Killed: 9" line to stderr and cluttering the CI log.
kill_probe() {
    local pid="$1"
    [ -n "$pid" ] || return 0
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

trap 'kill_probe "$ALIVE_PID"' EXIT

# A process whose argv carries a unique marker, so `pgrep -f` cannot match this
# test's own shell or anything else on a shared runner. `exec -a` renames the
# sleep in place, so nothing has to be written to disk and the probe costs no
# CPU while it waits to be found.
PROBE_PID=""
start_probe() {
    local marker="$1"
    ( exec -a "$marker" sleep 300 ) &
    PROBE_PID="$!"
    # Do not return until it is actually matchable: a just-forked process is
    # not in `pgrep` output yet, and the alive case would be testing that race
    # rather than the predicate.
    local tries=0
    until pgrep -f "$marker" >/dev/null 2>&1; do
        tries=$(( tries + 1 ))
        [ "$tries" -lt 100 ] || { echo "probe $marker never became visible" >&2; exit 1; }
        sleep 0.05
    done
}

check() {
    local name="$1" expected="$2" pattern="$3" timeout="$4"
    local actual=gone
    wait_for_process_gone "$pattern" "$timeout" || actual=alive
    if [ "$actual" = "$expected" ]; then
        echo "$name ... PASS"
        PASSED=$(( PASSED + 1 ))
    else
        echo "$name ... FAIL (expected $expected, got $actual)"
        exit 1
    fi
}

# A live process must not be reported as gone, which is what the lane assumed
# without checking. Weaker than its name on its own: `check` reads any non-zero
# status as "alive", so a helper that does not exist at all (127) also passes
# here. The two cases below are what fail the suite in that event.
MARKER_ALIVE="e2e-probe-alive-$$"
start_probe "$MARKER_ALIVE"
ALIVE_PID="$PROBE_PID"
check alive_process_is_not_gone alive "$MARKER_ALIVE" 1

# The ordinary success path: the kill worked, so the wait returns promptly.
MARKER_KILLED="e2e-probe-killed-$$"
start_probe "$MARKER_KILLED"
kill_probe "$PROBE_PID"
check killed_process_is_gone gone "$MARKER_KILLED" 5

# The production scenario this whole file exists for: a `pkill` that matched
# nothing looks exactly like one that worked. Nothing to wait for means gone,
# and the caller has to learn that from the return value rather than assume it.
check never_running_is_gone gone "e2e-probe-never-started-$$" 1

echo "$PASSED checks passed"
