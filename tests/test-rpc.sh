#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-restic RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises all plugin RPC methods against the live OMV configuration database.
# Creates test repositories, backup jobs, and env vars, then removes them on
# exit. Most repos are registered with skipinit=true so no real restic server
# is required. The end-to-end section creates two temporary shared folders
# (restic-test-repo-*/restic-test-src-*) next to an existing shared folder,
# backs up a single test file into a local repository there, and deletes both
# folders afterwards. No existing data is read or written.
#
# Tests that need no root: tests/test-unit.php and tests/test-templates.py.
#
# Requirements:
#   - Run as root
#   - OMV with the restic plugin installed

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Colours / counters  (display goes to stderr; $() captures only JSON)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }
_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}
_skip() { echo -e "  ${YELLOW}SKIP${NC}  $1${2:+  ($2)}" >&2; ((SKIP++)) || true; }

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

# Last successful RPC output is stored here.  Never call assert_rpc inside
# a $() subshell — that would prevent PASS/FAIL counter updates from
# propagating back to the parent shell.
RPC_OUT=""

rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

# Assert RPC succeeds. Optional 5th arg: grep pattern that must appear in output.
# Result JSON is available in $RPC_OUT after the call.
assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        RPC_OUT=""
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:200}"
        RPC_OUT=""
        return 1
    fi
    _pass "$desc"
    RPC_OUT="$out"
    echo "$out"
    return 0
}

# Objects created by an RPC that was expected to fail, as "method uuid".
# They are deleted on exit so a failing run leaves nothing behind.
declare -a LEAKED=()

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0 uuid
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        uuid=$(json_field "$out" "uuid")
        [ -n "$uuid" ] && [ "$uuid" != "$OMV_NEW_UUID" ] && LEAKED+=("$method $uuid")
        return 1
    fi
    _pass "$desc"
    return 0
}

json_field() {
    local json=$1 field=$2
    echo "$json" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('$field',''))" 2>/dev/null || echo ""
}

# Start a background task RPC and print the status filename it returns.
start_task() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params" 2>/dev/null | \
        python3 -c "import sys,json; v=json.load(sys.stdin); print(v if isinstance(v,str) else '')" \
        2>/dev/null || true
}

# Wait for a background task to finish. Sets TASK_STATE to "ok", "error" or
# "timeout", TASK_OUTPUT to the task output (or the error it raised), and
# TASK_RAW_OUTPUT to the output file content, which is also there on error.
TASK_STATE=""
TASK_OUTPUT=""
TASK_RAW_OUTPUT=""
wait_task() {
    local file=$1 timeout=${2:-120} out ec i
    TASK_STATE="timeout"
    TASK_OUTPUT=""
    TASK_RAW_OUTPUT=""
    [ -z "$file" ] && { TASK_STATE="error"; TASK_OUTPUT="no task started"; return; }
    for ((i = 0; i < timeout; i++)); do
        ec=0
        out=$(omv-rpc -u admin "Exec" "getOutput" "{\"filename\":\"$file\",\"pos\":0}" 2>&1) || ec=$?
        if [ $ec -ne 0 ]; then
            TASK_STATE="error"
            TASK_OUTPUT=$out
            TASK_RAW_OUTPUT=$(python3 -c "
import sys,json
print(open(json.load(open(sys.argv[1]))['outputfilename']).read())" "$file" 2>/dev/null)
            return
        fi
        if echo "$out" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('running') else 1)" 2>/dev/null; then
            sleep 1
            continue
        fi
        TASK_STATE="ok"
        TASK_OUTPUT=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('output',''))" 2>/dev/null)
        return
    done
}

# Run a background task RPC and assert how it ends ("ok" or "error").
# Optional 6th arg: grep pattern that must appear in the output; optional
# 7th arg: grep pattern that must NOT appear.
assert_task() {
    local desc=$1 expect=$2 svc=$3 method=$4 params=$5 want=${6:-} unwanted=${7:-}
    wait_task "$(start_task "$svc" "$method" "$params")"
    if [ "$TASK_STATE" != "$expect" ]; then
        _fail "$desc" "expected task to end '$expect', got '$TASK_STATE': ${TASK_OUTPUT:0:300}"
        return 1
    fi
    if [ -n "$want" ] && ! echo "$TASK_OUTPUT" | grep -q -- "$want"; then
        _fail "$desc" "'$want' not in task output: ${TASK_OUTPUT:0:300}"
        return 1
    fi
    if [ -n "$unwanted" ] && echo "$TASK_OUTPUT" | grep -q -- "$unwanted"; then
        _fail "$desc" "'$unwanted' unexpectedly in task output: ${TASK_OUTPUT:0:300}"
        return 1
    fi
    _pass "$desc"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
REST_REPO_UUID=""
SFTP_REPO_UUID=""
S3_REPO_UUID=""
B2_REPO_UUID=""
RCLONE_REPO_UUID=""
SNAPSHOT_UUID=""
RESTORETEST_UUID=""
ENVVAR_UUID=""
ENVVAR_SHARED_UUID=""
RESTUSER_UUID=""
ORIG_RESTSERVER=""
# Failure reporting / end-to-end tests
FAIL_REPO_UUID=""
FAIL_JOB_UUID=""
FAIL_RT_UUID=""
E2E_REPO_UUID=""
E2E_JOB_UUID=""
E2E_FILES_JOB_UUID=""
E2E_SF_REPO_UUID=""
E2E_SF_SRC_UUID=""

LIST_PARAMS='{"start":0,"limit":25,"sortfield":null,"sortdir":null}'

OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

# Syntactically valid UUIDv4 used as a placeholder shared folder ref when we
# only need DB storage (not actual path resolution).
FAKE_SF_UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
    echo "12345678-1234-4234-8234-123456789abc")

# The fake REST repos point at closed local ports. restic keeps retrying a
# refused connection for several minutes, so every background task started
# against them would otherwise outlive the test and tie up an omv-engined
# worker each (enough of them make the web UI unresponsive). Kill them by
# matching the repository URL in the `sh -c` wrapper, then its restic child.
FAKE_REST_URL_RE="RESTIC_REPOSITORY='rest:http://localhost:1800[01]/'"

kill_test_restic_procs() {
    local pid n=0
    for pid in $(pgrep -f "$FAKE_REST_URL_RE"); do
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
        ((n++)) || true
    done
    [ "$n" -gt 0 ] && info "Stopped $n leftover restic task(s) for the fake test repos"
    return 0
}

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
# The delete RPC for an object created by the given set RPC.
delete_method_for() {
    case $1 in
        setSnapshot)    echo deleteSnapshot ;;
        setRestoreTest) echo deleteRestoreTest ;;
        setEnvVar)      echo deleteEnvVar ;;
        setRestUser)    echo deleteRestUser ;;
        setRepo)        echo deleteRepo ;;
    esac
}

# Delete objects left behind by earlier runs that were interrupted or ran
# against an older plugin version: anything named restic-test*, everything
# referencing such a repository, the env vars the tests create, and the
# temporary shared folders of the end-to-end test (matched by their comment).
purge_test_leftovers() {
    local list='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
    local svc method uuid n=0
    while read -r svc method uuid; do
        [ -z "$uuid" ] && continue
        info "Removing leftover from an earlier run: $svc.$method $uuid"
        if [ "$method" = "delete" ]; then
            rpc "$svc" "$method" "{\"uuid\":\"$uuid\",\"recursive\":true}" &>/dev/null || true
        else
            rpc "$svc" "$method" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
        fi
        ((n++)) || true
    done < <(python3 - \
        "$(rpc Restic getRepoList "$list" 2>/dev/null)" \
        "$(rpc Restic getSnapshotList "$list" 2>/dev/null)" \
        "$(rpc Restic getRestoreTestList "$list" 2>/dev/null)" \
        "$(rpc Restic getEnvVarList "$list" 2>/dev/null)" \
        "$(rpc Restic getRestUserList "$list" 2>/dev/null)" \
        "$(rpc ShareMgmt getList "$list" 2>/dev/null)" <<'EOF'
import json, sys

def data(s):
    try:
        return json.loads(s).get('data', [])
    except Exception:
        return []

repos, jobs, rtests, envs, users, folders = (data(a) for a in sys.argv[1:7])

def is_test_name(name):
    name = name or ''
    return name.startswith(('restic-test', 'restic_test')) or '\n' in name or '\r' in name

test_repos = {r['uuid'] for r in repos if is_test_name(r.get('name'))}
test_env_names = {'MY-VAR', 'A=B', 'MY_TEST_ENVVAR'}

for j in jobs:
    if is_test_name(j.get('name')) or j.get('reporef') in test_repos:
        print('Restic deleteSnapshot', j['uuid'])
for t in rtests:
    if is_test_name(t.get('name')) or t.get('reporef') in test_repos:
        print('Restic deleteRestoreTest', t['uuid'])
for e in envs:
    name = e.get('envname') or ''
    if e.get('reporef') in test_repos or name in test_env_names or name.startswith('RESTIC_TEST') \
            or name == 'RESTIC_SHARED_TEST':
        print('Restic deleteEnvVar', e['uuid'])
for u in users:
    if is_test_name(u.get('username')):
        print('Restic deleteRestUser', u['uuid'])
for uuid in test_repos:
    print('Restic deleteRepo', uuid)
for f in folders:
    if f.get('name', '').startswith(('restic-test-repo-', 'restic-test-src-')) and \
            f.get('comment') == 'openmediavault-restic test, safe to delete':
        print('ShareMgmt delete', f['uuid'])
EOF
    )
    if [ "$n" -gt 0 ]; then
        # The env var files on disk still hold the removed variables until
        # restic is deployed again, and the RPC service reads those files.
        info "Removed $n leftover object(s); redeploying restic to refresh /etc/restic"
        omv-salt deploy run --quiet restic >/dev/null 2>&1 || \
            info "omv-salt deploy run restic failed — later tests may be affected"
    fi
    return 0
}

