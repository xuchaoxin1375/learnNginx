#!/usr/bin/env bash
set -euo pipefail

# Generate a self-signed certificate for the local HTTPS lab.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

CERT_DIR="$ROOT_DIR/labs/nginx/certs"
readonly CERT_DIR
CERT_FILE="$CERT_DIR/lab.crt"
KEY_FILE="$CERT_DIR/lab.key"
readonly CERT_FILE KEY_FILE

force=0
tmp_dir=""

usage() {
  cat <<'EOF'
用法: gen-cert.sh [--force] [--help]

为 localhost 生成自签名证书，写入 labs/nginx/certs/。
证书只用于本机实验，不能用于生产环境。

选项:
  --force     覆盖已有证书
  -h, --help  显示帮助

示例:
  bash scripts/gen-cert.sh
  bash scripts/gen-cert.sh --force
EOF
}

cleanup() {
  if [[ -n $tmp_dir && -d $tmp_dir ]]; then
    rm -rf -- "$tmp_dir"
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done

  require_cmd openssl
  mkdir -p -- "$CERT_DIR"

  if [[ -f $CERT_FILE && -f $KEY_FILE && $force -eq 0 ]]; then
    log "证书已存在，跳过生成: $CERT_FILE"
    log "需要重新生成时使用: bash scripts/gen-cert.sh --force"
    return 0
  fi

  tmp_dir="$(mktemp -d)"
  trap cleanup EXIT

  cat >"$tmp_dir/openssl.cnf" <<'EOF'
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C  = CN
ST = Lab
L  = Lab
O  = learnNginx
OU = Teaching
CN = localhost

[v3_req]
basicConstraints = critical, CA:TRUE
keyUsage         = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = localhost
IP.1  = 127.0.0.1
EOF

  log "生成自签名证书: CN=localhost, SAN=localhost,127.0.0.1"
  # 用配置文件而不是 -subj，避免 Git Bash 把 /C=CN/... 当成 Windows 路径转换。
  openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -config "$tmp_dir/openssl.cnf" \
    -keyout "$tmp_dir/lab.key" \
    -out "$tmp_dir/lab.crt" >/dev/null 2>&1

  mv -f -- "$tmp_dir/lab.crt" "$CERT_FILE"
  mv -f -- "$tmp_dir/lab.key" "$KEY_FILE"
  chmod 644 -- "$CERT_FILE"
  chmod 600 -- "$KEY_FILE" 2>/dev/null || warn "Windows 上可能无法设置 600 权限，实验环境可接受"

  log "证书: $CERT_FILE"
  log "私钥: $KEY_FILE"
  log "有效期: 365 天。浏览器仍会提示自签名证书不受信任。"
  openssl x509 -in "$CERT_FILE" -noout -subject -dates -fingerprint -sha256
}

main "$@"
