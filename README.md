## Nginx 入门与实战

一份面向初学者的 nginx 教程，假设你已经会使用 shell：知道 `cd`、管道、重定向、环境变量和 `curl` 的基本用法，但不需要事先了解 nginx。

教程从 nginx 的工作模型和配置模型讲起，逐步进入静态站点、`location` 匹配、反向代理、负载均衡、HTTPS、日志排障、性能与安全，最后介绍 OpenResty 和其他服务器软件的取舍。每章都配有可以运行的 Docker Compose 实验、检查点和练习。

**nginx** 是一个事件驱动的 HTTP 服务器和反向代理。它既可以单独提供静态文件，也可以站在应用前面，负责 **TLS**(Transport Layer Security, 传输层安全) 终止、路由、负载均衡、缓存、限速和访问日志。

### 为什么学 nginx

- **入口统一**：一个域名下可以同时提供静态资源、**API**(Application Programming Interface, 应用程序接口)、WebSocket 和旧地址跳转。
- **部署普遍**：Linux 发行版、容器镜像、云负载均衡和 Kubernetes Ingress 中都能见到它。
- **配置可版本化**：站点配置是文本，能进 Git、能评审、能回滚。
- **理解 Web 请求的骨架**：Host、URI、状态码、转发头、超时和连接复用，都会在 nginx 配置里变得具体。
- **排查有抓手**：访问日志、错误日志、`nginx -T` 和状态页能把“打不开”拆成可验证的环节。

### 学完能做什么

- 读懂一个典型的 `nginx.conf`，说清 `http`、`server`、`location`、`upstream` 各管什么。
- 独立配置静态站点、SPA 回退、自定义 404 和缓存响应头。
- 用 `proxy_pass` 接入上游应用，正确传递 `Host` 与 `X-Forwarded-*` 请求头。
- 用 `upstream` 做负载均衡，理解轮询、权重、健康检查和连接复用。
- 配置 HTTPS、HTTP 到 HTTPS 跳转，并知道自签名证书与 Let's Encrypt 的边界。
- 用日志、`nginx -t`、`nginx -T` 和状态页定位 403、404、413、429、499、502、504。
- 做基础的安全加固、限速、请求体限制和代理缓存。
- 判断什么时候该用 nginx、OpenResty、Caddy、Traefik、Envoy、HAProxy 或 IIS。

### 适合谁

本教程假设读者：

- 能在终端里执行命令，理解相对路径、绝对路径和退出码。
- 知道 HTTP 请求由方法、路径、请求头和响应状态码组成。
- 有 Docker Desktop 或 Docker Engine，能运行 `docker compose`。
- 愿意先预测结果，再用 `curl` 和日志核对，而不是只复制配置。

不要求会 C、Lua、Kubernetes 或 TLS 数学。OpenResty 和服务器对比两章是选学，不影响前面的主线。

### 学习路径

按下面的顺序阅读，概念依赖最顺。标为“查阅”的章节适合学完后回来查，不需要一次读完。

| 文档 | 内容 | 建议 |
| --- | --- | --- |
| [环境与实验台](docs/setup.md) | Docker、端口、启动、停止、清理 | 必读 |
| [nginx 的工作模型](docs/how-nginx-works.md) | master/worker、事件循环、请求生命周期、重载 | 必读 |
| [配置模型](docs/configuration-model.md) | 指令、上下文、`server_name`、`root`/`alias`、变量 | 必读 |
| [location 与 URI 处理](docs/location-and-rewrite.md) | 匹配顺序、`try_files`、`return`、`rewrite` | 必读 |
| [静态站点](docs/static-site.md) | `root`、MIME、缓存、gzip、错误页、隐藏文件 | 必读 |
| [反向代理](docs/reverse-proxy.md) | `proxy_pass`、转发头、超时、缓冲、WebSocket | 必读 |
| [负载均衡](docs/load-balancing.md) | `upstream`、算法、健康检查、keepalive | 必读 |
| [HTTPS 与证书](docs/https.md) | TLS、证书链、HSTS、ACME、自签名实验 | 必读 |
| [日志与排障](docs/logs-and-troubleshooting.md) | 日志格式、状态码、`nginx -T`、故障表 | 必读 |
| [性能与缓存](docs/performance.md) | worker、缓冲区、代理缓存、HTTP/2、测量 | 必读 |
| [安全基础](docs/security.md) | 响应头、限速、请求体限制、访问控制、TLS 加固 | 必读 |
| [OpenResty](docs/openresty.md) | Lua、请求阶段、共享字典、取舍 | 选学 |
| [服务器软件对比](docs/server-comparison.md) | nginx、Caddy、Traefik、Envoy、HAProxy、Apache、IIS | 选学 |
| [常用配置配方](docs/recipes.md) | SPA、WebSocket、CORS、维护页、动态上游 | 查阅 |
| [速查表](docs/cheatsheet.md) | 命令、指令、状态码、日志变量 | 查阅 |
| [综合项目](docs/capstone.md) | 把静态站点、API、LB、HTTPS、限速组合起来 | 选做 |

### 实验台一览

实验由 `labs/compose.yaml` 启动，包含一个 nginx、两个相同的 Python API 实例，以及一个可选的 OpenResty。所有端口都可以在 `.env` 中修改。

| 入口 | 默认端口 | 演示 |
| --- | --- | --- |
| 静态站点 | `8080` | `root`、`try_files`、缓存、404、`location` 演示 |
| 反向代理 | `8081` | `proxy_pass`、转发头、超时、流式响应 |
| 负载均衡 | `8082` | `upstream`、缓存、限速、请求体限制、状态页 |
| HTTPS | `8443` | 自签名证书、HTTP/2、HSTS |
| OpenResty | `8083` | Lua 内容生成、共享字典、A/B 分支 |
| 综合项目 | `8084` | 完成 capstone 后启用的统一入口 |