cleanup() {
    section "Cleanup"

    kill_test_restic_procs

    # Objects that should have been rejected but were created. Repos last,
    # as deleteRepo refuses while jobs still reference them.
    local entry
    for pass in other repo; do
        for entry in "${LEAKED[@]}"; do
            if [ "$pass" = repo ] && [ "${entry%% *}" != setRepo ]; then continue; fi
            if [ "$pass" = other ] && [ "${entry%% *}" = setRepo ]; then continue; fi
            info "Deleting object created by an unexpectedly accepted ${entry%% *}: ${entry#* }"
            rpc "Restic" "$(delete_method_for "${entry%% *}")" "{\"uuid\":\"${entry#* }\"}" &>/dev/null || true
        done
    done

    # Backup jobs must go before repos (deleteRepo checks for references)
    for uuid in "$SNAPSHOT_UUID" "$FAIL_JOB_UUID" "$E2E_JOB_UUID" "$E2E_FILES_JOB_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting test backup job $uuid"
        rpc "Restic" "deleteSnapshot" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    # Restore tests must also go before repos (deleteRepo checks for references)
    for uuid in "$RESTORETEST_UUID" "$FAIL_RT_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting test restore test $uuid"
        rpc "Restic" "deleteRestoreTest" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    for uuid in "$ENVVAR_UUID" "$ENVVAR_SHARED_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting env var $uuid"
        rpc "Restic" "deleteEnvVar" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    if [ -n "$RESTUSER_UUID" ]; then
        info "Deleting REST server user $RESTUSER_UUID"
        rpc "Restic" "deleteRestUser" "{\"uuid\":\"$RESTUSER_UUID\"}" &>/dev/null || true
    fi

    if [ -n "$ORIG_RESTSERVER" ]; then
        info "Restoring REST server settings"
        rpc "Restic" "setRestServer" "$ORIG_RESTSERVER" &>/dev/null || true
    fi

    for uuid in "$REST_REPO_UUID" "$SFTP_REPO_UUID" "$S3_REPO_UUID" "$B2_REPO_UUID" \
            "$RCLONE_REPO_UUID" "$FAIL_REPO_UUID" "$E2E_REPO_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting repo $uuid"
        rpc "Restic" "deleteRepo" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    # Temporary shared folders of the end-to-end test, with their content
    for uuid in "$E2E_SF_REPO_UUID" "$E2E_SF_SRC_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting temporary shared folder $uuid"
        rpc "ShareMgmt" "delete" "{\"uuid\":\"$uuid\",\"recursive\":true}" &>/dev/null || true
    done

    info "Done."

    # Deploy pending config changes so the OMV web UI "apply changes" banner
    # does not linger after this test run. Runs detached/async so the script
    # returns promptly; --append-dirty clears the dirty-module markers (the
    # banner) once the deploy completes.
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
section "Pre-flight"

# Clear anything left behind by an interrupted earlier run.
kill_test_restic_procs
purge_test_leftovers

for cmd in omv-rpc python3; do
    if command -v "$cmd" &>/dev/null; then
        _pass "command available: $cmd"
    else
        _fail "command available: $cmd" "$cmd not found in PATH"
    fi
done

RESTIC_AVAILABLE=false
if command -v restic &>/dev/null; then
    _pass "command available: restic ($(restic version 2>/dev/null | head -1))"
    RESTIC_AVAILABLE=true
else
    _skip "command available: restic" "not installed — bg-op and snapshot-list tests will be skipped"
fi

if ! omv-rpc -u admin "Config" "isDirty" '{}' &>/dev/null; then
    echo -e "\n${RED}omv-rpc not functional — aborting.${NC}" >&2
    exit 1
fi
_pass "omv-rpc functional"

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
section "Settings"

assert_rpc "getSettings" "Restic" "getSettings" '{}' >/dev/null
ORIG_CACHEDIR=$(json_field "$RPC_OUT" "cachedir")

ORIG_SETTINGS=$RPC_OUT

assert_rpc "setSettings (roundtrip)" "Restic" "setSettings" \
    "{\"cachedir\":\"${ORIG_CACHEDIR}\"}" >/dev/null

assert_rpc "setSettings (default excludes)" "Restic" "setSettings" "$(python3 -c "
import json; print(json.dumps({
    'cachedir': '$ORIG_CACHEDIR',
    'exclude': '*.tmp\\n.Trash-*',
    'excludecaches': True,
}))")" >/dev/null

assert_rpc "getSettings — default excludes persisted" "Restic" "getSettings" '{}' \
    '"excludecaches":true' >/dev/null

# Restore the original settings so the test leaves no trace.
assert_rpc "setSettings (restore original)" "Restic" "setSettings" "$ORIG_SETTINGS" >/dev/null

# ---------------------------------------------------------------------------
# Repository CRUD — REST (skipinit=true, no restic server required)
# ---------------------------------------------------------------------------
section "Repository CRUD — REST"

assert_rpc "getRepoList (pre-test)" "Restic" "getRepoList" "$LIST_PARAMS" >/dev/null

assert_rpc "setRepo (REST, new)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-rest',
    'type': 'rest',
    'passphrase': 'testpassword123',
    'uri': 'http://localhost:18000/',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")" >/dev/null
REST_REPO_UUID=$(json_field "$RPC_OUT" "uuid")

if [ -n "$REST_REPO_UUID" ] && [ "$REST_REPO_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setRepo REST — got real UUID ($REST_REPO_UUID)"
else
    _fail "setRepo REST — no real UUID returned"
    REST_REPO_UUID=""
fi

if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc "getRepo" "Restic" "getRepo" \
        "{\"uuid\":\"$REST_REPO_UUID\"}" "\"uuid\":\"$REST_REPO_UUID\"" >/dev/null

    assert_rpc "getRepoList includes REST repo" "Restic" "getRepoList" \
        "$LIST_PARAMS" "restic-test-rest" >/dev/null

    # Update the repo. A restic repo's passphrase cannot be rotated by editing
    # config, so setRepo must IGNORE a changed passphrase on edit and keep the
    # stored one (otherwise the repository would be orphaned).
    assert_rpc "setRepo (REST, update)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$REST_REPO_UUID',
    'name': 'restic-test-rest',
    'type': 'rest',
    'passphrase': 'updatedpassword456',
    'uri': 'http://localhost:18001/',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")" >/dev/null

    # Regression: passphrase must be unchanged after edit, but other fields
    # (e.g. uri) must still update.
    assert_rpc "getRepo (post-update)" "Restic" "getRepo" \
        "{\"uuid\":\"$REST_REPO_UUID\"}" >/dev/null
    UPD_PASS=$(json_field "$RPC_OUT" "passphrase")
    UPD_URI=$(json_field "$RPC_OUT" "uri")
    if [ "$UPD_PASS" = "testpassword123" ]; then
        _pass "setRepo edit — passphrase preserved (not rewritten)"
    else
        _fail "setRepo edit — passphrase preserved" "Expected 'testpassword123', got '$UPD_PASS'"
    fi
    if [ "$UPD_URI" = "http://localhost:18001/" ]; then
        _pass "setRepo edit — non-passphrase fields still update"
    else
        _fail "setRepo edit — uri update" "Expected 'http://localhost:18001/', got '$UPD_URI'"
    fi
fi

# ---------------------------------------------------------------------------
# Repository CRUD — SFTP (skipinit=true)
# ---------------------------------------------------------------------------
section "Repository CRUD — SFTP"

assert_rpc "setRepo (SFTP, new)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-sftp',
    'type': 'sftp',
    'passphrase': 'testpassword123',
    'uri': 'user@192.168.99.1:/srv/restic-repo',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")" >/dev/null
SFTP_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
if [ -n "$SFTP_REPO_UUID" ] && [ "$SFTP_REPO_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setRepo SFTP — got real UUID ($SFTP_REPO_UUID)"
else
    _fail "setRepo SFTP — no real UUID returned"
    SFTP_REPO_UUID=""
fi

# ---------------------------------------------------------------------------
# Repository CRUD — S3 (skipinit=true)
# ---------------------------------------------------------------------------
section "Repository CRUD — S3"

assert_rpc "setRepo (S3, new)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-s3',
    'type': 's3',
    'passphrase': 'testpassword123',
    'uri': 's3.amazonaws.com/restic-test-bucket',
    'sharedfolderref': '',
    'accesskey': 'AKIAIOSFODNN7EXAMPLE',
    'secretkey': 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    'skipinit': True,
}))")" >/dev/null
S3_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
if [ -n "$S3_REPO_UUID" ] && [ "$S3_REPO_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setRepo S3 — got real UUID ($S3_REPO_UUID)"
else
    _fail "setRepo S3 — no real UUID returned"
    S3_REPO_UUID=""
fi

# ---------------------------------------------------------------------------
# Repository CRUD — B2 (skipinit=true)
# ---------------------------------------------------------------------------
section "Repository CRUD — B2"

assert_rpc "setRepo (B2, new)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-b2',
    'type': 'b2',
    'passphrase': 'testpassword123',
    'uri': 'restic-test-bucket:/path',
    'sharedfolderref': '',
    'accesskey': 'b2accountid123',
    'secretkey': 'b2accountkey456',
    'skipinit': True,
}))")" >/dev/null
B2_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
if [ -n "$B2_REPO_UUID" ] && [ "$B2_REPO_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setRepo B2 — got real UUID ($B2_REPO_UUID)"
else
    _fail "setRepo B2 — no real UUID returned"
    B2_REPO_UUID=""
fi

# ---------------------------------------------------------------------------
# Repository CRUD — rclone (skipinit=true)
# ---------------------------------------------------------------------------
section "Repository CRUD — rclone"

assert_rpc "setRepo (rclone, new)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-rclone',
    'type': 'rclone',
    'passphrase': 'testpassword123',
    'uri': 'gdrive:restic-backups',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")" >/dev/null
RCLONE_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
if [ -n "$RCLONE_REPO_UUID" ] && [ "$RCLONE_REPO_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setRepo rclone — got real UUID ($RCLONE_REPO_UUID)"
else
    _fail "setRepo rclone — no real UUID returned"
    RCLONE_REPO_UUID=""
fi

# getRepoList should now include all five test repos
assert_rpc "getRepoList includes all test repos" "Restic" "getRepoList" \
    "$LIST_PARAMS" "restic-test" >/dev/null

# ---------------------------------------------------------------------------
# Repository name normalisation (spaces → underscores)
# ---------------------------------------------------------------------------
section "Repository name normalisation"

assert_rpc "setRepo (name with spaces)" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic test spaces',
    'type': 'rest',
    'passphrase': 'test',
    'uri': 'http://localhost:18001/',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")" >/dev/null
SPACE_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
SPACE_REPO_NAME=$(json_field "$RPC_OUT" "name")
if [ -n "$SPACE_REPO_UUID" ] && [ "$SPACE_REPO_UUID" != "$OMV_NEW_UUID" ]; then
    if [ "$SPACE_REPO_NAME" = "restic_test_spaces" ]; then
        _pass "setRepo — spaces normalised to underscores"
    else
        _fail "setRepo — space normalisation" "Expected restic_test_spaces, got $SPACE_REPO_NAME"
    fi
    rpc "Restic" "deleteRepo" "{\"uuid\":\"$SPACE_REPO_UUID\"}" &>/dev/null || true
else
    _fail "setRepo (name with spaces) — no real UUID returned"
fi

# ---------------------------------------------------------------------------
# enumerateRepoCandidates
# ---------------------------------------------------------------------------
section "enumerateRepoCandidates"

assert_rpc "enumerateRepoCandidates" "Restic" "enumerateRepoCandidates" '{}' >/dev/null

if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc "enumerateRepoCandidates includes REST repo" "Restic" \
        "enumerateRepoCandidates" '{}' "restic-test-rest" >/dev/null
fi

assert_rpc "enumerateRepoCandidates (with shared flag)" "Restic" \
    "enumerateRepoCandidates" '{"shared":true}' '"All Repositories"' >/dev/null

# ---------------------------------------------------------------------------
# Backup Jobs (Snapshots) CRUD
# ---------------------------------------------------------------------------
section "Backup Jobs CRUD"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "backup job CRUD" "no test repo available"
else
    assert_rpc "getSnapshotList (pre-test)" "Restic" "getSnapshotList" "$LIST_PARAMS" >/dev/null

    assert_rpc "setSnapshot (new, daily)" "Restic" "setSnapshot" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'enable': True,
    'name': 'restic-test-job',
    'hash': '',
    'tags': 'test,automated',
    'sharedfolderrefs': ['$FAKE_SF_UUID'],
    'reporef': '$REST_REPO_UUID',
    'exclude': '*.tmp,*.log',
    'execution': 'daily',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['2'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*'],
    'keeplast': 0,
    'keepdaily': 7,
    'keepweekly': 4,
    'keepmonthly': 12,
    'keepyearly': 0,
}))")" >/dev/null
    SNAPSHOT_UUID=$(json_field "$RPC_OUT" "uuid")

    if [ -n "$SNAPSHOT_UUID" ] && [ "$SNAPSHOT_UUID" != "$OMV_NEW_UUID" ]; then
        _pass "setSnapshot — got real UUID ($SNAPSHOT_UUID)"
    else
        _fail "setSnapshot — no real UUID returned"
        SNAPSHOT_UUID=""
    fi

    if [ -n "$SNAPSHOT_UUID" ]; then
        assert_rpc "getSnapshot" "Restic" "getSnapshot" \
            "{\"uuid\":\"$SNAPSHOT_UUID\"}" "\"uuid\":\"$SNAPSHOT_UUID\"" >/dev/null

        # getSnapshot should return sharedfolderrefs as array, not CSV
        SF_REFS_COUNT=$(echo "$RPC_OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
refs=d.get('sharedfolderrefs',[])
print(len(refs) if isinstance(refs,list) else 0)" 2>/dev/null || echo 0)
        if [ "$SF_REFS_COUNT" = "1" ]; then
            _pass "getSnapshot — sharedfolderrefs returned as array"
        else
            _fail "getSnapshot — sharedfolderrefs not array or empty (count=$SF_REFS_COUNT)"
        fi

        # getSnapshot should return schedule fields as arrays
        MINUTE_IS_ARRAY=$(echo "$RPC_OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('yes' if isinstance(d.get('minute',[]), list) else 'no')" 2>/dev/null || echo no)
        if [ "$MINUTE_IS_ARRAY" = "yes" ]; then
            _pass "getSnapshot — schedule fields returned as arrays"
        else
            _fail "getSnapshot — minute field not an array"
        fi

        assert_rpc "getSnapshotList includes backup job" "Restic" "getSnapshotList" \
            "$LIST_PARAMS" "restic-test-job" >/dev/null

        # getSnapshotList should include a schedule field (built from execution type)
        SCHEDULE=$(echo "$RPC_OUT" | python3 -c "
import sys,json
data=json.load(sys.stdin).get('data',[])
for s in data:
    if s.get('name')=='restic-test-job':
        print(s.get('schedule',''))
        break" 2>/dev/null || echo "")
        if [ "$SCHEDULE" = "0 0 * * *" ]; then
            _pass "getSnapshotList — schedule field correct for daily execution"
        else
            _fail "getSnapshotList — schedule field" "Expected '0 0 * * *', got '$SCHEDULE'"
        fi

        # Update the job — change execution to weekly with retention policy
        assert_rpc "setSnapshot (update, weekly)" "Restic" "setSnapshot" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$SNAPSHOT_UUID',
    'enable': True,
    'name': 'restic-test-job',
    'hash': '',
    'tags': 'test,updated',
    'sharedfolderrefs': ['$FAKE_SF_UUID'],
    'reporef': '$REST_REPO_UUID',
    'exclude': '',
    'execution': 'weekly',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['3'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['0'],
    'keeplast': 5,
    'keepdaily': 7,
    'keepweekly': 4,
    'keepmonthly': 12,
    'keepyearly': 1,
}))")" >/dev/null

        # Test 'exactly' execution mode — verify custom cron expression is built
        assert_rpc "setSnapshot (exactly, custom cron)" "Restic" "setSnapshot" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$SNAPSHOT_UUID',
    'enable': True,
    'name': 'restic-test-job',
    'hash': '',
    'tags': '',
    'sharedfolderrefs': ['$FAKE_SF_UUID'],
    'reporef': '$REST_REPO_UUID',
    'exclude': '',
    'execution': 'exactly',
    'minute': ['30'],
    'everynminute': False,
    'hour': ['4'],
    'everynhour': False,
    'dayofmonth': ['1'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*'],
    'keeplast': 0,
    'keepdaily': 7,
    'keepweekly': 4,
    'keepmonthly': 12,
    'keepyearly': 0,
    'sendemail': True,
    'emailonerror': True,
    'prescript': '  /usr/local/bin/pre.sh --flag \"a b\"  ',
    'postscript': 'echo done',
}))")" >/dev/null

        assert_rpc "getSnapshotList — schedule for exactly" "Restic" "getSnapshotList" \
            "$LIST_PARAMS" >/dev/null
        EXACT_SCHED=$(echo "$RPC_OUT" | python3 -c "
import sys,json
data=json.load(sys.stdin).get('data',[])
for s in data:
    if s.get('name')=='restic-test-job':
        print(s.get('schedule',''))
        break" 2>/dev/null || echo "")
        if [ "$EXACT_SCHED" = "30 4 1 * *" ]; then
            _pass "getSnapshotList — custom cron expression correct"
        else
            _fail "getSnapshotList — custom cron" "Expected '30 4 1 * *', got '$EXACT_SCHED'"
        fi

        # Email notification fields must round-trip
        assert_rpc "getSnapshot (email fields)" "Restic" "getSnapshot" \
            "{\"uuid\":\"$SNAPSHOT_UUID\"}" >/dev/null
        SNAP_SE=$(json_field "$RPC_OUT" "sendemail")
        SNAP_EOE=$(json_field "$RPC_OUT" "emailonerror")
        if [ "$SNAP_SE" = "True" ] && [ "$SNAP_EOE" = "True" ]; then
            _pass "setSnapshot — email fields persisted"
        else
            _fail "setSnapshot — email fields" "Expected True/True, got sendemail=$SNAP_SE emailonerror=$SNAP_EOE"
        fi

        # Hook scripts must round-trip (trimmed on save)
        SNAP_PRE=$(json_field "$RPC_OUT" "prescript")
        SNAP_POST=$(json_field "$RPC_OUT" "postscript")
        if [ "$SNAP_PRE" = '/usr/local/bin/pre.sh --flag "a b"' ] && [ "$SNAP_POST" = "echo done" ]; then
            _pass "setSnapshot — hook scripts persisted"
        else
            _fail "setSnapshot — hook scripts" "Got prescript='$SNAP_PRE' postscript='$SNAP_POST'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Restore Test Jobs CRUD
# Uses the SFTP repo (no backup job references it) so the deleteRepo guard
# below is genuinely exercised by the restore test, not masked by a snapshot.
# ---------------------------------------------------------------------------
section "Restore Test Jobs CRUD"

RT_REPO_UUID="${SFTP_REPO_UUID:-$REST_REPO_UUID}"

if [ -z "$RT_REPO_UUID" ]; then
    _skip "restore test CRUD" "no test repo available"
else
    assert_rpc "getRestoreTestList (pre-test)" "Restic" "getRestoreTestList" "$LIST_PARAMS" >/dev/null

    # Create a dry-run restore test (weekly)
    assert_rpc "setRestoreTest (new, dry-run, weekly)" "Restic" "setRestoreTest" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'enable': True,
    'name': 'restic-test-restoretest',
    'reporef': '$RT_REPO_UUID',
    'mode': 'dryrun',
    'targetref': '',
    'cleanup': True,
    'includepath': '',
    'execution': 'weekly',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['2'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['0'],
}))")" >/dev/null
    RESTORETEST_UUID=$(json_field "$RPC_OUT" "uuid")

    if [ -n "$RESTORETEST_UUID" ] && [ "$RESTORETEST_UUID" != "$OMV_NEW_UUID" ]; then
        _pass "setRestoreTest — got real UUID ($RESTORETEST_UUID)"
    else
        _fail "setRestoreTest — no real UUID returned"
        RESTORETEST_UUID=""
    fi

    if [ -n "$RESTORETEST_UUID" ]; then
        assert_rpc "getRestoreTest" "Restic" "getRestoreTest" \
            "{\"uuid\":\"$RESTORETEST_UUID\"}" "\"uuid\":\"$RESTORETEST_UUID\"" >/dev/null

        # getRestoreTest should return schedule fields as arrays
        MIN_IS_ARRAY=$(echo "$RPC_OUT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('yes' if isinstance(d.get('minute',[]), list) else 'no')" 2>/dev/null || echo no)
        if [ "$MIN_IS_ARRAY" = "yes" ]; then
            _pass "getRestoreTest — schedule fields returned as arrays"
        else
            _fail "getRestoreTest — minute field not an array"
        fi

        assert_rpc "getRestoreTestList includes restore test" "Restic" "getRestoreTestList" \
            "$LIST_PARAMS" "restic-test-restoretest" >/dev/null

        # getRestoreTestList should build a schedule string from execution type
        RT_SCHED=$(echo "$RPC_OUT" | python3 -c "
import sys,json
data=json.load(sys.stdin).get('data',[])
for s in data:
    if s.get('name')=='restic-test-restoretest':
        print(s.get('schedule',''))
        break" 2>/dev/null || echo "")
        if [ "$RT_SCHED" = "0 0 * * 0" ]; then
            _pass "getRestoreTestList — schedule field correct for weekly"
        else
            _fail "getRestoreTestList — schedule field" "Expected '0 0 * * 0', got '$RT_SCHED'"
        fi

        # Update to verify mode with a target folder
        assert_rpc "setRestoreTest (update, verify)" "Restic" "setRestoreTest" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$RESTORETEST_UUID',
    'enable': True,
    'name': 'restic-test-restoretest',
    'reporef': '$RT_REPO_UUID',
    'mode': 'verify',
    'targetref': '$FAKE_SF_UUID',
    'cleanup': True,
    'includepath': '/etc',
    'execution': 'daily',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['3'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*'],
    'sendemail': True,
    'emailonerror': True,
    'prescript': '  /usr/local/bin/pre.sh --flag \"a b\"  ',
    'postscript': 'echo done',
}))")" >/dev/null

        # Email notification fields must round-trip
        assert_rpc "getRestoreTest (email fields)" "Restic" "getRestoreTest" \
            "{\"uuid\":\"$RESTORETEST_UUID\"}" >/dev/null
        RT_SE=$(json_field "$RPC_OUT" "sendemail")
        RT_EOE=$(json_field "$RPC_OUT" "emailonerror")
        if [ "$RT_SE" = "True" ] && [ "$RT_EOE" = "True" ]; then
            _pass "setRestoreTest — email fields persisted"
        else
            _fail "setRestoreTest — email fields" "Expected True/True, got sendemail=$RT_SE emailonerror=$RT_EOE"
        fi

        # Hook scripts must round-trip (trimmed on save)
        RT_PRE=$(json_field "$RPC_OUT" "prescript")
        RT_POST=$(json_field "$RPC_OUT" "postscript")
        if [ "$RT_PRE" = '/usr/local/bin/pre.sh --flag "a b"' ] && [ "$RT_POST" = "echo done" ]; then
            _pass "setRestoreTest — hook scripts persisted"
        else
            _fail "setRestoreTest — hook scripts" "Got prescript='$RT_PRE' postscript='$RT_POST'"
        fi

        # Negative: verify mode without a target folder must be rejected
        assert_rpc_fails "setRestoreTest — verify requires a target folder" \
            "Restic" "setRestoreTest" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$RESTORETEST_UUID',
    'enable': True,
    'name': 'restic-test-restoretest',
    'reporef': '$RT_REPO_UUID',
    'mode': 'verify',
    'targetref': '',
    'cleanup': True,
    'includepath': '',
    'execution': 'daily',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['3'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*'],
}))")"

        # deleteRepo must be blocked while a restore test references it
        assert_rpc_fails "deleteRepo — blocked by referenced restore test" \
            "Restic" "deleteRepo" "{\"uuid\":\"$RT_REPO_UUID\"}"

        # Reset back to dry-run so a manual run needs no real target folder
        assert_rpc "setRestoreTest (reset, dry-run)" "Restic" "setRestoreTest" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$RESTORETEST_UUID',
    'enable': True,
    'name': 'restic-test-restoretest',
    'reporef': '$RT_REPO_UUID',
    'mode': 'dryrun',
    'targetref': '',
    'cleanup': True,
    'includepath': '',
    'execution': 'weekly',
    'minute': ['0'],
    'everynminute': False,
    'hour': ['2'],
    'everynhour': False,
    'dayofmonth': ['*'],
    'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['0'],
}))")" >/dev/null

        # Manually run the dry-run restore test (starts a background task)
        if ! $RESTIC_AVAILABLE; then
            _skip "runRestoreTest — dry-run" "restic binary not installed"
        else
            RT_OUT=$(rpc "Restic" "runRestoreTest" "{\"uuid\":\"$RESTORETEST_UUID\"}" 2>&1) || true
            if [ -n "$RT_OUT" ] && ! echo "$RT_OUT" | grep -qi "exception\|error"; then
                _pass "runRestoreTest — dry-run accepted (background task started)"
            else
                _fail "runRestoreTest — dry-run rejected" "${RT_OUT:0:200}"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Environment Variables CRUD
