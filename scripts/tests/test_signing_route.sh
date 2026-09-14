#!/bin/bash
# Regression test for `have_signing_route` in scripts/lib/signing.sh.
#
# Why this exists: the silent-recording lane refuses to run on a host with no
# signing route, because a denied capture is indistinguishable from the silence
# that lane asserts. The full reasoning lives with the predicate itself, in
# scripts/lib/signing.sh.
#
# What is pinned here is the predicate's own contract: which combinations of an
# explicit Developer ID and a dev keychain count as a route.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASSED=0

PRESENT="$TMP/present.keychain-db"
: > "$PRESENT"
ABSENT="$TMP/absent.keychain-db"

check() {
    local name="$1" expected="$2" developer_id="$3" keychain="$4"
    local actual=route
    have_signing_route "$developer_id" "$keychain" || actual=none
    if [ "$actual" = "$expected" ]; then
        echo "$name ... PASS"
        PASSED=$(( PASSED + 1 ))
    else
        echo "$name ... FAIL (expected $expected, got $actual)"
        exit 1
    fi
}

# The CI path: the workflow exports a Developer ID and the bundle is re-signed
# with it. No dev keychain is involved.
check developer_id_only route "Developer ID Application: Someone (TEAMID)" "$ABSENT"

# The self-hosted and local-dev path: no Developer ID, but the setup script has
# created a keychain holding a self-signed identity.
check dev_keychain_only route "" "$PRESENT"

# The case the refusal exists for. A host with neither cannot keep the TCC
# grants that the capture stack needs, so the lane would assert a silence it
# caused itself.
check neither_available none "" "$ABSENT"

echo "$PASSED checks passed"
