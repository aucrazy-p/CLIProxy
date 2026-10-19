#!/usr/bin/env bash
# =============================================================
#  CLIProxyAPI 一键部署脚本（原生二进制版 · 无 Docker）
# -------------------------------------------------------------
#  作用：在 Linux 服务器上以**原生二进制 + systemd** 方式部署
#        CLIProxyAPI，把已有订阅账号的额度统一包装成标准
#        OpenAI 兼容 API（默认监听 8317，可被任意支持自定义
#        base_url 的客户端调用）。
#
#  本版特点（相比旧版彻底去掉 Docker 依赖，最省内存）：
#    - CLIProxyAPI 直接作为宿主机 systemd 服务运行，不拉镜像、
#      不装 Docker 守护进程，零容器开销
#    - Caddy 使用官方静态二进制安装（不走 apt、不进容器），
#      并自动写好 systemd 服务 + 开机自启
#    - 自动在 Caddyfile 中插入带标记的配置块（不破坏已有站点）
#    - 写入前备份 + `caddy validate` 校验，校验失败自动回滚
#    - 自动重载/启动 Caddy
#
#  网络模式（安装时交互选择，写入状态文件，update 自动复用）：
#    ① 域名：留空 = 直接用 IP:8317；填写 = 走域名
#    ② 反代：1 = 启用 Caddy 自动 HTTPS；0 = 不启用
#    ③ 证书：cf = 内部自签(CF 橙云最稳，默认)；le = Let's Encrypt
#    ④⑤⑥ 凭据：回车自动生成随机值，也可自己指定
#
#  用法：
#    bash cli-proxy-deploy.sh help       # 查看完整帮助
#    交互菜单： bash cli-proxy-deploy.sh
#    子命令：   bash cli-proxy-deploy.sh install|start|stop|restart|status|logs|update|uninstall|menu
#    非交互：
#      API_TOKEN=xxx CF_DOMAIN=cliproxy.xxx.com USE_CADDY=1 CERT_MODE=cf \
#      bash cli-proxy-deploy.sh install
# =============================================================

set -euo pipefail

PERSIST_DIR="${PERSIST_DIR:-/opt/cliproxy}"
API_PORT="${API_PORT:-8317}"
CONFIG_FILE="$PERSIST_DIR/config.yaml"
STATE_FILE="$PERSIST_DIR/.deploy.env"
CADDYFILE_DEFAULT="/etc/caddy/Caddyfile"

# CLIProxyAPI 版本与安装落点（原生二进制）
CLI_VERSION="${CLI_VERSION:-8.0.33}"
CLI_BIN="${CLI_BIN:-/usr/local/bin/CLIProxyAPI}"
CLI_UNIT="/etc/systemd/system/cliproxy-api.service"

# Caddy 运行形态：native=宿主机二进制 | none=未安装
CADDY_MODE="${CADDY_MODE:-}"
CADDY_PLAIN="${CADDY_PLAIN:-}"
CADDY_USER="${CADDY_USER:-admin}"
API_TOKEN="${API_TOKEN:-}"
MGMT_SECRET="${MGMT_SECRET:-}"

CF_DOMAIN="${CF_DOMAIN:-}"
GCP_PUBLIC_IP="${GCP_PUBLIC_IP:-}"
USE_CADDY="${USE_CADDY:-0}"
CERT_MODE="${CERT_MODE:-cf}"          # cf=内部自签 | le=Let's Encrypt

# ---------- 通用工具 ----------
# /dev/tty 存在不代表能打开（容器里常见），必须实测可读
have_tty(){ { : < /dev/tty; } 2>/dev/null; }

_ask(){
  local prompt="${1:-}"
  if have_tty; then
    [ -n "$prompt" ] && printf '%s' "$prompt" > /dev/tty
    read -r _V < /dev/tty 2>/dev/null || _V=""
  else
    [ -n "$prompt" ] && printf '%s' "$prompt" >&2
    read -r _V 2>/dev/null || _V=""
  fi
  printf '%s' "$_V"
}
info(){ echo -e "\033[32m==>\033[0m $*"; }
warn(){ echo -e "\033[33m!!\033[0m $*"; }
err(){ echo -e "\033[31m✗\033[0m $*" >&2; }

gen_rand(){
  openssl rand -hex 16 2>/dev/null \
    || head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' \
    || echo "$(date +%s)-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' ')"
}

