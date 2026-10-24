# ArgoX-Lite

**Sing-box 专用代理部署脚本** — 单一核心、单一节点模式，把原 ArgoX 的 6900+ 行精简为约 1200 行。

- 代理核心：**sing-box**（唯一，v1.10+，验证版本 v1.14.4）
- 节点模式：**VMess + WebSocket + TLS + CDN**（唯一）
- TLS 终止位置：**nginx**（sing-box 侧仅监听 `127.0.0.1` 的明文 WS）
- 可选：**Cloudflare Argo Tunnel**（cloudflared 接入）
- 兼容客户端：Shadowrocket、SFA (sing-box)、v2rayN、v2rayNG、Clash.Meta 等任何支持 VMess + WS 的客户端

## 一键安装

### Linux（推荐）

```bash
bash <(wget -O- https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh)
```

或使用 curl：

```bash
bash <(curl -sL https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh)
```

### 带参数

```bash
# 中文安装（默认）
bash <(curl -sL https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh)

# 英文安装
bash <(curl -sL https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh) -l E

# 启用 Argo 隧道（需提前配置 ARGO_AUTH）
bash <(curl -sL https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh) -a -f config.conf

# 非交互安装
bash <(curl -sL https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh) -f config.conf
```

### 手动安装

```bash
# 下载脚本
wget -O argox.sh https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh

# 赋予执行权限
chmod +x argox.sh

# 运行
bash argox.sh
```

## 安装说明

### 系统要求

| 项目 | 要求 |
|---|---|
| 操作系统 | Debian/Ubuntu/Kali/Mint, CentOS/RHEL/Rocky/AlmaLinux, Fedora, Arch/Manjaro, Alpine, OpenSUSE |
| 架构 | x86_64 / ARM64 / ARMv7 / ARMv6 / 32-bit x86 |
| 服务管理器 | **systemd**（Alpine 默认 OpenRC，需手动适配） |
| 用户 | **root**（`sudo bash argox.sh` 或 `su -` 后运行） |
| 网络 | 需能访问 GitHub（下载 sing-box 二进制） |

### 前置条件

脚本会自动安装以下依赖，无需手动准备：

- `curl` 或 `wget`（下载 sing-box）
- `jq`（JSON 处理）
- `unzip` / `tar`（解压）
- `openssl`（生成 TLS 证书）
- `nginx`（TLS 终止 + WebSocket 反代）
- `ca-certificates`（CA 证书）

### 完整安装流程

1. **获取脚本**
   ```bash
   bash <(curl -sL https://raw.githubusercontent.com/enticingns/ArgoX/sing-box-lite/argox.sh)
   ```

2. **选择语言**
   - `C` = 中文（默认）
   - `E` = 英文

3. **输入节点参数**（均可留空使用默认值）

   | 参数 | 默认值 | 说明 |
  |---|---|---|
   | UUID | 自动生成 | 36 位 UUID v4 |
   | WS Path | `argox-ws-vm` | WebSocket 路径，仅允许字母/数字/`-_./@` |
   | CDN Domain | `skk.moe` | 公共 CDN 域名，或你自己的域名 |
   | TLS SNI | `addons.mozilla.org` | TLS Server Name |
   | sing-box Port | 自动分配 | 内部监听端口，从 30000 开始找空闲 |
   | nginx Port | `8080` | 对外端口，CDN 将 443 流量转发到此 |
   | Node Name | 主机名 | 节点显示名称 |

4. **安装完成后**

   脚本会自动：
   - 下载 sing-box 到 `/etc/argox/sing-box`
   - 生成 TLS 证书到 `/etc/argox/cert.pem`
   - 写入 sing-box 配置到 `/etc/argox/config.json`
   - 写入 nginx 配置到 `/etc/argox/nginx.conf`
   - 生成订阅文件到 `/etc/argox/subscribe/`
   - 安装 systemd 服务并启动
   - 打印节点信息与订阅链接

5. **配置客户端**

   使用打印的订阅链接或直接复制 VMess 分享链接到客户端。

### 卸载

```bash
bash argox.sh -u
# 或进入菜单选择 [6] 卸载
```

## 常用命令速查

| 命令 | 说明 |
|---|---|
| `bash argox.sh` | 交互式菜单 |
| `bash argox.sh -i` | 安装（交互） |
| `bash argox.sh -f config.conf` | 非交互安装 |
| `bash argox.sh -a -f config.conf` | 启用 Argo 并安装 |
| `bash argox.sh -l E` | 英文模式 |
| `bash argox.sh -n` | 查看节点信息与订阅 |
| `bash argox.sh -v` | 升级 sing-box |
| `bash argox.sh -u` | 卸载 |
| `bash argox.sh -h` | 帮助 |