# ---------------------------------------------------------------------------
section "Environment Variables CRUD"

assert_rpc "getEnvVarList (pre-test)" "Restic" "getEnvVarList" "$LIST_PARAMS" >/dev/null

# Per-repo env var
if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc "setEnvVar (per-repo)" "Restic" "setEnvVar" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'envname': 'RESTIC_TEST_VAR',
    'envvalue': 'test_value_123',
    'reporef': '$REST_REPO_UUID',
}))")" >/dev/null
    ENVVAR_UUID=$(json_field "$RPC_OUT" "uuid")

    if [ -n "$ENVVAR_UUID" ] && [ "$ENVVAR_UUID" != "$OMV_NEW_UUID" ]; then
        _pass "setEnvVar per-repo — got real UUID ($ENVVAR_UUID)"

        assert_rpc "getEnvVar" "Restic" "getEnvVar" \
            "{\"uuid\":\"$ENVVAR_UUID\"}" "\"uuid\":\"$ENVVAR_UUID\"" >/dev/null

        assert_rpc "getEnvVarList includes per-repo var" "Restic" "getEnvVarList" \
            "$LIST_PARAMS" "RESTIC_TEST_VAR" >/dev/null

        # getEnvVarList adds reponame for display
        REPO_NAME=$(echo "$RPC_OUT" | python3 -c "
import sys,json
data=json.load(sys.stdin).get('data',[])
for e in data:
    if e.get('envname')=='RESTIC_TEST_VAR':
        print(e.get('reponame',''))
        break" 2>/dev/null || echo "")
        if [ "$REPO_NAME" = "restic-test-rest" ]; then
            _pass "getEnvVarList — reponame resolved correctly"
        else
            _fail "getEnvVarList — reponame" "Expected 'restic-test-rest', got '$REPO_NAME'"
        fi
    else
        _fail "setEnvVar per-repo — no real UUID returned"
        ENVVAR_UUID=""
    fi
fi

# Shared env var (reporef = "shared")
assert_rpc "setEnvVar (shared)" "Restic" "setEnvVar" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'envname': 'RESTIC_SHARED_TEST',
    'envvalue': 'shared_value_456',
    'reporef': 'shared',
}))")" >/dev/null
ENVVAR_SHARED_UUID=$(json_field "$RPC_OUT" "uuid")

