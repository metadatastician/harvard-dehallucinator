#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-lock-sync.sh"
GATE="$REPO_ROOT/.github/workflows/lock-sync-gate.yml"
LOCK="$REPO_ROOT/.github/workflows/actions.lock"
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

pass=0
fail=0
status=0
output=""

record_pass() {
    printf '  PASS  %s\n' "$1"
    pass=$((pass + 1))
}

record_fail() {
    printf '  FAIL  %s\n%s\n' "$1" "$2"
    fail=$((fail + 1))
}

assert_status() {
    local name="$1" expected="$2"
    if [ "$status" -eq "$expected" ]; then
        record_pass "$name"
    else
        record_fail "$name" "        expected status: $expected
        actual status:   $status
        output:          $output"
    fi
}

assert_output_contains() {
    local name="$1" expected="$2"
    if [[ "$output" == *"$expected"* ]]; then
        record_pass "$name"
    else
        record_fail "$name" "        missing text: $expected
        output:       $output"
    fi
}

assert_file_matches() {
    local name="$1" pattern="$2" file="$3"
    if grep -Eq -- "$pattern" "$file"; then
        record_pass "$name"
    else
        record_fail "$name" "        pattern not found: $pattern
        file:              $file"
    fi
}

assert_file_not_matches() {
    local name="$1" pattern="$2" file="$3"
    if grep -Eq -- "$pattern" "$file"; then
        record_fail "$name" "        unexpected pattern: $pattern
        file:               $file"
    else
        record_pass "$name"
    fi
}

new_fixture() {
    case_root="$FIXTURE_ROOT/case"
    rm -rf "$case_root"
    workflows="$case_root/.github/workflows"
    mkdir -p "$workflows"
}

write_workflow() {
    local filename="$1"
    shift
    printf '%s\n' "$@" > "$workflows/$filename"
}

write_lock() {
    printf '%s\n' "$@" > "$workflows/actions.lock"
}

write_external_workflow() {
    local filename="$1" ref="$2"
    write_workflow "$filename" \
        'name: Fixture' \
        'on: push' \
        'jobs:' \
        '  check:' \
        '    runs-on: ubuntu-latest' \
        '    steps:' \
        "      - uses: $ref"
}

write_single_ref_lock() {
    local filename="$1" workflow_ref="$2" dependency_ref="${3:-$2}"
    write_lock \
        "version: 'v0.0.2'" \
        'workflows:' \
        "    '.github/workflows/$filename':" \
        "        - '$workflow_ref'" \
        'dependencies:' \
        "    '$dependency_ref':" \
        "        ref: '$dependency_ref'"
}

run_checker() {
    output="$("$CHECKER" "$workflows" 2>&1)"
    status=$?
}

echo '== synchronized fixtures =='

new_fixture
write_workflow build.yml \
    'name: Fixture' \
    'on: push' \
    'jobs:' \
    '  check:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: "Actions/Checkout/subdirectory@v1" # normalize action subpaths' \
    '      - uses: actions/checkout@v1'
write_single_ref_lock build.yml 'actions/checkout@v1' 'ACTIONS/CHECKOUT@v1'
run_checker
assert_status 'accepts synchronized refs, duplicate uses, comments, quotes, subpaths, and repository case differences' 0
assert_output_contains 'reports a synchronized lockfile' 'actions.lock is in sync and transitively closed'
assert_output_contains 'reports complete workflow-file coverage' 'every workflow file has a lockfile key (zero-uses: workflows included)'

new_fixture
write_workflow local.yaml \
    'name: Local action' \
    'on: push' \
    'jobs:' \
    '  check:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: ./actions/local' \
    '      - run: echo done'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/local.yaml': []" \
    'dependencies:'
run_checker
assert_status 'ignores relative local actions and supports the .yaml extension' 0

new_fixture
write_external_workflow build.yml 'actions/checkout@v1'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/build.yml':" \
    "        - 'actions/checkout@v1'" \
    'dependencies:' \
    "    'actions/checkout@v1':" \
    "        ref: 'v1'" \
    "    'unused/action@v2':" \
    "        ref: 'v2'"
run_checker
assert_status 'allows harmless unreferenced dependency records' 0
assert_output_contains 'reports unreferenced dependency records' '1 dependencies: record(s) are unreferenced'