## 菜单操作

安装后运行 `bash argox.sh` 进入菜单：

| 选项 | 功能 |
|---|---|
| 1 | 查看节点信息（UUID/WS 路径/分享链接/订阅 URL） |
| 2 | 重启服务（sing-box + nginx + cloudflared） |
| 3 | 更新 sing-box 到最新 |
| 4 | 重新配置参数（UUID/WS/CDN/端口等） |
| 5 | 查看日志（sing-box + nginx + cloudflared） |
| 7 | Argo 隧道（启用/禁用） |
| 6 | 卸载 |
| 0 | 退出 |

## 文件位置

| 路径 | 说明 |
|---|---|
| `/etc/argox/sing-box` | sing-box 二进制 |
| `/etc/argox/config.json` | sing-box 配置 |
| `/etc/argox/nginx.conf` | nginx 配置 |
| `/etc/argox/cert.pem` / `key.pem` | TLS 证书 |
| `/etc/argox/subscribe/base64` | SFA 订阅文件 |
| `/etc/argox/subscribe/shadowrocket` | Shadowrocket 订阅文件 |
| `/etc/argox/custom` | 用户参数（持久化） |
| `/etc/argox/sing-box.log` | sing-box 日志 |
| `/etc/argox/nginx-error.log` | nginx 错误日志 |
| `/etc/systemd/system/sing-box.service` | sing-box 服务 |
| `/etc/systemd/system/argox-nginx.service` | nginx 服务 |
| `/etc/systemd/system/cloudflared.service` | cloudflared 服务（Argo 模式） |

## 主要变更（相对 v2.1.9）

**删除**

- Xray / v2ray 核心：下载、启动、热更新、API 端口、协议切换等全部逻辑。
- 除 VMess + WS + TLS + CDN 之外的协议分支：VLESS Reality/Vision/gRPC/WS、Trojan、Shadowsocks、Hysteria2、XHTTP、Reality 端口跳跃等。
- ArgoX 原有的**多协议 Argo 分支**（vless-argo / trojan-argo / ss-argo / hysteria2-argo 等，各自独立的 Argo 路由逻辑）。
- 临时隧道（trycloudflare.com）的自动域名查询、metrics 端点解析等历史代码。
- Reality 密钥生成、Hysteria2 端口跳跃、`PORT_HOPPING_*`、`REALITY_*` 相关代码。
- WARP、BBR、自定义路由、订阅模板下载、协议选择菜单、语言选择菜单等。
- 大量迁移兼容代码（tag 名兼容、v2rayN 拆分、api/stats/policy 补全等历史补丁）。
- 依赖项 `jq`、`zip`、`unzip`（`jq` 保留用于可选用途）。

**保留 / 简化**

- systemd 服务管理（sing-box + nginx 两个 unit）。
- 自签 TLS 证书生成（`openssl`）。
- 订阅文件生成（Base64 与 Shadowrocket 两种）。
- 节点信息展示与分享链接生成。
- 依赖安装（`curl / wget / jq / unzip / tar / openssl / nginx / ca-certificates`）。
- 端口与 UUID 校验、`find_free_port`、端口跳跃防火墙规则。
- 非交互安装（`bash argox.sh -f config.conf`）。
- 更新 sing-box 二进制并回滚保护。
- **Cloudflare Argo Tunnel**：保留 cloudflared 集成（JSON / Token 两种认证），tunnel.yml 与 tunnel.json 由脚本生成，cloudflared 作为独立 systemd 服务运行。

**新增**

- 生成配置后**先用 `sing-box check -c config.json` 校验**，失败即回滚；nginx 配置也先 `-t` 校验。
- 下载 sing-box 时先备份旧版本，新版本启动失败自动回滚。
- VMess 分享链接包含 `add / port / id / aid / scy / net / type / host / path / tls / sni / alpn` 完整字段。
- 交互/CLI 参数：`-i/-u/-v/-n/-f/-l/-h`。
- 语言参数 `-l C|E`。
- **`-a / --argo`**：一次性启用 Argo 隧道模式（需配合 config.conf 中的 `ARGO_AUTH` / `ARGO_DOMAIN`）。

## 兼容性限制

