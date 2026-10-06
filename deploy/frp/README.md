# frp 部署说明（用腾讯云轻量服务器当"门面"）

## 这套方案在干什么

```
别人的浏览器
   │  http://VPS公网IP:8080/
   ▼
腾讯云轻量 VPS  ── 只跑 frps，只做流量转发（1核1G 都够）
   │  隧道（VPS:7000，由本地主动连出去）
   ▼
本地虚拟机  ── frpc 客户端
   │  127.0.0.1:80
   ▼
nginx 容器 ──> langgraph-api ──> redis / postgres / mysql
```

**核心好处**：业务（5 个容器吃 3G+ 内存）还在你本地虚拟机跑，
VPS 只是个"门面"，不承担业务压力，也不会再被 OOM 杀掉。

---

## 第 0 步：重置后的服务器初始化（重装系统 / 重置密码之后必做）

重置完**先别急着跑脚本**，按顺序把下面五小步过一遍，少任何一步后面都会卡住。

### 0.1 先弄清"重置"到底重置了什么

| 你做的操作 | 后果 | 要注意什么 |
|---|---|---|
| **重置密码** | 只改登录密码 | 之前装的 frps / 防火墙规则**都还在**，可直接跳到第 1 步 |
| **重装系统** | 系统盘清空、**公网 IP 一般不变** | 等于一张白纸，之前的 frps 全没了，老老实实从 0.2 开始 |
| **更换公网 IP** | IP 变了 | 以后 frpc 里的 `serverAddr` 要跟着改成新 IP |

### 0.2 拿到三样东西

| 项目 | 在哪看 |
|---|---|
| 公网 IP | 轻量控制台 → 服务器列表 / 实例详情页顶部 |
| 登录用户名 | **Ubuntu 镜像默认是 `ubuntu`（不是 root）**；Debian / CentOS 系是 `root` |
| 密码 | 刚重置的那个。忘了就在控制台「重置密码」再设一次，**改完必须「重启」实例才生效** |

### 0.3 登录，并确认是干净系统

```bash
ssh ubuntu@<公网IP>          # Debian / CentOS 系换成 root@<公网IP>
```

进来后确认没有旧残留（两条都应该**没有输出**）：

```bash
systemctl status frps 2>/dev/null
sudo docker ps 2>/dev/null
```

> 若是 Ubuntu 却报 `Permission denied (publickey)`，说明该镜像只允许密钥登录 →
> 在控制台「密钥」里绑定密钥对，或重装时选「密码登录」方式。

### 0.4 放通端口（**最容易漏，漏了必然连不上**）

腾讯云**轻量应用服务器**用的是「**防火墙**」（在实例详情页里），**不是**「安全组」：

控制台 → 轻量服务器 → 你的实例 → **防火墙** → 添加规则：

| 协议 | 端口 | 用途 | 来源 |
|---|---|---|---|
| TCP | **7000** | frp 控制端口（frpc 主动连进来） | 0.0.0.0/0 |
| TCP | **8080** | 对外访问端口（浏览器访问） | 0.0.0.0/0 |

> 22 端口一般默认已放通，不用管。
> 如果你用的是 **CVM（云服务器）**而不是轻量，那就在「**安全组**」里配同样两条**入站**规则。

改完，在你 **Windows 的 PowerShell** 里验一下端口到底通没通（能提前排除 80% 的坑）：

```powershell
Test-NetConnection <公网IP> -Port 7000
```

看最后一行 `TcpTestSucceeded`：

- `True` → 端口已放通（此时 frps 还没装，能连上说明防火墙是通的）
- `False` → **防火墙没放通**，回控制台补规则

> 用命令行也行：`curl -v telnet://<公网IP>:7000`（Git Bash 自带的 curl 就支持）。
> 注意 Windows 的 Git Bash **没有 `nc`**，别照抄网上的 `nc -vz`。

### 0.5 装两个基础工具 + 确认架构

```bash
sudo apt update && sudo apt install -y curl openssl     # CentOS/OpenCloudOS 系: sudo yum install -y curl openssl
uname -m                                                 # x86_64 → amd64 包；aarch64 → arm64 包
```

`curl` 用来下 frp，`openssl` 用来生成 token，`uname -m` 只是让你心里有数（脚本会自动判断架构）。

> **脚本固定用 frp v0.61.0**（已验证可用）。官方现在已发到 v0.69.x，想换新版就把脚本里的
> `FRP_VERSION` 改掉即可 —— 但**配置必须保持 TOML 格式**，0.62+ 依然只认 toml，不认老的 `frps.ini`。

五小步做完，服务器就算准备妥了，继续往下走。

---

## 第 1 步：先在 VPS 上装 frps

**先把脚本传上去**，二选一：

```bash
# 方式一：在你 Windows 的 Git Bash 里直接推（推荐，一行搞定）
cd /f/project/my_langgraph_app
scp deploy/frp/setup-frps.sh ubuntu@<公网IP>:~/

# 方式二：VS Code 用 Remote-SSH 连上 VPS，手工新建 ~/setup-frps.sh 再把内容粘进去
```

传上去之后，**在 VPS 上**执行：

```bash
cd ~
# 1) 生成 token 并抄下来（两端必须完全一致）
openssl rand -hex 16
# 2) 假设输出是 a1b2c3d4e5f67890abcdef1234567890，把它作为参数传进去
sudo bash setup-frps.sh a1b2c3d4e5f67890abcdef1234567890
```

