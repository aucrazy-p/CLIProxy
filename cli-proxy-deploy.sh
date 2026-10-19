#!/usr/bin/env bash
# =============================================================
#  CLIProxyAPI 一键部署脚本（全自动版）
# -------------------------------------------------------------
#  作用：在 Linux 服务器上以 Docker 方式部署 CLIProxyAPI，
#        把已有订阅账号的额度统一包装成标准 OpenAI 兼容 API
#        （默认监听 8317，可被任意支持自定义 base_url 的客户端调用）
#
#  本版自动化范围（无需任何手工步骤）：
#    - 自动安装缺失的 Docker
#    - 自动检测 Caddy：已装则复用；未装则 apt 安装；apt 失败
#      自动改用官方静态二进制，并自动写好 systemd 服务 + 开机自启
#    - 自动在 Caddyfile 中插入带标记的配置块（不破坏已有站点）
#    - 写入前备份 + `caddy validate` 校验，校验失败自动回滚
#    - 自动重载/启动 Caddy
#    - 自动放行 GCP 防火墙，默认把来源收紧为 Cloudflare 回源段
#
#  网络模式（安装时交互选择，写入状态文件，update 自动复用）：
#    ① 域名：留空 = 直接用 IP:8317；填写 = 走域名
#    ② 反代：1 = 启用 Caddy 自动 HTTPS；0 = 不启用
#    ③ 证书：cf = 内部自签(CF 橙云最稳，默认)；le = Let's Encrypt
#    ④ 防火墙：1 = 仅放行 Cloudflare 回源段；0 = 全部放行
#    ⑤⑥⑦ 凭据：回车自动生成随机值，也可自己指定
#
#  用法：
#    bash cli-proxy-deploy.sh help       # 查看完整帮助
#    交互菜单： bash cli-proxy-deploy.sh
#    子命令：   bash cli-proxy-deploy.sh install|start|stop|restart|status|logs|update|uninstall|menu
#    非交互：
#      API_TOKEN=xxx CF_DOMAIN=cliproxy.xxx.com USE_CADDY=1 CERT_MODE=cf \
#      CF_IPS_ONLY=1 bash cli-proxy-deploy.sh install
# =============================================================

set -euo pipefail

PERSIST_DIR="${PERSIST_DIR:-/opt/cliproxy}"
IMAGE="${IMAGE:-eceasy/cli-proxy-api:latest}"
API_PORT="${API_PORT:-8317}"
CONTAINER="cli-proxy-api"
CONFIG_FILE="$PERSIST_DIR/config.yaml"
STATE_FILE="$PERSIST_DIR/.deploy.env"
CADDYFILE_DEFAULT="/etc/caddy/Caddyfile"
# OAuth 回调端口(Gemini=8085/Codex=1455/Claude=54545/Antigravity=51121/iFlow=11451/xAI=56121)
MGMT_PORTS=(8085 1455 54545 51121 11451 56121)

CF_DOMAIN="${CF_DOMAIN:-}"
GCP_PUBLIC_IP="${GCP_PUBLIC_IP:-}"
USE_CADDY="${USE_CADDY:-0}"
CERT_MODE="${CERT_MODE:-cf}"          # cf=内部自签 | le=Let's Encrypt
CF_IPS_ONLY="${CF_IPS_ONLY:-1}"       # 1=防火墙只放行 Cloudflare 回源段
CADDY_PLAIN="${CADDY_PLAIN:-}"
CADDY_USER="${CADDY_USER:-admin}"
API_TOKEN="${API_TOKEN:-}"
MGMT_SECRET="${MGMT_SECRET:-}"
# Caddy 运行形态：native=宿主机进程 | docker=已有容器 | none=未安装
# docker 模式下额外记录容器名与 Caddyfile 的宿主机/容器内路径
CADDY_MODE="${CADDY_MODE:-}"
CADDY_CONTAINER="${CADDY_CONTAINER:-}"
CADDY_CONF_HOST="${CADDY_CONF_HOST:-}"
CADDY_CONF_CONT="${CADDY_CONF_CONT:-}"

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
    err "本脚本需要 root 权限（会写 /opt、/etc/caddy、/usr/local/bin，并操作防火墙）"
    err "请改用： sudo bash $0 $*"
    exit 1
  fi
}