if [ -n "$ENVVAR_SHARED_UUID" ] && [ "$ENVVAR_SHARED_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setEnvVar shared — got real UUID ($ENVVAR_SHARED_UUID)"

    assert_rpc "getEnvVar (shared)" "Restic" "getEnvVar" \
        "{\"uuid\":\"$ENVVAR_SHARED_UUID\"}" '"reporef":"shared"' >/dev/null

    assert_rpc "getEnvVarList — shared reponame is 'All Repositories'" \
        "Restic" "getEnvVarList" "$LIST_PARAMS" '"All Repositories"' >/dev/null
else
    _fail "setEnvVar shared — no real UUID returned"
    ENVVAR_SHARED_UUID=""
fi

# Name normalisation: spaces → underscores
assert_rpc "setEnvVar (name with spaces)" "Restic" "setEnvVar" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'envname': 'MY TEST ENVVAR',
    'envvalue': 'value',
    'reporef': 'shared',
}))")" >/dev/null
ENVVAR_SPACE_UUID=$(json_field "$RPC_OUT" "uuid")
ENVVAR_SPACE_NAME=$(json_field "$RPC_OUT" "envname")

if [ -n "$ENVVAR_SPACE_UUID" ] && [ "$ENVVAR_SPACE_UUID" != "$OMV_NEW_UUID" ]; then
    if [ "$ENVVAR_SPACE_NAME" = "MY_TEST_ENVVAR" ]; then
        _pass "setEnvVar — spaces normalised to underscores"
    else
        _fail "setEnvVar — name normalisation" "Expected MY_TEST_ENVVAR, got $ENVVAR_SPACE_NAME"
    fi
    rpc "Restic" "deleteEnvVar" "{\"uuid\":\"$ENVVAR_SPACE_UUID\"}" &>/dev/null || true
else
    _fail "setEnvVar (name with spaces) — no real UUID returned"
fi