| 项 | 说明 |
|---|---|
| sing-box 最低版本 | **v1.10.0**（VMess inbound 从该版本起稳定）。脚本默认下载 v1.14.4；如 GitHub 上拉到的最新稳定版低于 1.10，会自动回退到默认版本并打印警告。 |
| 操作系统 | Debian/Ubuntu/Amaryan/Kali/Mint、CentOS/RHEL/Rocky/AlmaLinux/OL/AmazonLinux、Fedora、Arch/Manjaro/EndeavourOS/Garuda、Alpine、OpenSUSE。 |
| 架构 | amd64 / 386 / armv5 / armv6 / armv7 / arm64 / mipsle / mips64le / riscv64 / loong64。 |
| 服务管理器 | **仅 systemd**。Alpine 默认使用 OpenRC，请自行转换（`rc-service` 版本可用系统 unit 文件直接改）。 |
| WebSocket 传输 | 使用 V2Ray Transport 中的 `type: ws`（**不是** HTTP 传输）。TLS 由 nginx 终止，sing-box 侧不启用 `tls`。 |
| 协议 | 仅 VMess。不再生成 VLESS / Trojan / SS / Hysteria2 / XHTTP 节点。 |
| CDN | 用户自备 CDN 域名（Cloudflare 代理、任意 443 反代、或其他支持 WebSocket 的 CDN）。脚本不管理 Cloudflare 账号。 |
| Argo 隧道 | **完全移除**。原 ArgoX 依赖的 cloudflared 及 Argo Tunnel 概念在此版本不再存在。 |
| 客户端 | 生成的是标准 `vmess://` 分享链接和 Base64 订阅；所有主流 v2ray / sing-box 客户端均可解析。 |

## 部署方法

### 1. 获取脚本

```bash
# 从原始项目克隆（已备份原文件为 .xray-original.bak）
git clone https://github.com/fscarmen/argox.git
cd argox
```

或者直接下载新的 `argox.sh`：

```bash
wget -O argox.sh https://raw.githubusercontent.com/<your-mirror>/main/argox.sh
```

### 2. 安装依赖

脚本会在安装时自动安装：

```
curl wget jq unzip tar openssl ca-certificates nginx
```

如已安装请跳过。

### 3. 运行安装

**交互式安装**：

```bash
bash argox.sh
```

按提示输入：

1. **UUID** — 留空自动生成
2. **WebSocket 路径** — 默认 `argox-ws-vm`，只能包含字母/数字/`-_./@`
3. **CDN 域名** — 例如 `skk.moe`、`ip.sb`、`time.is`，或你自己的域名
4. **TLS SNI** — 默认 `addons.mozilla.org`
5. **sing-box 内部端口** — 默认自动选择空闲端口（起点 30000）
6. **nginx 对外端口** — 默认 `8080`（CDN 会将 443 流量转发到这里）
7. **节点名称** — 默认主机名

**非交互安装**：

编辑 `config.conf`，然后：

```bash
bash argox.sh -f config.conf
```

**指定语言**：

```bash
bash argox.sh -l E    # English
bash argox.sh -l C    # Chinese (default)
```

### 4. 常见命令

| 命令 | 说明 |
|---|---|
| `bash argox.sh` | 交互式菜单 |
| `bash argox.sh -n` | 只显示节点信息与订阅链接 |
| `bash argox.sh -v` | 升级 sing-box 到最新 |
| `bash argox.sh -u` | 卸载 |
| `bash argox.sh -a` | 启用 Argo 隧道模式 |
| `bash argox.sh -h` | 帮助 |

菜单内：

- `1` 查看节点信息
- `2` 重启服务
- `3` 更新 sing-box
- `4` 重新配置
- `5` 查看日志
- `7` Argo 隧道（启用/禁用）
- `6` 卸载
- `0` 退出

### 5. 防火墙

脚本自动对 `ufw` 和 `firewalld` 打开：

- `NGINX_PORT/tcp`
- `443/tcp`

如使用 `iptables` 或 `nftables`，请自行添加对应规则。

### 6. CDN 侧配置

**Cloudflare 用户**：

- 在你的域名下新建一条 A 记录，指向 VPS 公网 IP。
- 开启橙色云（Proxied）。
- CDN 会自动把 443 流量转到 `NGINX_PORT`。
- 如果你的 Cloudflare 只支持 443 端口转发，请保持 `NGINX_PORT=8080` 或改成你能接受的任何值；脚本会同步 nginx 配置。

**自建 CDN / 其他 CDN**：

需要 443 端口能正常反代到 VPS 的 `NGINX_PORT`，并支持 WebSocket（大多数反代网关默认支持）。

