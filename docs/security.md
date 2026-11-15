## 安全基础

nginx 站在入口处，能做很多安全相关的事：**TLS**(Transport Layer Security, 传输层安全) 终止、隐藏版本、限制方法、限制请求体、限速、访问控制、加安全响应头。但它不是 **WAF**(Web Application Firewall, Web 应用防火墙)，也不能替代应用层的输入校验、认证授权和补丁管理。这一章按“能落地的入口加固”来讲，不追求堆满所有模块。

### 先明确威胁模型

不同站点的风险不同。先问：

- 谁能访问这个入口？公网、内网、仅本机？
- 最坏的后果是什么？数据泄露、被刷接口、被上传大文件、被暴力破解、服务不可用？
- 哪些防护应该在 nginx 做，哪些必须由应用、数据库、CDN 或 WAF 做？

nginx 适合做**统一的入口策略**，例如所有站点都加安全头、所有登录接口都限速、所有上传都限制大小。业务权限、SQL 注入、越权访问不能靠 nginx 配置解决。

### 隐藏版本与响应头

```nginx
server_tokens off;
```

它隐藏 nginx 版本号，但响应里通常仍有 `Server: nginx`。要完全移除 `Server` 头，需要 `headers-more` 模块（OpenResty 常带）或在上游/CDN 层处理：

```nginx
more_clear_headers Server;
```

也可以隐藏上游暴露的技术信息：

```nginx
proxy_hide_header X-Powered-By;
proxy_hide_header Server;
```

隐藏版本只是降低信息暴露，不是安全边界。真正重要的是及时打补丁。

### 安全响应头

实验的共享片段：

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
```

| 头 | 作用 | 注意 |
| --- | --- | --- |
| `X-Content-Type-Options: nosniff` | 禁止浏览器猜测 MIME 类型 | 防止把文本当脚本执行 |
| `X-Frame-Options` | 控制是否允许被 iframe 嵌入 | `SAMEORIGIN` 允许同源；`DENY` 更严格 |
| `Referrer-Policy` | 控制 Referer 泄露多少 | 外链多时选合适策略 |
| `Permissions-Policy` | 限制地理位置、摄像头、麦克风等 | 按业务需要开启 |
| `Strict-Transport-Security` | 强制 HTTPS | 只在 HTTPS 响应中生效，见 HTTPS 章节 |

**CSP**(Content Security Policy, 内容安全策略)很强，但也很容易把站点打挂：

```nginx
add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'" always;
```

上线前先用 `Content-Security-Policy-Report-Only` 收集报告，确认不会阻断正常脚本、样式、字体和第三方接口，再切换到强制模式。不要从别处复制一条 CSP 就直接上生产。

`add_header` 的继承是“覆盖”而不是“追加”。如果某个 `location` 自己写了 `add_header`，server 级的安全头不会自动带过去。可以在该 location 重复 include 安全头片段，或使用支持继承控制的模块/指令。

### 访问控制与方法限制

按 IP 放行：

```nginx
location /admin/ {
    allow 10.0.0.0/8;
    allow 192.168.0.0/16;
    deny all;
}
```

规则按顺序匹配，第一条命中就生效；`deny all;` 放最后。IP 允许列表不是身份认证：同一 NAT 后的所有人都共享来源 IP，IP 也可能被伪造或代理。敏感后台应叠加认证、VPN 或零信任访问。

限制方法：

```nginx
location /api/ {
    limit_except GET POST {
        deny all;
    }
}
```

`limit_except` 只允许列出的方法，其他方法返回 403。注意 `OPTIONS`、CORS 预检和健康检查可能需要单独放行；`HEAD` 的处理还要按实际版本和测试结果确认，不要一刀切把正常客户端挡掉。

### Basic Auth

适合临时保护测试环境、内部工具或低风险后台：

```nginx
location /admin/ {
    auth_basic           "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;
}
```

生成密码文件：

```shell
htpasswd -c /etc/nginx/.htpasswd alice
```

有些 Alpine 镜像没有 `htpasswd`，可以安装 `apache2-utils`，或用 `openssl passwd -apr1` 生成哈希后手动写入。密码文件必须放在 Web 根目录之外，不能通过 URL 访问；Basic Auth 必须配合 HTTPS，否则密码只是 Base64，不是加密。

用户多、需要单点登录、**MFA**(Multi-Factor Authentication, 多因素认证) 或细粒度权限时，Basic Auth 不够。可以用 `auth_request` 子请求接认证服务，或在 OpenResty/网关层做 **JWT**(JSON Web Token) 与 **OIDC**(OpenID Connect) 校验。

### 限速与连接限制

实验配置：

```nginx
limit_req_zone  $binary_remote_addr zone=api_limit:10m rate=5r/s;
limit_conn_zone $binary_remote_addr zone=api_conn:10m;

