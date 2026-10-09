# 安全加固操作手册（对应审计报告的问题 1 / 3 / 4）

> 对应《house-agent 仓库安全审计报告》第五节「推荐处理顺序」：
> - **问题 1** = 给 nginx 加访问口令（P0-2，唯一会造成实际金钱损失的风险）
> - **问题 3** = 数据库换成强密码 + 清掉公开注释里的弱口令（P1-1）
> - **问题 4** = 提交邮箱改为 noreply（P1-2）
>
> 建议执行顺序：**1 → 3 → 4**。问题 1 和 3 互不影响，问题 4 需要强推，放最后。

---

## 问题 1：给网站加访问口令（nginx HTTP Basic 认证）

**效果**：任何人打开网站先弹「输入用户名 / 密码」框，没有凭据一律返回 401，防止他人白用你的 GLM 额度。

### 仓库里已经改好的部分

| 文件 | 改动 |
|---|---|
| `nginx/nginx.conf` | 新增 `auth_basic` + `auth_basic_user_file` 两行（作用在 server 级，静态页和 API 全部覆盖） |
| `docker-compose.yml` | nginx 服务新增挂载 `./nginx/.htpasswd:/etc/nginx/.htpasswd:ro` |
| `.gitignore` | 新增忽略 `nginx/.htpasswd`（含密码哈希，绝不能提交） |

### 第 1 步：在虚拟机上生成密码文件

```bash
cd ~/project/huose_agent/my_langgraph_app

# 装 htpasswd 工具（apache2-utils 提供）
sudo apt update && sudo apt install -y apache2-utils

# 生成密码文件：
#   -c 新建文件   -b 密码直接写在命令里   -m 使用 MD5(apr1) —— 这个格式 nginx 才认
htpasswd -cbm nginx/.htpasswd house '你的密码'

# 确认内容，应形如 house:$apr1$xxxxxxxx$yyyyyyyyyyyyyyyy
cat nginx/.htpasswd
```

用户名用了 `house`，可自行更换。**没有 apache2-utils 时的替代写法**：

```bash
printf 'house:%s\n' "$(printf '你的密码' | openssl passwd -apr1 -stdin)" > nginx/.htpasswd
```

> ⚠️ 顺序很重要：**密码文件必须先存在**。如果先改配置再生成文件，nginx 会因为读不到文件而启动失败。

### 第 2 步：同步两个配置文件（在 Windows Git Bash）

```bash
cd /f/project/my_langgraph_app
scp nginx/nginx.conf   <VM用户>@<VM_IP>:~/project/huose_agent/my_langgraph_app/nginx/
scp docker-compose.yml <VM用户>@<VM_IP>:~/project/huose_agent/my_langgraph_app/
```

### 第 3 步：重建 nginx 容器（在虚拟机上）

```bash
cd ~/project/huose_agent/my_langgraph_app
sudo docker compose up -d nginx
```

**这里必须用 `up -d`，不能用 `restart`**：新增了 volumes 挂载项，只有「重建容器」才会应用新的挂载配置，`restart` 只是重启进程。

### 第 4 步：验证

```bash
curl -s -o /dev/null -w "无凭据: HTTP %{http_code}\n" http://localhost/                          # 期望 401
curl -s -o /dev/null -w "有凭据: HTTP %{http_code}\n" -u house:'你的密码' http://localhost/        # 期望 200
curl -s -o /dev/null -w "后端:   HTTP %{http_code}\n" -u house:'你的密码' http://localhost/ok      # 期望 200
```

然后浏览器 Ctrl+F5 硬刷新，会弹登录框；公网地址 `http://<VPS公网IP>:8080/` 同理。

### 三个坑

| 坑 | 说明 |
|---|---|
| 密码文件不存在就改配置 | nginx 启动失败，`sudo docker compose logs nginx` 会报 `auth_basic_user_file ... failed`；补上文件后 `up -d nginx` 即可 |
| 用了 bcrypt | `htpasswd -B` 生成的是 `$2y$` 开头，**nginx 不支持**；必须用 `-m`（`$apr1$`） |
| 密码文件被提交 | 已加入 `.gitignore`；改完跑 `git status --short` 确认列表里没有 `nginx/.htpasswd` |

**忘记密码**：重跑第 1 步覆盖（去掉 `-c` 就是改密码：`htpasswd -bm nginx/.htpasswd house '新密码'`），再 `sudo docker compose restart nginx` —— 文件路径没变，重启就生效。

