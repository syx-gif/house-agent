# 把本地虚拟机项目放上公网（免费方案）

> 场景：**短期演示**（答辩 / 给面试官看 / 给同学试用），**0 预算**
> 方案：**内网穿透**——不给家里的机器搞公网 IP，而是用一条隧道把虚拟机的 80 端口
> 反向映射到一个公网 HTTPS 地址，别人打开那个网址即可访问。

---

## 一、先建立三个认知

1. **家用宽带没有公网 IPv4**。国内运营商都在 NAT 后面，路由器上做端口映射（虚拟服务器）对外无效。所以只能走"穿透"。
2. **演示期间必须一直开机**：Windows 主机 + 虚拟机都得开着，且**不能睡眠**。你关机 = 网站下线。
3. **隧道一定要指向 `80` 端口（nginx），不要指向 `8123`**。
   - 原因：`static/house.html` 里的接口调用用的是**相对路径**（`/threads`、`/threads/xxx/runs/stream`）。
   - 只有把页面和 API 都通过 nginx 的 80 端口同源暴露，相对路径才能正确解析；指到 8123 只有 API、没有页面，会 404 或跨域。

---

## 二、开始前先在虚拟机里自测

```bash
curl http://localhost/ | head -3      # 能吐出 html
curl http://localhost:8123/ok         # 返回 {"ok":true}
```

两条都正常，才说明服务本身没问题，可以往外暴露。

> 隧道是**出站连接**，不需要在 ufw / 安全组开任何端口。如果 ufw 是 active，本地 localhost 访问也不受影响。

---

## 三、方案 A：Cloudflare Tunnel（首推）

**优点**：免费、**不需要注册账号**、自带 HTTPS、不限速、地址立刻可用。
**缺点**：每次重启隧道地址会变（随机 `xxx.trycloudflare.com`）。

### 1. 安装 cloudflared

**方式一：官方源（推荐，不经过 GitHub）**

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared
```

**方式二：GitHub 被墙时的镜像直下二进制**

```bash
# 镜像域名若失效，换 gh-proxy.com / ghproxy.net 再试
wget -O cloudflared https://ghfast.top/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/
```

验证：

```bash
cloudflared --version
```

### 2. 先在前台跑一次，把地址抄下来

```bash
cloudflared tunnel --url http://localhost:80
```

等几秒，终端里会出现一个方框，里面写着：

```
Your quick Tunnel has been created! Visit it at:
https://随机单词-xxxx.trycloudflare.com
```

**这个 `https://....trycloudflare.com` 就是给别人用的网址。** 先自己在 Windows 浏览器里打开验证一下。

按 `Ctrl + C` 可以停掉。

### 3. 让它后台常驻（演示期间别关窗口）

```bash
cd ~
nohup cloudflared tunnel --url http://localhost:80 > ~/tunnel.log 2>&1 &

# 等 8 秒，从日志里把地址抓出来
sleep 8
grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' ~/tunnel.log | head -1
```

输出那个网址，就是你要发出去的链接。

### 4. 关闭隧道

```bash
pkill cloudflared
```

---

## 四、方案 B：cpolar（备选，国内下载快）

**优点**：官网在国内，安装脚本下载不卡；控制台有中文。
**缺点**：需要邮箱注册；免费版带宽 **1M**、地址每 24 小时会重置一次、并发有限制。

```bash
# 1. 一键安装
curl -L https://www.cpolar.com/static/downloads/install-release-cpolar.sh | sudo bash

# 2. 到 cpolar 官网注册后，在后台复制 authtoken，填进去
cpolar authtoken 你的authtoken

# 3. 开隧道（把 80 端口暴露出去）
cpolar http 80
```

前台会打印一个类似 `https://xxxx.r3.cpolar.cn` 的地址，那就是外网访问地址。

后台常驻：

```bash
nohup cpolar http 80 > ~/cpolar.log 2>&1 &
grep -oE 'https://[a-z0-9]+\.r[0-9]\.cpolar\.cn' ~/cpolar.log | head -1
```

---

## 五、演示期间的保命清单

| 事项 | 做法 |
|---|---|
| **别让电脑睡眠** | Windows：设置 → 系统 → 电源 → 屏幕和睡眠 → 都改成「从不」 |
| **别关虚拟机** | 虚拟机保持运行；VMware 里别点「挂起」 |
| **别关隧道窗口** | 用 `nohup ... &` 起了后台就不会随 XShell 断开而退出 |
| **演示前重拿地址** | 隧道重启后地址会变，跑一次第 3 步重新抓 |
| **演示完关掉** | `pkill cloudflared`（或 `pkill cpolar`），避免别人继续访问 |

