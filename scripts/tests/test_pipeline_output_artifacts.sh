#!/bin/bash
# Regression test for the record-only "the pipeline did not run" assertion.
#
# Why this exists: the assertion is a negative one, and a negative assertion
# that looks in the wrong place is indistinguishable from a passing lane. The
# original form searched `<output>/recordings` at `-maxdepth 1`, while the app
# writes both the transcript and the protocol to `<output>/protocols`. No
# `.txt` or `.md` can appear in the searched directory in either the working or
# the broken world, so the check was satisfied unconditionally and two lanes
# claimed to prove something they never touched.
#
# The case that pins that defect is `transcript_in_protocols`: it is the exact
# on-disk shape a record-only regression produces, and it must be reported.
# Reverting the search to the recordings directory turns that case red.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/e2e-helpers.sh
source "$ROOT/scripts/lib/e2e-helpers.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0

# Each case gets its own output tree with a marker dated in the past, so every
# file the case then writes at "now" is unconditionally newer. Backdating the
# marker rather than sleeping between the two keeps this file inside the
# "finish in about a second" contract that `.github/workflows/ci.yml` states for
# `scripts/tests/test_*.sh`, and it removes the dependence on filesystem mtime
# granularity that a one-second pause was only papering over.
MARKER_STAMP=202601011000   # after PREDATES_STAMP, before any file written now
PREDATES_STAMP=202601010900

new_output_dir() {
    local name="$1"
    local dir="$TMP/$name"
    mkdir -p "$dir/recordings" "$dir/protocols"
    touch -t "$MARKER_STAMP" "$dir/.marker"
    printf '%s' "$dir"
}

# Every record-only run legitimately writes these. They must never be reported.
seed_record_only_output() {
    local dir="$1"
    : > "$dir/recordings/20260914_1000_mix.wav"
    printf '{"version":2}\n' > "$dir/recordings/20260914_1000_meta.json"
}

check() {
    local name="$1" expected="$2" dir="$3"
    local found actual=clean
    found="$(pipeline_output_artifacts "$dir" "$dir/.marker")"
    [ -z "$found" ] || actual=reported
    if [ "$actual" = "$expected" ]; then
        echo "$name ... PASS"
        PASSED=$(( PASSED + 1 ))
    else
        echo "$name ... FAIL (expected $expected, got $actual)"
        [ -z "$found" ] || printf '%s\n' "$found" | sed 's|^|    |'
        exit 1
    fi
}

# The defect this file exists for. A record-only regression runs the full
# pipeline, and the pipeline writes the transcript into `protocols/`, not into
# `recordings/`. Searching only `recordings/` never sees it.
d="$(new_output_dir transcript_in_protocols)"
seed_record_only_output "$d"
printf 'wortwoertliches transkript\n' > "$d/protocols/20260914_1000_Standup_ab12.txt"
check transcript_in_protocols reported "$d"

# The protocol is the other half of the same regression, and the same search
# missed it for the same reason.
d="$(new_output_dir protocol_in_protocols)"
seed_record_only_output "$d"
printf '# Protokoll\n' > "$d/protocols/20260914_1000_Standup_ab12.md"
check protocol_in_protocols reported "$d"

# A healthy record-only run: audio plus its sidecar, nothing else. This is the
# case the lane is asserting, so it has to stay clean or the lane is useless in
# the other direction.
d="$(new_output_dir record_only_is_clean)"
seed_record_only_output "$d"
check record_only_is_clean clean "$d"

# Output from an EARLIER meeting must not be blamed on this one. The lane runs
# against the developer's or the runner's real output folder, which routinely
# already holds transcripts from previous runs.
d="$(new_output_dir predates_marker)"
mkdir -p "$d/protocols"
printf 'altes transkript\n' > "$d/protocols/20260101_0900_Alt_zz99.txt"
touch -t "$PREDATES_STAMP" "$d/protocols/20260101_0900_Alt_zz99.txt"
seed_record_only_output "$d"
check predates_marker clean "$d"

# A first run on a fresh machine has no output folder at all. The helper must
# report nothing rather than letting `find` fail the caller under `set -e`.
check missing_output_dir clean "$TMP/does-not-exist"

echo "$PASSED checks passed"