need_python3(){
  command -v python3 >/dev/null 2>&1 || {
    err "缺少 python3（用于解析配置与写入 Caddyfile）"
    err "请先安装： apt-get update && apt-get install -y python3"
    exit 1
  }
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
CF_IPS_ONLY="$CF_IPS_ONLY"
CADDY_MODE="$CADDY_MODE"
CADDY_CONTAINER="$CADDY_CONTAINER"
CADDY_CONF_HOST="$CADDY_CONF_HOST"
CADDY_CONF_CONT="$CADDY_CONF_CONT"
CADDY_PLAIN="$CADDY_PLAIN"
CADDY_USER="$CADDY_USER"
API_TOKEN="$API_TOKEN"
MGMT_SECRET="$MGMT_SECRET"
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
    API_TOKEN=$(python3 -c "import re;m=re.search(r'api-keys:\s*\n\s*-\s*\"([^\"]+)\"', open('$CONFIG_FILE').read());print(m.group(1) if m else '')" 2>/dev/null || true)
  fi
  return 0
}

# docker0 网桥地址（宿主机在容器网络里的身份）
docker0_ip(){ ip -4 addr show docker0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1 || true; }

# Caddy 容器是否用 host 网络（是则它能看到宿主机 127.0.0.1）
caddy_is_host_net(){
  [[ "${CADDY_MODE:-}" == "docker" ]] || return 1
  [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CADDY_CONTAINER" 2>/dev/null || true)" == "host" ]]
}

# 容器 8317 绑定地址：
#   native Caddy / host 网络的 Caddy → 只绑 127.0.0.1
#   bridge 网络的 Caddy 容器 → 绑 docker0 网关（容器内才够得着，公网仍不可达）
#   不用 Caddy → 0.0.0.0
bind_addr(){
  if [[ "${USE_CADDY:-0}" != "1" ]]; then echo "0.0.0.0"; return 0; fi
  if [[ "${CADDY_MODE:-}" == "docker" ]] && ! caddy_is_host_net; then
    local gw; gw="$(docker0_ip)"
    if [[ -n "$gw" ]]; then echo "$gw"; else echo "0.0.0.0"; fi
    return 0
  fi
  echo "127.0.0.1"
}

# 反代目标主机（从 Caddy 的视角看 CLIProxyAPI 在哪）
caddy_upstream(){
  if [[ "${CADDY_MODE:-}" == "docker" ]] && ! caddy_is_host_net; then
    local gw; gw="$(docker0_ip)"
    printf '%s' "${gw:-host.docker.internal}"
    return 0
  fi
  printf '127.0.0.1'
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
  echo "========================================================="
}

# ---------- Docker ----------
ensure_docker(){
  if ! command -v docker >/dev/null 2>&1; then
    warn "未检测到 Docker，开始自动安装（get.docker.com）..."
    curl -fsSL https://get.docker.com | sh || {
      err "Docker 自动安装失败，请手动执行： curl -fsSL https://get.docker.com | sh"
      exit 1
    }
  fi
  if ! docker info >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    sleep 2
    docker info >/dev/null 2>&1 || { err "Docker 未运行，请检查： systemctl status docker"; exit 1; }
  fi
  info "Docker 就绪： $(docker --version 2>/dev/null)"
}

run_container(){
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  local mgmt_map="" baddr p
  baddr="$(bind_addr)"
  for p in "${MGMT_PORTS[@]}"; do mgmt_map="$mgmt_map -p 127.0.0.1:$p:$p"; done
  # shellcheck disable=SC2086
  docker run -d --name "$CONTAINER" --restart unless-stopped \
    --memory 512m \
    -p "$baddr:$API_PORT:$API_PORT" \
    $mgmt_map \
    -v "$CONFIG_FILE:/CLIProxyAPI/config.yaml" \
    -v "$PERSIST_DIR/auths:/root/.cli-proxy-api" \
    -v "$PERSIST_DIR/logs:/CLIProxyAPI/logs" \
    "$IMAGE" >/dev/null
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
  warn "等待超时，请查看日志： docker logs $CONTAINER --tail 50"
  return 0
}

# ---------- 防火墙 ----------
cf_cidrs(){
  local v4 v6 out=""
  v4="$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v4 2>/dev/null | grep -E '^[0-9]' | paste -sd, - || true)"
  v6="$(curl -fsSL --max-time 10 https://www.cloudflare.com/ips-v6 2>/dev/null | grep -E '^[0-9a-fA-F]' | paste -sd, - || true)"
  [[ -n "$v4" ]] && out="$v4"
  [[ -n "$v6" ]] && out="${out:+$out,}$v6"
  printf '%s' "$out"
}

