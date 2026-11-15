## 常用配置配方

这一章是查阅型内容：每个配方给出问题、配置片段、验证方式和边界。片段默认放在 `server` 或 `location` 上下文；涉及 `upstream`、`map`、`limit_req_zone` 的指令要放在 `http`。示例中的域名、上游名和路径都是占位，复制到实验或生产时要替换。

### 单页应用加 API

**问题**：前端路由 `/app/users/42` 在磁盘上没有对应文件，但刷新页面不能 404；`/api/` 要转给后端。

```nginx
server {
    listen 80;
    server_name app.example.com;
    root /srv/app;
    index index.html;

    location /api/ {
        proxy_pass http://api_backend/;
        include /etc/nginx/snippets/proxy-headers.conf;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

验证：

```shell
curl -i https://app.example.com/app/users/42
curl -i https://app.example.com/api/health
```

边界：`/api/` 必须比 `/` 更具体，否则会被 SPA 回退吞掉；`try_files` 的最后一跳是 URI，不要写成磁盘路径。前端路由和后端 API 的路径前缀要约定清楚。

### HTTP 跳转到 HTTPS

**问题**：用户仍可能访问 `http://`，需要统一跳到 HTTPS，并保留路径和查询串。

```nginx
server {
    listen 80;
    server_name example.com www.example.com;
    return 301 https://example.com$request_uri;
}
```

验证：

```shell
curl -I 'http://example.com/a?b=1'
```

预期 `Location: https://example.com/a?b=1`。边界：如果 HTTPS 不在 443，要显式写端口；如果前面有可信代理，`$scheme` 可能不是最终协议，需要结合 `X-Forwarded-Proto` 判断。

### www 与裸域统一

**问题**：`www.example.com` 和 `example.com` 都能访问，SEO 和 Cookie 作用域混乱。

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name www.example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    return 301 https://example.com$request_uri;
}
```

验证：

```shell
curl -k -I https://www.example.com/path
```

边界：证书必须覆盖 `www` 和裸域，或者使用通配符证书；跳转目标不要又跳回 `www`，否则会循环。

### 维护页面

**问题**：发布或故障时需要暂时返回 503，并告诉客户端稍后重试，而不是直接断开。

```nginx
server {
    listen 80;
    server_name example.com;
    root /srv/www;

    location / {
        return 503;
    }

    location = /maintenance.html {
        internal;
    }

    error_page 503 /maintenance.html;
    add_header Retry-After 3600 always;
}
```

验证：

```shell
curl -i http://example.com/
```

预期 503、维护页正文和 `Retry-After`。边界：`error_page` 的页面要 `internal`，避免用户直接打开；维护页不要依赖后端。

### 拒绝隐藏文件，放行 ACME

**问题**：`.git`、`.env`、编辑器备份文件不应被 Web 访问，但 Let's Encrypt 的 challenge 需要放行。

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
}

location ~ /\. {
    deny all;
}
```

验证：

```shell
curl -i https://example.com/.env
curl -i https://example.com/.well-known/acme-challenge/test
```

边界：`^~` 让 `.well-known` 前缀跳过后面的隐藏文件正则；顺序不能反。不要用 `location ~ /\.` 把 ACME 一起拒绝。

### 后台 IP 限制加 Basic Auth

**问题**：`/admin/` 只允许办公网访问，并且再加一层密码。

```nginx
location /admin/ {
    allow 10.0.0.0/8;
    allow 192.168.0.0/16;
    deny all;

    auth_basic           "Admin";
    auth_basic_user_file /etc/nginx/.htpasswd;

    proxy_pass http://admin_backend/;
}
```

验证：

```shell
curl -i https://example.com/admin/
```

边界：`allow`/`deny` 按顺序匹配；IP 允许列表不是身份认证，NAT 后所有人共享来源 IP。Basic Auth 必须配 HTTPS，密码文件放在 Web 根目录之外。

### CORS

**问题**：前端在 `https://app.example.com`，API 在 `https://api.example.com`，浏览器需要 **CORS**(Cross-Origin Resource Sharing, 跨源资源共享)。

```nginx
location /api/ {
    add_header Access-Control-Allow-Origin "https://app.example.com" always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;
    add_header Access-Control-Max-Age 600 always;

    if ($request_method = OPTIONS) {
        return 204;
    }

    proxy_pass http://api_backend/;
}
```

验证：

```shell
curl -i -X OPTIONS -H 'Origin: https://app.example.com' https://api.example.com/api/
```

边界：CORS 不是认证；不要反射任意 `Origin`，带凭据时不能用 `*`。如果上游也返回 CORS 头，可能重复，需要用 `proxy_hide_header` 去掉一侧。

### WebSocket

**问题**：`/ws/` 需要升级为 WebSocket 长连接。

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

location /ws/ {
    proxy_pass http://ws_backend/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 3600s;
}
```

验证：用浏览器或 WebSocket 客户端连接 `wss://example.com/ws/`。边界：`proxy_read_timeout` 要覆盖空闲时间；不要开启 `proxy_buffering`；上游也要支持 Upgrade。

### SSE 与流式响应

**问题**：`/events/` 需要用 **SSE**(Server-Sent Events, 服务器发送事件) 持续推送，不能被 nginx 攒批。

```nginx
location /events/ {
    proxy_pass http://api_backend/events/;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 1h;
    add_header X-Accel-Buffering no;
}
```

验证：

```shell
curl -N https://example.com/events/
```