# 只允许可直接写进 YAML / Caddyfile 的字符，避免引号、空格、$ 把配置写坏
valid_key(){ [[ "${1:-}" =~ ^[A-Za-z0-9._~:@%+=/-]{8,128}$ ]]; }

# 交互录入凭据：回车=保留/随机生成；非法输入=退回随机值
# 用法: ask_credential "提示" 变量名 "预设值"
ask_credential(){
  local prompt="$1" name="$2" preset="${3:-}" v
  v="$(_ask "$prompt")"
  if [[ -z "$v" ]]; then
    printf -v "$name" '%s' "${preset:-$(gen_rand)}"
    return 0
  fi
  if ! valid_key "$v"; then
    warn "输入不合法（仅允许字母数字与 . _ ~ : @ % + = / -，长度 8-128），已忽略该输入"
    printf -v "$name" '%s' "${preset:-$(gen_rand)}"
    return 0
  fi
  printf -v "$name" '%s' "$v"
  return 0
}

need_root(){
  if [[ "$(id -u)" != "0" ]]; then
    err "本脚本需要 root 权限（会写 /opt、/etc/caddy、/usr/local/bin）"
    err "请改用： sudo bash $0 $*"
    exit 1
  fi
}

need_python3(){
  command -v python3 >/dev/null 2>&1 && return 0

  warn "未检测到 python3（用于解析配置与安全写入 Caddyfile），开始自动安装..."
  if command -v apt-get >/dev/null 2>&1; then
    # 先直接装（多数机器索引已就绪），失败再 update 重试
    apt-get install -y --no-install-recommends python3 >/dev/null 2>&1 || {
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y --no-install-recommends python3 >/dev/null 2>&1 || true
    }
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache python3 >/dev/null 2>&1 || true
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 自动安装失败（包管理器不可用或网络受限）"
    err "请手动执行后重跑： apt-get update && apt-get install -y python3"
    exit 1
  fi
  info "python3 已安装： $(python3 --version 2>&1)"
}

# 探测 CPU 架构，返回 CLIProxyAPI 发布包用的后缀
#   x86_64/amd64  -> amd64
#   aarch64/arm64 -> aarch64   （注意：官方文件名用 aarch64）
cli_arch(){
  local a; a="$(uname -m)"
  case "$a" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'aarch64' ;;
    *) err "不支持的架构： $a（仅支持 amd64 / aarch64）"; return 1 ;;
  esac
}

