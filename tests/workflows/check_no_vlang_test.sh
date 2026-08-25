#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

CHECKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-no-vlang.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name "RSR fixture"
git -C "$FIXTURE" config user.email "fixture@example.invalid"

printf '%s\n' 'pub fn main() void {}' > "$FIXTURE/build.zig"
printf '%s\n' 'Zig is the supported FFI language.' > "$FIXTURE/README.adoc"
git -C "$FIXTURE" add build.zig README.adoc

"$CHECKER" "$FIXTURE" | grep -q '^PASS:'

printf '%s\n' 'import vweb' > "$FIXTURE/legacy.txt"
git -C "$FIXTURE" add legacy.txt
if "$CHECKER" "$FIXTURE" > "$FIXTURE/content.out" 2>&1; then
    echo "FAIL: checker accepted tracked V-language content" >&2
    exit 1
fi
grep -q 'legacy.txt' "$FIXTURE/content.out"

git -C "$FIXTURE" reset -q legacy.txt
rm "$FIXTURE/legacy.txt"
printf '%s\n' 'Module {}' > "$FIXTURE/v.mod"
git -C "$FIXTURE" add v.mod
if "$CHECKER" "$FIXTURE" > "$FIXTURE/module.out" 2>&1; then
    echo "FAIL: checker accepted a tracked v.mod" >&2
    exit 1
fi
grep -q 'tracked module file: v.mod' "$FIXTURE/module.out"

echo "PASS: Zig allowed; V-language content and v.mod rejected"
