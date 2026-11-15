## 环境与实验台

这一章把实验台跑起来，并建立后面各章都会用到的观察方式：**先看请求结果，再看配置和日志**。如果环境还没准备好，后面的 `curl` 和日志实验都无法复现。

### 你需要什么

- **Docker**：Windows 和 macOS 推荐 Docker Desktop；Linux 使用 Docker Engine 加 Compose 插件。
- **bash**：Windows 用 Git Bash 或 WSL；macOS/Linux 使用系统终端。
- **curl**：用来查看响应头和状态码；Git Bash、macOS 和多数 Linux 发行版自带。
- **openssl**：用来生成自签名证书；Git for Windows 自带。
- **端口**：默认需要 `8080`、`8081`、`8082`、`8443`，OpenResty 实验额外需要 `8083`，综合项目需要 `8084`。

不需要预装 nginx 或 Python。nginx 和 API 都跑在容器里，Python 版本由镜像固定。

### 安装 Docker

Windows 和 macOS 的图形安装步骤以官方文档为准：

- [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Docker Desktop for macOS](https://docs.docker.com/desktop/setup/install/mac-install/)
- [Docker Engine for Linux](https://docs.docker.com/engine/install/)

Windows 上 Docker Desktop 通常依赖 WSL2。安装后启动 Docker Desktop，确认托盘图标显示运行中，再回到终端。

Linux 上安装 Compose 插件后，普通用户可能需要加入 `docker` 组才能直接运行 `docker`。这会带来权限和安全影响，是否这样做由你决定；不改组也可以用 `sudo`，但仓库脚本里的 `docker` 调用会需要相应权限。

检查版本：

```shell
docker --version
docker compose version
docker info
```

`docker info` 能输出 Server 信息，说明 daemon 可连接；只看到 Client 信息通常表示 daemon 没启动或当前用户无权访问。

### 获取仓库

```shell
cd /path/to/learnNginx
```

如果目录里已经有 `README.md`、`docs/`、`labs/`，说明位置正确。所有脚本都从仓库根目录运行，不要只复制 `labs/` 到别处。

### 第一次检查

```shell
bash scripts/check-env.sh
```

这个脚本只读检查，不启动容器，也不会修改文件。正常时会看到类似“检查完成: 没有发现阻塞项”的结论，并列出每个实验端口是否空闲。

常见失败：

- **`docker: command not found`**：Docker 没装好，或终端没有重新打开。
- **`docker compose` 不可用**：装的是旧版 `docker-compose`，需要 Compose v2 插件。
- **`docker daemon 没有运行`**：先启动 Docker Desktop 或 `docker` 服务。
- **端口已被占用**：可能实验已经在运行，也可能是别的程序占用了端口。先看 `docker compose ps`，或改 `.env` 里的端口。

### 启动实验台

```shell
bash scripts/lab.sh up
```

脚本会做三件事：

- 检查 Docker 与 Compose。
- 在 `labs/nginx/certs/` 生成自签名证书；已有证书时跳过。
- 构建 API 镜像并启动 `api1`、`api2`、`nginx`。

需要 OpenResty 章节时：

```shell
bash scripts/lab.sh up --with-openresty
```

这会额外启动 `openresty` 服务，占用默认端口 `8083`。不需要时可以 `bash scripts/lab.sh down` 后重新 `up`，或者只停止 OpenResty：

```shell
docker compose -f labs/compose.yaml stop openresty
```

### 实验入口

| 入口 | 默认地址 | 说明 |
| --- | --- | --- |
| 静态站点 | `http://localhost:8080/` | 页面、资源、404、`location` 演示 |
| 反向代理 | `http://localhost:8081/api/` | 固定转发到 `api1` |
| 负载均衡 | `http://localhost:8082/api/` | 在 `api1` 与 `api2` 之间分配 |
| 状态页 | `http://localhost:8082/nginx_status` | `stub_status` 输出 |
| HTTPS | `https://localhost:8443/` | 自签名证书，浏览器会警告 |
| OpenResty | `http://localhost:8083/lua/hello` | 需要 `--with-openresty` |
| 综合项目 | `http://localhost:8084/` | 完成 capstone 配置后启用 |

第一次打开 HTTPS 时，浏览器会提示证书不受信任。这是自签名证书的正常现象，选择继续访问即可；不要把这个证书用于任何真实站点。

### 验证实验台

先看最基本的响应：

```shell
curl -i http://localhost:8080/
curl -i http://localhost:8080/healthz
curl -i http://localhost:8081/api/
curl -s http://localhost:8082/api/
curl -k -i https://localhost:8443/
```

`curl -i` 会同时输出响应头和正文。重点看：

- 第一行状态码，例如 `HTTP/1.1 200 OK`。
- `Content-Type`、`Cache-Control`、`X-Content-Type-Options` 等响应头。
- 代理和负载均衡入口返回的 JSON 中，`instance` 是 `api1` 还是 `api2`。

运行完整验收：

```shell
bash scripts/verify.sh
```

它会逐项检查配置、静态资源、代理、负载均衡、缓存、限速、413、HTTPS 和可选的 OpenResty。失败时会指出具体入口，并提示查看日志。

### 端口冲突时

复制示例配置并按需修改：

```shell
cp .env.example .env
```

例如把静态站点改成 `9090`：

```shell
LAB_HTTP_PORT=9090
LAB_PROXY_PORT=9091
LAB_LB_PORT=9092
LAB_OPENRESTY_PORT=9093
LAB_HTTPS_PORT=9443
LAB_CAPSTONE_PORT=9084
```

然后重新启动：

```shell
bash scripts/lab.sh down
bash scripts/lab.sh up
```

`.env` 已被 `.gitignore` 忽略，不会误提交。修改端口后，`verify.sh` 会读取 `.env`；站点首页里写死的 `localhost:8081` 等链接需要手动同步，或者直接用 `curl` 访问。

### 常用生命周期命令

| 命令 | 作用 | 是否保留证书 |
| --- | --- | --- |
| `bash scripts/lab.sh up` | 构建并启动核心服务 | 保留 |
| `bash scripts/lab.sh up --with-openresty` | 额外启动 OpenResty | 保留 |
| `bash scripts/lab.sh reload` | `nginx -t` 后平滑重载 | 保留 |
| `bash scripts/lab.sh status` | 查看容器状态和入口 | 保留 |
| `bash scripts/lab.sh logs nginx` | 跟踪 nginx 日志 | 保留 |
| `bash scripts/lab.sh down` | 停止并移除容器与网络 | 保留 |
| `bash scripts/lab.sh clean` | 额外移除 Compose 卷 | 保留 |
| `bash scripts/lab.sh clean --certs` | 删除容器、网络、卷和生成的证书 | 删除 |

`reload` 只对 nginx 生效，适合改完 `conf.d` 后使用。修改 `compose.yaml`、镜像或端口映射后，用 `down` 再 `up`。

### 没有 Docker 时

本教程的主线依赖 Docker。没有 Docker 时，可以选择：

- 在 Linux 虚拟机或 WSL2 中运行 Docker Engine。
- 在 Linux 虚拟机中直接安装 nginx，手动把 `labs/nginx/conf.d` 里的配置路径改成目标系统路径；这会失去 Compose 的网络和 DNS，`api1`、`api2` 需要换成真实地址。
- 先读工作模型、配置模型、location 和静态站点章节，把实验留到环境准备好之后。

不建议在 Windows 上直接安装 nginx 来跟随本教程。Windows 版 nginx 的进程模型、路径、权限和部分模块与 Linux 不同，容易把环境差异误当成配置错误。

### 目录与职责

| 路径 | 职责 |
| --- | --- |
| `labs/nginx/nginx.conf` | 主配置：worker、日志格式、gzip、`http` 公共部分 |
| `labs/nginx/conf.d/00-static.conf` | 静态站点与 `location` 演示 |
| `labs/nginx/conf.d/10-proxy.conf` | 固定上游的反向代理 |
| `labs/nginx/conf.d/20-lb.conf` | 负载均衡、缓存、限速、状态页 |
| `labs/nginx/conf.d/30-https.conf` | TLS 站点 |
| `labs/nginx/snippets/` | 可复用的安全头与代理头 |
| `labs/api/app.py` | 上游 API，无第三方依赖 |
| `labs/site/` | 静态站点源文件 |
| `labs/openresty/nginx.conf` | OpenResty 的 Lua 配置 |
| `scripts/` | 检查、启停、证书、验收脚本 |

### 练习

- 运行 `check-env.sh`，记录哪些检查通过、哪些失败。失败项分别对应什么前置条件？
- 把静态站点端口改成 `9090`，重新启动，并用 `curl -I` 验证。页面里的哪些链接会因此失效？
- 运行 `bash scripts/lab.sh logs nginx`，另开一个终端请求首页，观察访问日志新增的一行。日志里的 `$status`、`$request_time` 和 `$upstream_addr` 分别是什么？

<details>
<summary>参考答案</summary>

- `check-env.sh` 的失败项通常对应 Docker 未安装、daemon 未启动、Compose 版本不对、`curl`/`openssl` 缺失或端口被占用。端口占用不一定代表故障，可能实验已经在运行。
- 改端口后，`verify.sh` 会读取 `.env`，但 `labs/site/index.html` 里写死的 `http://localhost:8081`、`8082`、`8443` 不会自动变化，需要手动改或直接 `curl` 新端口。这是“配置值不要在多处复制”的反例，生产环境应通过模板或相对路径减少重复。
- 访问日志的 `$status` 是最终响应状态码，`$request_time` 是从读到客户端第一个字节到写完响应的总时间，`$upstream_addr` 是本次请求实际连接的上游地址。静态请求的 `$upstream_addr` 是 `-`。

</details>