# ---------------------------------------------------------------------------
# REST server settings and users. The server is never enabled here, so the
# cleanup deploy does not install restic-rest-server.
# ---------------------------------------------------------------------------
section "REST server"

assert_rpc "getRestServer" "Restic" "getRestServer" '{}' '"auth"' >/dev/null
ORIG_RESTSERVER=$RPC_OUT

assert_rpc "setRestServer (roundtrip)" "Restic" "setRestServer" "$ORIG_RESTSERVER" >/dev/null

assert_rpc_fails "setRestServer — enable without shared folder rejected" \
    "Restic" "setRestServer" \
    '{"enable":true,"sharedfolderref":"","port":8000,"auth":true}'

assert_rpc_fails "setRestServer — TLS without certificate rejected" \
    "Restic" "setRestServer" \
    '{"enable":false,"sharedfolderref":"","port":8000,"auth":true,"tls":true,"sslcertificateref":""}'

assert_rpc_fails "setRestServer — private repos without login rejected" \
    "Restic" "setRestServer" \
    '{"enable":false,"sharedfolderref":"","port":8000,"auth":false,"privaterepos":true}'

assert_rpc_fails "setRestServer — invalid port rejected" \
    "Restic" "setRestServer" \
    '{"enable":false,"sharedfolderref":"","port":70000,"auth":true}'

assert_rpc_fails "setRestUser — password required for new user" \
    "Restic" "setRestUser" \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"username\":\"restic-test-user\",\"password\":\"\"}"

assert_rpc_fails "setRestUser — invalid username rejected" \
    "Restic" "setRestUser" \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"username\":\"bad:name\",\"password\":\"x\"}"

assert_rpc "setRestUser (new)" "Restic" "setRestUser" \
    "{\"uuid\":\"$OMV_NEW_UUID\",\"username\":\"restic-test-user\",\"password\":\"s3cret pass\"}" >/dev/null
RESTUSER_UUID=$(json_field "$RPC_OUT" "uuid")

if [ -n "$RESTUSER_UUID" ] && [ "$RESTUSER_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setRestUser — got real UUID ($RESTUSER_UUID)"

    assert_rpc "getRestUserList includes user" "Restic" "getRestUserList" \
        "$LIST_PARAMS" "restic-test-user" >/dev/null
    if echo "$RPC_OUT" | grep -q 'passwordhash\|\$2y\$'; then
        _fail "getRestUserList — password hash leaked to the UI"
    else
        _pass "getRestUserList — no password hash in output"
    fi

    assert_rpc "getRestUser — password blank" "Restic" "getRestUser" \
        "{\"uuid\":\"$RESTUSER_UUID\"}" '"password":""' >/dev/null

    HASH_BEFORE=$(omv-confdbadm read --uuid "$RESTUSER_UUID" conf.service.restic.restuser 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('passwordhash',''))" 2>/dev/null)
    case "$HASH_BEFORE" in
        '$2y$'*) _pass "setRestUser — password stored as bcrypt hash" ;;
        *)       _fail "setRestUser — password not stored as bcrypt hash" "${HASH_BEFORE:0:20}" ;;
    esac

    assert_rpc "setRestUser (edit, blank password)" "Restic" "setRestUser" \
        "{\"uuid\":\"$RESTUSER_UUID\",\"username\":\"restic-test-user\",\"password\":\"\"}" >/dev/null
    HASH_AFTER=$(omv-confdbadm read --uuid "$RESTUSER_UUID" conf.service.restic.restuser 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('passwordhash',''))" 2>/dev/null)
    if [ -n "$HASH_BEFORE" ] && [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then
        _pass "setRestUser — blank password on edit keeps existing hash"
    else
        _fail "setRestUser — blank password on edit changed the hash"
    fi

    assert_rpc_fails "setRestUser — duplicate username rejected" "Restic" "setRestUser" \
        "{\"uuid\":\"$OMV_NEW_UUID\",\"username\":\"restic-test-user\",\"password\":\"x\"}"
else
    _fail "setRestUser — no real UUID returned"
    RESTUSER_UUID=""
fi

# ---------------------------------------------------------------------------
# Negative tests
# ---------------------------------------------------------------------------
section "Negative tests"

assert_rpc_fails "getRepo — unknown UUID" "Restic" "getRepo" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

assert_rpc_fails "deleteRepo — unknown UUID" "Restic" "deleteRepo" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

assert_rpc_fails "getSnapshot — unknown UUID" "Restic" "getSnapshot" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

assert_rpc_fails "deleteSnapshot — unknown UUID" "Restic" "deleteSnapshot" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

assert_rpc_fails "getRestoreTest — unknown UUID" "Restic" "getRestoreTest" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

assert_rpc_fails "deleteRestoreTest — unknown UUID" "Restic" "deleteRestoreTest" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

assert_rpc_fails "getEnvVar — unknown UUID" "Restic" "getEnvVar" \
    '{"uuid":"00000000-0000-4000-8000-000000000001"}'

# Duplicate repo name
if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc_fails "setRepo — duplicate name rejected" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-rest',
    'type': 'rest',
    'passphrase': 'other',
    'uri': 'http://localhost:18001/',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")"
fi

# deleteRepo blocked while a backup job references it
if [ -n "$REST_REPO_UUID" ] && [ -n "$SNAPSHOT_UUID" ]; then
    assert_rpc_fails "deleteRepo — blocked by referenced backup job" \
        "Restic" "deleteRepo" "{\"uuid\":\"$REST_REPO_UUID\"}"
fi

# Invalid repo type
assert_rpc_fails "setRepo — invalid type rejected" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'name': 'restic-test-badtype',
    'type': 'ftp',
    'passphrase': 'test',
    'uri': 'ftp://example.com',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
}))")"

# Scheduled check options
if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc "setRepo — scheduled check options" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$REST_REPO_UUID',
    'name': 'restic-test-rest',
    'type': 'rest',
    'passphrase': 'testpassword123',
    'uri': 'http://localhost:18000/',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
    'checkschedule': 'weekly',
    'checkreaddata': '5%',
    'checkemail': 'always',
}))")" '"checkschedule":"weekly"' >/dev/null

    assert_rpc_fails "setRepo — invalid read data subset rejected" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({
    'uuid': '$REST_REPO_UUID',
    'name': 'restic-test-rest',
    'type': 'rest',
    'passphrase': 'testpassword123',
    'uri': 'http://localhost:18000/',
    'sharedfolderref': '',
    'accesskey': '',
    'secretkey': '',
    'skipinit': True,
    'checkschedule': 'weekly',
    'checkreaddata': '5%; rm -rf /',
    'checkemail': 'always',
}))")"
fi

# getRepoSnapshotList — missing reporef
assert_rpc_fails "getRepoSnapshotList — missing reporef" \
    "Restic" "getRepoSnapshotList" \
    '{"start":0,"limit":25,"sortfield":null,"sortdir":null}'

# ---------------------------------------------------------------------------
# getRepoSnapshotList — runs `restic snapshots --json` against the repo.
# With a fake REST URL restic may hang waiting for a connection, so wrap in
# a timeout. A timeout is treated as a skip rather than a failure.
# ---------------------------------------------------------------------------
section "getRepoSnapshotList (fake repo — expects an error or connection timeout)"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "getRepoSnapshotList" "no test repo available"
elif ! $RESTIC_AVAILABLE; then
    _skip "getRepoSnapshotList" "restic binary not installed"
else
    SL_PARAMS="{\"reporef\":\"$REST_REPO_UUID\",\"start\":0,\"limit\":25,\"sortfield\":\"time\",\"sortdir\":\"desc\"}"
    SL_OUT=""
    SL_EC=0
    SL_OUT=$(timeout 15 omv-rpc -u admin "Restic" "getRepoSnapshotList" "$SL_PARAMS" 2>&1) || SL_EC=$?

    # An unreachable repository must be reported as an error, not shown as
    # an empty snapshot list.
    if [ $SL_EC -eq 124 ]; then
        _pass "getRepoSnapshotList — timed out as expected (fake REST URL, synchronous call)"
    elif [ $SL_EC -ne 0 ] || echo "$SL_OUT" | grep -qi "exception"; then
        _pass "getRepoSnapshotList — unreachable repository reported as an error"
    else
        _fail "getRepoSnapshotList — unreachable repository returned a result" "${SL_OUT:0:200}"
    fi
fi

# ---------------------------------------------------------------------------
# Background operations: checkRepo, pruneRepo, getRepoStats, testRepo, unlockRepo
# These start a background process (execBgProc) and return a task handle.
# The task will fail because the REST URL is fake; we just verify the RPC
# accepts the call and returns a non-empty response.
# ---------------------------------------------------------------------------
section "Background operations (check / prune / stats / test / unlock)"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "background operations" "no test repo available"
elif ! $RESTIC_AVAILABLE; then
    _skip "background operations" "restic binary not installed"
else
    for op in checkRepo pruneRepo getRepoStats testRepo unlockRepo; do
        BG_OUT=$(rpc "Restic" "$op" "{\"uuid\":\"$REST_REPO_UUID\"}" 2>&1) || true
        if [ -n "$BG_OUT" ] && ! echo "$BG_OUT" | grep -qi "exception\|error"; then
            _pass "$op — RPC accepted (background task started)"
        else
            _fail "$op — RPC failed or returned exception" "${BG_OUT:0:200}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Single-snapshot operations: inspect / list files / forget
