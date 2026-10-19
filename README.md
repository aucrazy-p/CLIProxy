# CLIProxyAPI 一键部署脚本

在 Linux 服务器（Debian / Ubuntu 优先，其它发行版可用）上把 CLIProxyAPI 部署起来，用 Docker 跑，可选配 Caddy 反向代理 + HTTPS。

它做的事情：把你已有的 AI 订阅账号授权给 CLIProxyAPI，由它对外暴露一个**标准 OpenAI 兼容接口**（默认 `8317` 端口），任何支持自定义 `base_url` 的客户端都能直接调用。

**一条命令装完，中间只需要回答几个问题，不需要手工改配置文件。**

- 缺 Docker 自动装
- Caddy 先探测再决定：**已有的（含 Docker 容器）直接复用**，没有才装
- 缺 Caddy 自动装（apt 优先，失败降级官方静态二进制），自动写 systemd 服务并开机自启
- 装之前先检查 80/443 是否被占用，被占则明确报错并回退，不会装出一个起不来的服务
- Caddyfile 用标记块插入，**不会覆盖你已有的其它站点**
- 写入前备份、写入后 `caddy validate` 校验，校验不过自动回滚并退回 IP 直连
- 端口、令牌、密钥全部自动生成并落盘
- 自动放行 GCP 防火墙（Cloudflare 场景默认只允许 CF 回源段）
- 装完打印全套凭据，随时可用 `status` 再查一次

---

## 一键安装

```bash
curl -fsSL -o /tmp/cpa.sh https://raw.githubusercontent.com/aucrazy-p/CLIProxy/main/cli-proxy-deploy.sh \
  && sudo bash /tmp/cpa.sh install
```

> 不要写成 `curl ... | sudo bash`。管道会吞掉 tty，脚本的交互提问会被静默跳过、全部走默认值。

下载下来跑菜单模式也可以（推荐首次使用）：

```bash
sudo bash /tmp/cpa.sh
```

---

## 安装时会问什么

只有 4 个网络选项 + 3 个凭据选项，**全部可以直接回车用默认值**。

| 序号 | 问题 | 默认 | 说明 |
|---|---|---|---|
| ① | Cloudflare 域名 | 空 | 留空 = 直接用 `IP:8317`；填 `proxy.example.com` = 走域名 |
| ② | 启用 Caddy 反代 | `1` | 想纯 IP 直连就填 `0` |
| ③ | 证书方式 | `cf` | `cf` = 内部自签（适配 Cloudflare 橙云）；`le` = Caddy 自动申请 Let's Encrypt |
| ④ | 防火墙只放行 Cloudflare | `1` | 填 `0` 则对全网开放 |
| ⑤ | API 令牌 | 随机 | 客户端填的 `api_key` |
| ⑥ | 管理面板登录密钥 | 随机 | 后台登录用 |
| ⑦ | Basic 认证密码 | 随机 | 仅 Caddy 反代时出现，账号固定 `admin` |

`③` 选 `cf` 的原因：Cloudflare 橙云（代理开启）后面做 HTTP-01 挑战经常失败，自签证书没有 ACME 挑战，CF 的 `Full` 模式也不校验它，浏览器看到的仍是 CF 的证书，用户端无感知。**此时 CF 的 SSL/TLS 模式必须是 `Full`，不能选 `Full (strict)`**，strict 会校验自签证书直接报 526。

---

## 已有 Caddy 会不会重复装

不会。脚本按这个顺序探测，**能复用就不装新的**：

| 顺序 | 探测目标 | 命中后 |
|---|---|---|
| 1 | Docker 里正在跑的 Caddy 容器 | 复用：改它挂载的 Caddyfile，`docker exec` 校验并 reload |
| 2 | 宿主机 `caddy` 二进制 | 复用：改 `/etc/caddy/Caddyfile`，走 systemd reload |
| 3 | 都没有 | 安装（装前先检查 80/443 是否被占用） |

### Docker 版复用需要注意的两件事

**① 容器必须挂载了 Caddyfile。** 脚本靠 `docker inspect` 找挂载点，识别这两种写法：

```bash
-v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile   # 推荐
-v /opt/caddy:/etc/caddy                       # 也认，取其中的 Caddyfile
```

如果配置是打进镜像的（没挂载），脚本**不会**去动它——改了重启就丢，不如不碰。这种情况会提示你，然后回退到 IP 直连。

**② 反代地址会自动换。** 容器里的 `127.0.0.1` 是容器自己，不是宿主机。所以脚本会：

- 反代目标从 `127.0.0.1:8317` 自动换成 **docker0 网关**（通常是 `172.17.0.1:8317`）
- 8317 也随之绑到这个网关地址而不是 `0.0.0.0`，公网依旧访问不到，只有本机容器能连