> ⚠️ **这串 token 一定要抄下来** —— 第 2 步在虚拟机上要用一模一样的一串；弄丢了就只能重跑脚本换新的。

跑完顺手确认 frps 真的起来了：

```bash
ss -lntp | grep 7000             # 应看到 frps 监听 0.0.0.0:7000
sudo systemctl is-active frps    # 应输出 active
```

> 只做了「**重置密码**」、没重装系统的机器，VPS 上可能还留着旧 frps 或之前那套崩掉的 docker 部署。
> 脚本本身是幂等的（会覆盖安装并重启服务），但旧容器白占内存，建议顺手清一下；
> **重装过系统的机器直接跳过这段**：
>
> ```bash
> sudo docker ps                                                   # 先看在跑什么
> cd ~/my_langgraph_app/deploy 2>/dev/null && sudo docker compose down
> ```

脚本会：下载 frp（自动切镜像）→ 装 `frps` → 写 `/etc/frp/frps.toml` → 注册 systemd 并启动。

---

## 第 2 步：在本地虚拟机上装 frpc

确保容器都正常：

```bash
cd ~/project/huose_agent/my_langgraph_app
sudo docker compose ps                    # 5 个都 Up
curl http://localhost/ | head -3          # 能吐出 html
```

然后把 `setup-frpc.sh` 传到虚拟机，在**虚拟机上**执行：

```bash
# 从 Windows Git Bash 推到虚拟机（虚拟机 IP 用 ip a 里的那个）
cd /f/project/my_langgraph_app
scp deploy/frp/setup-frpc.sh <虚拟机用户名>@<虚拟机IP>:~/

# 回到虚拟机终端
cd ~
sudo bash setup-frpc.sh <VPS公网IP> a1b2c3d4e5f67890abcdef1234567890 8080
```

> 三个参数：VPS 的 IP、**和第 1 步完全一致的 token**、对外端口（默认 8080）。

脚本会先自测 `localhost:80`，再下载安装 frpc、写配置、注册 systemd 并启动，
最后打印出对外地址。

---

## 第 3 步：验证

**在虚拟机上**看隧道状态：

```bash
tail -f /var/log/frpc.log
```

看到 `start proxy success` 就说明隧道打通了。

**在 Windows 浏览器**打开脚本最后打印的地址：

```
http://<VPS公网IP>:8080/
```

能看到「智能租房助手」页面、点右下角圆按钮能聊天，就全通了。

---

## 日常运维

| 操作 | 命令（VPS 和虚拟机通用） |
|---|---|
| 看状态 | `sudo systemctl status frps` / `frpc` |
| 看日志 | `tail -f /var/log/frps.log` / `frpc.log` |
| 重启 | `sudo systemctl restart frps` / `frpc` |
| 停掉隧道 | `sudo systemctl stop frpc` |
| 改配置后 | `sudo systemctl restart frpc` |

两个服务都是 `systemctl enable` 过的，**开机自启**。

---

## 三条安全铁律

1. **`auth.token` 必须设**，且不要用弱口令。否则任何人都能把 frpc 连到你的 frps 上，
   拿你的 VPS 当流量跳板。
2. **只映射 80 端口**。`frpc.toml` 里只留 `house-web` 这一条；
   **绝不要**再映射 `3306`（MySQL）、`6379`（Redis）、`5432`（Postgres）。
   这些数据库默认无认证或弱密码，挂上公网几分钟内就会被扫到并植入挖矿程序。
3. **不要用 80 做 `remotePort`**。国内云主机的 80 端口对外需要域名备案，
   用 8080 之类的端口即可，反正前端走的是相对路径，端口是什么都无所谓。

> 附带：`docker-compose.yml` 里 mysql 已改成 `127.0.0.1:3306:3306`，
> 只允许虚拟机本机连，双保险。

---

## 排错

| 现象 | 原因 / 解决 |
|---|---|
| `ssh: connect to host ... port 22: Connection refused / timed out` | 刚重装完系统还在初始化，等 1~2 分钟再试；仍不行就检查控制台是否放通 22 |
| `Permission denied (publickey)` | 镜像只允许密钥登录 → 控制台绑定密钥对，或重装时选「密码登录」 |
| 重置密码后还是登不上 | 密码改完**必须重启实例**才生效 |
| 全部配好、外网就是打不开 | 90% 是控制台没放通端口：轻量看「**防火墙**」、CVM 看「**安全组**」，7000/8080 都得加 |
| `frpc.log` 报 `connect to server error` | VPS 防火墙没放通 7000；或 IP/token 填错 |
| 报 `token in login doesn't match` | 两边 token 不一致，改成一样后 `restart` |
| 报 `port already used` | 8080 被 VPS 上别的程序占了，换一个 `remotePort` |
| 隧道通了但页面 404 | `localPort` 不是 80，或 nginx 容器没起 |
| 页面能开、发消息报错 | `.env` 里 `MODEL_NAME` 必须是 `glm-4.7`，`DB_HOST=mysql` |
| 换网络后隧道断 | `frpc` 是 `Restart=always`，一般会自愈；不恢复就 `sudo systemctl restart frpc` |

---

## 以后想换成 Cloudflare Tunnel（不花钱版）

见 `deploy/public-access.md` 第三节，一条命令的事。
两条路可以并存，互不冲突。