**要不要给 API 单独放行？** 不需要。页面加载时浏览器已缓存该站点的凭据，页面里 `/threads`、`/runs/stream` 都是**同源请求**，会自带同一份凭据，SSE 流照常工作。

---

## 问题 3：数据库换成强密码

### 先理解一个关键点

`MYSQL_ROOT_PASSWORD` **只在数据卷第一次初始化时生效**。你的库已经建好了，所以：

- ❌ 只改 `.env` 里的 `DB_PASSWORD` → 数据库里的真实密码**没变**，容器反而连不上；
- ✅ 正确顺序：**先在数据库里改密码 → 再同步 `.env` → 重建容器**。

### 第 0 步：看清有哪些 root 账号

```bash
sudo docker exec house-mysql mysql -uroot -p'旧密码' -e "SELECT user, host FROM mysql.user WHERE user='root';"
```

通常会看到 `root@localhost` 和 `root@%` 两条。**建议两条都改**（漏掉 `%` 那条，容器之间会连不上）。

### 第 1 步：生成强密码

```bash
openssl rand -base64 18
# 形如 K7fQ2mZx9pL4vR8tBn6yWg==，抄下来
```

### 第 2 步：在容器里改数据库密码

```bash
sudo docker exec -it house-mysql mysql -uroot -p'旧密码' -e "
ALTER USER 'root'@'localhost' IDENTIFIED BY '新密码';
ALTER USER 'root'@'%'         IDENTIFIED BY '新密码';
FLUSH PRIVILEGES;"
```

> 第 0 步如果只有 `localhost` 一条，就把 `'root'@'%'` 那行删掉再执行。
> 密码里**不要含单引号**（会截断 SQL）；`openssl rand -base64 18` 的输出只含 `A-Za-z0-9+/=`，安全。

### 第 3 步：立刻同步 `.env`（这一步不做，服务会断）

```bash
nano .env
# 把 DB_PASSWORD=旧密码 改成 新密码
```

顺手确认同一文件里的 `DB_HOST=mysql`（compose 服务名）。若这里写成 `127.0.0.1`，容器内连的是它自己，会连不上数据库。

### 第 4 步：重建依赖它的容器

```bash
sudo docker compose up -d --force-recreate mysql langgraph-api
```

**为什么要重建**：mysql 的 healthcheck 是 `mysqladmin ping -p${DB_PASSWORD}`，而 langgraph-api 又 `depends_on: mysql (service_healthy)`。`.env` 不同步，mysql 会一直处于 unhealthy，api 就永远起不来。

### 第 5 步：验证

```bash
sudo docker exec house-mysql mysql -uroot -p'新密码' -e "SELECT COUNT(*) AS 房源数 FROM house_prd.house;"
sudo docker compose ps                                             # mysql 应为 Healthy，api 应为 Up
curl -s -o /dev/null -w "%{http_code}\n" -u house:'口令' http://localhost/ok    # 期望 200
```

最后到页面里问一句「西安 2000 以内的一居室」，能出表格就说明全链路正常。

### 补充说明

- 密码只存在于 `.env`（已被 gitignore 忽略），**代码里没有硬编码**，所以不需要改任何 `.py`。数据库地址走 `DB_USER / DB_PASSWORD / DB_HOST / DB_PORT / DB_NAME` 环境变量。
- 顺带修掉的两处：`docker-compose.yml` 里那句注释已由 `root/123456` 改为通用描述（本次已改）；`test_db.py` 会明文打印密码（审计报告 P2-3），有空可以改成只打印 host/port/db。
- **不想走这套流程的替代方案**：`sudo docker compose down -v` 删卷重建，密码直接按新 `.env` 生效，但 **8912 行房源数据会丢，需要重新导入 SQL**，不推荐。

---

## 问题 4：提交邮箱改为 noreply（避免被爬虫收录）

### 现状

两个提交的作者都是 `bhsuk <syx1001102@gmail.com>`，公开仓库里任何人（含爬虫）都能看到。

### 第 1 步：在 GitHub 上拿到专用匿名邮箱

GitHub → 右上角头像 → **Settings** → 左侧 **Emails** → 勾选 **Keep my email addresses private**。

页面上会显示形如 `12345678+syx-gif@users.noreply.github.com` 的地址，**抄下来**（前面那串数字是你的用户 ID，用带 ID 的版本最稳）。

### 第 2 步：改本仓库的提交署名（Windows Git Bash）

