## HTTPS 与证书

HTTPS 不是“给 nginx 加一行 `ssl` 就完了”。它涉及证书、私钥、域名匹配、证书链、协议版本和浏览器信任。这一章先建立 TLS 的最小模型，再用自签名证书把实验跑通，最后说明生产环境怎样用 Let's Encrypt 签发和续期。

### TLS 在保护什么

**TLS**(Transport Layer Security, 传输层安全)在 TCP 之上建立一条加密通道，主要提供：

- **机密性**：中间人看不到明文请求和响应。
- **完整性**：传输中的内容被篡改会被发现。
- **身份认证**：客户端通过证书确认自己连的是哪个域名对应的服务端。

一次简化的握手：

1. 客户端连接服务器的 443（或实验的 8443）端口，发送支持的协议版本、加密套件和 **SNI**(Server Name Indication, 服务器名称指示)。
2. 服务器选择证书和参数，返回证书链。
3. 客户端验证证书：域名是否匹配、是否过期、是否由受信任的 CA 签发、链是否完整。
4. 双方协商出会话密钥，之后的 HTTP 数据用对称加密传输。

证书里最重要的是：

- **主题/SAN**：证书对哪些域名或 IP 有效。现代浏览器主要看 **SAN**(Subject Alternative Name, 主题备用名称)，不再只看 CN。
- **有效期**：过期后浏览器直接报错。
- **签发者**：受信任的 CA，或者自签名。
- **公钥**：与服务器持有的私钥配对。

私钥必须保密。证书可以公开，私钥不能进 Git、不能写进前端、不能通过日志泄露。

### 实验配置

`labs/nginx/conf.d/30-https.conf` 的核心：

```nginx
server {
    listen 8443 ssl;
    http2 on;
    server_name localhost;

    ssl_certificate     /etc/nginx/certs/lab.crt;
    ssl_certificate_key /etc/nginx/certs/lab.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=300" always;
}
```

要点：

- `listen 8443 ssl;` 让这个 server 只在 TLS 上监听。实验把宿主机 `8443` 映射到容器 `8443`。
- `http2 on;` 是 nginx 1.25.1 之后的写法；旧写法 `listen 8443 ssl http2;` 已不推荐。
- `ssl_certificate` 是证书（通常包含服务器证书和中间证书），`ssl_certificate_key` 是私钥。
- `ssl_protocols` 只保留 TLS 1.2 和 1.3；更老的协议不应再启用。
- `ssl_session_cache` 复用会话，减少重复握手；`ssl_session_tickets off` 关闭会话票据，减少票据密钥管理的复杂度。
- HSTS 让浏览器以后强制用 HTTPS 访问；实验只设 300 秒，避免自签名证书把浏览器“锁”太久。

证书和私钥由脚本生成：

```shell
bash scripts/gen-cert.sh
```

脚本会写入 `labs/nginx/certs/lab.crt` 和 `lab.key`，并设置 SAN 为 `localhost` 和 `127.0.0.1`。这两个文件已被 `.gitignore` 忽略。

### 自签名证书与受信任证书

| 类型 | 谁签发 | 浏览器是否信任 | 适用 |
| --- | --- | --- | --- |
| 自签名 | 自己 | 默认不信任，需要手动例外 | 本地实验、内部测试 |
| 内部 CA | 组织自己的 CA | 只有安装了 CA 的客户端信任 | 企业内网 |
| 公共 CA | Let's Encrypt、DigiCert 等 | 通常信任 | 公网服务 |

自签名证书没有第三方背书，浏览器无法确认“这个服务器真的是 localhost”。实验里点“继续访问”只代表你接受风险，不代表证书可信。

查看证书内容：

```shell
openssl x509 -in labs/nginx/certs/lab.crt -noout -subject -issuer -dates -ext subjectAltName
```

预期能看到 `CN=localhost`、有效期和 `DNS:localhost, IP Address:127.0.0.1`。

### HTTP 跳转到 HTTPS

实验在静态站点上提供了一个演示入口：

```nginx
location = /https-redirect {
    return 301 https://$host:8443/;
}
```

请求：

```shell
curl -I http://localhost:8080/https-redirect
```

会看到 301 和指向 `https://...:8443/` 的 `Location`。生产环境通常是整个站点的 HTTP server 都跳转：

```nginx
server {
    listen 80;
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

注意：

- `$host` 通常不含端口；如果 HTTPS 不在 443，需要显式写端口或使用 `$server_port` 之外的变量。
- `$request_uri` 保留原始路径和查询串，避免跳转后丢失参数。
- 如果 nginx 前面还有一层代理，`$scheme` 可能是 `http`。这时要根据可信代理传来的 `X-Forwarded-Proto` 判断，不能直接信任任意客户端发送的头。
- 跳转规则写错可能造成重定向循环；用 `curl -I` 看 `Location`，再用浏览器开发者工具确认最终地址。

### HSTS

**HSTS**(HTTP Strict Transport Security, HTTP 严格传输安全)通过响应头告诉浏览器：以后访问这个域名时，直接走 HTTPS，不要先尝试 HTTP。

```nginx
add_header Strict-Transport-Security "max-age=31536000" always;
```

可选参数：

- `includeSubDomains`：所有子域也强制 HTTPS。启用前确认每个子域都有有效证书。
- `preload`：申请加入浏览器预加载列表。门槛高、退出慢，生产环境要非常谨慎。

HSTS 只在 HTTPS 响应中生效；浏览器会缓存 `max-age`。如果证书配置错误，用户可能在一段时间内完全打不开站点。先在实验环境用短 `max-age` 验证，再逐步增加。

### Let's Encrypt 与 ACME

**Let's Encrypt** 是一个公共 CA，通过 **ACME**(Automatic Certificate Management Environment, 自动证书管理环境)协议签发免费证书。常见验证方式：

- **HTTP-01**：CA 访问 `http://域名/.well-known/acme-challenge/<token>`，确认你控制这个域名。需要 80 端口可达，且 nginx 能返回 challenge 文件。
- **DNS-01**：在 DNS 里添加 TXT 记录，适合通配符证书和 80 端口不可达的场景。
- **TLS-ALPN-01**：在 443 上通过特殊 ALPN 完成验证，使用较少。