# ---------- 状态持久化 ----------
save_state(){
  mkdir -p "$PERSIST_DIR"
  # umask 077：文件从创建那一刻起就只有 root 可读，避免出现短暂的 644 窗口
  (
    umask 077
    cat > "$STATE_FILE" <<EOF
CF_DOMAIN="$CF_DOMAIN"
USE_CADDY="$USE_CADDY"
CERT_MODE="$CERT_MODE"
CADDY_MODE="$CADDY_MODE"
CADDY_PLAIN="$CADDY_PLAIN"
CADDY_USER="$CADDY_USER"
API_TOKEN="$API_TOKEN"
MGMT_SECRET="$MGMT_SECRET"
CLI_VERSION="$CLI_VERSION"
EOF
  )
  chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state(){
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  return 0
}

load_token(){
  if [[ -z "${API_TOKEN:-}" && -f "$CONFIG_FILE" ]]; then
    # 纯 awk 解析，不依赖 python3（status / logs 等只读命令可能在未装 python3 时先跑）
    API_TOKEN=$(awk '
      /^[[:space:]]*api-keys:[[:space:]]*$/ { inlist = 1; next }
      inlist && /^[[:space:]]*-[[:space:]]*"/ {
        sub(/^[[:space:]]*-[[:space:]]*"/, ""); sub(/".*$/, ""); print; exit
      }
      inlist && /^[^[:space:]-]/ { exit }
    ' "$CONFIG_FILE" 2>/dev/null || true)
  fi
  return 0
}

# CLIProxyAPI 监听地址（写进 config.yaml 的 server.host）
#   启用 Caddy 反代 → 只绑 127.0.0.1（仅本机 Caddy 够得着，公网不可直连）
#   不用 Caddy     → 0.0.0.0（直接对外）
cli_bind_host(){
  if [[ "${USE_CADDY:-0}" == "1" ]]; then echo "127.0.0.1"; else echo "0.0.0.0"; fi
}

public_ip(){
  local ip="${GCP_PUBLIC_IP:-}"
  if [[ -z "$ip" ]]; then
    # GCP 元数据服务（hostname -I 返回的是内网 IP）
    ip="$(curl -fsS --max-time 3 -H 'Metadata-Flavor: Google' \
      'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null || true)"
  fi
  [[ -z "$ip" ]] && ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  printf '%s' "$ip"
}

port_in_use(){
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$" && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

show_info(){
  local ip addr mode panel
  ip="$(public_ip)"
  panel="http://$ip:$API_PORT/management.html"
  if [[ -n "$CF_DOMAIN" ]]; then
    if [[ "${USE_CADDY:-0}" == "1" ]]; then
      addr="https://$CF_DOMAIN/v1"
      mode="域名 + Caddy 反代 (HTTPS / TLS=${CERT_MODE})"
      panel="https://$CF_DOMAIN/management.html"
    else
      addr="http://$CF_DOMAIN:$API_PORT/v1"; mode="域名直连(无反代, 无 HTTPS)"
    fi
  else
    addr="http://$ip:$API_PORT/v1"; mode="IP 直连(无域名/无反代)"
  fi
  echo
  echo "========================================================="
  echo " 当前模式：$mode"
  echo " OpenAI 兼容 API（客户端填写）："
  echo "   base_url: $addr"
  echo "   api_key:  ${API_TOKEN:-（见 $CONFIG_FILE 的 access.api-keys）}"
  echo "   model:    先用 GET $addr/models 获取列表，再任选其一"
  echo "---------------------------------------------------------"
  echo " 管理面板: $panel"
  echo "   登录密钥(secret-key): ${MGMT_SECRET:-（见 $STATE_FILE）}"
  if [[ "${USE_CADDY:-0}" == "1" && -n "$CADDY_PLAIN" ]]; then
    echo "   后台 Basic 认证: $CADDY_USER / $CADDY_PLAIN"
    if [[ "$CERT_MODE" == "cf" ]]; then
      echo " 注意：使用内部自签证书 → Cloudflare SSL/TLS 模式须为 Full（不要选 Full strict）"
    fi
  fi
  echo "---------------------------------------------------------"
  echo " 凭据文件: $STATE_FILE （权限 600，含本页全部明文凭据）"
  echo " 服务形态: CLIProxyAPI 原生 systemd 服务（无 Docker）"
  echo "========================================================="
}

# ---------- CLIProxyAPI 原生二进制 ----------
# 下载官方预编译单文件二进制并安装到 /usr/local/bin
download_cliproxy_binary(){
  local ver="${CLI_VERSION:-8.0.33}"
  local arch; arch="$(cli_arch)" || return 1
  local url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${ver}/CLIProxyAPI_${ver}_linux_${arch}.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  info "下载 CLIProxyAPI v${ver}（arch=${arch}）..."
  if ! curl -fsSL --max-time 180 "$url" -o "$tmp/cli.tar.gz"; then
    err "下载失败： $url"
    err "请检查网络，或手动下载后放到 $CLI_BIN 并重跑 install"
    rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/cli.tar.gz" -C "$tmp"; then
    err "压缩包解压失败，可能下载被截断"
    rm -rf "$tmp"; return 1
  fi
  # 容错：发布包内二进制名可能是 CLIProxyAPI / cli-proxy-api，挑第一个可执行文件
  local bin
  bin="$(find "$tmp" -type f \( -name 'CLIProxyAPI' -o -name 'cli-proxy-api' \) 2>/dev/null | head -1)"
  [[ -z "$bin" ]] && bin="$(find "$tmp" -type f -perm -u+x 2>/dev/null | head -1)"
  if [[ -z "$bin" ]]; then
    err "压缩包内未找到 CLIProxyAPI 二进制"
    rm -rf "$tmp"; return 1
  fi
  install -m 0755 "$bin" "$CLI_BIN"
  rm -rf "$tmp"
  info "CLIProxyAPI 已安装： $CLI_BIN"
  return 0
}

# 写 systemd 单元（原生服务，不依赖 Docker）
install_cliproxy_unit(){
  mkdir -p "$PERSIST_DIR"/{auths,logs}
  cat > "$CLI_UNIT" <<UNIT
[Unit]
Description=CLIProxyAPI (native, no docker)
Documentation=https://github.com/router-for-me/CLIProxyAPI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CLI_BIN -config $CONFIG_FILE
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576
WorkingDirectory=$PERSIST_DIR
# 把登录态/缓存目录固定到 PERSIST_DIR 下，等价于旧版的 auths 挂载
Environment=HOME=$PERSIST_DIR

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1 || true
  info "已写入 systemd 服务 $CLI_UNIT"
}

svc_cliproxy(){
  local act="$1"
  if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q '^cliproxy-api\.service'; then
    err "服务 cliproxy-api 未安装，请先执行 install"
    return 1
  fi
  systemctl "$act" cliproxy-api >/dev/null 2>&1 && return 0 || return 1
}

wait_api(){
  local i code
  info "等待 CLIProxyAPI 就绪..."
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
      "http://127.0.0.1:$API_PORT/v1/models" 2>/dev/null || echo 000)"
    if [[ "$code" != "000" ]]; then
      info "服务已就绪（${i}s，HTTP $code）"
      return 0
    fi
    sleep 1
  done
  warn "等待超时，请查看日志： journalctl -u cliproxy-api --tail 50"
  return 0
}

# ---------- Caddy（官方静态二进制，无 Docker） ----------
install_caddy_unit(){
  [[ -f /etc/systemd/system/caddy.service ]] && return 0
  mkdir -p /etc/caddy
  [[ -f "$CADDYFILE_DEFAULT" ]] || : > "$CADDYFILE_DEFAULT"
  cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1 || true
  info "已写入 systemd 服务 /etc/systemd/system/caddy.service"
}

# 探测 Caddy 形态：仅复用宿主机二进制，否则记为 none
detect_caddy(){
  if command -v caddy >/dev/null 2>&1; then
    CADDY_MODE="native"; return 0
  fi
  CADDY_MODE="none"; return 0
}

caddy_validate(){
  caddy validate --config "$1" >/dev/null 2>&1
}

caddy_hash(){
  caddy hash-password --plaintext "$1" 2>/dev/null \
    || printf '%s' "$1" | caddy hash-password 2>/dev/null
}

ensure_caddy(){
  detect_caddy
  if [[ "${CADDY_MODE:-none}" == "native" ]]; then
    info "已检测到 Caddy： $(command -v caddy)  $(caddy version 2>/dev/null | head -1)"
    return 0
  fi

  # 装之前先看 80/443 是否已被别人占着（nginx / 其它进程）
  local p
  for p in 80 443; do
    if port_in_use "$p"; then
      err "端口 $p 已被占用，此时装 Caddy 会起不来"
      ss -ltnp 2>/dev/null | grep -E "[:.]$p[[:space:]]" || true
      err "请先释放该端口（或让占用方反代到 127.0.0.1:$API_PORT），再重跑 install"
      return 1
    fi
  done

  warn "未检测到 Caddy，开始自动安装官方静态二进制（无 apt / 无容器，最省内存）"

  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) err "不支持的架构： $arch"; return 1 ;;
  esac

  info "下载 Caddy 静态二进制（arch=$arch）..."
  if ! curl -fsSL --max-time 120 "https://caddyserver.com/api/download?os=linux&arch=$arch" -o /usr/local/bin/caddy; then
    err "Caddy 下载失败，请检查网络后重试，或手动安装"
    return 1
  fi
  chmod +x /usr/local/bin/caddy
  install_caddy_unit
  CADDY_MODE="native"
  info "Caddy 已安装： $(caddy version 2>/dev/null | head -1)"
  return 0
}