# The snapshot ID is validated as hex before any command is built, so
# anything else (including shell metacharacters) must be rejected up front.
# ---------------------------------------------------------------------------
section "Snapshot operations (inspect / ls / forget)"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "snapshot operations" "no test repo available"
else
    for op in inspectRepoSnapshot listRepoSnapshotFiles; do
        assert_rpc_fails "$op — non-hex snapshot ID rejected" "Restic" "$op" \
            "{\"reporef\":\"$REST_REPO_UUID\",\"snapshotid\":\"abcdef12;id\"}"
        assert_rpc_fails "$op — missing snapshot ID rejected" "Restic" "$op" \
            "{\"reporef\":\"$REST_REPO_UUID\"}"
    done
    for ids in "abcdef12;id" "abcdef12," "" "abcdef12,xyz"; do
        assert_rpc_fails "forgetRepoSnapshots — invalid ID list '$ids' rejected" \
            "Restic" "forgetRepoSnapshots" \
            "{\"reporef\":\"$REST_REPO_UUID\",\"snapshotids\":\"$ids\"}"
    done

    if ! $RESTIC_AVAILABLE; then
        _skip "snapshot operations — accepted" "restic binary not installed"
    else
        for call in \
            "inspectRepoSnapshot|{\"reporef\":\"$REST_REPO_UUID\",\"snapshotid\":\"abcdef12\"}" \
            "listRepoSnapshotFiles|{\"reporef\":\"$REST_REPO_UUID\",\"snapshotid\":\"abcdef12\"}" \
            "forgetRepoSnapshots|{\"reporef\":\"$REST_REPO_UUID\",\"snapshotids\":\"abcdef12,0123abcd\",\"prune\":false}"; do
            op=${call%%|*}
            OP_OUT=$(rpc "Restic" "$op" "${call#*|}" 2>&1) || true
            if [ -n "$OP_OUT" ] && ! echo "$OP_OUT" | grep -qi "exception\|error"; then
                _pass "$op — RPC accepted (background task started)"
            else
                _fail "$op — RPC failed or returned exception" "${OP_OUT:0:200}"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Task output must never contain secrets. The "Command:" line used to print
# the full environment, including RESTIC_PASSWORD.
# ---------------------------------------------------------------------------
section "Secrets masked in task output"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "secret masking" "no test repo available"
elif ! $RESTIC_AVAILABLE; then
    _skip "secret masking" "restic binary not installed"
else
    BG_FILE=$(rpc "Restic" "testRepo" "{\"uuid\":\"$REST_REPO_UUID\"}" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null)
    sleep 2
    # The RPC returns JSON (which escapes "/" as "\/"), so decode it and
    # check the plain task output text.
    TASK_OUT=$(rpc "Exec" "getOutput" "{\"filename\":\"$BG_FILE\",\"pos\":0}" 2>&1 | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('output',''))" 2>&1 || true)
    if [ -z "$BG_FILE" ] || ! echo "$TASK_OUT" | grep -q "Command: /usr/bin/restic"; then
        _fail "task output — could not read Command line" "${TASK_OUT:0:200}"
    elif echo "$TASK_OUT" | grep -q "testpassword123\|RESTIC_PASSWORD"; then
        _fail "task output — repository password leaked"
    else
        _pass "task output — command shown without password or environment"
    fi
fi

# ---------------------------------------------------------------------------
# Scheduled retention policy per repository
# ---------------------------------------------------------------------------
section "Repository retention policy"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "retention policy" "no test repo available"
else
    RETENTION_BASE="'uuid': '$REST_REPO_UUID', 'name': 'restic-test-rest', 'type': 'rest',
    'passphrase': 'testpassword123', 'uri': 'http://localhost:18000/', 'sharedfolderref': '',
    'accesskey': '', 'secretkey': '', 'skipinit': True"

    assert_rpc "setRepo — retention disabled, no keep rules" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({$RETENTION_BASE, 'forgetschedule': 'disabled',
    'forgetkeeplast': 0, 'forgetkeepdaily': 0, 'forgetkeepweekly': 0,
    'forgetkeepmonthly': 0, 'forgetkeepyearly': 0}))")" >/dev/null

    assert_rpc_fails "applyRepoForget — no policy rejected" "Restic" "applyRepoForget" \
        "{\"uuid\":\"$REST_REPO_UUID\",\"dryrun\":true}"

    assert_rpc_fails "setRepo — schedule without keep rules rejected" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({$RETENTION_BASE, 'forgetschedule': 'weekly',
    'forgetkeeplast': 0, 'forgetkeepdaily': 0, 'forgetkeepweekly': 0,
    'forgetkeepmonthly': 0, 'forgetkeepyearly': 0}))")"

    assert_rpc_fails "setRepo — invalid retention host rejected" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({$RETENTION_BASE, 'forgetschedule': 'weekly',
    'forgetkeepdaily': 7, 'forgethost': 'bad host;id'}))")"

    assert_rpc "setRepo — retention policy saved" "Restic" "setRepo" "$(python3 -c "
import json; print(json.dumps({$RETENTION_BASE, 'forgetschedule': 'weekly',
    'forgetkeeplast': 3, 'forgetkeepdaily': 7, 'forgetkeepweekly': 4,
    'forgetkeepmonthly': 0, 'forgetkeepyearly': 0, 'forgethost': 'client-1',
    'forgettag': 'daily', 'forgetprune': True, 'forgetemail': 'onerror'}))")" \
        '"forgetschedule":"weekly"' >/dev/null

    if ! $RESTIC_AVAILABLE; then
        _skip "applyRepoForget — accepted" "restic binary not installed"
    else
        for dry in true false; do
            AF_OUT=$(rpc "Restic" "applyRepoForget" \
                "{\"uuid\":\"$REST_REPO_UUID\",\"dryrun\":$dry}" 2>&1) || true
            if [ -n "$AF_OUT" ] && ! echo "$AF_OUT" | grep -qi "exception\|error"; then
                _pass "applyRepoForget (dryrun=$dry) — RPC accepted (background task started)"
            else
                _fail "applyRepoForget (dryrun=$dry) — RPC rejected" "${AF_OUT:0:200}"
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Restore — dry-run preview
# A dry-run restore (dryrun=true) needs no target folder and starts a
# background `restic restore --dry-run` task. Against the fake REST repo the
# task itself will fail, but the RPC must accept the call and start the task.
# A normal restore (dryrun=false) must reject a missing target folder.
# ---------------------------------------------------------------------------
section "Restore (dry-run preview)"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "restore dry-run" "no test repo available"
else
    # Negative: a real (non-dry-run) restore requires a target folder.
    assert_rpc_fails "restoreSnapshot — target required when not a dry run" \
        "Restic" "restoreSnapshot" \
        "{\"reporef\":\"$REST_REPO_UUID\",\"snapshotid\":\"latest\",\"dryrun\":false}"

    # Negative: reporef and snapshotid are mandatory regardless of dry-run.
    assert_rpc_fails "restoreSnapshot — missing snapshotid rejected" \
        "Restic" "restoreSnapshot" \
        "{\"reporef\":\"$REST_REPO_UUID\",\"dryrun\":true}"

    if ! $RESTIC_AVAILABLE; then
        _skip "restoreSnapshot — dry-run accepted" "restic binary not installed"
    else
        # Positive: dry-run needs no target and must be accepted (bg task).
        DR_OUT=$(rpc "Restic" "restoreSnapshot" \
            "{\"reporef\":\"$REST_REPO_UUID\",\"snapshotid\":\"latest\",\"dryrun\":true}" 2>&1) || true
        if [ -n "$DR_OUT" ] && ! echo "$DR_OUT" | grep -qi "exception\|error"; then
            _pass "restoreSnapshot — dry-run accepted (no target, background task started)"
        else
            _fail "restoreSnapshot — dry-run rejected" "${DR_OUT:0:200}"
        fi

        # Positive: dry-run with an include-path filter must also be accepted.
        DR_OUT2=$(rpc "Restic" "restoreSnapshot" \
            "{\"reporef\":\"$REST_REPO_UUID\",\"snapshotid\":\"latest\",\"dryrun\":true,\"includepath\":\"/etc\"}" 2>&1) || true
        if [ -n "$DR_OUT2" ] && ! echo "$DR_OUT2" | grep -qi "exception\|error"; then
            _pass "restoreSnapshot — dry-run with include-path accepted"
        else
            _fail "restoreSnapshot — dry-run with include-path rejected" "${DR_OUT2:0:200}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Input validation added with the bug fixes: values that end up in generated
# shell scripts, cron lines or htpasswd must not carry newlines or shell
# syntax, and an "every N" schedule needs exactly one positive number.
# ---------------------------------------------------------------------------
section "Input validation"

# Backup job parameters shared by the tests below (python dict literal body).
JOB_BASE="'uuid': '$OMV_NEW_UUID', 'enable': False, 'name': 'restic-test-validation',
    'hash': '', 'tags': '', 'sharedfolderrefs': ['$FAKE_SF_UUID'],
    'reporef': '${REST_REPO_UUID:-$FAKE_SF_UUID}', 'exclude': '', 'execution': 'exactly',
    'minute': ['0'], 'everynminute': False, 'hour': ['0'], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False, 'month': ['*'], 'dayofweek': ['*']"

assert_rpc_fails "setSnapshot — name with a newline rejected" "Restic" "setSnapshot" \
    "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'name': 'a\nb'}))")"
assert_rpc_fails "setSnapshot — cron line injection in a schedule value rejected" "Restic" "setSnapshot" \
    "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'minute': ['0\n* * * * * root id']}))")"
for kw in "'minute': ['0', '30'], 'everynminute': True" \
          "'minute': ['*'], 'everynminute': True" \
          "'hour': ['0'], 'everynhour': True" \
          "'dayofmonth': ['1', '15'], 'everyndayofmonth': True"; do
    assert_rpc_fails "setSnapshot — invalid 'every N' schedule rejected ($kw)" "Restic" "setSnapshot" \
        "$(python3 -c "import json; print(json.dumps({$JOB_BASE, $kw}))")"
done
assert_rpc_fails "setRestoreTest — name with a newline rejected" "Restic" "setRestoreTest" \
    "$(python3 -c "import json; print(json.dumps({'uuid': '$OMV_NEW_UUID', 'name': 'a\nb',
    'reporef': '$FAKE_SF_UUID', 'mode': 'dryrun', 'execution': 'weekly', 'minute': ['0'],
    'everynminute': False, 'hour': ['0'], 'everynhour': False, 'dayofmonth': ['*'],
    'everyndayofmonth': False, 'month': ['*'], 'dayofweek': ['*']}))")"