echo '== clause 1: every workflow use is locked =='

new_fixture
write_external_workflow build.yml 'actions/checkout@v1'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/build.yml': []" \
    'dependencies:' \
    "    'actions/checkout@v1':" \
    "        ref: 'v1'"
run_checker
assert_status 'rejects a ref missing from an existing workflow lock entry' 1
assert_output_contains 'identifies the missing lock ref' 'refs missing from the lockfile: actions/checkout@v1'

new_fixture
write_external_workflow reusable.yml 'owner/repository/.github/workflows/reuse.yml@main'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    'dependencies:' \
    "    'owner/repository@main':" \
    "        ref: 'main'"
run_checker
assert_status 'rejects an un-onboarded job-level reusable workflow' 1
assert_output_contains 'distinguishes an absent workflow entry from a missing ref' 'not onboarded: no lockfile entry for this path'
assert_output_contains 'normalizes reusable workflow subpaths' 'unlocked refs: owner/repository@main'
assert_output_contains 'also reports the missing reusable-workflow file as unlisted' 'UNLISTED WORKFLOWS'

new_fixture
write_external_workflow build.yml 'actions/checkout@V1'
write_single_ref_lock build.yml 'actions/checkout@v1'
run_checker
assert_status 'keeps refs case-sensitive while folding owner and repository case' 1
assert_output_contains 'reports a case-mismatched ref as missing' 'actions/checkout@V1'

echo '== clause 2: every lock entry is live =='

new_fixture
write_workflow build.yml \
    'name: Fixture' \
    'on: push' \
    'jobs:' \
    '  check:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: echo done'
write_single_ref_lock build.yml 'actions/checkout@v1'
run_checker
assert_status 'rejects a stale ref no longer used by its workflow' 1
assert_output_contains 'identifies stale workflow lock entries' 'stale lockfile entries, no uses: references them: actions/checkout@v1'

new_fixture
write_workflow current.yml \
    'name: Fixture' \
    'on: push' \
    'jobs:' \
    '  check:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: echo done'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/deleted.yml': []" \
    'dependencies:'
run_checker
assert_status 'rejects lock entries for deleted workflow files' 1
assert_output_contains 'names a deleted workflow lock entry' 'lockfile entry for a workflow file that does not exist'

echo '== clause 3: every lock ref resolves transitively =='

new_fixture
write_external_workflow build.yml 'actions/checkout@v1'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/build.yml':" \
    "        - 'actions/checkout@v1'" \
    'dependencies:'
run_checker
assert_status 'rejects a direct workflow ref without a dependency record' 1
assert_output_contains 'labels direct missing records as dangling edges' 'DANGLING EDGES'
assert_output_contains 'reports the source workflow for a dangling edge' 'named by: .github/workflows/build.yml'

new_fixture
write_external_workflow build.yml 'actions/checkout@v1'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/build.yml':" \
    "        - 'actions/checkout@v1'" \
    'dependencies:' \
    "    'actions/checkout@v1':" \
    "        ref: 'v1'" \
    '        uses:' \
    "            - 'nested/dependency@sha'"
run_checker
assert_status 'rejects a nested dependency without its own record' 1
assert_output_contains 'reports which dependency introduced a dangling nested edge' 'named by: dependencies:actions/checkout@v1'

write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/build.yml':" \
    "        - 'actions/checkout@v1'" \
    'dependencies:' \
    "    'actions/checkout@v1':" \
    "        ref: 'v1'" \
    '        uses:' \
    "            - 'nested/dependency@sha'" \
    "    'nested/dependency@sha':" \
    "        ref: 'sha'"
run_checker
assert_status 'accepts a transitively closed dependency graph' 0

echo '== clause 4: every workflow file has a lock key =='

new_fixture
write_workflow unlisted.yml \
    'name: No external actions' \
    'on: push' \
    'jobs:' \
    '  check:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - run: echo done'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    'dependencies:'
run_checker
assert_status 'rejects an unlisted workflow with no uses entries' 1
assert_output_contains 'labels missing workflow keys as a coverage failure' 'FAIL actions.lock: UNLISTED WORKFLOWS'
assert_output_contains 'reports the number of unlisted workflow files' '1 workflow file(s) have no key in the lockfile'
assert_output_contains 'names the unlisted zero-uses workflow' '.github/workflows/unlisted.yml'
assert_output_contains 'explains the empty-list remediation' "'.github/workflows/x.yml': []"