location = /api/limited {
    limit_req zone=api_limit burst=3 nodelay;
    limit_req_status 429;
    limit_conn api_conn 5;
    limit_conn_status 429;
}
```

- `rate=5r/s` 是平均速率；`burst=3` 允许短时突发 3 个请求。
- `nodelay` 让突发请求立即处理，而不是排队延迟；超出部分返回 429。
- 不加 `nodelay` 时，超出速率的请求会被延迟，可能表现为“变慢”而不是 429。
- `limit_conn` 限制同一 key 的并发连接数，适合慢连接、下载或登录接口。
- 两个 zone 都按 `$binary_remote_addr` 计数；NAT 后很多用户共享 IP，可能误伤。
- 限速状态码可以改成 503，但 429 更符合“请求过多”的语义。

限速不是 **DDoS**(Distributed Denial of Service, 分布式拒绝服务) 防护。攻击者可以用大量 IP、慢连接或分布式流量绕过单机限速；真正的大流量攻击需要 **CDN**(Content Delivery Network, 内容分发网络)、WAF、清洗中心或云厂商防护。

### 请求体与超时

```nginx
client_max_body_size 1m;
client_body_timeout   10s;
client_header_timeout 10s;
send_timeout          30s;
```

- `client_max_body_size` 限制请求体，超出返回 413。按业务最大上传大小设置，不要为了“省事”设成无限。
- `client_body_timeout` 限制两次读请求体之间的间隔；`client_header_timeout` 限制读请求头的时间。它们可以缓解慢速攻击，但设得太短会误伤慢网络用户。
- `send_timeout` 限制两次写响应之间的间隔，不是整个响应时间。

上传接口可以单独放宽：

```nginx
location /upload/ {
    client_max_body_size 100m;
    proxy_request_buffering off;
}
```

放宽范围要尽量小，并配合认证、限速、文件类型校验和存储配额。

### TLS 加固

基础配置：

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
```

- 禁用 TLS 1.0/1.1；只保留 1.2 和 1.3。
- 密码套件优先使用现代配置；TLS 1.3 的套件由协议决定，不受 `ssl_ciphers` 完全控制。
- 私钥权限收紧，证书和私钥不要进 Git。
- 证书到期监控和自动续期要做，过期证书会让站点直接不可用。
- 需要双向认证时，配置 `ssl_client_certificate` 和 `ssl_verify_client on;`，并把验证结果传给上游；不要只在客户端做“有没有证书”的判断。

### 不要把这些放进配置

- 数据库密码、API Key、JWT 密钥、云厂商 Access Key。
- 真实用户的密码、Token、Cookie。
- 生产私钥和完整证书链（证书可以公开，但私钥不行；仓库里仍不建议放生产证书）。
- 包含敏感查询串的访问日志。

配置需要秘密时，用环境变量、模板渲染或密钥管理服务在部署时注入；不要把秘密写进镜像层或 Git 历史。访问日志如果记录了 `$request_uri`，要确认 URL 里不会出现 Token、重置密码链接等敏感信息。