if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc "setSnapshot — 'every 15 minutes' accepted" "Restic" "setSnapshot" \
        "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'name': 'restic-test-every-n',
        'minute': ['15'], 'everynminute': True, 'hour': ['*']}))")" >/dev/null
    EVERY_N_UUID=$(json_field "$RPC_OUT" "uuid")
    if [ -n "$EVERY_N_UUID" ]; then
        assert_rpc "getSnapshotList — 'every N' schedule shown as */N" "Restic" "getSnapshotList" \
            "$LIST_PARAMS" '"schedule":"\*\\/15 \* \* \* \*"' >/dev/null
        rpc "Restic" "deleteSnapshot" "{\"uuid\":\"$EVERY_N_UUID\"}" &>/dev/null || true
    fi
fi

assert_rpc_fails "setEnvVar — name with a dash rejected" "Restic" "setEnvVar" \
    '{"uuid":"'"$OMV_NEW_UUID"'","envname":"MY-VAR","envvalue":"x","reporef":"shared"}'
assert_rpc_fails "setEnvVar — name with = rejected" "Restic" "setEnvVar" \
    '{"uuid":"'"$OMV_NEW_UUID"'","envname":"A=B","envvalue":"x","reporef":"shared"}'
assert_rpc_fails "setEnvVar — value with a newline rejected" "Restic" "setEnvVar" \
    '{"uuid":"'"$OMV_NEW_UUID"'","envname":"RESTIC_TEST_NL","envvalue":"a\nb","reporef":"shared"}'
assert_rpc "setEnvVar — value with shell metacharacters accepted" "Restic" "setEnvVar" \
    "$(python3 -c "import json; print(json.dumps({'uuid': '$OMV_NEW_UUID',
    'envname': 'RESTIC_TEST_META', 'envvalue': 'pa\$\$ \`x\` \"y\" \\'z\\'', 'reporef': 'shared'}))")" >/dev/null
META_UUID=$(json_field "$RPC_OUT" "uuid")
[ -n "$META_UUID" ] && rpc "Restic" "deleteEnvVar" "{\"uuid\":\"$META_UUID\"}" &>/dev/null

assert_rpc_fails "setRepo — local repository without a shared folder rejected" "Restic" "setRepo" \
    '{"uuid":"'"$OMV_NEW_UUID"'","name":"restic-test-nosf","type":"local","sharedfolderref":"","passphrase":"x","skipinit":true}'
assert_rpc_fails "setRepo — name with a newline rejected" "Restic" "setRepo" \
    '{"uuid":"'"$OMV_NEW_UUID"'","name":"restic-test\nx","type":"rest","uri":"http://localhost:18001/","sharedfolderref":"","passphrase":"x","skipinit":true}'
assert_rpc_fails "setRestUser — username with a trailing newline rejected" "Restic" "setRestUser" \
    '{"uuid":"'"$OMV_NEW_UUID"'","username":"restic-test-nl\n","password":"x"}'
if [ -n "$REST_REPO_UUID" ]; then
    assert_rpc_fails "inspectRepoSnapshot — ID with a trailing newline rejected" "Restic" \
        "inspectRepoSnapshot" '{"reporef":"'"$REST_REPO_UUID"'","snapshotid":"abcdef12\n"}'
fi
assert_rpc_fails "deleteRepo — non-boolean deletedata rejected" "Restic" "deleteRepo" \
    '{"uuid":"00000000-0000-4000-8000-000000000001","deletedata":"yes"}'
assert_rpc_fails "createSnapshot — no longer callable over RPC" "Restic" "createSnapshot" \
    '{"reporef":"'"$FAKE_SF_UUID"'","sharedfolderrefs":[],"prescript":"id"}'

# ---------------------------------------------------------------------------
# Failures must be reported. An rclone repository whose remote does not exist
# makes restic fail within a second, so every operation against it must end
# with an error instead of a "successful" task.
# ---------------------------------------------------------------------------
section "Failures are reported (repository that cannot be opened)"

# A real shared folder, used only as a backup source that is never read
# (restic fails to open the repository first) and for name resolution.
REAL_SF_UUID=$(rpc "ShareMgmt" "enumerateSharedFolders" '{}' 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d[0]['uuid'] if d else '')" 2>/dev/null || echo "")
REAL_SF_NAME=$(rpc "ShareMgmt" "enumerateSharedFolders" '{}' 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d[0]['name'] if d else '')" 2>/dev/null || echo "")

if ! $RESTIC_AVAILABLE || ! command -v rclone &>/dev/null; then
    _skip "failure reporting" "restic or rclone not installed"
else
    assert_rpc "setRepo (rclone, missing remote)" "Restic" "setRepo" \
        '{"uuid":"'"$OMV_NEW_UUID"'","name":"restic-test-failing","type":"rclone","uri":"restic-test-missing-remote:repo","sharedfolderref":"","accesskey":"","secretkey":"","passphrase":"x","skipinit":true}' >/dev/null
    FAIL_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
fi

if [ -n "$FAIL_REPO_UUID" ]; then
    P="{\"uuid\":\"$FAIL_REPO_UUID\"}"
    assert_task "testRepo — failure reported, no 'Connection successful'" error \
        "Restic" "testRepo" "$P" "" "Connection successful"
    for op in checkRepo pruneRepo getRepoStats unlockRepo; do
        assert_task "$op — failure reported" error "Restic" "$op" "$P"
    done
    assert_rpc "setRepo (failing repo, retention policy)" "Restic" "setRepo" \
        '{"uuid":"'"$FAIL_REPO_UUID"'","name":"restic-test-failing","type":"rclone","uri":"restic-test-missing-remote:repo","sharedfolderref":"","accesskey":"","secretkey":"","passphrase":"x","skipinit":true,"forgetschedule":"disabled","forgetkeeplast":1}' >/dev/null
    assert_task "applyRepoForget (dry run) — failure reported" error "Restic" "applyRepoForget" \
        "{\"uuid\":\"$FAIL_REPO_UUID\",\"dryrun\":true}"
    assert_task "restoreSnapshot (dry run) — failure reported" error "Restic" "restoreSnapshot" \
        "{\"reporef\":\"$FAIL_REPO_UUID\",\"snapshotid\":\"latest\",\"dryrun\":true}"
    assert_rpc_fails "getRepoSnapshotList — failure reported, not an empty list" \
        "Restic" "getRepoSnapshotList" \
        "{\"reporef\":\"$FAIL_REPO_UUID\",\"start\":0,\"limit\":25,\"sortfield\":\"time\",\"sortdir\":\"desc\"}"

    assert_rpc "setRestoreTest (dry run, failing repo)" "Restic" "setRestoreTest" \
        "$(python3 -c "import json; print(json.dumps({'uuid': '$OMV_NEW_UUID', 'enable': False,
        'name': 'restic-test-failing-rt', 'reporef': '$FAIL_REPO_UUID', 'mode': 'dryrun',
        'execution': 'weekly', 'minute': ['0'], 'everynminute': False, 'hour': ['0'],
        'everynhour': False, 'dayofmonth': ['*'], 'everyndayofmonth': False,
        'month': ['*'], 'dayofweek': ['*']}))")" >/dev/null
    FAIL_RT_UUID=$(json_field "$RPC_OUT" "uuid")
    [ -n "$FAIL_RT_UUID" ] && assert_task "runRestoreTest — failed restore reported" error \
        "Restic" "runRestoreTest" "{\"uuid\":\"$FAIL_RT_UUID\"}"

    if [ -z "$REAL_SF_UUID" ]; then
        _skip "runSnapshot — failed backup" "no shared folder to use as a source"
    else
        assert_rpc "setSnapshot (failing repo, retention on)" "Restic" "setSnapshot" \
            "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'name': 'restic-test-failing-job',
            'sharedfolderrefs': ['$FAKE_SF_UUID', '$REAL_SF_UUID'], 'reporef': '$FAIL_REPO_UUID',
            'execution': 'daily', 'keepdaily': 7, 'postscript': 'echo post-ran'}))")" >/dev/null
        FAIL_JOB_UUID=$(json_field "$RPC_OUT" "uuid")
    fi
    if [ -n "$FAIL_JOB_UUID" ]; then
        # The job's first source folder does not exist; the list must still
        # not start with a separator.
        assert_rpc "getSnapshotList — failing job listed" "Restic" "getSnapshotList" "$LIST_PARAMS" >/dev/null
        SRC_NAME=$(echo "$RPC_OUT" | python3 -c "
import sys,json
for s in json.load(sys.stdin).get('data',[]):
    if s.get('uuid')=='$FAIL_JOB_UUID': print(s.get('sourcename',''))" 2>/dev/null)
        if [ "$SRC_NAME" = "$REAL_SF_NAME" ]; then
            _pass "getSnapshotList — source names have no leading separator"
        else
            _fail "getSnapshotList — source names" "expected '$REAL_SF_NAME', got '$SRC_NAME'"
        fi

        # A failed manual backup must fail the task and must not go on to
        # apply the retention policy; the post-script still runs. Drop the
        # missing source folder first, so the backup really runs restic.
        assert_rpc "setSnapshot (failing repo, existing source only)" "Restic" "setSnapshot" \
            "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'uuid': '$FAIL_JOB_UUID',
            'name': 'restic-test-failing-job', 'sharedfolderrefs': ['$REAL_SF_UUID'],
            'reporef': '$FAIL_REPO_UUID', 'execution': 'daily', 'keepdaily': 7,
            'postscript': 'echo post-ran'}))")" >/dev/null
        assert_task "runSnapshot — failed backup reported" error \
            "Restic" "runSnapshot" "{\"uuid\":\"$FAIL_JOB_UUID\"}"
        if ! echo "$TASK_RAW_OUTPUT" | grep -q "Command: /usr/bin/restic backup"; then
            _fail "runSnapshot — could not read the task output" "${TASK_RAW_OUTPUT:0:200}"
        elif echo "$TASK_RAW_OUTPUT" | grep -q "Applying retention policy"; then
            _fail "runSnapshot — retention applied after a failed backup"
        else
            _pass "runSnapshot — no retention after a failed backup"
        fi
        if echo "$TASK_RAW_OUTPUT" | grep -q "post-ran"; then
            _pass "runSnapshot — post-script still runs after a failed backup"
        else
            _fail "runSnapshot — post-script did not run after a failed backup"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# End to end against a real local repository in temporary shared folders:
