#!/usr/bin/env bash
# Deterministic install tests for mirrored base image caching and retries.
# Docker, timeout, Git, and sleeps are replaced inside temporary checkouts;
# no daemon, network, or real deployment data is used.
set -Eeuo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SOURCE_SCRIPT=${NETWORKAUTH_SCRIPT:-"$TEST_DIR/networkauth.sh"}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/networkauth-pulls.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
    printf 'pull test failed: %s\n' "$*" >&2
    if [[ -n "${CASE_ROOT:-}" ]]; then
        cat "$CASE_ROOT/output" "$CASE_ROOT/docker.log" "$CASE_ROOT/timeout.log" >&2 || true
    fi
    exit 1
}

new_case() {
    CASE_ROOT="$TMP_ROOT/$1"
    mkdir -p "$CASE_ROOT"/{tools,deploy,frontend,.git,bin}
    cp "$SOURCE_SCRIPT" "$CASE_ROOT/tools/networkauth.sh"
    cp "$TEST_DIR/../deploy/networkauth-compose.yml" "$CASE_ROOT/deploy/networkauth-compose.yml"
    printf 'module example.test/networkauth\n' >"$CASE_ROOT/go.mod"
    printf '{}\n' >"$CASE_ROOT/frontend/package.json"
    : >"$CASE_ROOT/docker.log"
    : >"$CASE_ROOT/timeout.log"
    : >"$CASE_ROOT/sleep.log"
    : >"$CASE_ROOT/images"
    printf '0\n' >"$CASE_ROOT/pull-count"
    printf '0\n' >"$CASE_ROOT/timeout-count"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE_ROOT/bin/git"
    cat >"$CASE_ROOT/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PULL_TEST_ROOT/sleep.log"
EOF
    cat >"$CASE_ROOT/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PULL_TEST_ROOT/timeout.log"
count=$(cat "$PULL_TEST_ROOT/timeout-count")
count=$(( count + 1 ))
printf '%s\n' "$count" >"$PULL_TEST_ROOT/timeout-count"
[[ "${1:-}" == --kill-after=10 ]] && shift
[[ "${1:-}" =~ ^[0-9]+$ ]] || exit 98
shift
if [[ "$PULL_TEST_MODE" == timeout-once && "$count" == 1 ]]; then
    exit 124
fi
exec "$@"
EOF
    cat >"$CASE_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PULL_TEST_ROOT/docker.log"
case "${1:-}" in
    compose) exit 0 ;;
    inspect) printf 'healthy\n'; exit 0 ;;
    image)
        [[ "${2:-}" == inspect ]] || exit 97
        grep -Fxq -- "$3" "$PULL_TEST_ROOT/images"
        ;;
    pull)
        count=$(cat "$PULL_TEST_ROOT/pull-count")
        count=$(( count + 1 ))
        printf '%s\n' "$count" >"$PULL_TEST_ROOT/pull-count"
        case "$PULL_TEST_MODE" in
            retry-success) (( count > 2 )) || exit 1 ;;
            exhausted) exit 1 ;;
            interrupted) exit 130 ;;
        esac
        printf '%s\n' "$2" >>"$PULL_TEST_ROOT/images"
        ;;
    tag)
        grep -Fxq -- "$2" "$PULL_TEST_ROOT/images" || exit 96
        printf '%s\n' "$3" >>"$PULL_TEST_ROOT/images"
        ;;
    *) exit 95 ;;
esac
EOF
    chmod 700 "$CASE_ROOT/tools/networkauth.sh" "$CASE_ROOT/bin/"*
}

run_install() {
    local mode=$1 refresh=${2:-0} timeout=${3:-600}
    PULL_TEST_ROOT="$CASE_ROOT" PULL_TEST_MODE="$mode" \
        NETWORKAUTH_DOCKER_REGISTRY=mirror.example/docker.io \
        NETWORKAUTH_PULL_IMAGES="$refresh" NETWORKAUTH_PULL_RETRIES=3 \
        NETWORKAUTH_PULL_TIMEOUT="$timeout" PATH="$CASE_ROOT/bin:$PATH" \
        "$CASE_ROOT/tools/networkauth.sh" install >"$CASE_ROOT/output" 2>&1
}

assert_count() {
    local pattern=$1 file=$2 expected=$3 actual
    actual=$(grep -Ec -- "$pattern" "$CASE_ROOT/$file" || true)
    [[ "$actual" == "$expected" ]] || fail "$file: expected $expected matches of '$pattern', got $actual"
}

assert_built() { assert_count '(^| )build( |$)' docker.log 1; }
assert_not_built() {
    assert_count '(^| )(build|up)( |$)' docker.log 0
    assert_count '^tag ' docker.log 0
}

seed_images() {
    local prefix=$1
    printf '%snode:22-bookworm\n%sgolang:1.25-bookworm\n%sdebian:bookworm-slim\n' \
        "$prefix" "$prefix" "$prefix" >"$CASE_ROOT/images"
}

new_case retry-success
run_install retry-success || fail 'retryable failures did not recover'
assert_count '^pull ' docker.log 5
assert_count '^tag ' docker.log 3
assert_count '^5$|^10$' sleep.log 2
assert_count '(^| )600 docker pull ' timeout.log 5
assert_built

new_case exhausted
if run_install exhausted; then fail 'exhausted pulls unexpectedly succeeded'; fi
assert_count '^pull ' docker.log 3
assert_count '^5$|^10$' sleep.log 2
assert_not_built

new_case timeout-once
run_install timeout-once 0 9 || fail 'timeout exit 124 was not retried'
assert_count '(^| )9 docker pull ' timeout.log 4
assert_count '^pull ' docker.log 3
assert_count '^5$' sleep.log 1
assert_built

new_case interrupted
if run_install interrupted; then fail 'interrupted pull unexpectedly succeeded'; fi
assert_count '^pull ' docker.log 1
assert_count '.' sleep.log 0
assert_not_built

new_case source-cache
seed_images mirror.example/docker.io/library/
run_install success || fail 'cached source images were not reused'
assert_count '^pull ' docker.log 0
assert_count '^tag ' docker.log 3
assert_count '.' timeout.log 0
assert_built

new_case local-cache
seed_images networkauth-base-
run_install success || fail 'cached local images were not reused'
assert_count '^pull ' docker.log 0
assert_count '^tag ' docker.log 0
assert_count '.' timeout.log 0
assert_built

new_case force-refresh
seed_images networkauth-base-
run_install success 1 || fail 'forced refresh failed'
assert_count '^pull ' docker.log 3
assert_count '^tag ' docker.log 3
assert_built

new_case timeout-disabled
run_install success 0 0 || fail 'disabled timeout failed'
assert_count '^pull ' docker.log 3
assert_count '.' timeout.log 0
assert_built

printf 'networkauth pull tests passed\n'
