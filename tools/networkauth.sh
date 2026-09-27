#!/usr/bin/env bash
# One-command Docker deployment and maintenance for NetworkAuth.
# Run this file from the NetworkAuth checkout. All persistent state is kept
# below deploy/ in that checkout, so moving or backing up the repository also
# moves the service state.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
DEPLOY_DIR="$ROOT_DIR/deploy"
COMPOSE_FILE="$DEPLOY_DIR/networkauth-compose.yml"
ENV_FILE="$DEPLOY_DIR/networkauth.env"
CONFIG_DIR="$DEPLOY_DIR/networkauth-config"
CONFIG_FILE="$CONFIG_DIR/config.json"
DATA_DIR="$DEPLOY_DIR/networkauth-data"
LOG_DIR="$DEPLOY_DIR/networkauth-logs"
die() { printf 'networkauth: %s\n' "$*" >&2; exit 1; }
info() { printf 'networkauth: %s\n' "$*"; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先安装 Docker Engine 和 Docker Compose v2"
}

ensure_source_repo() {
    [[ -f "$ROOT_DIR/go.mod" && -f "$ROOT_DIR/frontend/package.json" ]] ||
        die "不是 NetworkAuth 源码目录: $ROOT_DIR"
    [[ -e "$ROOT_DIR/.git" ]] || die "源码目录不是 Git 仓库: $ROOT_DIR"
}

source_is_clean() {
    ensure_source_repo
    [[ -z "$(git -c "safe.directory=$ROOT_DIR" -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] ||
        die '源码工作区有未提交修改或未跟踪文件，请提交或清理后再构建/升级'
}

build_service() {
    ensure_source_repo
    source_is_clean
    case "$(env_value NETWORKAUTH_PULL_IMAGES 1)" in
        1) compose build --pull ;;
        0) compose build ;;
        *) die 'NETWORKAUTH_PULL_IMAGES 必须是 0 或 1' ;;
    esac
}

compose() {
    docker compose --project-directory "$DEPLOY_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

ensure_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        local run_uid run_gid bind_address bind_port container_name image image_tag timezone trusted_proxies cors_origins health_timeout log_max_size log_max_file pull_images
        run_uid=${NETWORKAUTH_UID:-$(id -u)}
        run_gid=${NETWORKAUTH_GID:-$(id -g)}
        if [[ "$run_uid" == 0 ]]; then
            run_uid=10001
            run_gid=10001
        fi
        bind_address=${NETWORKAUTH_BIND_ADDRESS:-0.0.0.0}
        bind_port=${NETWORKAUTH_PORT:-8080}
        container_name=${NETWORKAUTH_CONTAINER_NAME:-networkauth}
        image=${NETWORKAUTH_IMAGE:-networkauth-local}
        image_tag=${NETWORKAUTH_IMAGE_TAG:-latest}
        timezone=${TZ:-Asia/Shanghai}
        trusted_proxies=${NETWORKAUTH_TRUSTED_PROXIES:-}
        cors_origins=${NETWORKAUTH_CORS_ORIGINS:-}
        health_timeout=${NETWORKAUTH_HEALTH_TIMEOUT:-120}
        log_max_size=${NETWORKAUTH_LOG_MAX_SIZE:-10m}
        log_max_file=${NETWORKAUTH_LOG_MAX_FILE:-5}
        pull_images=${NETWORKAUTH_PULL_IMAGES:-1}
        cat >"$ENV_FILE" <<EOF
# NetworkAuth deployment settings.  This file is shell/.env syntax; do not
# commit it when it contains site-specific values.
# Required when the public reverse-proxy runs on another LAN host. Restrict
# access with the host firewall to that proxy host and port.
NETWORKAUTH_BIND_ADDRESS=$bind_address
NETWORKAUTH_PORT=$bind_port
NETWORKAUTH_CONTAINER_NAME=$container_name
NETWORKAUTH_IMAGE=$image
NETWORKAUTH_IMAGE_TAG=$image_tag
NETWORKAUTH_UID=$run_uid
NETWORKAUTH_GID=$run_gid
TZ=$timezone
# Set this to the LAN address/CIDR of the reverse-proxy host, for example
# 192.168.1.20/32.  Leave empty when no proxy is used.
NETWORKAUTH_TRUSTED_PROXIES=$trusted_proxies
# Same-origin access normally needs no CORS entry.  Add the public origin only
# if a separate frontend or API client is used, e.g. https://auth.example.com.
NETWORKAUTH_CORS_ORIGINS=$cors_origins
NETWORKAUTH_HEALTH_TIMEOUT=$health_timeout
NETWORKAUTH_LOG_MAX_SIZE=$log_max_size
NETWORKAUTH_LOG_MAX_FILE=$log_max_file
NETWORKAUTH_PULL_IMAGES=$pull_images
EOF
        chmod 600 "$ENV_FILE"
        info "已生成 ${ENV_FILE}，请按反代主机实际地址修改 NETWORKAUTH_TRUSTED_PROXIES"
    fi
}