```bash
cd /f/project/my_langgraph_app

git config user.name  "syx-gif"
git config user.email "12345678+syx-gif@users.noreply.github.com"   # 换成你抄到的

# 确认
git config user.name; git config user.email
```

> 这是**仓库级**配置，只影响这个项目，不会动你全局那个 `bhsuk`。
> 显示名建议与简历 / GitHub 账号一致（`syx-gif` 或真名拼音），面试官点进来能对上人。

### 第 3 步：把已有两个提交的作者也改掉

```bash
# 改前先看一眼（此刻应显示 bhsuk <syx1001102@gmail.com>）
git log --format="%h %an <%ae> %s"

git rebase --root --exec 'git commit --amend --no-edit --reset-author'

# 改后再看（两行都应是 syx-gif <...noreply...>）
git log --format="%h %an <%ae> %s"
```

逐段解释这条命令：

| 片段 | 作用 |
|---|---|
| `rebase --root` | 从第一个提交开始重放（你只有 2 个提交，几秒钟） |
| `--exec '...'` | 每重放完一个提交就执行一次引号里的命令 |
| `--amend` | 重写这个提交对象（内容不变） |
| `--no-edit` | 不改提交信息 |
| `--reset-author` | 把作者重置为当前的 `user.name / user.email`（即第 2 步设的 noreply 地址） |

### 第 4 步：强推

```bash
git push --force-with-lease
```

历史被重写后 commit hash 会变，普通 `push` 会被拒，必须强推。用 `--force-with-lease` 而不是 `--force`：万一远端有别人新推的提交会被拦下来，更安全。

### 第 5 步：验证

刷新 GitHub 仓库页 → Commits 列表的作者应显示为 `syx-gif`；点开单个提交，邮箱应为 `...@users.noreply.github.com`。

> 说明：强推后，GitHub 上通过旧 commit SHA 直链理论上短期内仍可能访问到旧对象，要彻底消失需等 GitHub 自身回收或联系支持。对「防爬虫收录邮箱」这个目的而言，重写已经足够。

---

## 附：如果以后要做问题 2，建议合并成一次重写

问题 2（git 历史里残留的服务器 IP）和问题 4（邮箱）**都需要重写历史 + 强推**。既然都要痛一次，可以合并成一遍做：

```bash
# 1) 安装 git-filter-repo
"C:/Users/言锡/.workbuddy/binaries/python/versions/3.13.12/python.exe" -m pip install git-filter-repo

# 2) 一次把邮箱换掉 + 把服务器 IP 替换成占位符
cd /f/project/my_langgraph_app
git filter-repo \
  --email-callback "return email.replace(b'syx1001102@gmail.com', b'12345678+syx-gif@users.noreply.github.com')" \
  --replace-text <(printf '你的真实IP==>YOUR_VPS_IP\n')

# 3) filter-repo 会顺手删掉 origin 远程，要重新加回来
git remote add origin https://github.com/syx-gif/house-agent.git
git push --force-with-lease origin main
```

用 `git filter-repo` 前建议先整目录备份一份（`.git` 被重写不可逆）。

---

## 执行清单（打印出来划勾用）

- [ ] 问题 1：VM 上 `htpasswd -cbm nginx/.htpasswd house '密码'`
- [ ] 问题 1：同步 `nginx/nginx.conf` + `docker-compose.yml` 到 VM
- [ ] 问题 1：`sudo docker compose up -d nginx`（重建，不是 restart）
- [ ] 问题 1：`curl` 验证 401 / 200，浏览器弹登录框
- [ ] 问题 3：`SELECT user, host FROM mysql.user WHERE user='root'` 看清账号
- [ ] 问题 3：`ALTER USER ... IDENTIFIED BY '新密码'` + `FLUSH PRIVILEGES`
- [ ] 问题 3：改 `.env` 的 `DB_PASSWORD`（并确认 `DB_HOST=mysql`）
- [ ] 问题 3：`sudo docker compose up -d --force-recreate mysql langgraph-api`
- [ ] 问题 3：`SELECT COUNT(*)` 得 8912，页面能正常推荐
- [ ] 问题 4：GitHub 勾选 Keep my email private，抄下 noreply 地址
- [ ] 问题 4：`git config user.name / user.email`（仓库级）
- [ ] 问题 4：`git rebase --root --exec 'git commit --amend --no-edit --reset-author'`
- [ ] 问题 4：`git push --force-with-lease`
- [ ] 问题 4：GitHub 上确认作者已变为 syx-gif
