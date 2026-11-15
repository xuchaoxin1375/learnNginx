#!/usr/bin/env bash
set -euo pipefail

# End-to-end checks for a running lab stack.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

BASE_HTTP=""
BASE_PROXY=""
BASE_LB=""
BASE_HTTPS=""
BASE_OPENRESTY=""
checks=0
failures=0

usage() {
  cat <<'EOF'
用法: verify.sh [--help]

在实验已经启动的前提下，检查静态站点、反向代理、负载均衡、
缓存、限速、请求体限制、HTTPS 和可选 OpenResty。

前置:
  bash scripts/lab.sh up

选项:
  -h, --help  显示帮助
EOF
}

pass() {
  checks=$((checks + 1))
  printf '  [ok]   %s\n' "$*"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf '  [fail] %s\n' "$*" >&2
}

info() {
  printf '  [skip] %s\n' "$*"
}

http_code() {
  curl -sS -o /dev/null -w '%{http_code}' "$@"
}

get_header() {
  local name="$1"
  shift
  curl -sS -D - -o /dev/null "$@" | tr -d '\r' | awk -v key="$name" '
    tolower($1) == tolower(key ":") {
      sub(/^[^:]+:[[:space:]]*/, "")
      print
      exit
    }
  '
}

check_status() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local code
  if ! code="$(http_code "$url")"; then
    fail "$name: curl 请求失败"
    return
  fi
  if [[ $code == "$expected" ]]; then
    pass "$name: HTTP $code"
  else
    fail "$name: 期望 HTTP $expected，实际 $code"
  fi
}

check_status_https() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local code
  if ! code="$(curl -k -sS -o /dev/null -w '%{http_code}' "$url")"; then
    fail "$name: curl 请求失败"
    return
  fi
  if [[ $code == "$expected" ]]; then
    pass "$name: HTTP $code"
  else
    fail "$name: 期望 HTTP $expected，实际 $code"
  fi
}

check_body_contains() {
  local name="$1"
  local url="$2"
  local needle="$3"
  local body
  if ! body="$(curl -sS "$url")"; then
    fail "$name: curl 请求失败"
    return
  fi
  if [[ $body == *"$needle"* ]]; then
    pass "$name: 响应包含预期内容"
  else
    fail "$name: 响应中没有找到 '$needle'"
  fi
}

check_header_contains() {
  local name="$1"
  local url="$2"
  local header="$3"
  local needle="$4"
  shift 4
  local value
  value="$(get_header "$header" "$@" "$url" || true)"
  if [[ $value == *"$needle"* ]]; then
    pass "$name: $header 包含 '$needle'"
  else
    fail "$name: $header='$value'，没有包含 '$needle'"
  fi
}

check_lb_distribution() {
  local instances=""
  local body instance
  for _ in {1..6}; do
    body="$(curl -sS "$BASE_LB/api/" || true)"
    instance="$(printf '%s' "$body" | grep -o '"instance": "[^"]*"' | head -n 1 || true)"
    instances="${instances}${instance}"$'\n'
  done

  if [[ $instances == *api1* && $instances == *api2* ]]; then
    pass "负载均衡: 观察到 api1 和 api2 两个实例"
  else
    fail "负载均衡: 6 次请求没有同时命中两个实例"
    printf '%s' "$instances" >&2
  fi
}

check_rate_limit() {
  local codes=""
  local code count
  for _ in {1..12}; do
    code="$(http_code "$BASE_LB/api/limited" || true)"
    codes="${codes}${code}"$'\n'
  done
  count="$(printf '%s' "$codes" | grep -c '^429$' || true)"
  if [[ $count -ge 1 ]]; then
    pass "限速: 12 次快速请求中有 $count 次返回 429"
  else
    fail "限速: 没有观察到 429"
  fi
}

check_cache_status() {
  local value
  value="$(get_header "X-Cache-Status" "$BASE_LB/api/cache-test" || true)"
  case "$value" in
    MISS | HIT | EXPIRED | STALE | UPDATING | REVALIDATED)
      pass "缓存状态: X-Cache-Status=$value"
      ;;
    *)
      fail "缓存状态: X-Cache-Status='$value'，不是预期的缓存状态"
      ;;
  esac
}