边界：`add_header` 会覆盖 server 级安全头，必要时在该 location 重复安全头；上游也要逐条 flush。长连接会占用 worker 连接数，容量要单独评估。

### 大文件上传

**问题**：默认 1m 的请求体限制会挡住上传。

```nginx
location /upload/ {
    client_max_body_size 100m;
    proxy_request_buffering off;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_pass http://upload_backend/;
}
```

验证：用小文件和大文件各测一次，确认 413 边界和上游超时。边界：放宽范围要尽量小，必须配合认证、限速、文件类型校验和存储配额；`proxy_request_buffering off` 会改变重试和错误处理行为。

### 下载附件

**问题**：浏览器打开 PDF/图片，而不是下载。

```nginx
location ^~ /download/ {
    alias /srv/files/;
    add_header Content-Disposition "attachment" always;
    add_header X-Content-Type-Options "nosniff" always;
}
```

验证：

```shell
curl -I https://example.com/download/report.pdf
```

边界：`alias` 末尾斜杠要和 location 对应；如果要指定文件名，需要动态生成 `Content-Disposition`，注意转义和头注入。`add_header` 覆盖了 server 级安全头，示例里重复了需要的头。

### 公共 API 微缓存

**问题**：一个公开、更新不频繁的 API 被大量重复请求，希望缓存几秒。

```nginx
proxy_cache_path /var/cache/nginx/api levels=1:2 keys_zone=api_cache:10m
                 max_size=1g inactive=10m use_temp_path=off;

location /api/public/ {
    proxy_cache api_cache;
    proxy_cache_valid 200 10s;
    proxy_cache_key "$scheme$request_method$host$request_uri";
    proxy_cache_lock on;
    add_header X-Cache-Status $upstream_cache_status always;
    proxy_pass http://api_backend/public/;
}
```

验证：

```shell
curl -s -D - -o /dev/null https://example.com/api/public/config | grep -i x-cache-status
```

边界：只缓存公共数据；带用户身份、Cookie、`Authorization` 的响应不要缓存。缓存键要包含所有影响内容的维度；`max_size` 和磁盘权限要配置好。

### 健康检查端点

**问题**：负载均衡器或容器编排需要一个轻量健康检查，不写访问日志。

```nginx
location = /healthz {
    access_log off;
    default_type text/plain;
    return 200 "ok\n";
}
```

验证：

```shell
curl -i http://127.0.0.1/healthz
```

边界：这个端点只证明 nginx 在运行，不证明上游健康。需要上游健康时，用单独的 `/readyz` 代理到上游，并限制访问；不要让健康检查暴露内部依赖细节。

### Docker DNS 动态上游

**问题**：容器重启后 IP 变化，nginx 仍连旧地址。

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;

upstream api_backend {
    zone api_backend 64k;
    server api1:8000 resolve;
    server api2:8000 resolve;
}
```

验证：重启一个 API 容器，观察 nginx 是否在 TTL 后连到新地址。边界：`resolve` 需要 nginx 1.27.3+；旧版本用 reload 或变量形式的 `proxy_pass`。`resolver 127.0.0.11` 是 Docker 内置 DNS，非 Docker 环境要换成实际 DNS。

### JSON 访问日志

**问题**：需要把访问日志送进日志平台，按字段检索。

```nginx
log_format json escape=json
    '{"time":"$time_iso8601",'
    '"remote":"$remote_addr",'
    '"method":"$request_method",'
    '"uri":"$request_uri",'
    '"status":$status,'
    '"request_time":$request_time,'
    '"upstream":"$upstream_addr",'
    '"upstream_time":"$upstream_response_time"}';

access_log /var/log/nginx/access.json json;
```

验证：

```shell
tail -n 1 /var/log/nginx/access.json
```

边界：`$request_uri` 可能包含敏感查询参数；日志权限和保留周期要管理。不要把整个 Authorization/Cookie 头写进日志。

### 旧路径跳转

**问题**：站点改版后，旧链接需要 301 到新路径，并保留子路径。

```nginx
location ^~ /old/ {
    rewrite ^/old/(.*)$ /new/$1 permanent;
}
```

验证：

```shell
curl -I https://example.com/old/a/b?x=1
```

边界：简单固定跳转优先用 `return 301 /new/;`；`rewrite` 适合需要捕获组的场景。小心新路径又匹配同一条规则，造成循环；用 `rewrite_log on;` 调试。

### 登录接口限速

**问题**：登录接口被暴力尝试，需要按 IP 限速，但不能影响正常用户太多。

```nginx
limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;

location = /login {
    limit_req zone=login burst=5 nodelay;
    limit_req_status 429;
    proxy_pass http://auth_backend/login;
}
```

验证：快速请求 10 次，观察 429；再用正常节奏请求，确认不受影响。边界：NAT 后很多用户共享 IP；登录限速应配合账号锁定、验证码、MFA 和日志告警，不能只靠 IP。

### 配方的组合顺序

组合多个配方时，先确认三件事：

- **location 的优先级**：`=`、`^~`、正则、普通前缀，谁先命中。
- **`add_header` 的继承**：子层级一旦写 `add_header`，server 级的安全头不会自动带过去。
- **`error_page` 与内部跳转**：错误页建议加 `internal`，避免被直接访问。

配方是起点，不是生产配置的完整答案。上线前用 `nginx -t`、`nginx -T`、`curl -I` 和真实客户端验证，并检查日志里是否出现新的 4xx/5xx。