caddy_conf_path(){
  local p
  p="$(systemctl cat caddy 2>/dev/null | grep -oE '\-\-config[ =][^ ]+' | head -1 | awk '{print $NF}' || true)"
  if [[ -n "$p" ]]; then printf '%s' "$p"; else printf '%s' "$CADDYFILE_DEFAULT"; fi
}

restart_caddy(){
  local site="$1"
  if [[ -d /run/systemd/system ]] && systemctl list-unit-files --type=service 2>/dev/null | grep -q '^caddy\.service'; then
    systemctl enable caddy >/dev/null 2>&1 || true
    if systemctl is-active --quiet caddy; then
      systemctl reload caddy 2>/dev/null && { info "Caddy 已重载"; return 0; }
      systemctl restart caddy 2>/dev/null && { info "Caddy 已重启"; return 0; }
    else
      systemctl start caddy 2>/dev/null && { info "Caddy 已启动"; return 0; }
    fi
  fi
  caddy reload --config "$site" 2>/dev/null && { info "Caddy 已重载(无 systemd)"; return 0; }
  caddy start --config "$site" 2>/dev/null && { info "Caddy 已在后台启动(无 systemd)"; return 0; }
  warn "Caddy 重载失败，请手动： caddy validate --config $site"
  return 0
}

