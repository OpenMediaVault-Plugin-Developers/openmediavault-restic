#!/usr/bin/env bash
# run-all.sh — Run every test suite of openmediavault-restic.
#
# Usage: ./tests/run-all.sh            (unit + template tests only)
#        sudo ./tests/run-all.sh       (also the live RPC tests)
#        sudo ./tests/run-all.sh --no-rpc
#
# test-unit.php and test-templates.py need no root. test-rpc.sh works on the
# live OMV configuration database, so it only runs as root and can be left
# out with --no-rpc.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

RUN_RPC=1
for arg in "$@"; do
    case "$arg" in
        --no-rpc) RUN_RPC=0 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

declare -a RESULTS=()
FAILED=0

run_suite() {
    local name="$1"
    shift
    echo -e "\n${BOLD}=== ${name} ===${NC}"
    if "$@"; then
        RESULTS+=("${GREEN}PASS${NC}  ${name}")
    else
        RESULTS+=("${RED}FAIL${NC}  ${name} (exit code $?)")
        FAILED=1
    fi
}

skip_suite() {
    RESULTS+=("${YELLOW}SKIP${NC}  $1 ($2)")
}

run_suite "test-unit.php" php "${TESTS_DIR}/test-unit.php"
run_suite "test-templates.py" python3 -I "${TESTS_DIR}/test-templates.py"

if [ ${RUN_RPC} -eq 0 ]; then
    skip_suite "test-rpc.sh" "--no-rpc"
elif [ "$(id -u)" -ne 0 ]; then
    skip_suite "test-rpc.sh" "needs root"
else
    run_suite "test-rpc.sh" "${TESTS_DIR}/test-rpc.sh"
fi

echo -e "\n${BOLD}=== Summary ===${NC}"
for r in "${RESULTS[@]}"; do
    echo -e "  $r"
done

exit ${FAILED}