firewall_src(){
  local src="0.0.0.0/0" cf
  if [[ "${CF_IPS_ONLY:-0}" == "1" && "${USE_CADDY:-0}" == "1" && -n "${CF_DOMAIN:-}" ]]; then
    cf="$(cf_cidrs)"
    if [[ -n "$cf" ]]; then
      src="$cf"
      info "防火墙来源已收紧为 Cloudflare 回源段（$(printf '%s' "$cf" | tr ',' '\n' | wc -l) 条）"
    else
      warn "Cloudflare IP 段拉取失败，退回 0.0.0.0/0（源站可能被直连绕开 CF）"
    fi
  fi
  printf '%s' "$src"
}

gcp_allow(){
  local p="$1"
  local src="$2"
  local rule="allow-cliproxy-$p"
  if gcloud compute firewall-rules describe "$rule" >/dev/null 2>&1; then
    if gcloud compute firewall-rules update "$rule" --source-ranges="$src" --rules="tcp:$p" >/dev/null 2>&1; then
      info "防火墙规则 $rule 已更新"
    else
      warn "防火墙规则 $rule 更新失败，请手动检查"
    fi
  else
    if gcloud compute firewall-rules create "$rule" --direction=INGRESS --priority=1000 \
      --network=default --action=ALLOW --rules="tcp:$p" --source-ranges="$src" \
      --description="CLIProxyAPI" >/dev/null 2>&1; then
      info "已放行 tcp:$p"
    else
      warn "自动创建失败，请手动放行 tcp:$p"
    fi
  fi
}

check_default_rules(){
  command -v gcloud >/dev/null 2>&1 || return 0
  local r srcs a
  for r in default-allow-http default-allow-https; do
    gcloud compute firewall-rules describe "$r" >/dev/null 2>&1 || continue
    srcs="$(gcloud compute firewall-rules describe "$r" --format='value(sourceRanges)' 2>/dev/null || true)"
    [[ "$srcs" == *"0.0.0.0/0"* ]] || continue
    warn "检测到 $r 仍对 0.0.0.0/0 开放，任何人可绕过 Cloudflare 直连源站"
    a="$(_ask "   是否删除 $r ？[y/N]: ")"
    if [[ "$a" == "y" || "$a" == "Y" ]]; then
      gcloud compute firewall-rules delete "$r" --quiet >/dev/null 2>&1 \
        && info "已删除 $r" || warn "删除失败，请手动在 GCP 控制台处理"
    else
      warn "已保留 $r —— 源站仍可被直连，请注意"
    fi
  done
  return 0
}

do_firewall(){
  if ! command -v gcloud >/dev/null 2>&1; then
    if [[ "${USE_CADDY:-0}" == "1" ]]; then
      warn "未检测到 gcloud，请手动放行 tcp:80,443（来源建议仅 Cloudflare IP 段）"
    else
      warn "未检测到 gcloud，请手动放行 tcp:$API_PORT"
    fi
    return 0
  fi
  local src
  src="$(firewall_src)"
  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    gcp_allow 80 "$src"
    gcp_allow 443 "$src"
    check_default_rules
  else
    gcp_allow "$API_PORT" "$src"
  fi
  return 0
}

# ---------- Caddy ----------
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

# 在 Docker 里找 Caddy 容器挂载的 Caddyfile，定位宿主机路径与容器内路径
resolve_docker_caddyfile(){
  local c="$1" m type src dst
  m="$(docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$c" 2>/dev/null || true)"
  [[ -z "$m" ]] && return 1
  # ① 直接挂了 Caddyfile 文件
  while IFS='|' read -r type src dst; do
    [[ -z "$dst" ]] && continue
    if [[ "$dst" == *Caddyfile* && -n "$src" ]]; then
      CADDY_CONF_HOST="$src"; CADDY_CONF_CONT="$dst"; return 0
    fi
  done <<< "$m"
  # ② 挂了 /etc/caddy 目录
  while IFS='|' read -r type src dst; do
    [[ -z "$dst" ]] && continue
    if [[ "$dst" == "/etc/caddy" || "$dst" == "/etc/caddy/" ]]; then
      CADDY_CONF_HOST="${src%/}/Caddyfile"; CADDY_CONF_CONT="/etc/caddy/Caddyfile"; return 0
    fi
  done <<< "$m"
  return 1
}