setup_caddy(){
  if ! ensure_caddy; then
    err "Caddy 不可用，已回退为『IP 直连』模式"
    USE_CADDY=0
    save_state
    return 1
  fi

  local site; site="$(caddy_conf_path)"
  mkdir -p "$(dirname "$site")"
  [[ -f "$site" ]] || : > "$site"

  # 密码复用：state 里已有就不再重新生成（避免 update 后旧密码失效）
  if [[ -z "${CADDY_PLAIN:-}" ]]; then
    CADDY_PLAIN="$(gen_rand)"
    info "首次生成管理面板 Basic 认证密码"
  else
    info "沿用已有 Basic 认证密码"
  fi

  local hashp=""
  hashp="$(caddy_hash "$CADDY_PLAIN" || true)"
  if [[ -z "$hashp" ]]; then
    warn "密码哈希生成失败 —— 管理面板将不设 Basic 认证，仅靠 management.secret-key 保护"
  fi

  # 原生 Caddy 与 CLIProxyAPI 同机，反代目标恒为 127.0.0.1
  local up="127.0.0.1"
  local start_marker='# >>> CLIProxyAPI START'
  local end_marker='# >>> CLIProxyAPI END'
  local auth_block="" block=""

  if [[ -n "$hashp" ]]; then
    auth_block="    basicauth /management.html {
        $CADDY_USER $hashp
    }
"
  fi

  if [[ "${CERT_MODE:-cf}" == "cf" ]]; then
    # CF 橙云模式：443 用内部自签（CF 的 Full 模式不校验证书），80 兜底兼容 Flexible
    block="http://$CF_DOMAIN {
${auth_block}    reverse_proxy $up:$API_PORT
}

https://$CF_DOMAIN {
    tls internal
${auth_block}    reverse_proxy $up:$API_PORT
}
"
  else
    # Let's Encrypt：Caddy 自动签发（需 80/443 公网可达）
    block="$CF_DOMAIN {
${auth_block}    reverse_proxy $up:$API_PORT
}
"
  fi

  cp -f "$site" "$site.cliproxy.bak" 2>/dev/null || true

  python3 - "$site" "$start_marker" "$end_marker" "$block" <<'PY'
import sys, re
site, sm, em, block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    txt = open(site).read()
except FileNotFoundError:
    txt = ""
marker = sm + "\n" + block + em + "\n"
pat = re.compile(re.escape(sm) + r".*?" + re.escape(em) + r"\n?", re.S)
if pat.search(txt):
    txt = pat.sub(marker, txt)
    action = "已更新"
else:
    txt = (txt.rstrip("\n") + "\n\n" + marker) if txt.strip() else marker
    action = "已写入"
open(site, "w").write(txt)
print("Caddyfile %s: %s" % (action, site))
PY

  if ! caddy_validate "$site"; then
    err "Caddyfile 校验失败，正在回滚..."
    [[ -f "$site.cliproxy.bak" ]] && cp -f "$site.cliproxy.bak" "$site"
    err "已回滚。请手动检查 $site 是否有语法冲突"
    USE_CADDY=0
    save_state
    return 1
  fi
  info "Caddyfile 校验通过"

  restart_caddy "$site"
  save_state
  return 0
}

remove_caddy_block(){
  local site; site="$(caddy_conf_path)"
  [[ -f "$site" ]] || return 0
  python3 - "$site" <<'PY' || true
import sys, re
p = sys.argv[1]
t = open(p).read()
n = re.sub(re.escape("# >>> CLIProxyAPI START") + r".*?" + re.escape("# >>> CLIProxyAPI END") + r"\n?", "", t, flags=re.S)
if n != t:
    open(p, "w").write((n.rstrip("\n") + "\n") if n.strip() else "")
    print("已从 Caddyfile 移除 CLIProxyAPI 配置块")
else:
    print("Caddyfile 中未找到 CLIProxyAPI 配置块")
PY
  restart_caddy "$site"
}

