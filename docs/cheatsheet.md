## 速查表

这一页用于学后查阅，不替代正文。命令默认在仓库根目录或 nginx 容器内执行；路径、端口和上游名按实际环境替换。

### 命令

| 命令 | 作用 |
| --- | --- |
| `nginx -t` | 检查配置语法 |
| `nginx -T` | 打印实际加载的完整配置 |
| `nginx -s reload` | 平滑重载 |
| `nginx -s quit` | 优雅停止 |
| `nginx -s stop` | 快速停止 |
| `nginx -s reopen` | 重新打开日志文件 |
| `nginx -v` | 版本 |
| `nginx -V` | 版本、编译参数和模块 |
| `nginx -p <prefix> -c <file>` | 指定前缀和配置文件 |
| `nginx -g "daemon off;"` | 前台运行，容器常用 |

Docker 实验对应：

```shell
docker compose -f labs/compose.yaml exec nginx nginx -t
docker compose -f labs/compose.yaml exec nginx nginx -T
docker compose -f labs/compose.yaml exec nginx nginx -s reload
bash scripts/lab.sh logs nginx
bash scripts/lab.sh status
```

### 配置指令

| 指令 | 常用写法 | 作用 |
| --- | --- | --- |
| `listen` | `listen 80;` / `listen 443 ssl;` | 监听端口 |
| `server_name` | `server_name example.com www.example.com;` | 虚拟主机名 |
| `root` | `root /srv/www;` | URI 拼到目录后 |
| `alias` | `alias /srv/files/;` | 替换 location 前缀 |
| `index` | `index index.html;` | 目录默认文件 |
| `location` | `location /api/ { ... }` | URI 匹配 |
| `try_files` | `try_files $uri $uri/ =404;` | 依次检查文件/目录 |
| `return` | `return 301 https://$host$request_uri;` | 立即返回 |
| `rewrite` | `rewrite ^/old/(.*)$ /new/$1 permanent;` | 正则重写 |
| `proxy_pass` | `proxy_pass http://api_backend/;` | 转发上游 |
| `proxy_set_header` | `proxy_set_header Host $host;` | 设置转发头 |
| `upstream` | `upstream api_backend { server api1:8000; }` | 上游组 |
| `keepalive` | `keepalive 16;` | 上游空闲连接池 |
| `ssl_certificate` | `ssl_certificate /path/fullchain.pem;` | 证书 |
| `ssl_certificate_key` | `ssl_certificate_key /path/privkey.pem;` | 私钥 |
| `ssl_protocols` | `ssl_protocols TLSv1.2 TLSv1.3;` | 协议版本 |
| `gzip` | `gzip on;` | 压缩 |
| `expires` | `expires 1h;` | 静态缓存时间 |
| `add_header` | `add_header X-Frame-Options "SAMEORIGIN" always;` | 响应头 |
| `error_page` | `error_page 404 /404.html;` | 错误页 |
| `limit_req` | `limit_req zone=api burst=3 nodelay;` | 请求速率限制 |
| `limit_conn` | `limit_conn addr 10;` | 并发连接限制 |
| `client_max_body_size` | `client_max_body_size 10m;` | 请求体上限 |
| `access_log` | `access_log /var/log/nginx/access.log main;` | 访问日志 |
| `error_log` | `error_log /var/log/nginx/error.log notice;` | 错误日志 |
| `stub_status` | `stub_status;` | 状态页 |

### location 修饰符

| 写法 | 含义 |
| --- | --- |
| `location = /path` | 精确匹配，优先级最高 |
| `location ^~ /prefix/` | 最长前缀命中后跳过后面的正则 |
| `location ~ regex` | 正则，区分大小写，按出现顺序 |
| `location ~* regex` | 正则，不区分大小写 |
| `location /prefix/` | 普通前缀，记住最长匹配 |
| `location @name` | 命名 location，供内部跳转 |

### 状态码