# 探测 Caddy 形态：优先复用 Docker 容器，其次宿主机二进制，最后 none
detect_caddy(){
  # 沿用上次记录的容器（还活着就直接用，避免同一个 Caddyfile 被认成别的）
  if [[ "${CADDY_MODE:-}" == "docker" && -n "${CADDY_CONTAINER:-}" ]]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER"; then
      return 0
    fi
    warn "上次复用的 Caddy 容器 $CADDY_CONTAINER 已不存在，重新探测"
    CADDY_MODE=""; CADDY_CONTAINER=""; CADDY_CONF_HOST=""; CADDY_CONF_CONT=""
  fi

  if command -v docker >/dev/null 2>&1; then
    local line name
    line="$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -i caddy | head -1 || true)"
    if [[ -n "$line" ]]; then
      name="${line%%|*}"
      if resolve_docker_caddyfile "$name"; then
        CADDY_MODE="docker"; CADDY_CONTAINER="$name"
        return 0
      fi
      if [[ "${_CADDY_WARNED:-0}" != "1" ]]; then
        warn "发现 Caddy 容器 $name，但它没有挂载 Caddyfile，无法安全复用"
        warn "  可改用 IP 直连，或给容器加上 -v /etc/caddy/Caddyfile:/etc/caddy/Caddyfile 后重跑"
        _CADDY_WARNED=1
      fi
    fi
  fi

  if command -v caddy >/dev/null 2>&1; then
    CADDY_MODE="native"; CADDY_CONTAINER=""; CADDY_CONF_HOST=""; CADDY_CONF_CONT=""
    return 0
  fi

  CADDY_MODE="none"; return 0
}

# 统一的 Caddy 操作入口：docker 模式走 docker exec
caddy_validate(){
  local site="$1"
  if [[ "${CADDY_MODE:-}" == "docker" ]]; then
    docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_CONF_CONT" --adapter caddyfile >/dev/null 2>&1
  else
    caddy validate --config "$site" >/dev/null 2>&1
  fi
}

caddy_hash(){
  if [[ "${CADDY_MODE:-}" == "docker" ]]; then
    docker exec "$CADDY_CONTAINER" caddy hash-password --plaintext "$1" 2>/dev/null
  else
    caddy hash-password --plaintext "$1" 2>/dev/null \
      || printf '%s' "$1" | caddy hash-password 2>/dev/null
  fi
}

ensure_caddy(){
  detect_caddy
  case "${CADDY_MODE:-none}" in
    docker)
      info "复用已有 Caddy 容器： $CADDY_CONTAINER"
      info "  Caddyfile（宿主机）: $CADDY_CONF_HOST"
      info "  Caddyfile（容器内）: $CADDY_CONF_CONT"
      if ! caddy_is_host_net; then
        info "  容器为 bridge 网络 → 反代目标用 $(caddy_upstream):$API_PORT"
      fi
      return 0
      ;;
    native)
      info "已检测到 Caddy： $(command -v caddy)  $(caddy version 2>/dev/null | head -1)"
      return 0
      ;;
  esac

  # 装之前先看 80/443 是否已被别人占着（nginx / 其它容器 / 残留进程）
  local p
  for p in 80 443; do
    if port_in_use "$p"; then
      err "端口 $p 已被占用，此时装 Caddy 会起不来"
      ss -ltnp 2>/dev/null | grep -E "[:.]$p[[:space:]]" || true
      err "请先释放该端口（或让占用方反代到 127.0.0.1:$API_PORT），再重跑 install"
      return 1
    fi
  done

  warn "未检测到 Caddy（含 Docker 容器），开始自动安装（无需手工操作）"

  if command -v apt-get >/dev/null 2>&1; then
    info "尝试用 apt 安装 caddy ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    if apt-get install -y --no-install-recommends caddy >/dev/null 2>&1 && command -v caddy >/dev/null 2>&1; then
      CADDY_MODE="native"
      info "apt 安装成功： $(caddy version 2>/dev/null | head -1)"
      return 0
    fi
    warn "apt 安装未成功，改用官方静态二进制"
  fi

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
  if [[ "${CADDY_MODE:-}" == "docker" && -n "${CADDY_CONF_HOST:-}" ]]; then
    printf '%s' "$CADDY_CONF_HOST"; return 0
  fi
  local p
  p="$(systemctl cat caddy 2>/dev/null | grep -oE '\-\-config[ =][^ ]+' | head -1 | awk '{print $NF}' || true)"
  if [[ -n "$p" ]]; then printf '%s' "$p"; else printf '%s' "$CADDYFILE_DEFAULT"; fi
}