API 实例返回的 JSON 里带有 `instance` 字段，值是 `api1` 或 `api2`。连续请求负载均衡入口时，观察这个字段就能知道请求被分到了哪个实例。

### 快速开始

前置条件：

- Docker Desktop（Windows/macOS）或 Docker Engine + Compose 插件（Linux）。
- 可用端口 `8080`、`8081`、`8082`、`8443`，以及可选的 `8083`；综合项目还需要 `8084`。
- Git Bash、WSL 或任意 bash 环境，用来运行仓库脚本。

如果还没获取仓库：

```shell
git clone https://gitee.com/xuchaoxin1375/learnNginx.git
cd learnNginx
```

GitHub 镜像：[xuchaoxin1375/learnNginx](https://github.com/xuchaoxin1375/learnNginx)。

然后在仓库根目录执行：

```shell
bash scripts/check-env.sh
bash scripts/lab.sh up
```

`check-env.sh` 只做检查，不启动容器。它会确认 Docker daemon、Compose、`curl`、`openssl`、Compose 语法和端口占用情况。`lab.sh up` 会生成自签名证书、构建 API 镜像并启动容器。

启动后打开或请求：

```shell
curl -i http://localhost:8080/
curl -i http://localhost:8081/api/
curl -s http://localhost:8082/api/
curl -k -i https://localhost:8443/
```

运行完整验收：

```shell
bash scripts/verify.sh
```

它会检查首页、404、gzip、缓存头、代理、负载均衡、限速、413、HTTPS，并在 OpenResty 已启动时检查 Lua 端点。任何一项失败都会返回非零退出码。

停止与清理：

```shell
bash scripts/lab.sh down
bash scripts/lab.sh clean
bash scripts/lab.sh clean --certs
```

`down` 停止并移除容器，保留证书；`clean` 还会移除网络和 Compose 卷，但保留镜像；`clean --certs` 额外删除生成的证书和私钥。镜像不会自动删除，避免下次重新下载。

### 仓库结构

| 路径 | 内容 |
| --- | --- |
| `docs/` | 教程正文，从工作模型到综合项目 |
| `labs/compose.yaml` | 实验编排：nginx、api1、api2、可选 openresty |
| `labs/nginx/` | nginx 主配置、`conf.d`、snippets、生成的证书 |
| `labs/api/` | 无第三方依赖的 Python 上游 API |
| `labs/site/` | 静态站点、SPA 回退页、404 与 50x 页面 |
| `labs/openresty/` | OpenResty 的 Lua 实验配置 |
| `examples/` | 综合项目参考配置与可选示例 |
| `scripts/` | 环境检查、启停、证书生成、端到端验证 |
| `.env.example` | 端口覆盖示例 |

### 教程约定

- 命令默认在**仓库根目录**执行；文档中的路径相对于仓库根目录或当前文档位置。
- 可复制命令块不带提示符；终端记录块用 `$` 开头，不要把 `$` 一起复制。
- 实验镜像使用 nginx `1.30.6`；配置结构和核心行为在 nginx `1.25.2` 上按相同指令组合验证过。新版本通常兼容，涉及行为变化的地方会标注。
- 自签名证书只用于本机实验。`labs/nginx/certs/` 下的 `lab.crt` 和 `lab.key` 不应提交到版本库。
- 端口、上游地址和证书路径都写在配置里。改端口后，页面中的演示链接和 `verify.sh` 的默认值也要同步调整。
- 未实际运行的内容会写“示意”或“未验证”，不把推断当成实测。

### 验证范围

本仓库的配置结构、`location` 匹配、静态文件、反向代理、负载均衡、缓存、限速、413、自定义 502、HTTPS 与 HSTS 已用 nginx 1.25.2 在 Windows 上按同样的指令组合验证（测试时替换了本地端口和上游地址）。实验镜像使用 nginx 1.30.6，所用指令在 1.30.x 中仍然有效，但 **Docker Compose 启动流程和 `verify.sh` 尚未在本机完整执行**（当前开发环境没有 Docker）；首次运行请先跑 `bash scripts/check-env.sh`，遇到问题按[日志与排障](docs/logs-and-troubleshooting.md)排查。

### 练习与自检

每篇正文末尾有少量练习，答案折叠在“参考答案”里。建议先写出配置或命令，再展开对照。全部读完后，用[综合项目](docs/capstone.md)做一次独立配置，并运行：

```shell
bash scripts/verify.sh
```

如果你想验证自己的环境是否符合预期，也先运行它。

### 参考资料

- [nginx 官方文档](https://nginx.org/en/docs/)：指令、模块和行为的第一手说明。
- [nginx 配置手册](https://nginx.org/en/docs/beginners_guide.html)：官方入门指南。
- [OpenResty 官方文档](https://openresty.org/en/)：Lua API、组件和最佳实践。
- [Caddy 官方文档](https://caddyserver.com/docs/)：自动 HTTPS 与 Caddyfile。
- [Traefik 官方文档](https://doc.traefik.io/traefik/)：容器服务发现与中间件。
- [Envoy 官方文档](https://www.envoyproxy.io/docs/envoy/latest/)：L7 代理与 xDS。
- [HAProxy 官方文档](https://docs.haproxy.org/)：L4/L7 负载均衡与健康检查。
- [Apache HTTP Server 文档](https://httpd.apache.org/docs/)：模块、`.htaccess` 与进程/线程模型。
- [Let's Encrypt 文档](https://letsencrypt.org/docs/)：ACME、证书签发与续期。
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/)：TLS 配置的起点。

### 许可

本仓库使用 [MIT License](LICENSE)。示例数据均为虚构，证书只用于本机实验。