| 状态码 | 常见原因 |
| --- | --- |
| `200` | 成功 |
| `204` | 成功但无正文，常用于 CORS 预检 |
| `301` / `302` | 永久/临时重定向 |
| `304` | 缓存仍然有效 |
| `400` | 请求格式错误 |
| `401` | 需要认证 |
| `403` | 禁止访问（权限、deny、隐藏文件） |
| `404` | 文件或路由不存在 |
| `405` | 方法不允许 |
| `413` | 请求体太大 |
| `429` | 请求过多（限速） |
| `499` | 客户端提前关闭（nginx 日志专有） |
| `500` | 上游内部错误 |
| `502` | 上游连接失败/提前断开 |
| `503` | 服务不可用（上游全挂、限流、维护） |
| `504` | 上游响应超时 |

### 日志变量

| 变量 | 含义 |
| --- | --- |
| `$remote_addr` | 直接客户端地址 |
| `$request` | 原始请求行 |
| `$status` | 响应状态码 |
| `$body_bytes_sent` | 响应正文大小 |
| `$request_time` | 请求总耗时 |
| `$upstream_addr` | 实际连接的上游地址 |
| `$upstream_response_time` | 上游响应耗时 |
| `$http_user_agent` | User-Agent |
| `$http_x_forwarded_for` | X-Forwarded-For |
| `$host` | 规范化 Host |
| `$uri` | 当前 URI，不含查询串 |
| `$request_uri` | 原始 URI，含查询串 |
| `$args` | 查询串 |
| `$scheme` | http/https |
| `$server_port` | 接收请求的端口 |

### 常用取值与单位

| 项 | 说明 |
| --- | --- |
| 大小单位 | `k`/`K`、`m`/`M`；不带单位是字节 |
| 时间单位 | `ms`、`s`、`m`、`h`、`d`、`w`；不带单位通常是秒 |
| `worker_processes` | 默认 1；`auto` 按 CPU 核心数，教程使用 `auto` |
| `worker_connections` | 每个 worker 的连接上限；默认 512，教程使用 1024 |
| `keepalive_timeout` | 客户端 keepalive 空闲时间；默认 75s（版本可能不同） |
| `client_max_body_size` | 默认请求体上限 1m |
| `proxy_read_timeout` | 默认上游读超时 60s |
| `gzip` | 默认关闭 |

不同 nginx 版本和发行版的默认值可能不同；以 `nginx -T`、官方文档和实际版本为准。

### 实验命令

```shell
bash scripts/check-env.sh
bash scripts/lab.sh up
bash scripts/lab.sh up --with-openresty
bash scripts/lab.sh reload
bash scripts/lab.sh logs nginx
bash scripts/lab.sh status
bash scripts/lab.sh down
bash scripts/lab.sh clean
bash scripts/lab.sh clean --certs
bash scripts/verify.sh
bash scripts/gen-cert.sh --force
```

### 安全检查

- 全站 HTTPS，HTTP 跳转，HSTS 逐步加长。
- `server_tokens off;`，隐藏不必要的上游技术头。
- 安全响应头：`nosniff`、`X-Frame-Options`/CSP、`Referrer-Policy`、`Permissions-Policy`。
- 后台有认证和 IP/VPN 限制，不只靠隐藏 URL。
- 登录、上传、搜索有限速和请求体限制。
- `stub_status`、管理端点不暴露公网。
- 证书自动续期，私钥不进 Git。
- 日志不含 Token、密码、Cookie。
- nginx 不是 WAF；需要时在 CDN/WAF/应用层补足。

### 排障顺序

1. 访问日志有没有新行？
2. 状态码是 4xx 还是 5xx？
3. `nginx -T` 选中的 server/location 是否符合预期？
4. 从 nginx 容器直接请求上游，是否通？
5. error.log 有没有 `connect()`、`timed out`、`Permission denied`？
6. 用 `curl -v` 最小复现，一次只改一个变量。
7. 修复后跑 `nginx -t`、`verify.sh` 和目标业务请求。
