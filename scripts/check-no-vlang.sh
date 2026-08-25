#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Enforce the estate ban on the V programming language. Zig is the supported
# systems/FFI language and must never be matched by this check.

set -euo pipefail

REPO_ROOT="${1:-.}"
if [ ! -d "$REPO_ROOT" ]; then
    echo "ERROR: repository path does not exist: $REPO_ROOT" >&2
    exit 2
fi

PATTERN='gen-v-connector|V-TRIPLE|v-triple|vlang|connectors/v-|import[[:space:]]+vweb'
HITS=""
V_MODS=""

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Search tracked content only. The exclusions are the policy and its
    # enforcement/tests, which necessarily name the forbidden patterns.
    HITS=$(git -C "$REPO_ROOT" grep -n -i -E "$PATTERN" -- \
        . \
        ':(exclude)affinescript/**' \
        ':(exclude)scripts/check-no-vlang.sh' \
        ':(exclude)tests/workflows/check_no_vlang_test.sh' \
        ':(exclude).github/workflows/estate-rules.yml' \
        ':(exclude).machine_readable/descriptiles/PLAYBOOK.a2ml' \
        2>/dev/null || true)
    V_MODS=$(git -C "$REPO_ROOT" ls-files -- 'v.mod' '**/v.mod' 2>/dev/null || true)
else
    HITS=$(grep -rni -E "$PATTERN" "$REPO_ROOT" \
        --exclude-dir=.git \
        --exclude-dir=affinescript \
        --exclude-dir=node_modules \
        --exclude=check-no-vlang.sh \
        --exclude=check_no_vlang_test.sh \
        --exclude=estate-rules.yml \
        --exclude=PLAYBOOK.a2ml \
        2>/dev/null || true)
    V_MODS=$(find "$REPO_ROOT" -type f -name v.mod \
        -not -path '*/.git/*' -not -path '*/affinescript/*' \
        -printf '%P\n' 2>/dev/null || true)
fi

if [ -z "$HITS" ] && [ -z "$V_MODS" ]; then
    echo "PASS: no V-language references in the inspected repository"
    exit 0
fi

COUNT=0
if [ -n "$HITS" ]; then
    CONTENT_COUNT=$(printf '%s\n' "$HITS" | awk 'NF { count++ } END { print count + 0 }')
    COUNT=$((COUNT + CONTENT_COUNT))
fi
if [ -n "$V_MODS" ]; then
    FILE_COUNT=$(printf '%s\n' "$V_MODS" | awk 'NF { count++ } END { print count + 0 }')
    COUNT=$((COUNT + FILE_COUNT))
fi

echo "FAIL: $COUNT V-language reference(s) found (estate policy forbids V):" >&2
if [ -n "$HITS" ]; then
    printf '%s\n' "$HITS" | sed 's/^/  /' >&2
fi
if [ -n "$V_MODS" ]; then
    printf '%s\n' "$V_MODS" | sed 's/^/  tracked module file: /' >&2
fi
echo >&2
echo "Remove the V-language remnants; use the supported Zig adapter where an FFI/API bridge is needed." >&2
exit 1