# ---------- 配置 ----------
write_config(){
  if [[ -d "$CONFIG_FILE" ]]; then
    warn "发现 $CONFIG_FILE 是目录，已删除重建"
    rm -rf "$CONFIG_FILE"
  fi

  local host; host="$(cli_bind_host)"

  if [[ -f "$CONFIG_FILE" ]]; then
    # 已有配置：保留原密钥，仅修正 allow-remote 与监听地址
    sed -i -E 's/(allow-remote:[[:space:]]*)(true|false)/\1true/' "$CONFIG_FILE" 2>/dev/null || true
    if grep -qE '^[[:space:]]*host:' "$CONFIG_FILE"; then
      sed -i -E "s/^([[:space:]]*host:[[:space:]]*).*/\1\"$host\"/" "$CONFIG_FILE" 2>/dev/null || true
    else
      sed -i -E "/^[[:space:]]*server:/a\\  host: \"$host\"" "$CONFIG_FILE" 2>/dev/null || true
    fi
    info "已有 config.yaml，保留原密钥，仅修正 allow-remote=true 与 host=$host"
    load_token
    if [[ -z "${MGMT_SECRET:-}" ]]; then
      # 兼容两种写法：带引号的明文，以及 CLIProxyAPI 回写的无引号 bcrypt 哈希
      MGMT_SECRET="$(awk '
        /^[[:space:]]*secret-key:/ {
          if (match($0, /"[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); exit }
          s = $0
          sub(/^[[:space:]]*secret-key:[[:space:]]*/, "", s)
          sub(/[[:space:]]*#.*$/, "", s)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
          print s; exit
        }
      ' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ "${MGMT_SECRET:0:2}" == '$2' ]]; then
      warn "config 中 secret-key 已是 bcrypt 哈希，明文无法还原"
      warn "如需重置： 删除 $CONFIG_FILE 后重新 install（会重新生成令牌与密钥）"
    fi
  else
    [[ -z "$API_TOKEN" ]] && API_TOKEN="$(gen_rand)"
    [[ -z "$MGMT_SECRET" ]] && MGMT_SECRET="$(gen_rand)"
    cat > "$CONFIG_FILE" <<EOF
config-version: 8
server:
  host: "$host"         # 启用 Caddy 反代时绑 127.0.0.1；直连时绑 0.0.0.0
  port: $API_PORT
management:
  allow-remote: true    # 反代 / NAT 下必须 true，否则管理后台 403
  secret-key: "$MGMT_SECRET"
  disable-control-panel: false
access:
  api-keys:
    - "$API_TOKEN"
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    info "已写入 $CONFIG_FILE（host=$host）"
  fi
}

# 凭据：新建 config 时可自定义 token / secret；Caddy 密码每次都可由 state 复用或重设
ask_credentials(){
  have_tty || return 0
  echo
  echo "---- 凭据设置（直接回车 = 保持现有值 / 自动生成）----"
  if [[ -f "$CONFIG_FILE" ]]; then
    info "已存在 $CONFIG_FILE，API 令牌与登录密钥保持不变"
    info "  如需更换：编辑该文件的 access.api-keys / management.secret-key 后执行 restart"
  else
    ask_credential "⑤ API 令牌(客户端填的 api_key)[回车=随机生成]: " API_TOKEN "${API_TOKEN:-}"
    ask_credential "⑥ 管理面板登录密钥(secret-key)[回车=随机生成]: " MGMT_SECRET "${MGMT_SECRET:-}"
  fi
  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    local hint="随机生成"
    if [[ -n "${CADDY_PLAIN:-}" ]]; then hint="保持现有"; fi
    ask_credential "⑦ 管理面板 Basic 认证密码(账号 $CADDY_USER)[回车=$hint]: " CADDY_PLAIN "${CADDY_PLAIN:-}"
  fi
  return 0
}

do_install(){
  need_root "$@"
  need_python3

  mkdir -p "$PERSIST_DIR"/{auths,logs}
  load_state

  # ---------- 交互选择（必须在写 config 之前，凭据要在这里定下来）----------
  if have_tty; then
    echo
    echo "---- 网络模式选择（直接回车 = 用括号内默认值）----"
    local v
    v="$(_ask "① Cloudflare 域名[当前: ${CF_DOMAIN:-未配置}, 回车=保持]: ")"
    if [[ -n "$v" ]]; then CF_DOMAIN="${v// /}"; fi

    v="$(_ask "② 启用 Caddy 反代[1=启用 0=不启用, 默认 ${USE_CADDY:-1}]: ")"
    USE_CADDY="${v:-${USE_CADDY:-1}}"

    if [[ "$USE_CADDY" == "1" ]]; then
      v="$(_ask "③ 证书方式[cf=内部自签(CF橙云推荐) le=Let's Encrypt, 默认 ${CERT_MODE:-cf}]: ")"
      CERT_MODE="${v:-${CERT_MODE:-cf}}"
      [[ "$CERT_MODE" == "le" || "$CERT_MODE" == "cf" ]] || CERT_MODE=cf

    fi
  fi

  [[ "$USE_CADDY" == "1" ]] && USE_CADDY=1 || USE_CADDY=0

  # 守卫：Caddy 需要域名才能提供有效证书
  if [[ "$USE_CADDY" == "1" && -z "$CF_DOMAIN" ]]; then
    warn "Caddy 需要域名才能提供有效证书，已退回『IP 直连』模式"
    USE_CADDY=0
  fi

  ask_credentials

  # 先定下 Caddy 形态：它决定 8317 绑哪里、反代目标填什么地址
  if [[ "$USE_CADDY" == "1" ]]; then
    ensure_caddy
    info "将使用宿主机 Caddy： $(command -v caddy 2>/dev/null || echo '(即将安装)')"
  fi

  save_state
  write_config

  # 端口守卫
  if port_in_use "$API_PORT"; then
    err "端口 $API_PORT 已被其他进程占用，请先释放： ss -ltnp | grep :$API_PORT"
    exit 1
  fi

  # 安装并启动 CLIProxyAPI（原生二进制 + systemd，无 Docker）
  download_cliproxy_binary || exit 1
  install_cliproxy_unit
  systemctl enable --now cliproxy-api >/dev/null 2>&1 || true
  wait_api

  if [[ "$USE_CADDY" == "1" ]]; then
    setup_caddy || true
    # setup_caddy 失败时内部会把 USE_CADDY 置 0，此时服务还绑着 127.0.0.1，
    # 必须重新写 host=0.0.0.0 并重启服务，否则外部根本连不上
    if [[ "$USE_CADDY" != "1" ]]; then
      warn "已回退 IP 直连，重新绑定 0.0.0.0 并重启服务"
      write_config
      systemctl restart cliproxy-api >/dev/null 2>&1 || true
      wait_api
    fi
  fi
  save_state
  do_status
}

# ---------- 运行控制 ----------
do_start(){
  if svc_cliproxy start; then info "已启动"; else err "启动失败，看日志： journalctl -u cliproxy-api --tail 50"; fi
}

do_stop(){
  if svc_cliproxy stop; then info "已停止"; else warn "未运行"; fi
}

do_restart(){
  if svc_cliproxy restart; then info "已重启"; else err "重启失败，看日志： journalctl -u cliproxy-api --tail 50"; fi
}

do_status(){
  load_state
  if ! systemctl is-active --quiet cliproxy-api; then
    warn "服务 cliproxy-api 未运行（用 start 启动）"
  else
    info "服务 cliproxy-api 正在运行（$(cli_bind_host) :$API_PORT）"
  fi
  load_token

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "Authorization: Bearer ${API_TOKEN:-}" \
    "http://127.0.0.1:$API_PORT/v1/models" 2>/dev/null || echo 000)"

  if [[ "$code" == "200" ]]; then
    info "API 健康检查 200 OK，当前可用模型："
    curl -s --max-time 10 -H "Authorization: Bearer ${API_TOKEN:-}" \
      "http://127.0.0.1:$API_PORT/v1/models" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);[print('      -',m['id']) for m in d.get('data',[])]" 2>/dev/null \
      || echo "      (模型列表解析失败，可在管理面板查看)"
  else
    warn "API 健康检查返回 $code（看日志： journalctl -u cliproxy-api --tail 30）"
  fi

  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    if [[ -d /run/systemd/system ]] && systemctl is-active --quiet caddy; then
      info "Caddy 运行中： $(caddy version 2>/dev/null | head -1)（反代 → 127.0.0.1:$API_PORT）"
    else
      warn "Caddy 未作为 systemd 服务运行，重启机器后可能失效"
    fi
  fi
  show_info
}

do_logs(){
  if [[ -d /run/systemd/system ]] && systemctl list-unit-files --type=service 2>/dev/null | grep -q '^cliproxy-api\.service'; then
    journalctl -u cliproxy-api -n 100 --no-pager 2>&1 || warn "无日志（可能尚未运行）"
  else
    warn "未以 systemd 安装，日志路径： $PERSIST_DIR/logs"
  fi
}

do_update(){
  need_root "$@"
  load_state
  info "拉取最新 CLIProxyAPI 二进制（v${CLI_VERSION:-8.0.33}）..."
  download_cliproxy_binary || warn "下载失败，继续使用现有二进制"
  install_cliproxy_unit
  systemctl restart cliproxy-api >/dev/null 2>&1 || true
  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    ensure_caddy
  fi
  if [[ "${USE_CADDY:-0}" == "1" && -n "$CF_DOMAIN" ]]; then
    setup_caddy || true
    if [[ "$USE_CADDY" != "1" ]]; then
      warn "Caddy 异常，已回退 IP 直连并重新绑定 0.0.0.0"
      write_config
      systemctl restart cliproxy-api >/dev/null 2>&1 || true
      wait_api
    fi
  fi
  info "已更新并重启"
  do_status
}

do_uninstall(){
  need_root "$@"
  load_state

  systemctl stop cliproxy-api >/dev/null 2>&1 || true
  systemctl disable cliproxy-api >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cliproxy-api.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  info "CLIProxyAPI 服务已移除（未删除二进制 $CLI_BIN，可留作他用）"

  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    remove_caddy_block || true
  fi

  local c
  c="$(_ask "是否删除配置目录 $PERSIST_DIR ? [y/N]: ")"
  if [[ "$c" == "y" || "$c" == "Y" ]]; then
    rm -rf "$PERSIST_DIR"
    warn "已删除 $PERSIST_DIR"
  else
    info "保留配置目录 $PERSIST_DIR"
  fi
  info "Caddy 本体未卸载（可能还有其它站点在用）。如需卸载： rm -f /usr/local/bin/caddy /etc/systemd/system/caddy.service"
}

show_menu(){
  while true; do
    echo
    echo "====== CLIProxyAPI 管理菜单（原生二进制版）======"
    echo " 1) 安装/重建 install"
    echo " 2) 启动 start"
    echo " 3) 停止 stop"
    echo " 4) 重启 restart"
    echo " 5) 状态 status"
    echo " 6) 查看日志 logs"
    echo " 7) 更新 update"
    echo " 8) 卸载 uninstall"
    echo " 0) 退出"
    echo "================================================="
    local sel; sel="$(_ask '请选择 [0-8]: ')"
    case "$sel" in
      1) do_install ;;
      2) do_start ;;
      3) do_stop ;;
      4) do_restart ;;
      5) do_status ;;
      6) do_logs ;;
      7) do_update ;;
      8) do_uninstall ;;
      0|"") exit 0 ;;
      *) warn "无效选择: $sel，请重试" ;;
    esac
  done
}

