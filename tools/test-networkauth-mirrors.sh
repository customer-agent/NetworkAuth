#!/usr/bin/env bash
# Regression tests for the mirror selector in tools/networkauth.sh.
#
# The deployment script is copied into a temporary checkout so this test never
# reads or modifies deploy/networkauth.env in the working tree.  No image is
# pulled; the optional Compose assertion only renders the configuration.
set -Eeuo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SOURCE_SCRIPT=${NETWORKAUTH_SCRIPT:-"$TEST_DIR/networkauth.sh"}
[[ -f "$SOURCE_SCRIPT" ]] || { printf 'missing deployment script: %s\n' "$SOURCE_SCRIPT" >&2; exit 1; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/networkauth-mirrors.XXXXXX")
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

mkdir -p "$TMP_ROOT/tools" "$TMP_ROOT/deploy"
cp -- "$SOURCE_SCRIPT" "$TMP_ROOT/tools/networkauth.sh"
chmod 700 "$TMP_ROOT/tools/networkauth.sh"
ENV_FILE="$TMP_ROOT/deploy/networkauth.env"
cat >"$ENV_FILE" <<'EOF'
NETWORKAUTH_BIND_ADDRESS=127.0.0.1
NETWORKAUTH_PORT=18080
NETWORKAUTH_CONTAINER_NAME=existing-container
NETWORKAUTH_IMAGE=existing-image
NETWORKAUTH_IMAGE_TAG=existing-tag
NETWORKAUTH_UID=1234
NETWORKAUTH_GID=2345
TZ=UTC
NETWORKAUTH_TRUSTED_PROXIES=10.0.0.0/8
NETWORKAUTH_CORS_ORIGINS=https://existing.example
NETWORKAUTH_HEALTH_TIMEOUT=17
NETWORKAUTH_LOG_MAX_SIZE=20m
NETWORKAUTH_LOG_MAX_FILE=7
NETWORKAUTH_PULL_IMAGES=1
NETWORKAUTH_UNRELATED_SETTING=keep-me
EOF
chmod 600 "$ENV_FILE"

fail() {
    printf 'mirror test failed: %s\n' "$*" >&2
    printf '%s\n' '--- current env ---' >&2
    cat "$ENV_FILE" >&2 || true
    exit 1
}

run_mirror() {
    (cd "$TMP_ROOT" && "$TMP_ROOT/tools/networkauth.sh" "$@")
}

env_value() {
    local key=$1
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE"
}

assert_env() {
    local key=$1 expected=$2 actual
    actual=$(env_value "$key" || true)
    [[ "$actual" == "$expected" ]] || fail "$key expected '$expected', got '$actual'"
}

assert_single_entry() {
    local key=$1 count
    count=$(awk -F= -v wanted="$key" '$1 == wanted { count++ } END { print count + 0 }' "$ENV_FILE")
    [[ "$count" == 1 ]] || fail "$key appears $count times; mirror updates must be duplicate-free"
}

assert_mode_600() {
    local mode
    mode=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE")
    [[ "$mode" == 600 ]] || fail "deploy/networkauth.env mode is $mode, expected 600"
}

file_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

assert_common_settings_preserved() {
    assert_env NETWORKAUTH_BIND_ADDRESS 127.0.0.1
    assert_env NETWORKAUTH_PORT 18080
    assert_env NETWORKAUTH_CONTAINER_NAME existing-container
    assert_env NETWORKAUTH_IMAGE existing-image
    assert_env NETWORKAUTH_IMAGE_TAG existing-tag
    assert_env NETWORKAUTH_UID 1234
    assert_env NETWORKAUTH_GID 2345
    assert_env TZ UTC
    assert_env NETWORKAUTH_TRUSTED_PROXIES 10.0.0.0/8
    assert_env NETWORKAUTH_CORS_ORIGINS https://existing.example
    assert_env NETWORKAUTH_HEALTH_TIMEOUT 17
    assert_env NETWORKAUTH_LOG_MAX_SIZE 20m
    assert_env NETWORKAUTH_LOG_MAX_FILE 7
    assert_env NETWORKAUTH_UNRELATED_SETTING keep-me
}

assert_china_defaults() {
    assert_env NETWORKAUTH_DOCKER_REGISTRY m.daocloud.io/docker.io
    assert_env NETWORKAUTH_APT_MIRROR http://mirrors.tuna.tsinghua.edu.cn/debian
    assert_env NETWORKAUTH_APT_SECURITY_MIRROR http://mirrors.tuna.tsinghua.edu.cn/debian-security
    assert_env NETWORKAUTH_NPM_REGISTRY https://registry.npmmirror.com
    assert_env NETWORKAUTH_GOPROXY https://goproxy.cn,direct
    assert_env NETWORKAUTH_BASE_NODE_IMAGE networkauth-base-node:22-bookworm
    assert_env NETWORKAUTH_BASE_GOLANG_IMAGE networkauth-base-golang:1.25-bookworm
    assert_env NETWORKAUTH_BASE_DEBIAN_IMAGE networkauth-base-debian:bookworm-slim
    assert_env NETWORKAUTH_PULL_IMAGES 0
}

assert_official_defaults() {
    assert_env NETWORKAUTH_DOCKER_REGISTRY docker.io
    assert_env NETWORKAUTH_APT_MIRROR http://deb.debian.org/debian
    assert_env NETWORKAUTH_APT_SECURITY_MIRROR http://deb.debian.org/debian-security
    assert_env NETWORKAUTH_NPM_REGISTRY https://registry.npmjs.org
    assert_env NETWORKAUTH_GOPROXY https://proxy.golang.org,direct
    assert_env NETWORKAUTH_BASE_NODE_IMAGE node:22-bookworm
    assert_env NETWORKAUTH_BASE_GOLANG_IMAGE golang:1.25-bookworm
    assert_env NETWORKAUTH_BASE_DEBIAN_IMAGE debian:bookworm-slim
    assert_env NETWORKAUTH_PULL_IMAGES 1
}

run_mirror mirror china
assert_china_defaults
assert_common_settings_preserved
for key in \
    NETWORKAUTH_DOCKER_REGISTRY NETWORKAUTH_APT_MIRROR \
    NETWORKAUTH_APT_SECURITY_MIRROR NETWORKAUTH_NPM_REGISTRY \
    NETWORKAUTH_GOPROXY NETWORKAUTH_BASE_NODE_IMAGE \
    NETWORKAUTH_BASE_GOLANG_IMAGE NETWORKAUTH_BASE_DEBIAN_IMAGE \
    NETWORKAUTH_PULL_IMAGES; do
    assert_single_entry "$key"
done
assert_mode_600

# Applying the same profile twice must be byte-for-byte idempotent.
china_hash=$(file_hash "$ENV_FILE")
run_mirror mirror china
[[ "$china_hash" == "$(file_hash "$ENV_FILE")" ]] || fail 'mirror china is not idempotent'

# A registry prefix may contain a port and namespace, and must be retained.
run_mirror mirror china registry.example:5000/team/networkauth
assert_env NETWORKAUTH_DOCKER_REGISTRY registry.example:5000/team/networkauth
assert_env NETWORKAUTH_PULL_IMAGES 0
assert_common_settings_preserved

run_mirror mirror official
assert_official_defaults
assert_common_settings_preserved
assert_mode_600

show_output=$(run_mirror mirror show)
for key in \
    NETWORKAUTH_DOCKER_REGISTRY NETWORKAUTH_APT_MIRROR \
    NETWORKAUTH_APT_SECURITY_MIRROR NETWORKAUTH_NPM_REGISTRY \
    NETWORKAUTH_GOPROXY NETWORKAUTH_PULL_IMAGES; do
    value=$(env_value "$key")
    [[ "$show_output" == *"$key=$value"* ]] ||
        fail "mirror show did not display $key=$value"
done

# Scheme-bearing registry values are ambiguous in a Docker image reference;
# reject them without changing even one byte of the existing env file.
before_invalid=$(file_hash "$ENV_FILE")
if run_mirror mirror china https://registry.example/team >"$TMP_ROOT/invalid.out" 2>&1; then
    fail 'mirror accepted a scheme-bearing Docker registry URL'
fi
[[ "$before_invalid" == "$(file_hash "$ENV_FILE")" ]] ||
    fail 'invalid Docker registry input modified networkauth.env'
assert_official_defaults
assert_mode_600

# Render the real Compose file with a namespaced registry when Docker Compose
# is available.  `config` performs interpolation only and does not contact a
# registry or pull an image.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    run_mirror mirror china registry.example:5000/team/networkauth
    compose_output=$(docker compose \
        --project-directory "$TEST_DIR/../deploy" \
        --env-file "$ENV_FILE" \
        -f "$TEST_DIR/../deploy/networkauth-compose.yml" \
        config 2>&1) || {
        printf '%s\n' "$compose_output" >&2
        fail 'docker compose config rejected a namespaced registry'
    }
    [[ "$compose_output" == *'DOCKER_REGISTRY: registry.example:5000/team/networkauth'* ]] ||
        fail 'docker compose config did not preserve the namespaced registry build arg'
fi

printf 'networkauth mirror tests passed\n'