# init, test, backup (snapshot ID recorded), list, delete the job (snapshots
# kept), delete the repo (data kept), re-import, delete with its data.
# ---------------------------------------------------------------------------
section "End to end (temporary local repository)"

MNTENT_UUID=""
if [ -n "$REAL_SF_UUID" ]; then
    MNTENT_UUID=$(omv-confdbadm read --uuid "$REAL_SF_UUID" conf.system.sharedfolder 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('mntentref',''))" 2>/dev/null)
fi

if ! $RESTIC_AVAILABLE; then
    _skip "end to end" "restic binary not installed"
elif [ -z "$MNTENT_UUID" ]; then
    _skip "end to end" "no mounted file system with a shared folder found"
else
    SUFFIX=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
    for kind in repo src; do
        assert_rpc "create temporary shared folder ($kind)" "ShareMgmt" "set" \
            "{\"uuid\":\"$OMV_NEW_UUID\",\"name\":\"restic-test-$kind-$SUFFIX\",\"reldirpath\":\"restic-test-$kind-$SUFFIX/\",\"comment\":\"openmediavault-restic test, safe to delete\",\"mntentref\":\"$MNTENT_UUID\",\"mode\":\"700\"}" >/dev/null
        if [ "$kind" = repo ]; then E2E_SF_REPO_UUID=$(json_field "$RPC_OUT" "uuid");
        else E2E_SF_SRC_UUID=$(json_field "$RPC_OUT" "uuid"); fi
    done
fi

if [ -n "$E2E_SF_REPO_UUID" ] && [ -n "$E2E_SF_SRC_UUID" ]; then
    REPO_PATH=$(rpc "ShareMgmt" "getPath" "{\"uuid\":\"$E2E_SF_REPO_UUID\"}" | python3 -c "import sys,json; print(json.load(sys.stdin))")
    SRC_PATH=$(rpc "ShareMgmt" "getPath" "{\"uuid\":\"$E2E_SF_SRC_UUID\"}" | python3 -c "import sys,json; print(json.load(sys.stdin))")
    mkdir -p "$SRC_PATH/deep/skip" && echo "restic test data" > "$SRC_PATH/file.txt"
    echo "excluded" > "$SRC_PATH/deep/skip/secret.txt"

    E2E_REPO_JSON="'name': 'restic-test-e2e-$SUFFIX', 'type': 'local',
        'sharedfolderref': '$E2E_SF_REPO_UUID', 'passphrase': \"e2e pa\$\$ 'word\\\"\""
    assert_rpc "setRepo (local, initialise)" "Restic" "setRepo" \
        "$(python3 -c "import json; print(json.dumps({'uuid': '$OMV_NEW_UUID', $E2E_REPO_JSON, 'skipinit': False}))")" >/dev/null
    E2E_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
    [ -f "$REPO_PATH/config" ] && _pass "setRepo — repository initialised" || \
        _fail "setRepo — no repository config in $REPO_PATH"
fi

if [ -n "$E2E_REPO_UUID" ]; then
    assert_task "testRepo — reachable repository reports success" ok \
        "Restic" "testRepo" "{\"uuid\":\"$E2E_REPO_UUID\"}" "Connection successful"

    assert_rpc "setSnapshot (local e2e job)" "Restic" "setSnapshot" \
        "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'name': 'restic-test-e2e-job',
        'sharedfolderrefs': ['$E2E_SF_SRC_UUID'], 'reporef': '$E2E_REPO_UUID',
        'excludelist': '# nested directory\\n$SRC_PATH/deep/skip',
        'execution': 'daily', 'keepdaily': 7}))")" >/dev/null
    E2E_JOB_UUID=$(json_field "$RPC_OUT" "uuid")

    assert_rpc "setSnapshot (include list only)" "Restic" "setSnapshot" \
        "$(python3 -c "import json; print(json.dumps({$JOB_BASE, 'name': 'restic-test-e2e-files-job',
        'sharedfolderrefs': [], 'fileslist': '$SRC_PATH/file.txt', 'reporef': '$E2E_REPO_UUID'}))")" >/dev/null
    E2E_FILES_JOB_UUID=$(json_field "$RPC_OUT" "uuid")
fi

if [ -n "$E2E_JOB_UUID" ]; then
    HASH_FILE="/var/lib/openmediavault/restic/hash-$E2E_JOB_UUID"
    SL_PARAMS="{\"reporef\":\"$E2E_REPO_UUID\",\"start\":0,\"limit\":25,\"sortfield\":\"time\",\"sortdir\":\"desc\"}"
    assert_task "runSnapshot (dry run, list files) — exclude list applied" ok \
        "Restic" "runSnapshot" "{\"uuid\":\"$E2E_JOB_UUID\",\"dryrun\":true,\"listfiles\":true}" \
        "file.txt" "secret.txt"
    assert_task "runSnapshot (dry run, summary) — reports what would be added" ok \
        "Restic" "runSnapshot" "{\"uuid\":\"$E2E_JOB_UUID\",\"dryrun\":true}" \
        "Would add to the repository" "Applying retention policy"
    if [ -n "$E2E_FILES_JOB_UUID" ]; then
        assert_task "runSnapshot (dry run) — include list only job" ok \
            "Restic" "runSnapshot" "{\"uuid\":\"$E2E_FILES_JOB_UUID\",\"dryrun\":true,\"listfiles\":true}" \
            "file.txt"
        assert_rpc "deleteSnapshot — include list only job" "Restic" "deleteSnapshot" \
            "{\"uuid\":\"$E2E_FILES_JOB_UUID\"}" >/dev/null
        E2E_FILES_JOB_UUID=""
    fi
    assert_rpc "runSnapshot (dry run) — no snapshot created" "Restic" "getRepoSnapshotList" \
        "$SL_PARAMS" '"total":0' >/dev/null
    [ -e "$HASH_FILE" ] && _fail "runSnapshot (dry run) — snapshot ID recorded" || \
        _pass "runSnapshot (dry run) — no snapshot ID recorded"
    ls /tmp/restic-excludelist-* /tmp/restic-fileslist-* &>/dev/null && \
        _fail "runSnapshot — temporary list files left behind" || \
        _pass "runSnapshot — temporary list files removed"

    assert_task "runSnapshot — backup succeeds and applies retention" ok \
        "Restic" "runSnapshot" "{\"uuid\":\"$E2E_JOB_UUID\"}" "Applying retention policy"
    if [ -s "$HASH_FILE" ]; then
        _pass "runSnapshot — snapshot ID recorded ($(cat "$HASH_FILE"))"
    else
        _fail "runSnapshot — no snapshot ID recorded in $HASH_FILE"
    fi

    assert_rpc "getRepoSnapshotList — backup listed" "Restic" "getRepoSnapshotList" "$SL_PARAMS" '"total":1' >/dev/null
    assert_task "restoreSnapshot (dry run) — succeeds" ok "Restic" "restoreSnapshot" \
        "{\"reporef\":\"$E2E_REPO_UUID\",\"snapshotid\":\"latest\",\"dryrun\":true}"

    assert_rpc "deleteSnapshot — job deleted" "Restic" "deleteSnapshot" "{\"uuid\":\"$E2E_JOB_UUID\"}" >/dev/null
    E2E_JOB_UUID=""
    assert_rpc "deleteSnapshot — the job's snapshots are kept" "Restic" "getRepoSnapshotList" \
        "$SL_PARAMS" '"total":1' >/dev/null
    [ -e "$HASH_FILE" ] && _fail "deleteSnapshot — snapshot ID file left behind" || \
        _pass "deleteSnapshot — snapshot ID file removed"

    assert_rpc "deleteRepo (default) — removed from config" "Restic" "deleteRepo" \
        "{\"uuid\":\"$E2E_REPO_UUID\"}" >/dev/null
    E2E_REPO_UUID=""
    [ -f "$REPO_PATH/config" ] && [ -d "$REPO_PATH/data" ] && \
        _pass "deleteRepo (default) — repository data kept" || \
        _fail "deleteRepo (default) — repository data was deleted"

    assert_rpc "setRepo (re-import with skipinit)" "Restic" "setRepo" \
        "$(python3 -c "import json; print(json.dumps({'uuid': '$OMV_NEW_UUID', $E2E_REPO_JSON, 'skipinit': True}))")" >/dev/null
    E2E_REPO_UUID=$(json_field "$RPC_OUT" "uuid")
    assert_rpc "getRepoSnapshotList — re-imported repository still has its snapshot" \
        "Restic" "getRepoSnapshotList" \
        "{\"reporef\":\"$E2E_REPO_UUID\",\"start\":0,\"limit\":25,\"sortfield\":\"time\",\"sortdir\":\"desc\"}" \
        '"total":1' >/dev/null

    assert_rpc "deleteRepo (deletedata) — removed" "Restic" "deleteRepo" \
        "{\"uuid\":\"$E2E_REPO_UUID\",\"deletedata\":true}" >/dev/null
    E2E_REPO_UUID=""
    if [ ! -e "$REPO_PATH/config" ] && [ ! -e "$REPO_PATH/data" ] && [ -d "$REPO_PATH" ]; then
        _pass "deleteRepo (deletedata) — repository data deleted, shared folder kept"
    else
        _fail "deleteRepo (deletedata) — unexpected state of $REPO_PATH"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS + FAIL + SKIP))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC} (${TOTAL} total)" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done
fi
echo >&2

[ $FAIL -eq 0 ]