Certbot 的 webroot 方式：

```shell
sudo certbot certonly --webroot -w /var/www/certbot -d example.com -d www.example.com
```

nginx 需要为 challenge 目录放行，且不要被隐藏文件规则拦住：

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
}
```

证书签发后，在 nginx 里引用：

```nginx
ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;
```

续期与重载：

```shell
sudo certbot renew --dry-run
sudo certbot renew --deploy-hook "nginx -t && nginx -s reload"
```

`fullchain.pem` 包含服务器证书和中间证书，通常比只引用 `cert.pem` 更可靠。私钥 `privkey.pem` 权限应尽量收紧。不要把 `/etc/letsencrypt/` 整个目录提交到仓库。

### 常见 TLS 错误

| 现象 | 常见原因 | 排查 |
| --- | --- | --- |
| 浏览器提示证书名称不匹配 | 证书 SAN 没有当前域名 | `openssl x509 -text` 看 SAN |
| 证书已过期 | 未续期或系统时间错误 | 看 `notAfter` 和服务器时间 |
| 证书链不完整 | 只配置了服务器证书，缺中间证书 | 用 `fullchain.pem` 或补齐链 |
| `SSL_ERROR_RX_RECORD_TOO_LONG` | 用 HTTPS 访问了 HTTP 端口 | 检查端口和 `listen ... ssl` |
| `too many redirects` | HTTP/HTTPS 跳转规则循环 | `curl -I` 逐跳看 `Location` |
| `403` 出现在 ACME 验证 | `.well-known` 被隐藏文件规则拒绝 | 单独放行 challenge 目录 |
| 502/504 出现在 HTTPS 站点 | TLS 正常，但上游失败 | 看 error.log 的 upstream 错误 |

用 OpenSSL 直接观察握手：

```shell
echo | openssl s_client -connect localhost:8443 -servername localhost -brief
```

`-servername` 模拟 SNI；`-brief` 输出摘要。自签名证书会显示验证失败，这是预期结果。要看完整证书链时去掉 `-brief`，或加 `-showcerts`。

### 实验

重新生成证书并查看：

```shell
bash scripts/gen-cert.sh --force
openssl x509 -in labs/nginx/certs/lab.crt -noout -subject -issuer -dates -ext subjectAltName
```

访问 HTTPS：

```shell
curl -k -i https://localhost:8443/
curl -k -I https://localhost:8443/assets/style.css
```

`-k` 表示跳过证书验证，只用于本地实验。检查响应头里是否有：

- `Strict-Transport-Security: max-age=300`
- `X-Content-Type-Options: nosniff`

测试 HTTP 跳转：

```shell
curl -I http://localhost:8080/https-redirect
```

测试协议版本：

```shell
echo | openssl s_client -connect localhost:8443 -servername localhost -tls1_2 -brief
```

如果客户端和 OpenSSL 支持，TLS 1.2 应能握手；TLS 1.1 及以下应失败，因为配置只允许 1.2 和 1.3。

### 练习

- 为什么浏览器打开 `https://localhost:8443/` 会警告，而 `curl -k` 能正常返回？`-k` 跳过了哪一步？
- 证书的 SAN 里为什么同时需要 `localhost` 和 `127.0.0.1`？只写 CN 是否足够？
- 生产环境启用 HSTS 前，为什么要先确认所有子域都有 HTTPS？如果某个子域没有证书会发生什么？
- 写一条 HTTP 到 HTTPS 的跳转规则，要求保留原始路径和查询串。再用 `curl -I` 验证 `Location`。

<details>
<summary>参考答案</summary>

- 浏览器会验证证书是否由受信任的 CA 签发、域名是否匹配、是否过期、链是否完整；自签名证书没有受信任的签发者，所以警告。`curl -k` 跳过了证书验证，因此能拿到内容，但这不代表连接可信。
- 因为客户端可能用 `https://localhost:8443/` 或 `https://127.0.0.1:8443/` 访问；SAN 要覆盖实际使用的名字/IP。现代浏览器主要看 SAN，只有 CN 不足以覆盖所有客户端和场景。
- HSTS 会让浏览器在一段时间内强制使用 HTTPS。如果某个子域没有有效证书，用户会直接看到证书错误，无法回退到 HTTP；`includeSubDomains` 会放大这个影响。
- 片段：`return 301 https://$host$request_uri;`。用 `curl -I 'http://example.com/a?b=1'` 检查 `Location` 是否保留 `/a?b=1`；实验里把域名和端口换成实际值。

</details>