# ---------- 入口 ----------
usage(){
  cat <<'EOF'
CLIProxyAPI 一键部署脚本（原生二进制版 · 无 Docker）

用法:
  bash cli-proxy-deploy.sh [子命令]

子命令:
  (无)        有终端时进入管理菜单，无终端时等同 install
  install     安装或重建（下载二进制 / 写配置 / 起 systemd 服务 / 配 Caddy）
  start       启动服务
  stop        停止服务
  restart     重启服务
  status      查看状态、可用模型与全部凭据
  logs        查看最近 100 行日志（journalctl）
  update      重新下载最新二进制并重启（复用已有凭据与网络模式）
  uninstall   卸载服务（可选是否删除配置目录）
  menu        进入管理菜单
  help        显示本帮助

非交互安装（CI / 脚本调用），可用环境变量覆盖:
  API_TOKEN=xxx            客户端使用的 api_key（不填自动生成）
  MGMT_SECRET=xxx          管理面板 secret-key（不填自动生成）
  CADDY_PLAIN=xxx          管理面板 Basic 认证密码（不填自动生成）
  CF_DOMAIN=proxy.xxx.com  绑定域名；留空 = 直接用 IP:8317
  USE_CADDY=1|0            是否启用 Caddy 反代（默认 0）
  CERT_MODE=cf|le          cf=内部自签(适配 Cloudflare 橙云) | le=Let's Encrypt
  CLI_VERSION=8.0.33       CLIProxyAPI 版本（决定下载哪个 release）
  API_PORT=8317            服务端口
  PERSIST_DIR=/opt/cliproxy 配置与登录态目录

示例:
  sudo bash cli-proxy-deploy.sh install
  sudo API_TOKEN=mykey12345 CF_DOMAIN=proxy.example.com USE_CADDY=1 \
       bash cli-proxy-deploy.sh install
EOF
}

case "${1:-}" in
  install)   do_install ;;
  start)     do_start ;;
  stop)      do_stop ;;
  restart)   do_restart ;;
  status)    do_status ;;
  logs)      do_logs ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  menu)      show_menu ;;
  help|-h|--help) usage ;;
  "")
    if have_tty; then show_menu; else do_install; fi
    ;;
  *)
    warn "未知参数: $1"
    usage
    exit 1
    ;;
esac
