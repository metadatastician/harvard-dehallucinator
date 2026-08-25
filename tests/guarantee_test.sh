#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression suite for THE GUARANTEE: `completed` and `status` are only ever
# derived from engine/verify_register.sh, and no caller-supplied argument can
# reach the string COMPLETE.
#
# The original engine took `remaining` as a parameter and wrote COMPLETE on the
# agent's say-so. On 2026-08-23 it recorded 16/16 COMPLETE 1h27m before the
# first file of the migration was ported. These tests exist so that cannot
# silently return.
#
# Portable: operates entirely on a scratch copy via $HARVARD_ROOT and mktemp,
# so it never touches the repo's own state/state.txt.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v runghc >/dev/null 2>&1 || {
    echo "FAIL: runghc not found. The engine cannot be exercised, so its" >&2
    echo "      guarantee cannot be verified. Install GHC (runghc, and the" >&2
    echo "      process/directory/filepath boot packages) before this gate." >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Scratch checkout: engine + state only.
mkdir -p "$WORK/root/engine" "$WORK/root/state"
cp "$REPO_ROOT/engine/Engine.hs" "$REPO_ROOT/engine/verify_register.sh" "$WORK/root/engine/"
chmod +x "$WORK/root/engine/verify_register.sh"
export HARVARD_ROOT="$WORK/root"
ENGINE="runghc $WORK/root/engine/Engine.hs"

# Fixtures: one tree with surviving ReScript, one without.
mkdir -p "$WORK/dirty/src" "$WORK/clean/src"
printf 'let x = 1\n' > "$WORK/dirty/src/A.res"
printf 'let y = 2\n' > "$WORK/dirty/src/B.res"
printf '{}\n'        > "$WORK/dirty/rescript.json"
printf 'module A;\n' > "$WORK/clean/src/A.affine"

pass=0; fail=0
chk() { # chk <name> <got> <want>
    if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        want=[%s]\n        got =[%s]\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}
field() { sed -n "$1p" "$WORK/root/state/state.txt"; }

echo "== verifier =="
chk "counts .res/.resi/rescript.json" "$($ENGINE verify "$WORK/dirty" 2>&1)" "3"
chk "counts zero on a clean tree"     "$($ENGINE verify "$WORK/clean" 2>&1)" "0"

echo "== baseline =="
$ENGINE init 30 >/dev/null 2>&1
chk "init sets RUNNING"        "$(tr '\n' '/' < "$WORK/root/state/state.txt")" "30/0/0/RUNNING/"
$ENGINE init-from "$WORK/dirty" >/dev/null 2>&1
chk "init-from MEASURES total" "$(field 1)" "3"

echo "== THE GUARANTEE =="
$ENGINE init 30 >/dev/null 2>&1
$ENGINE update "$WORK/dirty" >/dev/null 2>&1
chk "non-zero target cannot write COMPLETE" "$(field 4)" "RUNNING"
chk "progress derived from the count"       "$(field 2)" "27"
chk "update charges an attempt"             "$(field 3)" "1"

# The original attack: assert progress as an argument. `update 0` used to mean
# "zero remaining, mark COMPLETE". It must now be read as a directory and fail.
$ENGINE update 0 >/dev/null 2>&1
chk "caller cannot assert a number (exit 4)" "$?" "4"
chk "status unchanged by the attempt"        "$(field 4)" "RUNNING"

$ENGINE update "$WORK/clean" >/dev/null 2>&1
chk "COMPLETE only via a MEASURED zero"      "$(field 4)" "COMPLETE"

$ENGINE update "$WORK/dirty" >/dev/null 2>&1
chk "regresses out of COMPLETE"              "$(field 4)" "RUNNING"

echo "== circuit breaker =="
$ENGINE init 1 >/dev/null 2>&1
for _ in 1 2 3 4 5 6; do $ENGINE attempt >/dev/null 2>&1; done
chk "attempts accumulate to budget" "$(field 3)" "6"
$ENGINE attempt >/dev/null 2>&1
chk "trips past total+5 (exit 3)"   "$?" "3"
chk "EMERGENCY_STOP written"        "$(field 4)" "EMERGENCY_STOP"
$ENGINE update "$WORK/clean" >/dev/null 2>&1
chk "stopped state is terminal (exit 1)" "$?" "1"
chk "stays stopped"                      "$(field 4)" "EMERGENCY_STOP"

echo "== robustness =="
printf 'not-a-number\n0\n0\nRUNNING\n' > "$WORK/root/state/state.txt"
out="$($ENGINE status 2>&1)"; rc=$?
chk "malformed state exits 1, no crash" "$rc" "1"
chk "names the offending field"         "$(printf '%s' "$out" | grep -c totalItems)" "1"

$ENGINE init 5 >/dev/null 2>&1
a="$(cd / && $ENGINE status 2>&1)"
b="$(cd "$WORK/root/engine" && runghc Engine.hs status 2>&1)"
chk "cwd-independent" "$a" "$b"

printf '\n%s\n' "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
