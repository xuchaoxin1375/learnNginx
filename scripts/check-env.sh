#!/usr/bin/env bash
set -euo pipefail

# Check the tools and ports needed by the Docker-based labs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
用法: check-env.sh [--help]

检查 Docker、Compose、curl、openssl、仓库路径和实验端口。
不会启动或停止容器，也不会修改文件。

选项:
  -h, --help  显示帮助

示例:
  bash scripts/check-env.sh
EOF
}

failures=0

note() {
  printf '%s: %s\n' "$1" "$2"
}

fail() {
  note "$1" "失败: $2"
  failures=$((failures + 1))
}

ok() {
  note "$1" "正常: $2"
}

check_command() {
  local name="$1"
  local hint="$2"
  if command -v "$name" >/dev/null 2>&1; then
    ok "$name" "$(command -v "$name")"
  else
    fail "$name" "$hint"
  fi
}

main() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  fi

  load_env

  printf 'learnNginx 环境检查\n'
  printf '仓库根目录: %s\n\n' "$ROOT_DIR"

  check_command docker "先安装 Docker Desktop 或 Docker Engine"
  check_command curl "用来验证 HTTP 响应"
  check_command openssl "用来生成自签名实验证书；Git for Windows 自带"

  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      ok "docker compose" "$(docker compose version --short 2>/dev/null || docker compose version)"
    else
      fail "docker compose" "需要 Compose v2 插件，不能使用旧版 docker-compose"
    fi

    if docker info >/dev/null 2>&1; then
      ok "docker daemon" "可连接"
    else
      fail "docker daemon" "没有运行，或当前用户无权访问"
    fi
  fi

  if [[ -f $COMPOSE_FILE ]]; then
    ok "compose 文件" "$COMPOSE_FILE"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      if docker compose -f "$COMPOSE_FILE" config --quiet >/dev/null 2>&1; then
        ok "compose 语法" "通过"
      else
        fail "compose 语法" "运行 docker compose -f labs/compose.yaml config 查看详情"
      fi
    fi
  else
    fail "compose 文件" "找不到 $COMPOSE_FILE"
  fi

  if [[ -f "$ROOT_DIR/.env" ]]; then
    ok ".env" "存在，端口以 .env 为准"
  else
    ok ".env" "不存在，使用默认端口"
  fi

  printf '\n实验端口:\n'
  local pair
  for pair in \
    "静态站点:$(http_port)" \
    "反向代理:$(proxy_port)" \
    "负载均衡:$(lb_port)" \
    "OpenResty:$(openresty_port)" \
    "HTTPS:$(https_port)" \
    "综合项目:$(capstone_port)"; do
    local label="${pair%%:*}"
    local port="${pair##*:}"
    if port_in_use "$port"; then
      warn "$label 端口 $port 已被占用（可能实验已经在运行）"
    else
      ok "$label 端口 $port" "空闲"
    fi
  done

  printf '\n'
  if ((failures > 0)); then
    printf '检查完成: %d 项失败。\n' "$failures"
    printf '先修复上面的问题，再运行 bash scripts/lab.sh up。\n'
    exit 1
  fi

  printf '检查完成: 没有发现阻塞项。\n'
  printf '下一步: bash scripts/lab.sh up\n'
}

main "$@"
