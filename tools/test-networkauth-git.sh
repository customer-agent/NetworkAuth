#!/usr/bin/env bash
# Regression tests for Git compatibility in tools/networkauth.sh.
#
# The deployment script used to pass -C to Git.  Git versions shipped by some
# older Linux distributions reject that global option, and the failed status
# check was then mistaken for a clean working tree.  These tests use fake Git
# and Docker commands so they are deterministic and do not require Docker or
# a network connection.
set -Eeuo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SOURCE_SCRIPT=${NETWORKAUTH_SCRIPT:-"$TEST_DIR/networkauth.sh"}
[[ -f "$SOURCE_SCRIPT" ]] || {
    printf 'missing deployment script: %s\n' "$SOURCE_SCRIPT" >&2
    exit 1
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/networkauth-git.XXXXXX")
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

TEST_UID=$(id -u)
TEST_GID=$(id -g)
if [[ "$TEST_UID" == 0 ]]; then
    # ensure_env intentionally changes a root default to an unprivileged
    # container UID. Numeric chown works even when this UID has no passwd entry.
    TEST_UID=10001
    TEST_GID=10001
fi

fail() {
    printf 'git compatibility test failed: %s\n' "$*" >&2
    exit 1
}

new_checkout() {
    local root=$1
    mkdir -p "$root/tools" "$root/deploy" "$root/frontend" "$root/.git" "$root/bin"
    printf 'module example.test/networkauth\n' >"$root/go.mod"
    printf '{"name":"networkauth-test"}\n' >"$root/frontend/package.json"
    cp -- "$SOURCE_SCRIPT" "$root/tools/networkauth.sh"
    cp -- "$TEST_DIR/../deploy/networkauth-compose.yml" "$root/deploy/networkauth-compose.yml"
    chmod 700 "$root/tools/networkauth.sh"
}

write_fake_docker() {
    local root=$1
    cat >"$root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$NETWORKAUTH_DOCKER_LOG"
if [[ "${1:-}" == compose ]]; then
    for arg in "$@"; do
        [[ "$arg" == version ]] && exit 0
    done
    exit 0
fi
if [[ "${1:-}" == inspect ]]; then
    printf 'healthy\n'
fi
exit 0
EOF
    chmod 700 "$root/bin/docker"
}

write_old_git() {
    local root=$1
    cat >"$root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >>"$NETWORKAUTH_GIT_ARGS_LOG"
for arg in "$@"; do
    if [[ "$arg" == -C ]]; then
        printf 'Unknown option: -C\n' >&2
        exit 129
    fi
done
exit 0
EOF
    chmod 700 "$root/bin/git"
}

write_failing_git() {
    local root=$1
    cat >"$root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >>"$NETWORKAUTH_GIT_ARGS_LOG"
for arg in "$@"; do
    if [[ "$arg" == status ]]; then
        printf 'simulated git status failure\n' >&2
        exit 77
    fi
done
exit 0
EOF
    chmod 700 "$root/bin/git"
}

run_install() {
    local root=$1
    NETWORKAUTH_UID="$TEST_UID" NETWORKAUTH_GID="$TEST_GID" \
        NETWORKAUTH_DOCKER_LOG="$root/docker.log" \
        NETWORKAUTH_GIT_ARGS_LOG="$root/git-args.log" \
        PATH="$root/bin:$PATH" \
        "$root/tools/networkauth.sh" install
}

assert_old_git_install() {
    local root="$TMP_ROOT/old-git"
    new_checkout "$root"
    write_fake_docker "$root"
    write_old_git "$root"
    : >"$root/docker.log"
    : >"$root/git-args.log"

    run_install "$root" >"$root/install.out" 2>"$root/install.err" || {
        cat "$root/install.out" "$root/install.err" >&2 || true
        fail 'install failed with a Git implementation that rejects -C'
    }

    if grep -Fxq -- '-C' "$root/git-args.log"; then
        fail 'deployment script still passed -C to Git'
    fi
    grep -Fxq -- '-c' "$root/git-args.log" ||
        fail 'deployment script did not set Git safe.directory through -c'
}

assert_status_failure_stops_build() {
    local root="$TMP_ROOT/status-failure"
    new_checkout "$root"
    write_fake_docker "$root"
    write_failing_git "$root"
    : >"$root/docker.log"
    : >"$root/git-args.log"

    if run_install "$root" >"$root/install.out" 2>"$root/install.err"; then
        cat "$root/install.out" "$root/install.err" >&2 || true
        fail 'install succeeded even though git status failed'
    fi
    grep -Fq '无法检查源码工作区' "$root/install.err" ||
        fail 'git status failure did not produce the expected fail-closed error'
    if grep -Eq '(^| )(pull|build)( |$)' "$root/docker.log"; then
        cat "$root/docker.log" >&2
        fail 'Docker pull/build started after git status failed'
    fi
}

assert_old_git_install
assert_status_failure_stops_build
printf 'networkauth Git compatibility tests passed\n'