restart_caddy(){
  local site="$1"
  if [[ "${CADDY_MODE:-}" == "docker" ]]; then
    if docker exec "$CADDY_CONTAINER" caddy reload --config "$CADDY_CONF_CONT" --adapter caddyfile >/dev/null 2>&1; then
      info "Caddy 容器已重载（$CADDY_CONTAINER）"; return 0
    fi
    if docker restart "$CADDY_CONTAINER" >/dev/null 2>&1; then
      info "Caddy 容器已重启（$CADDY_CONTAINER）"; return 0
    fi
    warn "Caddy 容器重载失败，请手动检查： docker logs $CADDY_CONTAINER --tail 30"
    return 0
  fi
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

  local up; up="$(caddy_upstream)"
  if [[ "$up" != "127.0.0.1" ]]; then
    info "反代目标： $up:$API_PORT（Caddy 在容器里，不能用 127.0.0.1）"
  fi

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

# ---------- 安装 ----------
write_config(){
  if [[ -d "$CONFIG_FILE" ]]; then
    warn "发现 $CONFIG_FILE 是目录(Docker 挂载陷阱)，已删除重建"
    rm -rf "$CONFIG_FILE"
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    sed -i -E 's/(allow-remote:[[:space:]]*)(true|false)/\1true/' "$CONFIG_FILE" 2>/dev/null || true
    info "已有 config.yaml，保留原密钥，仅修正 allow-remote=true"
    load_token
    if [[ -z "${MGMT_SECRET:-}" ]]; then
      MGMT_SECRET="$(python3 -c "import re;m=re.search(r'secret-key:\s*\"([^\"]*)\"', open('$CONFIG_FILE').read());print(m.group(1) if m else '')" 2>/dev/null || true)"
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
  host: ""              # 空 = 监听所有接口（容器内必须如此）
  port: $API_PORT
management:
  allow-remote: true    # Docker 网桥下必须 true，否则管理后台 403
  secret-key: "$MGMT_SECRET"
  disable-control-panel: false
access:
  api-keys:
    - "$API_TOKEN"
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    info "已写入 $CONFIG_FILE"
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
  ensure_docker

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

      v="$(_ask "④ 防火墙仅放行 Cloudflare 回源段?[1=是(推荐) 0=全部放行, 默认 ${CF_IPS_ONLY:-1}]: ")"
      CF_IPS_ONLY="${v:-${CF_IPS_ONLY:-1}}"
    fi
  fi

  [[ "$USE_CADDY" == "1" ]] && USE_CADDY=1 || USE_CADDY=0
  if [[ "${CF_IPS_ONLY:-1}" == "0" ]]; then CF_IPS_ONLY=0; else CF_IPS_ONLY=1; fi

  # 守卫：Caddy 需要域名才能提供有效证书
  if [[ "$USE_CADDY" == "1" && -z "$CF_DOMAIN" ]]; then
    warn "Caddy 需要域名才能提供有效证书，已退回『IP 直连』模式"
    USE_CADDY=0
  fi

  ask_credentials

  # 先定下 Caddy 形态：它决定 8317 绑哪里、反代目标填什么地址
  if [[ "$USE_CADDY" == "1" ]]; then
    detect_caddy
    case "${CADDY_MODE:-none}" in
      docker) info "将复用 Docker 里的 Caddy 容器： $CADDY_CONTAINER" ;;
      native) info "将复用宿主机 Caddy： $(command -v caddy)" ;;
      *)      info "未发现 Caddy，稍后自动安装" ;;
    esac
  fi

  save_state
  write_config

  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    if port_in_use "$API_PORT"; then
      err "端口 $API_PORT 已被其他进程占用，请先释放： ss -ltnp | grep :$API_PORT"
      exit 1
    fi
  fi

  run_container
  wait_api

  if [[ "$USE_CADDY" == "1" ]]; then
    setup_caddy || true
    # setup_caddy 失败时内部会把 USE_CADDY 置 0，此时容器还绑着 127.0.0.1，
    # 必须重新 run 一次改成 0.0.0.0，否则外部根本连不上
    if [[ "$USE_CADDY" != "1" ]]; then
      warn "已回退 IP 直连，重新绑定 0.0.0.0 并重启容器"
      run_container
      wait_api
    fi
  fi
  do_firewall
  save_state
  do_status
}