如果 Caddy 容器用的是 `--network host`，则仍用 `127.0.0.1`，不做替换。

> 复用的容器得自己已经发布了 80/443（`-p 80:80 -p 443:443`），否则 Cloudflare 过来的流量进不来——这属于你原容器的配置，脚本不去改。

### 80/443 已被占用

脚本会直接报错并列出占用者：

```
✗ 端口 80 已被占用，此时装 Caddy 会起不来
LISTEN 0  511  0.0.0.0:80  0.0.0.0:*
```

此时要么释放端口，要么让占用方自己反代到 `127.0.0.1:8317`，脚本这边选①留空域名、②填 `0` 走 IP 直连即可。

---

## 凭据是怎么处理的

三个凭据默认都是**安装时自动生成的 32 位随机串**（`openssl rand -hex 16`），也可以自己指定。它们互相独立，改一个不影响另一个。

| 凭据 | 用途 | 存放位置 | 生成后还能看到明文吗 |
|---|---|---|---|
| `API_TOKEN` | 客户端调 `/v1/*` 时的 `Authorization: Bearer` | `config.yaml` 的 `access.api-keys` | 能，明文一直在 |
| `MGMT_SECRET` | 管理面板 `management.html` 的登录密钥 | `config.yaml` 的 `management.secret-key`（启动后被 hash）；明文另存 `.deploy.env` | Caddyfile/config 里都看不到明文，去 `.deploy.env` 或 `status` 输出里找 |
| `CADDY_PLAIN` | 浏览器访问后台时的 Basic 认证密码 | 明文只在 `.deploy.env`；Caddyfile 里是哈希 | 能，从 `.deploy.env` 读 |

明文凭据统一落在 `/opt/cliproxy/.deploy.env`（权限 `600`，仅 root 可读），安装结束和每次 `status` 都会打印。

**`MGMT_SECRET` 就是管理面板的登录密码。** 打开 `management.html`，输入框里要填的就是它。

如果启用了 Caddy 反代，访问后台其实是**两层**：

1. 浏览器先弹 Basic 认证框 → 账号 `admin`、密码 `CADDY_PLAIN`（Caddy 挡在门口）
2. 通过后才看到 CLIProxyAPI 自己的登录页 → 输入 `MGMT_SECRET`

两个密码互相独立，换一个不影响另一个。只从本机 `http://127.0.0.1:8317/management.html` 访问时没有第 1 层，直接输 `MGMT_SECRET`。

### 三种指定方式

**1. 安装时手输（推荐）**

跑到 ⑤⑥⑦ 直接输入自己的值。只允许字母数字和 `. _ ~ : @ % + = / -`，长度 8–128；含空格、引号、`$` 之类的会拒绝并自动回退随机值（这些字符会把 YAML / Caddyfile 写坏）。

**2. 非交互用环境变量**

```bash
sudo API_TOKEN=mykey123456 \
     MGMT_SECRET=mysecret123456 \
     CADDY_PLAIN=mybasic123456 \
     CF_DOMAIN=proxy.example.com \
     USE_CADDY=1 CERT_MODE=cf CF_IPS_ONLY=1 \
     bash cli-proxy-deploy.sh install
```

**3. 装完之后再改**

- 改 `API_TOKEN`：编辑 `/opt/cliproxy/config.yaml` 的 `access.api-keys`，然后 `sudo bash cli-proxy-deploy.sh restart`
- 改 `MGMT_SECRET`：编辑 `management.secret-key`（写明文），重启后会自动 hash。**务必先备份**，hash 之后无法还原
- 改 Caddy Basic 密码：重跑 `install`，到第 ⑦ 项输入新密码即可（不输入则保持原密码）

> 重复执行 `install` 不会重置已存在的 `config.yaml` 里的令牌与密钥；要彻底重来，先备份再删掉这个文件。

---

## 装好之后怎么用

装完脚本会打印类似这样的信息：

```
 当前模式：域名 + Caddy 反代 (HTTPS / TLS=cf)
 OpenAI 兼容 API（客户端填写）：
   base_url: https://proxy.example.com/v1
   api_key:  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
 管理面板: https://proxy.example.com/management.html
   登录密钥(secret-key): xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   后台 Basic 认证: admin / xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**第一步：挂上你的账号**。打开管理面板，用 `secret-key` 登录，在里面完成 Gemini / Claude / Codex 等账号的 OAuth 授权。授权文件保存在 `/opt/cliproxy/auths/`，升级和重启容器都不会丢。

**第二步：确认接口通**

```bash
curl -s https://proxy.example.com/v1/models \
  -H "Authorization: Bearer 你的API_TOKEN"