---

## 六、排错

| 现象 | 原因 / 解决 |
|---|---|
| 网址打得开，但发消息 404 | 隧道指到了 8123，改回 `--url http://localhost:80` |
| 网址打得开，页面是 nginx 默认页 | nginx 容器没起或配置没生效：`sudo docker compose ps` / `sudo docker compose logs nginx` |
| 页面空白、按钮点不动 | 之前 `marked.min.js` 没同步进 `static/`：`ls static/` 确认有它 |
| 打开很慢 / 偶尔打不开 | Cloudflare 在国内访问有波动，可临时切 cpolar |
| 隧道进程莫名退出 | 看 `~/tunnel.log` 尾部；多半是网络抖动，重新起一次 |

---

## 七、以后想长期挂着怎么办

内网穿透依赖"你家电脑一直开机"，不适合长期。真要长期上线，回云服务器：

- 选 **2 核 4G**（这套 5 个容器至少 4G，之前 2G 那台大概率是被 OOM 杀掉的）
- 对外仍用 **非 80 端口**（如 8123），避开国内云主机的 80 端口备案要求
- 部署流程和虚拟机完全一样：传包 → 改 `.env`（`DB_HOST=mysql`）→ `docker compose up -d --build` → 导入 SQL

---

## 八、方案 C：frp（需要自备一台公网 VPS）

适用：**愿意花二三十块/月买一台最低配 VPS**，想要比 Cloudflare 更快更稳的国内链路。

### frp 是什么

它把一条隧道拆成两半：

```
别人 ──> VPS公网IP:8080 ──> frps(服务端，跑在VPS) ──隧道──> frpc(客户端，跑在你虚拟机) ──> localhost:80
```

- `frps`（server）：跑在有公网 IP 的 VPS 上，负责"接客"。
- `frpc`（client）：跑在你本地虚拟机里，主动连出去，把本地 80 端口"报到"服务器。

**为什么"配置低的 VPS 就是一个公网 IP"**：VPS 只转发流量、不跑业务，所以 **1 核 1G 完全够**。
业务（5 个容器）还是跑在你本地虚拟机上 —— 这比"把整套部署到 2G 云服务器上被 OOM 杀掉"聪明得多。

### 步骤

**① 买 VPS**：任意厂商最便宜的 1 核 1G Ubuntu 22.04，安全组放通 `7000`（frp 控制端口）和 `8080`（对外访问端口）。

**② 下 frp**（两端都下同一份）：

```bash
wget -O frp.tar.gz https://ghfast.top/https://github.com/fatedier/frp/releases/download/v0.61.0/frp_0.61.0_linux_amd64.tar.gz
tar -xzf frp.tar.gz && cd frp_0.61.0_linux_amd64
```

**③ VPS 上的 `frps.toml`**：

```toml
bindPort = 7000
auth.method = "token"
auth.token = "换成一串随机长字符串"
```

启动：`./frps -c frps.toml`

**④ 本地虚拟机上的 `frpc.toml`**：

```toml
serverAddr = "VPS的公网IP"
serverPort = 7000
auth.method = "token"
auth.token = "和上面那串完全一致"

[[proxies]]
name = "house-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 8080
```

启动：`./frpc -c frpc.toml`

**⑤ 访问**：`http://VPS的公网IP:8080/`

### frp 的三条铁律

1. **`auth.token` 必须设**，否则任何人都能把 frpc 连到你的 frps 上蹭隧道。
2. **只映射 80**。数据库端口（3306 / 5432 / 6379）一个都不要映射到 `remotePort`。
3. **别用 80 做 remotePort**：国内云主机 80 端口对外需要备案，用 8080 之类的即可。

### 和 Cloudflare Tunnel 怎么选

| | Cloudflare Tunnel | frp + 低价 VPS |
|---|---|---|
| 成本 | 0 元 | 约 ¥10~30/月 |
| 国内访问速度 | 一般，偶有波动 | **快且稳** |
| 地址 | 每次重启就变 | **固定 IP:端口** |
| 门槛 | 一条命令 | 要买 VPS + 配两端 |
| 需要备案 | 不需要 | 不需要（用非 80 端口） |

**结论**：0 预算短期演示 → A；想要更专业的固定地址和更快的国内速度 → C。