env_value() {
    local key=$1 fallback=${2:-}
    local value
    value=$(awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE" 2>/dev/null || true)
    printf '%s' "${value:-$fallback}"
}

validate_env_values() {
    local port uid gid timeout bind_address container_name image log_size log_file pull_images
    port=$(env_value NETWORKAUTH_PORT 8080)
    uid=$(env_value NETWORKAUTH_UID 10001)
    gid=$(env_value NETWORKAUTH_GID 10001)
    timeout=$(env_value NETWORKAUTH_HEALTH_TIMEOUT 120)
    bind_address=$(env_value NETWORKAUTH_BIND_ADDRESS 0.0.0.0)
    container_name=$(env_value NETWORKAUTH_CONTAINER_NAME networkauth)
    image=$(env_value NETWORKAUTH_IMAGE networkauth-local)
    log_size=$(env_value NETWORKAUTH_LOG_MAX_SIZE 10m)
    log_file=$(env_value NETWORKAUTH_LOG_MAX_FILE 5)
    pull_images=$(env_value NETWORKAUTH_PULL_IMAGES 1)
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die 'NETWORKAUTH_PORT 必须是 1-65535'
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || die 'NETWORKAUTH_UID/GID 必须是数字'
    [[ "$timeout" =~ ^[0-9]+$ ]] || die 'NETWORKAUTH_HEALTH_TIMEOUT 必须是非负整数'
    [[ -n "$bind_address" && "$bind_address" != *[[:space:]]* && "$bind_address" != *$'\n'* ]] || die 'NETWORKAUTH_BIND_ADDRESS 非法'
    [[ "$container_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'NETWORKAUTH_CONTAINER_NAME 非法'
    [[ -n "$image" && "$image" != *[[:space:]]* && "$image" != *$'\n'* ]] || die 'NETWORKAUTH_IMAGE 非法'
    [[ "$log_size" =~ ^[0-9]+[kKmMgG]$ ]] || die 'NETWORKAUTH_LOG_MAX_SIZE 必须如 10m'
    [[ "$log_file" =~ ^[1-9][0-9]*$ ]] || die 'NETWORKAUTH_LOG_MAX_FILE 必须是正整数'
    [[ "$pull_images" == 0 || "$pull_images" == 1 ]] || die 'NETWORKAUTH_PULL_IMAGES 必须是 0 或 1'
}


json_array_from_csv() {
    # Values are emitted as JSON strings after strict validation.  Empty input
    # becomes [], which preserves NetworkAuth's secure no-proxy default.
    local csv=${1:-} kind=${2:-origin} item first=1
    printf '['
    if [[ -n "$csv" ]]; then
        IFS=',' read -r -a items <<<"$csv"
        for item in "${items[@]}"; do
            item=${item//[[:space:]]/}
            [[ -n "$item" ]] || die '代理/CORS 列表包含空项目'
            [[ "$item" != *$'\n'* && "$item" != *$'\r'* ]] || die '代理/CORS 列表包含换行'
            # Trusted proxies are CIDRs/IPs; origins are URL strings.  JSON
            # escaping is deliberately limited to the characters accepted by
            # the validation below, avoiding a jq dependency during bootstrap.
            if [[ "$kind" == proxy ]]; then
                [[ "$item" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "非法可信代理: $item"
            else
                [[ "$item" =~ ^https?://[^[:space:]\"\\]+$ ]] || die "非法 CORS 来源: $item"
            fi
            (( first == 1 )) || printf ','
            first=0
            printf '"%s"' "$item"
        done
    fi
    printf ']'
}

ensure_config() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    chmod 700 "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    local uid gid
    uid=$(env_value NETWORKAUTH_UID 10001)
    gid=$(env_value NETWORKAUTH_GID 10001)
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] ||
        die 'NETWORKAUTH_UID 和 NETWORKAUTH_GID 必须是数字'
    if [[ "$(id -u)" == 0 ]] && [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]]; then
        chown -R "$uid:$gid" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    elif [[ "$(id -u)" != "$uid" ]]; then
        die "持久化目录需要 UID $uid；请以 root 运行一次或调整 NETWORKAUTH_UID/GID"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        # Preserve user-managed settings while keeping the secret-bearing
        # file readable only by the container identity.
        chmod 600 "$CONFIG_FILE"
        if [[ "$(id -u)" == 0 ]]; then
            chown "$uid:$gid" "$CONFIG_FILE"
        fi
        return 0
    fi

    local trusted origins
    trusted=$(json_array_from_csv "$(env_value NETWORKAUTH_TRUSTED_PROXIES)" proxy)
    origins=$(json_array_from_csv "$(env_value NETWORKAUTH_CORS_ORIGINS)" origin)
    cat >"$CONFIG_FILE" <<EOF
{
  "server": {
    "host": "0.0.0.0",
    "port": 8080,
    "dist": "",
    "dev_mode": false,
    "access_log": true,
    "cors_allow_origins": $origins,
    "trusted_proxies": $trusted
  },
  "database": {
    "type": "sqlite",
    "mysql": {
      "host": "",
      "port": 3306,
      "username": "",
      "password": "",
      "database": "",
      "charset": "utf8mb4",
      "max_idle_conns": 10,
      "max_open_conns": 100
    },
    "sqlite": { "path": "/app/data/database.db" }
  },
  "redis": { "host": "localhost", "port": 6379, "password": "", "db": 0 },
  "log": {
    "level": "info",
    "file": "/app/logs/app.log",
    "max_size": 100,
    "max_backups": 10,
    "max_age": 30
  }
}
EOF
    chmod 600 "$CONFIG_FILE"
    if [[ "$(id -u)" == 0 ]]; then
        chown "$uid:$gid" "$CONFIG_FILE"
    fi
    info "已生成 ${CONFIG_FILE}（首次启动后请使用 NetworkAuth 前端完成系统初始化）"
}

validate_prerequisites() {
    require_command docker
    docker compose version >/dev/null 2>&1 || die '需要 Docker Compose v2（docker compose）'
    [[ -f "$COMPOSE_FILE" ]] || die "缺少 $COMPOSE_FILE"
    ensure_env
    validate_env_values
}

backup() (
    local stamp archive container running_state was_running=0 rc=0

    # Keep the stop/start pair in an EXIT-protected subshell. This also
    # restores a service when tar is interrupted or an unexpected command
    # failure exits this function after the container has been stopped.
    restore_running() {
        (( was_running )) || return 0
        if ! compose start networkauth; then
            rc=1
            info "备份后无法恢复容器运行状态: $container"
        elif ! wait_for_healthy; then
            rc=1
            info "备份后容器健康检查失败: $container"
        fi
        was_running=0
    }
    trap restore_running EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    archive="$DEPLOY_DIR/networkauth-backup-$stamp.tar.gz"
    mkdir -p "$DEPLOY_DIR"
    container=$(env_value NETWORKAUTH_CONTAINER_NAME networkauth)
    if ! running_state=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null); then
        # A daemon/query failure is not equivalent to a stopped container;
        # fail closed so a live SQLite database is never copied.
        die "无法查询容器状态，已取消备份: $container"
    fi
    case "$running_state" in
      true)
        was_running=1
        # SQLite is only copied after the service has stopped. This avoids a
        # half-written WAL/database pair in the archive.
        if ! compose stop networkauth; then
            die "无法停止容器，已取消备份: $container"
        fi
        ;;
      false)
        ;;
      *)
        die "无法确认容器运行状态，已取消备份: $container（状态=$running_state）"
        ;;
    esac

    # The env/config files can contain secrets. Keep the archive owner-only.
    if tar -czf "$archive" -C "$DEPLOY_DIR" \
        networkauth-config networkauth-data networkauth-logs networkauth.env; then
        chmod 600 "$archive"
        info "备份已创建: $archive"
    else
        rc=$?
        rm -f -- "$archive"
        info '备份失败，未保留不完整的归档'
    fi

    restore_running
    return "$rc"
)

install_service() {
    ensure_env
    ensure_config
    build_service
    compose up -d --no-build
    compose ps
    wait_for_healthy || die '安装后的容器健康检查失败'
    info '服务已启动；首次安装请打开反代域名或本机端口完成前端初始化'
    setup_guidance
}

setup_guidance() {
    cat <<'EOF'

NetworkAuth 首次业务配置（全部在前端完成）:
  1. 在系统初始化中创建后台管理员账号；以后账号新增/改密由前端用户管理完成。
  2. 在应用管理记录应用 UUID 和应用密钥，终端请求同时携带这两项以及登录用户名/密码。
  3. 在该应用启用“机器验证”，将“多开范围”设为“单电脑（机器码）”，多开数量设为 1。
  4. 将登录方式设为“非顶号/拒绝新登录”，这样同一账号在第二台机器上会被拒绝；需要踢出旧设备时使用前端在线会话管理。

SQLite 数据库、配置和日志位于 deploy/networkauth-{data,config,logs}，请纳入备份。
EOF
}

update_service() {
    ensure_env
    ensure_config
    source_is_clean
    backup
    local branch
    branch=$(git -c "safe.directory=$ROOT_DIR" -C "$ROOT_DIR" symbolic-ref --quiet --short HEAD) ||
        die '升级要求当前 checkout 位于一个本地分支上'
    git -c "safe.directory=$ROOT_DIR" -C "$ROOT_DIR" fetch --tags --prune origin
    git -c "safe.directory=$ROOT_DIR" -C "$ROOT_DIR" pull --ff-only origin "$branch"
    build_service
    compose up -d --no-build
    compose ps
    wait_for_healthy || die '升级后的容器健康检查失败'
}

status_service() {
    ensure_env
    ensure_config
    compose ps
    if command -v curl >/dev/null 2>&1; then
        local port host
        host=$(env_value NETWORKAUTH_BIND_ADDRESS 127.0.0.1)
        port=$(env_value NETWORKAUTH_PORT 8080)
        [[ "$host" == "0.0.0.0" || "$host" == "::" ]] && host=127.0.0.1
        curl --fail --silent --show-error --max-time 5 "http://$host:$port/" >/dev/null \
            && info "HTTP 健康检查通过: http://$host:$port/" \
            || info "HTTP 健康检查未通过（容器可能仍在启动或端口仅绑定在其他地址）"
    fi
}

wait_for_healthy() {
    local container timeout started now health
    container=$(env_value NETWORKAUTH_CONTAINER_NAME networkauth)
    timeout=$(env_value NETWORKAUTH_HEALTH_TIMEOUT 120)
    [[ "$timeout" =~ ^[0-9]+$ ]] || die 'NETWORKAUTH_HEALTH_TIMEOUT 必须是非负整数'
    started=$(date +%s)
    while :; do
        health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)
        case "$health" in
            healthy)
                info "容器健康检查通过: $container"
                return 0
                ;;
            unhealthy)
                info '容器健康检查失败，最近日志如下:'
                compose logs --tail=100 networkauth || true
                return 1
                ;;
        esac
        now=$(date +%s)
        if (( now - started >= timeout )); then
            info '容器健康检查超时，最近日志如下:'
            compose logs --tail=100 networkauth || true
            return 1
        fi
        sleep 2
    done
}