### CORS 不是访问控制

```nginx
location /api/ {
    add_header Access-Control-Allow-Origin "https://app.example.com" always;
    add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Content-Type, Authorization" always;

    if ($request_method = OPTIONS) {
        return 204;
    }
}
```

**CORS**(Cross-Origin Resource Sharing, 跨源资源共享) 是浏览器的同源策略机制，不是服务端认证。不要因为设置了 CORS 就认为接口安全；也不要为了方便反射任意 `Origin`，尤其是带 `Access-Control-Allow-Credentials` 时。需要跨域凭据时，`Access-Control-Allow-Origin` 不能是 `*`，并且要严格校验来源。

### 安全检查清单

- [ ] 及时更新 nginx 和 OpenSSL，关注安全公告。
- [ ] `server_tokens off;`，隐藏不必要的上游技术头。
- [ ] 全站 HTTPS，HTTP 跳转；HSTS 在验证后逐步加长。
- [ ] 安全响应头按站点需要配置，CSP 先 report-only。
- [ ] 敏感路径有认证、IP 限制或 VPN，不能只靠隐藏 URL。
- [ ] 登录、上传、搜索等高风险接口有限速和请求体限制。
- [ ] `stub_status`、调试端点、管理端口不暴露公网。
- [ ] 证书自动续期，到期有监控。
- [ ] 访问日志不含敏感信息，日志文件权限合理。
- [ ] 配置、证书私钥、密钥不进入 Git。
- [ ] 知道 nginx 不是 WAF；需要时在 CDN/WAF/应用层补足。

### 实验

检查安全头：

```shell
curl -I http://localhost:8080/
curl -I http://localhost:8080/assets/style.css
```

确认 `X-Content-Type-Options`、`X-Frame-Options`、`Referrer-Policy`、`Permissions-Policy` 存在。

检查版本隐藏：

```shell
curl -I http://localhost:8080/ | grep -i '^server:'
```

预期只看到 `Server: nginx`，没有版本号。

触发限速：

```shell
for i in {1..12}; do
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8082/api/limited
done
```

应该看到若干 429。

触发请求体限制：

```shell
dd if=/dev/zero bs=1024 count=2048 2>/dev/null \
  | curl -i -X POST --data-binary @- http://localhost:8082/api/echo
```

应该返回 413。

检查隐藏文件：

```shell
printf 'secret' > labs/site/.secret
curl -i http://localhost:8080/.secret
rm labs/site/.secret
```

应该返回 403。

### 练习

- 为什么 `deny all;` 要放在 `allow` 规则之后？如果顺序反过来会怎样？
- Basic Auth 为什么要配合 HTTPS？Base64 编码和加密有什么区别？
- 限速为什么不能替代 DDoS 防护？攻击者可以用哪些方式绕过按 IP 的限速？
- 写一条规则，只允许 `GET` 和 `POST` 访问 `/api/`，其他方法返回 403。再说明 `OPTIONS` 预检是否需要额外放行。

<details>
<summary>参考答案</summary>

- nginx 的 `allow`/`deny` 按顺序匹配，第一条命中即生效。如果 `deny all;` 在最前面，后面的 `allow` 永远不会被检查，所有请求都被拒绝。
- Basic Auth 的密码只做 Base64 编码，不是加密；没有 TLS 时，中间人可以直接解码。HTTPS 才能保护传输中的凭据。
- 单机限速按 IP 或连接计数，攻击者可以用大量 IP、代理池、慢连接或分布式流量绕过；真正的 DDoS 需要上游清洗、CDN/WAF 和容量冗余。
- 片段：`location /api/ { limit_except GET POST { deny all; } }`。CORS 预检使用 `OPTIONS`，如果浏览器需要跨域调用，通常要单独放行 `OPTIONS` 并返回 204；否则预检会 403，实际请求不会发出。

</details>
