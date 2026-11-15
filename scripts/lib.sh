#!/usr/bin/env bash
# Shared helpers for the learnNginx scripts. This file is sourced, not executed.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR ROOT_DIR

COMPOSE_FILE="$ROOT_DIR/labs/compose.yaml"
readonly COMPOSE_FILE

log() {
  printf '[%s] INFO:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARN:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
  exit 1
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "缺少命令: $name"
}

load_env() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
  fi
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

require_docker() {
  require_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    die "Docker Compose v2 不可用。请安装 Docker Desktop 或 docker-compose-plugin。"
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker daemon 没有运行。先启动 Docker Desktop 或 docker 服务。"
  fi
}

http_port() {
  printf '%s' "${LAB_HTTP_PORT:-8080}"
}

proxy_port() {
  printf '%s' "${LAB_PROXY_PORT:-8081}"
}

lb_port() {
  printf '%s' "${LAB_LB_PORT:-8082}"
}

openresty_port() {
  printf '%s' "${LAB_OPENRESTY_PORT:-8083}"
}

https_port() {
  printf '%s' "${LAB_HTTPS_PORT:-8443}"
}

capstone_port() {
  printf '%s' "${LAB_CAPSTONE_PORT:-8084}"
}

port_in_use() {
  local port="$1"
  (echo >"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}