# ---------- 运行控制 ----------
do_start(){
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker start "$CONTAINER" >/dev/null && info "已启动"
  else
    err "容器不存在，请先执行 install"
  fi
}

do_stop(){
  docker stop "$CONTAINER" >/dev/null 2>&1 && info "已停止" || warn "未运行"
}

do_restart(){
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker restart "$CONTAINER" >/dev/null && info "已重启"
  else
    err "容器不存在，请先执行 install"
  fi
}

do_status(){
  load_state
  if ! command -v docker >/dev/null 2>&1; then
    err "未检测到 docker，请先执行 install"
    return 1
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    warn "容器 $CONTAINER 未运行（用 start 启动）"
    return 0
  fi
  info "容器 $CONTAINER 正在运行（$API_PORT 绑定 $(bind_addr)）"
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
    warn "API 健康检查返回 $code（看日志： docker logs $CONTAINER --tail 30）"
  fi

  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    if [[ "${CADDY_MODE:-}" == "docker" ]]; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CADDY_CONTAINER"; then
        info "Caddy 容器运行中： $CADDY_CONTAINER（反代 → $(caddy_upstream):$API_PORT）"
      else
        warn "Caddy 容器 $CADDY_CONTAINER 未运行"
      fi
    elif [[ -d /run/systemd/system ]] && systemctl is-active --quiet caddy; then
      info "Caddy 运行中： $(caddy version 2>/dev/null | head -1)"
    else
      warn "Caddy 未作为 systemd 服务运行，重启机器后可能失效"
    fi
  fi
  show_info
}

do_logs(){
  docker logs --tail 100 "$CONTAINER" 2>&1 || warn "无日志（可能尚未运行）"
}

do_update(){
  need_root "$@"
  load_state
  info "拉取最新镜像 $IMAGE ..."
  docker pull "$IMAGE" >/dev/null 2>&1 || warn "拉取失败，使用现有镜像"
  if [[ "${USE_CADDY:-0}" == "1" ]]; then
    detect_caddy
  fi
  run_container
  if [[ "${USE_CADDY:-0}" == "1" && -n "$CF_DOMAIN" ]]; then
    setup_caddy || true
    if [[ "$USE_CADDY" != "1" ]]; then
      warn "Caddy 异常，已回退 IP 直连并重新绑定 0.0.0.0"
      run_container
      wait_api
    fi
  fi
  info "已更新并重启"
  do_status
}

do_uninstall(){
  need_root "$@"
  load_state
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  info "容器已移除"

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
  info "Caddy 本体未卸载（可能还有其它站点在用）。如需卸载： apt remove caddy"
}

show_menu(){
  while true; do
    echo
    echo "====== CLIProxyAPI 管理菜单 ======"
    echo " 1) 安装/重建 install"
    echo " 2) 启动 start"
    echo " 3) 停止 stop"
    echo " 4) 重启 restart"
    echo " 5) 状态 status"
    echo " 6) 查看日志 logs"
    echo " 7) 更新 update"
    echo " 8) 卸载 uninstall"
    echo " 0) 退出"
    echo "=================================="
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
CLIProxyAPI 一键部署脚本

用法:
  bash cli-proxy-deploy.sh [子命令]

子命令:
  (无)        有终端时进入管理菜单，无终端时等同 install
  install     安装或重建（自动装 Docker / 写配置 / 起容器 / 配 Caddy / 放行防火墙）
  start       启动容器
  stop        停止容器
  restart     重启容器
  status      查看状态、可用模型与全部凭据
  logs        查看最近 100 行日志
  update      拉取最新镜像并重启（复用已有凭据与网络模式）
  uninstall   卸载容器（可选是否删除配置目录）
  menu        进入管理菜单
  help        显示本帮助

非交互安装（CI / 脚本调用），可用环境变量覆盖:
  API_TOKEN=xxx            客户端使用的 api_key（不填自动生成）
  MGMT_SECRET=xxx          管理面板 secret-key（不填自动生成）
  CADDY_PLAIN=xxx          管理面板 Basic 认证密码（不填自动生成）
  CF_DOMAIN=proxy.xxx.com  绑定域名；留空 = 直接用 IP:8317
  USE_CADDY=1|0            是否启用 Caddy 反代（默认 0）
  CERT_MODE=cf|le          cf=内部自签(适配 Cloudflare 橙云) | le=Let's Encrypt
  CF_IPS_ONLY=1|0          防火墙是否只放行 Cloudflare 回源段
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
