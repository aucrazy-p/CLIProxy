# CLIProxyAPI 一键部署脚本（无 Docker · 原生二进制版）

在 Linux 服务器（Debian / Ubuntu 优先，其它发行版可用）上把 **CLIProxyAPI** 部署起来，对外暴露一个**标准 OpenAI 兼容接口**（默认 `8317` 端口），任何支持自定义 `base_url` 的客户端都能直接调用。

**一条命令装完，中间只需回答几个问题，不需要手工改配置。**

本版已彻底去掉 Docker 依赖，最省内存：
- **CLIProxyAPI 直接作为宿主机 systemd 服务运行**（二进制 `/usr/local/bin/CLIProxyAPI`），不拉镜像、不装 Docker 守护进程，零容器开销
- **Caddy 使用官方静态二进制安装**（不走 apt、不进容器），自动写 systemd 服务 + 开机自启；已有宿主机 Caddy 则直接复用
- 缺 `python3` 自动安装（apt / dnf / yum / apk）
- Caddyfile 用标记块插入，**不破坏你已有的其它站点**；写入前备份 + `caddy validate` 校验，失败自动回滚
- 自动放行 GCP 防火墙（Cloudflare 场景默认仅放行 CF 回源段）
- 凭据自动生成并落盘，装完打印全套

---

## 一、一键安装

```bash
curl -fsSL -o /tmp/cpa.sh https://raw.githubusercontent.com/aucrazy-p/CLIProxy/main/cli-proxy-deploy.sh \
  && sudo bash /tmp/cpa.sh install
```

> ⚠️ 不要写成 `curl ... | sudo bash`。管道会吞掉 tty，脚本的交互提问会被静默跳过、全部走默认值。

第一次用也可以直接进菜单（推荐）：

```bash
sudo bash /tmp/cpa.sh
```

---

## 二、安装时会问什么

只有 **4 个网络项 + 3 个凭据项**，**全部可以直接回车用默认值**。

| # | 问题 | 默认 | 说明 |
|---|---|---|---|
| ① | Cloudflare 域名 | 空 | 留空 = 直接用 `IP:8317`；填 `proxy.example.com` = 走域名 |
| ② | 启用 Caddy 反代 | `1` | 想纯 IP 直连就填 `0`（非交互未指定时按 `0`） |
| ③ | 证书方式 | `cf` | 仅启用 Caddy 时问：`cf`=内部自签（适配 CF 橙云）/ `le`=Let's Encrypt |
| ④ | 防火墙仅放行 Cloudflare | `1` | 仅启用 Caddy 时问：填 `0` 则对全网开放 |
| ⑤ | API 令牌 | 随机 | 客户端调接口填的 `api_key` |
| ⑥ | 管理面板登录密钥 | 随机 | 后台登录用 |
| ⑦ | Basic 认证密码 | 随机 | 仅启用 Caddy 时问，账号固定 `admin` |

**③ 选 `cf` 的原因**：Cloudflare 橙云（Proxied）后面做 HTTP-01 挑战经常失败，自签证书没有 ACME 挑战，且 CF `Full` 模式不校验它，浏览器看到的是 CF 的证书，终端无感知。**此时 CF 的 SSL/TLS 模式必须选 `Full`，不能选 `Full (strict)`**（strict 会校验自签证书报 526）。想走 `le`（Let's Encrypt）需要 80/443 公网可达且域名已解析到本机；灰云（DNS only）直连场景才建议用 `le`。

> 启用 Caddy 后，CLIProxyAPI 只绑 `127.0.0.1`（仅本机 Caddy 够得着，公网不可直连）；不启用 Caddy 时绑 `0.0.0.0` 直接对外。

---

## 三、非交互 / 脚本调用

用环境变量一次性指定，无需回答问题：

```bash
sudo API_TOKEN=mykey123456 \
     MGMT_SECRET=mysecret123456 \
     CF_DOMAIN=proxy.example.com \
     USE_CADDY=1 CERT_MODE=cf CF_IPS_ONLY=1 \
     bash cli-proxy-deploy.sh install
```

| 变量 | 作用 | 默认 |
|---|---|---|
| `API_TOKEN` | 客户端 `api_key`（不填自动生成） | 随机 |
| `MGMT_SECRET` | 管理面板 `secret-key`（不填自动生成） | 随机 |
| `CADDY_PLAIN` | 后台 Basic 认证密码（不填自动生成） | 随机 |
| `CF_DOMAIN` | 绑定域名；留空 = `IP:8317` 直连 | 空 |
| `USE_CADDY` | 是否启用 Caddy 反代 | `0` |
| `CERT_MODE` | `cf`=内部自签 / `le`=Let's Encrypt | `cf` |
| `CF_IPS_ONLY` | 防火墙是否仅放行 CF 回源段 | `1` |
| `CLI_VERSION` | CLIProxyAPI 版本（决定下载哪个 release） | `8.0.33` |
| `API_PORT` | 服务端口 | `8317` |
| `PERSIST_DIR` | 配置与登录态目录 | `/opt/cliproxy` |

重复执行 `install` 不会重置已存在的 `config.yaml` 里的令牌与密钥；要彻底重来，先备份再删掉该文件重跑。

---

## 四、装好之后怎么用

装完脚本会打印类似这样的信息（按你的选择不同，地址前缀会变）：

