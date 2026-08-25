#!/usr/bin/env bash
# Counts surviving ReScript artefacts under a target tree.
#
# This is the ONLY authority on progress. Engine.hs derives `remaining` from
# this script's output; no caller may assert it. See README "The Guarantee".
#
# Exit codes: 0 = counted (count on stdout) | 2 = usage/target error
set -uo pipefail

TARGET_DIR="${1:-}"
if [ -z "$TARGET_DIR" ]; then
    echo "Usage: $0 <target_directory>" >&2
    exit 2
fi
if [ ! -d "$TARGET_DIR" ]; then
    echo "Not a directory: $TARGET_DIR" >&2
    exit 2
fi

# -prune (not -not -path): stops find DESCENDING into excluded trees rather
# than walking them and discarding the output. On this estate that is the
# difference between >120s and ~3s per call.
#
# Pruned:
#   node_modules, .git          - vendored/plumbing, never first-party source
#   */developer-ecosystem/rescript-ecosystem
#                               - vendored sub-ecosystem (~14,162 files)
#   */{repos,hyper-repos}/proven
#                               - the `proven` repo itself. Anchored to the
#                                 repo-root level ON PURPOSE: a bare
#                                 `-name proven` also swallows first-party
#                                 src/proven and integrations/proven trees,
#                                 which MUST be counted.
find "$TARGET_DIR" \
    \( -type d \( \
           -name node_modules \
        -o -name .git \
        -o -path "*/developer-ecosystem/rescript-ecosystem" \
        -o -path "*/repos/proven" \
        -o -path "*/hyper-repos/proven" \
       \) -prune \) \
    -o \( -type f \( \
           -name "*.res" \
        -o -name "*.resi" \
        -o -name "bsconfig.json" \
        -o -name "rescript.json" \
       \) -print \) 2>/dev/null | wc -l
