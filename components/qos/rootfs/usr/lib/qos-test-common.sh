# test-common.sh - shared scaffolding for qos-test / qos-test-e2e /
# qos-e2e-full. POSIX sh, not bash, since the test suites run on busybox
# on the target image.
#
# Each suite is expected to set its own TIMEOUT before sourcing this
# file, then parse its own CLI flags (they differ across suites), then
# write test cases, then call `print_summary` at the end.
#
# Sourced both in-repo (scripts/lib/test-common.sh) and on-target
# (/usr/lib/qos-test-common.sh) — see qos-test.sh for the lookup.

PASS=0
FAIL=0
SKIP=0
WARN=0

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Suites set VERBOSE=1 to opt into verbose run_test output.
VERBOSE="${VERBOSE:-0}"

pass() {
    PASS=$((PASS + 1))
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf "${RED}[FAIL]${NC} %s\n" "$1"
    [ -n "${2:-}" ] && printf "       Error: %s\n" "$2"
}

warn() {
    WARN=$((WARN + 1))
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
    [ -n "${2:-}" ] && printf "       Detail: %s\n" "$2"
}

skip() {
    SKIP=$((SKIP + 1))
    printf "${BLUE}[SKIP]${NC} %s\n" "$1"
}

section() {
    printf "\n${BLUE}══════════════════════════════════════════════${NC}\n"
    printf "${BLUE}  %s${NC}\n" "$1"
    printf "${BLUE}══════════════════════════════════════════════${NC}\n"
}

# run_test "desc" "shell command" [timeout_secs] [expect_fail]
run_test() {
    desc="$1"; cmd="$2"
    rt_timeout="${3:-${TIMEOUT:-10}}"
    expect_fail="${4:-0}"
    output=""
    exit_code=0
    output="$(timeout "$rt_timeout" sh -c "$cmd" 2>&1)" || exit_code=$?

    if [ "$exit_code" -eq 124 ]; then
        fail "$desc" "Timed out after ${rt_timeout}s"
    elif [ "$expect_fail" -eq 1 ] && [ "$exit_code" -ne 0 ]; then
        pass "$desc (expected failure)"
    elif [ "$exit_code" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc" "Exit code: $exit_code"
        [ "$VERBOSE" -eq 1 ] && [ -n "$output" ] && \
            printf "       Output: %s\n" "$(echo "$output" | head -3)"
    fi
}

# print_summary "<suite label>"
print_summary() {
    label="${1:-TESTS}"
    section "$label SUMMARY"
    TOTAL=$((PASS + FAIL + WARN + SKIP))
    printf "\n"
    printf "${GREEN}PASS:${NC}  %-5d\n" "$PASS"
    printf "${RED}FAIL:${NC}  %-5d\n" "$FAIL"
    printf "${YELLOW}WARN:${NC}  %-5d\n" "$WARN"
    printf "${BLUE}SKIP:${NC}  %-5d\n" "$SKIP"
    printf "TOTAL:  %-5d\n" "$TOTAL"
    if [ "$TOTAL" -gt 0 ]; then
        PASS_RATE=$((PASS * 100 / TOTAL))
        printf "\nPass Rate: ${GREEN}%d%%${NC}\n" "$PASS_RATE"
    fi
    printf "\n"
    if [ "$FAIL" -eq 0 ]; then
        printf "${GREEN}══════════════════════════════════════════════${NC}\n"
        printf "${GREEN}  ALL %s PASSED (%d/%d)${NC}\n" "$label" "$PASS" "$TOTAL"
        printf "${GREEN}══════════════════════════════════════════════${NC}\n"
        return 0
    fi
    printf "${RED}══════════════════════════════════════════════${NC}\n"
    printf "${RED}  %d %s FAILED${NC}\n" "$FAIL" "$label"
    printf "${RED}══════════════════════════════════════════════${NC}\n"
    return 1
}

# Resolve and source from suite scripts:
#   common="/usr/lib/qos-test-common.sh"
#   [ -f "$common" ] || common="$(dirname "$0")/lib/test-common.sh"
#   . "$common"
