#!/usr/bin/env bash
set -euo pipefail

# Lifecycle wrapper for the Docker Compose lab.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
用法: lab.sh <命令> [选项]

命令:
  up [--with-openresty]  构建并启动实验；可选启动 OpenResty
  down                   停止并移除容器，保留证书
  restart                重启容器
  reload                 检查 nginx 配置后平滑重载
  status                 查看容器状态和实验入口
  logs [服务名]          跟踪日志，默认全部服务
  config                 打印 Compose 解析后的配置
  clean [--certs]        移除容器和网络；加 --certs 同时删除生成的证书

选项:
  -h, --help             显示帮助

示例:
  bash scripts/lab.sh up
  bash scripts/lab.sh up --with-openresty
  bash scripts/lab.sh reload
  bash scripts/lab.sh logs nginx
  bash scripts/lab.sh clean --certs
EOF
}

print_urls() {
  printf '\n实验入口:\n'
  printf '  静态站点:   http://localhost:%s/\n' "$(http_port)"
  printf '  反向代理:   http://localhost:%s/api/\n' "$(proxy_port)"
  printf '  负载均衡:   http://localhost:%s/api/\n' "$(lb_port)"
  printf '  HTTPS:      https://localhost:%s/  (自签名证书)\n' "$(https_port)"
  printf '  OpenResty:  http://localhost:%s/lua/hello  (需要 --with-openresty)\n' "$(openresty_port)"
  printf '  综合项目:   http://localhost:%s/  (完成 capstone 后可用)\n' "$(capstone_port)"
  printf '\n'
}

cmd_up() {
  local with_openresty=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-openresty)
        with_openresty=1
        shift
        ;;
      *)
        die "up 不认识参数: $1"
        ;;
    esac
  done

  require_docker
  bash "$SCRIPT_DIR/gen-cert.sh"

  if [[ $with_openresty -eq 1 ]]; then
    log "启动核心服务与 OpenResty profile"
    compose --profile openresty up -d --build
  else
    log "启动核心服务"
    compose up -d --build
  fi

  log "等待容器健康检查"
  sleep 2
  compose ps
  print_urls
}

cmd_down() {
  [[ $# -eq 0 ]] || die "down 不接受参数"
  require_docker
  compose down
  log "容器已停止；证书保留在 labs/nginx/certs/"
}

cmd_restart() {
  [[ $# -eq 0 ]] || die "restart 不接受参数"
  require_docker
  compose restart
  log "容器已重启"
  print_urls
}

cmd_reload() {
  [[ $# -eq 0 ]] || die "reload 不接受参数"
  require_docker
  log "检查 nginx 配置"
  compose exec -T nginx nginx -t
  log "平滑重载 nginx"
  compose exec -T nginx nginx -s reload
}

cmd_status() {
  [[ $# -eq 0 ]] || die "status 不接受参数"
  require_docker
  compose ps
  print_urls
}

cmd_logs() {
  require_docker
  compose logs -f --tail=100 "$@"
}

cmd_config() {
  [[ $# -eq 0 ]] || die "config 不接受参数"
  require_docker
  compose config
}

cmd_clean() {
  local remove_certs=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --certs)
        remove_certs=1
        shift
        ;;
      *)
        die "clean 不认识参数: $1"
        ;;
    esac
  done

  require_docker
  compose down --volumes --remove-orphans
  log "容器、网络和 Compose 卷已移除；镜像仍保留"

  if [[ $remove_certs -eq 1 ]]; then
    rm -f -- "$ROOT_DIR/labs/nginx/certs/lab.crt" "$ROOT_DIR/labs/nginx/certs/lab.key"
    log "已删除生成的证书"
  else
    log "证书保留；需要删除时使用 bash scripts/lab.sh clean --certs"
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
  fi

  local command="$1"
  shift

  load_env

  case "$command" in
    up)
      cmd_up "$@"
      ;;
    down)
      cmd_down "$@"
      ;;
    restart)
      cmd_restart "$@"
      ;;
    reload)
      cmd_reload "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    logs)
      cmd_logs "$@"
      ;;
    config)
      cmd_config "$@"
      ;;
    clean)
      cmd_clean "$@"
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