### 7. Cloudflare Argo Tunnel（可选）

如果你不想配置 DNS / CDN，或希望通过 Cloudflare Tunnel 接入，可启用 Argo 模式。

**启用方式**

```bash
# 方式 1：CLI 一次性启用（需 config.conf 里已有 ARGO_AUTH）
bash argox.sh -a -f config.conf

# 方式 2：菜单交互（安装后）
bash argox.sh
# 选择 7 → Argo 隧道
```

**配置 ARGO_AUTH**（三种格式任选一）：

1. **JSON（推荐）**：从 Cloudflare Zero Trust 控制台或第三方工具导出完整 JSON（含 `TunnelSecret` / `TunnelID` / `AccountTag`）。

   ```bash
   ARGO_AUTH='{"AccountTag":"xxxxxxxxxxxxxxxxxxxxxxxxxxxx","TunnelSecret":"eyJhIjoiOWNj...","TunnelID":"01234567-89ab-cdef-0123-456789abcdef"}'
   ```

2. **Token**：Base64 风格的 Tunnel Token（120-250 字符），如 `eyJhIjoiOWNj...`。

3. **API Token**（40 字符）：需要 Cloudflare Custom API Token，权限包括：
   - Account > Cloudflare One Connectors: cloudflared > Edit
   - Zone > DNS > Edit
   - Zone Resources: Include > Specific zone > Argo Root Domain

   注意：ArgoX-Lite 不支持用 API Token **自动创建**隧道；你需要先在 Cloudflare 控制台手动创建隧道，再用 JSON 或 Token 模式接入。

**配置 ARGO_DOMAIN**：

Argo 隧道的接入域名，如 `my-node.example.com`。启用 Argo 后，客户端连接 `ARGO_DOMAIN:443`，流量经 cloudflared 转发到本机 nginx。

**运行流程**：

```
Client → ARGO_DOMAIN (Cloudflare 边缘) → cloudflared (VPS) → nginx (127.0.0.1:NGINX_PORT) → sing-box (127.0.0.1:SINGBOX_PORT)
```

- nginx 负责 TLS 终止与 WebSocket 反代（与普通 CDN 模式完全一致）。
- cloudflared 负责建立到 Cloudflare 的加密隧道。
- 启用 Argo 后，`CDN_DOMAIN` 不再使用；节点分享链接使用 `ARGO_DOMAIN`。

**服务管理**：

- `systemctl status cloudflared` 查看状态。
- `journalctl -u cloudflared -n 50` 查看日志。
- 菜单选项 7 可切换启用/禁用 Argo。

## 配置文件

- `/etc/argox/sing-box/config.json` — sing-box 主配置
- `/etc/argox/nginx.conf` — nginx TLS + WS 反代配置
- `/etc/argox/cert.pem` / `/etc/argox/key.pem` — 自签 TLS 证书
- `/etc/argox/subscribe/base64` — SFA 订阅文件
- `/etc/argox/subscribe/shadowrocket` — Shadowrocket 订阅文件
- `/etc/argox/custom` — 用户参数（UUID / WS_PATH / CDN_DOMAIN / 端口等）
- `/etc/argox/sing-box.log` — sing-box 运行日志
- `/etc/argox/nginx-error.log` — nginx 错误日志
- `/etc/systemd/system/sing-box.service` — sing-box 服务
- `/etc/systemd/system/argox-nginx.service` — nginx 服务

## 故障排查

- **sing-box 启动失败**：`journalctl -u sing-box -n 50`
- **nginx 启动失败**：`journalctl -u argox-nginx -n 50`
- **节点无法连接**：先确认 CDN 域名 443 能到 `nginx`；再检查订阅文件内容是否包含正确的 UUID 与路径。
- **重新配置后**：脚本会自动 `restart` 两个服务；如需手动：`systemctl restart sing-box argox-nginx`。
- **回滚 sing-box**：升级失败会自动把旧版本从 `/etc/argox/sing-box.<timestamp>.bak` 恢复。

## 目录

```
argox.sh                       # 主脚本 (约 980 行)
config.conf                    # 非交互安装配置模板
argox.sh.xray-original.bak     # 原 ArgoX v2.1.9 备份
config.conf.xray-original.bak  # 原 config.conf 备份
README.md                      # 本文件（已更新）
README.md.xray-original.bak    # 原 README 备份
LICENSE                        # MIT License
```

## 许可

MIT License（见 `LICENSE`）。