```

返回的 `data[].id` 就是可用的模型名。

**第三步：在客户端里填**

- `base_url`：填到 `/v1` 为止（脚本打印的就是这个），不要少了 `/v1`
- `api_key`：就是 `API_TOKEN`
- `model`：用上一步拿到的模型名

---

## 常用命令

脚本和容器都可以用子命令管理（`sudo` 需要）：

| 命令 | 作用 |
|---|---|
| `sudo bash cli-proxy-deploy.sh` | 打开管理菜单 |
| `sudo bash cli-proxy-deploy.sh install` | 安装 / 重建 / 改网络配置 |
| `sudo bash cli-proxy-deploy.sh status` | 状态、可用模型、全套凭据 |
| `sudo bash cli-proxy-deploy.sh logs` | 最近 100 行日志 |
| `sudo bash cli-proxy-deploy.sh restart` | 重启容器 |
| `sudo bash cli-proxy-deploy.sh stop` / `start` | 停止 / 启动 |
| `sudo bash cli-proxy-deploy.sh update` | 拉最新镜像并重启（凭据与配置复用） |
| `sudo bash cli-proxy-deploy.sh uninstall` | 移除容器（会问是否删配置目录） |
| `bash cli-proxy-deploy.sh help` | 完整帮助 |

底层等价于 `docker logs cli-proxy-api` / `docker restart cli-proxy-api`，直接敲 docker 命令也行。

---

## 目录结构

```
/opt/cliproxy/
├── config.yaml        # 主配置（令牌、密钥、端口）
├── .deploy.env        # 部署状态 + 明文凭据，600
├── auths/             # OAuth 授权文件（挂载为容器内 /root/.cli-proxy-api）
└── logs/              # 运行日志
```

Caddy 配置在 `/etc/caddy/Caddyfile`，本脚本写入的部分被 `# >>> CLIProxyAPI START` 和 `# >>> CLIProxyAPI END` 包着，卸载时会精确移除这一段。

---

## 常见问题

**装完访问不了？**
先 `status` 看健康检查是否 200。再看 `logs`。如果启用了 Caddy 但域名解析还没生效，Caddy 签证书会失败——等 DNS 生效后重跑 `install` 即可。

**Cloudflare 报 526 / 521？**
526 = CF 校验了自签证书，把 SSL/TLS 改成 `Full`（不是 strict）。521 = CF 连不上源站，检查防火墙是否放行了 80/443、Caddy 是否在跑。

**只开了橙云，但 8317 端口连不上？**
正常。CF 免费版只代理固定端口（80/443/8080/8443/2052…），`8317` 不在列表里。要么走域名 + Caddy 反代，要么把云朵点灰走 DNS only 直连。

**只想自己用，不想暴露公网？**
① 留空域名、② 填 `0`，然后只放行你家宽 IP：

```bash
gcloud compute firewall-rules create allow-cliproxy-8317 \
  --allow=tcp:8317 --source-ranges=你的公网IP/32
```

**Caddy 装在非 systemd 环境的容器里？**
脚本会退化成 `caddy start` 后台进程，机器重启后不会自动拉起来，需要重跑一次 `install`。

**VPS 上已经有 Docker 版 Caddy，会不会被重复装一个？**
不会。脚本先找容器，找到且挂了 Caddyfile 就直接复用，不会装第二个——两个 Caddy 抢 80/443 会直接起不来。容器没挂 Caddyfile 时它会提示并回退 IP 直连，不会悄悄改镜像内的配置。详见上文「已有 Caddy 会不会重复装」。

**卸载会不会连 Caddy 一起删？**
不会。Caddy 可能还跑着别的站点，只清理本脚本写入的配置块。确实要卸载 Caddy：`apt remove caddy`。

**要换 VPS 怎么办？**
把 `/opt/cliproxy` 整个目录拷到新机器，在新机器执行 `install`，域名解析改到新 IP 即可，授权不用重新做。

---

## 依赖

- Linux + root
- `python3`（配置解析与 Caddyfile 写入，脚本会检查并提示安装命令）
- Docker（缺失自动安装）
- Caddy（可选，仅启用反代时需要）：已有的直接复用（宿主机二进制或 Docker 容器都算），没有才自动安装
- `gcloud`（可选，仅在 GCP 上自动配防火墙；没有就打印手动放行命令）

---

## 说明

本脚本只负责部署与配置 CLIProxyAPI 本体，不包含任何账号授权信息，也不内置任何密钥——所有令牌均在安装时现场生成。授权请使用你自己的账号，并遵守对应服务商的条款。
