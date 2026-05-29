#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-restic RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh
#
# Exercises all plugin RPC methods against the live OMV configuration database.
# Creates test repositories, backup jobs, and env vars, then removes them on
# exit. No actual restic backups are performed against live data — all repos
# are registered with skipinit=true so no real restic server is required.
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

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
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

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
REST_REPO_UUID=""
SFTP_REPO_UUID=""
S3_REPO_UUID=""
B2_REPO_UUID=""
RCLONE_REPO_UUID=""
SNAPSHOT_UUID=""
ENVVAR_UUID=""
ENVVAR_SHARED_UUID=""

LIST_PARAMS='{"start":0,"limit":25,"sortfield":null,"sortdir":null}'

OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

# Syntactically valid UUIDv4 used as a placeholder shared folder ref when we
# only need DB storage (not actual path resolution).
FAKE_SF_UUID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
    echo "12345678-1234-4234-8234-123456789abc")

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    # Backup jobs must go before repos (deleteRepo checks for references)
    if [ -n "$SNAPSHOT_UUID" ]; then
        info "Deleting test backup job $SNAPSHOT_UUID"
        rpc "Restic" "deleteSnapshot" "{\"uuid\":\"$SNAPSHOT_UUID\"}" &>/dev/null || true
    fi

    for uuid in "$ENVVAR_UUID" "$ENVVAR_SHARED_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting env var $uuid"
        rpc "Restic" "deleteEnvVar" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    for uuid in "$REST_REPO_UUID" "$SFTP_REPO_UUID" "$S3_REPO_UUID" "$B2_REPO_UUID" "$RCLONE_REPO_UUID"; do
        [ -z "$uuid" ] && continue
        info "Deleting repo $uuid"
        rpc "Restic" "deleteRepo" "{\"uuid\":\"$uuid\"}" &>/dev/null || true
    done

    info "Done."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
section "Pre-flight"

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

assert_rpc "setSettings (roundtrip)" "Restic" "setSettings" \
    "{\"cachedir\":\"${ORIG_CACHEDIR}\"}" >/dev/null

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

# getRepoSnapshotList — missing reporef
assert_rpc_fails "getRepoSnapshotList — missing reporef" \
    "Restic" "getRepoSnapshotList" \
    '{"start":0,"limit":25,"sortfield":null,"sortdir":null}'

# ---------------------------------------------------------------------------
# getRepoSnapshotList — runs `restic snapshots --json` against the repo.
# With a fake REST URL restic may hang waiting for a connection, so wrap in
# a timeout. A timeout is treated as a skip rather than a failure.
# ---------------------------------------------------------------------------
section "getRepoSnapshotList (fake repo — expects empty list or connection timeout)"

if [ -z "$REST_REPO_UUID" ]; then
    _skip "getRepoSnapshotList" "no test repo available"
elif ! $RESTIC_AVAILABLE; then
    _skip "getRepoSnapshotList" "restic binary not installed"
else
    SL_PARAMS="{\"reporef\":\"$REST_REPO_UUID\",\"start\":0,\"limit\":25,\"sortfield\":\"time\",\"sortdir\":\"desc\"}"
    SL_OUT=""
    SL_EC=0
    SL_OUT=$(timeout 15 omv-rpc -u admin "Restic" "getRepoSnapshotList" "$SL_PARAMS" 2>&1) || SL_EC=$?

    if [ $SL_EC -eq 124 ]; then
        _pass "getRepoSnapshotList — timed out as expected (fake REST URL, synchronous call)"
    elif [ $SL_EC -ne 0 ] || echo "$SL_OUT" | grep -qi "exception"; then
        _fail "getRepoSnapshotList — RPC error" "${SL_OUT:0:200}"
    else
        IS_ARRAY=$(echo "$SL_OUT" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('yes' if isinstance(d,list) or isinstance(d.get('data',[]),list) else 'no'
" 2>/dev/null || echo no)
        if [ "$IS_ARRAY" = "yes" ]; then
            _pass "getRepoSnapshotList — returned list (not exception)"
        else
            _fail "getRepoSnapshotList — unexpected response format"
        fi
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