check_upload_limit() {
  local code
  code="$(dd if=/dev/zero bs=1024 count=2048 2>/dev/null | curl -sS -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$BASE_LB/api/echo" || true)"
  if [[ $code == "413" ]]; then
    pass "请求体限制: 2 MiB 上传返回 413"
  else
    fail "请求体限制: 期望 413，实际 $code"
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

  require_docker
  require_cmd curl

  load_env
  BASE_HTTP="http://127.0.0.1:$(http_port)"
  BASE_PROXY="http://127.0.0.1:$(proxy_port)"
  BASE_LB="http://127.0.0.1:$(lb_port)"
  BASE_HTTPS="https://127.0.0.1:$(https_port)"
  BASE_OPENRESTY="http://127.0.0.1:$(openresty_port)"

  printf 'learnNginx 实验验证\n'
  printf '静态站点 %s\n\n' "$BASE_HTTP"

  printf '配置与基础端点\n'
  if compose exec -T nginx nginx -t >/dev/null 2>&1; then
    pass "nginx -t: 配置通过"
  else
    fail "nginx -t: 配置检查失败，运行 docker compose exec nginx nginx -t"
  fi
  check_status "静态首页" "$BASE_HTTP/" 200
  check_body_contains "静态首页" "$BASE_HTTP/" "Nginx Lab"
  check_status "健康检查" "$BASE_HTTP/healthz" 200
  check_status "404 页面" "$BASE_HTTP/missing" 404
  check_body_contains "404 页面" "$BASE_HTTP/missing" "这个文件不存在"

  printf '\n静态文件与响应头\n'
  check_header_contains "静态资源缓存" "$BASE_HTTP/assets/style.css" "Cache-Control" "max-age=3600"
  check_header_contains "gzip 压缩" "$BASE_HTTP/assets/style.css" "Content-Encoding" "gzip" -H "Accept-Encoding: gzip"
  check_header_contains "安全响应头" "$BASE_HTTP/" "X-Content-Type-Options" "nosniff"
  check_status "SPA 回退" "$BASE_HTTP/app/users/42" 200
  check_body_contains "SPA 回退" "$BASE_HTTP/app/users/42" "SPA 回退实验"

  printf '\n反向代理\n'
  check_status "代理上游" "$BASE_PROXY/api/" 200
  check_body_contains "代理上游" "$BASE_PROXY/api/" '"instance": "api1"'
  check_body_contains "代理请求头" "$BASE_PROXY/api/headers" "X-Forwarded-For"
  check_status "代理超时" "$BASE_PROXY/api/slow-timeout" 504

  printf '\n负载均衡与运维实验\n'
  check_lb_distribution
  check_status "状态页" "$BASE_LB/nginx_status" 200
  check_body_contains "状态页" "$BASE_LB/nginx_status" "Active connections"
  check_cache_status
  check_rate_limit
  check_upload_limit

  printf '\nHTTPS\n'
  check_status_https "HTTPS 首页" "$BASE_HTTPS/" 200
  check_header_contains "HSTS" "$BASE_HTTPS/" "Strict-Transport-Security" "max-age=300" -k
  check_status_https "HTTPS 健康检查" "$BASE_HTTPS/healthz" 200

  printf '\nOpenResty（可选）\n'
  if curl -sS -o /dev/null --max-time 2 "$BASE_OPENRESTY/healthz"; then
    check_body_contains "OpenResty" "$BASE_OPENRESTY/lua/hello" "OpenResty"
    check_body_contains "OpenResty 计数器" "$BASE_OPENRESTY/lua/counter" "hits"
  else
    info "OpenResty 未启动；需要时运行 bash scripts/lab.sh up --with-openresty"
  fi

  printf '\n结果: %d 项检查，%d 项失败。\n' "$checks" "$failures"
  if ((failures > 0)); then
    printf '先看 docker compose logs 与 docs/logs-and-troubleshooting.md。\n'
    exit 1
  fi

  printf '全部检查通过。\n'
}

main "$@"