```
 当前模式：域名 + Caddy 反代 (HTTPS / TLS=cf)
 OpenAI 兼容 API（客户端填写）：
   base_url: https://proxy.example.com/v1
   api_key:  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
 管理面板: https://proxy.example.com/management.html
   登录密钥(secret-key): xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   后台 Basic 认证: admin / xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**第一步：挂上你的账号**。打开管理面板，用 `secret-key` 登录，在里面完成 Gemini / Claude / Codex 等账号的 OAuth 授权。授权文件保存在 `/opt/cliproxy/auths/`，重启/更新都不会丢。

**第二步：确认接口通**

```bash
curl -s https://proxy.example.com/v1/models \
  -H "Authorization: Bearer 你的API_TOKEN"
```

返回的 `data[].id` 就是可用模型名。

**第三步：在客户端里填**
- `base_url`：填到 `/v1` 为止（脚本打印的就是这个），别漏 `/v1`
- `api_key`：就是 `API_TOKEN`
- `model`：用上一步拿到的模型名

> 启用 Caddy 反代后访问后台是**两层**：先弹 Basic 认证框（`admin` / `CADDY_PLAIN`），通过后才到 CLIProxyAPI 登录页（输 `MGMT_SECRET`）。只从本机 `http://127.0.0.1:8317/management.html` 访问时没有第 1 层。

---

## 五、常用命令

| 命令 | 作用 |
|---|---|
| `sudo bash cli-proxy-deploy.sh` | 打开管理菜单 |
| `sudo bash cli-proxy-deploy.sh install` | 安装 / 重建 / 改网络配置 |
| `sudo bash cli-proxy-deploy.sh status` | 状态、可用模型、全套凭据 |
| `sudo bash cli-proxy-deploy.sh logs` | 最近 100 行日志（`journalctl -u cliproxy-api`） |
| `sudo bash cli-proxy-deploy.sh restart` | 重启服务 |
| `sudo bash cli-proxy-deploy.sh stop` / `start` | 停止 / 启动 |
| `sudo bash cli-proxy-deploy.sh update` | 重新下载最新二进制并重启（凭据与配置复用） |
| `sudo bash cli-proxy-deploy.sh uninstall` | 移除服务（会问是否删配置目录） |
| `bash cli-proxy-deploy.sh help` | 完整帮助 |

底层就是 systemd 操作：`systemctl start/stop/restart/status cliproxy-api`、`journalctl -u cliproxy-api`，直接敲也行。

---

## 六、目录与文件

```
/opt/cliproxy/
├── config.yaml        # 主配置（令牌、密钥、端口）
├── .deploy.env        # 部署状态 + 明文凭据，权限 600
├── auths/             # OAuth 授权文件
└── logs/              # 运行日志（journald 不可用时的兜底）

/usr/local/bin/CLIProxyAPI       # CLIProxyAPI 二进制
/usr/local/bin/caddy             # Caddy 二进制（仅启用反代时安装）
/etc/caddy/Caddyfile             # Caddy 配置；本脚本写入部分被
                                 #   # >>> CLIProxyAPI START / END 包着，卸载时精确移除
/etc/systemd/system/cliproxy-api.service
/etc/systemd/system/caddy.service
```

---

## 七、常见问题

**装完访问不了？**
先 `status` 看健康检查是否 200，再看 `logs`（或 `journalctl -u cliproxy-api --tail 50`）。启用 Caddy 但域名解析还没生效时，Caddy 签证书会失败——等 DNS 生效后重跑 `install` 即可。

**Cloudflare 报 526 / 521？**
526 = CF 校验了自签证书，把 SSL/TLS 改成 `Full`（不是 strict）。521 = CF 连不上源站，检查防火墙是否放行了 80/443、Caddy 是否在跑。

**只开了橙云，但 8317 端口连不上？**
正常。CF 免费版只代理固定端口（80/443/8080/8443/2052…），`8317` 不在列表。要么走域名 + Caddy 反代，要么把云朵点灰走 DNS only 直连。

**只想自己用，不想暴露公网？**
① 留空域名、② 填 `0`，然后只放行你家宽 IP：
```bash
gcloud compute firewall-rules create allow-cliproxy-8317 \
  --allow=tcp:8317 --source-ranges=你的公网IP/32
```

**机器没有 systemd（如某些容器 / WSL1）？**
Caddy 会退化成 `caddy start` 后台进程，机器重启后不会自动拉起，需重跑一次 `install`。CLIProxyAPI 依赖 systemd 起服务，建议在生产环境使用带 systemd 的发行版（Debian / Ubuntu 等）。

**卸载会连 Caddy 一起删吗？**
不会。只清理本脚本写入的 Caddyfile 配置块，Caddy 本体（二进制 + systemd 服务）保留，因为它可能还跑着别的站点。要彻底卸载 Caddy：`rm -f /usr/local/bin/caddy /etc/systemd/system/caddy.service`。

**要换 VPS 怎么办？**
把 `/opt/cliproxy` 整个目录拷到新机器，在新机器执行 `install`，域名解析改到新 IP 即可，授权不用重新做。

---

## 八、依赖

- Linux + root
- `python3`（配置解析与 Caddyfile 写入）：缺失会自动安装（apt / dnf / yum / apk 依次尝试），装不上才报错退出。只读命令（`status`、`logs`）不依赖它
- Caddy（可选，仅启用反代时）：自动安装官方静态二进制，已有宿主机 Caddy 则直接复用
- `gcloud`（可选，仅在 GCP 上自动配防火墙；没有就打印手动放行命令）

---

## 说明

本脚本只负责部署与配置 CLIProxyAPI 本体，不包含任何账号授权信息，也不内置任何密钥——所有令牌均在安装时现场生成。授权请使用你自己的账号，并遵守对应服务商的条款。