new_fixture
write_workflow alpha.yml \
    'name: First unlisted workflow' \
    'on: push'
write_workflow beta.yaml \
    'name: Second unlisted workflow' \
    'on: pull_request'
write_workflow listed.yml \
    'name: Listed workflow' \
    'on: workflow_dispatch'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/listed.yml': []" \
    'dependencies:'
run_checker
assert_status 'rejects every unlisted workflow across yml and yaml extensions' 1
assert_output_contains 'aggregates multiple missing workflow keys' '2 workflow file(s) have no key in the lockfile'
assert_output_contains 'names the missing yml workflow' '.github/workflows/alpha.yml'
assert_output_contains 'names the missing yaml workflow' '.github/workflows/beta.yaml'

write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/alpha.yml': []" \
    "    '.github/workflows/beta.yaml': []" \
    "    '.github/workflows/listed.yml': []" \
    'dependencies:'
run_checker
assert_status 'accepts zero-uses workflows once every empty-list key is present' 0

echo '== input and parser boundaries =='

new_fixture
write_external_workflow build.yml 'actions/checkout@v1'
run_checker
assert_status 'fails closed when actions.lock is absent' 1
assert_output_contains 'explains the missing lockfile prerequisite' 'FATAL: no lockfile at'

new_fixture
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    'dependencies:'
run_checker
assert_status 'fails closed when no workflow files exist' 1
assert_output_contains 'explains the missing workflow prerequisite' 'FATAL: no workflow files under'

new_fixture
write_workflow build.yml \
    'name: Fixture' \
    'on: push' \
    'jobs:' \
    '  check:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - uses: $/.github/actions/local'
write_lock \
    "version: 'v0.0.2'" \
    'workflows:' \
    "    '.github/workflows/build.yml': []" \
    'dependencies:'
run_checker
assert_status 'rejects dollar-prefixed local-action rewrites' 1
assert_output_contains 'identifies the invalid local-action rewrite' 'invalid local-action rewrite (uses: $/...)'

new_fixture
write_external_workflow build.yml 'actions/checkout@v1'
write_single_ref_lock build.yml 'actions/checkout@v1'
mkdir -p "$FIXTURE_ROOT/no-tools"
output="$(PATH="$FIXTURE_ROOT/no-tools" /usr/bin/bash "$CHECKER" "$workflows" 2>&1)"
status=$?
assert_status 'fails closed when GNU-compatible awk is unavailable' 1
assert_output_contains 'explains the GNU awk prerequisite' 'no awk supporting 3-argument match()'

echo '== checked-in gate contract =='

assert_file_matches 'gate runs for pull requests' '^  pull_request:$' "$GATE"
assert_file_matches 'gate supports manual workflow dispatch' '^  workflow_dispatch:$' "$GATE"
assert_file_matches 'gate runs for pushes to main' '^    branches: \[main\]$' "$GATE"
assert_file_matches 'gate uses read-only repository contents permission' '^  contents: read$' "$GATE"
assert_file_not_matches 'gate has no path filter that can suppress a required check' '^[[:space:]]+paths:' "$GATE"
assert_file_not_matches 'gate carries no action or reusable-workflow uses entry' '^[[:space:]]*-?[[:space:]]*uses:' "$GATE"
assert_file_matches 'gate checks the pull-request head revision' 'SHA: \$\{\{ github\.event\.pull_request\.head\.sha \|\| github\.sha \}\}' "$GATE"
assert_file_matches 'gate executes the lock-sync checker' '^[[:space:]]*\./scripts/check-lock-sync\.sh$' "$GATE"
assert_file_matches 'lockfile lists the zero-uses lock-sync gate' "^    '.github/workflows/lock-sync-gate\\.yml': \[\]$" "$LOCK"

echo '== current pull-request fixtures =='

output="$(cd "$REPO_ROOT" && "$CHECKER" 2>&1)"
status=$?
assert_status 'current pull-request workflows and actions.lock satisfy the checker' 0

printf '\nPASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