usage() {
    cat <<'EOF'
用法: tools/networkauth.sh <命令>

命令:
  install      生成本地配置、构建镜像并启动服务（首次部署）
  up|start     启动已有容器
  down|stop    停止容器（不删除数据）
  restart      重启容器
  status       查看 Compose 状态和 HTTP 健康状态
  logs [参数]  查看日志；例如 logs -f --tail=200
  update       备份、快进同步 Git、重建镜像并启动
  backup       备份 SQLite 数据库、配置和环境文件
  config       打开配置文件编辑（使用 $EDITOR）
  shell        进入运行中的容器
  setup        打印应用 UUID/密钥、账号和单设备绑定的前端配置步骤
EOF
}

main() {
    local command_name=${1:-help}
    shift || true
    # Help and the static setup checklist should work before Docker is
    # installed; all operational commands validate prerequisites below.
    case "$command_name" in
        help|-h|--help) usage; return 0 ;;
        setup) setup_guidance; return 0 ;;
    esac
    validate_prerequisites
    case "$command_name" in
        install) install_service ;;
        up|start) ensure_env; ensure_config; compose up -d --no-build; compose ps; wait_for_healthy || die '启动后的容器健康检查失败' ;;
        down|stop) ensure_env; compose down ;;
        restart) ensure_env; ensure_config; compose restart; compose ps; wait_for_healthy || die '重启后的容器健康检查失败' ;;
        status) status_service ;;
        logs) ensure_env; compose logs "$@" networkauth ;;
        update|upgrade) update_service ;;
        backup) ensure_env; ensure_config; backup ;;
        config) ensure_env; ensure_config; "${EDITOR:-vi}" "$CONFIG_FILE" ;;
        shell) ensure_env; compose exec networkauth /bin/sh ;;
        *) usage >&2; die "未知命令: $command_name" ;;
    esac
}

main "$@"
