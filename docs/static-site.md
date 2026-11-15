## 静态站点

静态站点是 nginx 最基础也最常用的能力：把磁盘上的文件按 URI 返回给浏览器。看起来只是 `root` 加 `index`，但缓存、压缩、错误页、MIME 和权限都会影响“文件明明存在，为什么浏览器拿到的不是想要的东西”。

### 一个请求怎样变成文件

实验里的静态站点配置可以简化成：

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
```

请求 `/about.html` 时：

1. `location /` 匹配。
2. `try_files` 先检查 `$uri`，也就是 `/usr/share/nginx/html/about.html`。
3. 文件存在，返回它。
4. 根据扩展名设置 `Content-Type`，并写访问日志。

请求 `/` 时，`$uri` 是 `/`，`$uri/` 是目录；`index index.html;` 让 nginx 在这个目录下找 `index.html`。

### root、index 与目录

`root` 指定文档根目录，URI 会原样拼在后面：

| 请求 | `root /usr/share/nginx/html;` 对应的文件 |
| --- | --- |
| `/` | `/usr/share/nginx/html/index.html`（由 `index` 补全） |
| `/about.html` | `/usr/share/nginx/html/about.html` |
| `/assets/style.css` | `/usr/share/nginx/html/assets/style.css` |
| `/app/` | `/usr/share/nginx/html/app/index.html`（由 `index` 补全） |

请求一个真实目录但没有尾斜杠时，`index` 模块通常会返回 301，让浏览器跳到带斜杠的地址。例如 `/app` 可能跳到 `/app/`，再由 `index` 返回 `app/index.html`。这是正常行为，不是配置错误。

`autoindex on;` 可以列出目录内容，但生产环境通常关闭。目录列表会暴露文件名、备份文件和内部结构；实验配置没有开启它。

### MIME 类型

浏览器根据 `Content-Type` 决定怎样处理响应。**MIME**(Multipurpose Internet Mail Extensions, 多用途互联网邮件扩展) 类型告诉浏览器这是 HTML、CSS、图片还是其他内容；nginx 通过 `mime.types` 建立扩展名到类型的映射：

```nginx
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
}
```

实验主配置还设置了：

```nginx
charset utf-8;
```

这会影响文本类响应的字符集声明。HTML 自己也可以用 `<meta charset="utf-8">` 声明；两者最好一致。

如果 CSS 被返回成 `application/octet-stream`，浏览器可能拒绝把它当样式表使用，控制台会报 MIME 类型错误。先看 `curl -I` 的 `Content-Type`，再检查 `mime.types` 是否被 include、扩展名是否拼错。

### try_files 与错误页

实验的静态站点使用：

```nginx
location / {
    try_files $uri $uri/ =404;
}

location = /404.html {
    internal;
}

error_page 404 /404.html;
```

`try_files` 依次检查文件、目录，都没有就返回 404。`error_page` 把 404 的响应体换成 `404.html`，但状态码仍然是 404。`internal` 表示这个页面只能由 nginx 内部跳转访问，客户端直接请求 `/404.html` 会得到 404，而不是一个可以单独打开的页面。

可以用下面的命令验证状态码和响应体：

```shell
curl -i http://localhost:8080/missing
curl -i http://localhost:8080/404.html
```

### 缓存响应头

静态资源适合缓存，但 HTML 通常不适合长缓存。实验配置对 CSS、JS、图片等设置了：

```nginx
location ~* \.(?:css|js|mjs|svg|png|jpe?g|gif|ico|woff2?)$ {
    expires 1h;
    access_log off;
    try_files $uri =404;
}
```

`expires 1h;` 会生成 `Expires` 和 `Cache-Control: max-age=3600`。浏览器在有效期内可以直接用本地缓存，不必再问服务器。

常见策略：

| 资源 | 建议 | 原因 |
| --- | --- | --- |
| 带内容哈希的 JS/CSS | 长缓存，例如 `expires 1y;` | 文件名变了就是新资源，可以放心缓存 |
| 不带哈希的图片/字体 | 中等缓存，例如 `expires 7d;` | 更新后可能仍被旧缓存命中 |
| HTML | 短缓存或不缓存 | 需要尽快看到新页面和新资源引用 |
| API JSON | 由业务决定 | 可能包含用户相关数据，不能盲目公共缓存 |

如果资源文件名不带哈希，长缓存会导致更新后用户仍看旧文件。这时需要改文件名、加查询串，或者缩短缓存时间。

nginx 对静态文件默认会发送 `ETag` 和 `Last-Modified`。浏览器再次请求时带 `If-None-Match` 或 `If-Modified-Since`，文件没变就返回 304，不传正文。可以这样观察：

```shell
etag=$(curl -sI http://localhost:8080/assets/style.css | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r')
curl -i -H "If-None-Match: $etag" http://localhost:8080/assets/style.css
```

预期状态码是 `304 Not Modified`。

`expires` 和 `add_header Cache-Control` 不要重复设置同一个头。`add_header` 的继承规则还会覆盖 server 级安全头；实验配置在资源 location 里只用 `expires`，就是为了避免这个问题。

### gzip 压缩

文本资源压缩后体积通常明显变小。实验主配置：

```nginx
gzip on;
gzip_vary on;
gzip_min_length 256;
gzip_comp_level 5;
gzip_types text/plain text/css text/javascript application/javascript application/json application/xml image/svg+xml;
```

要点：

- `text/html` 默认就会被压缩，不需要在 `gzip_types` 里重复列。
- 图片、视频、压缩包通常已经压缩过，再 gzip 收益很小，甚至变大。
- `gzip_vary on;` 会发送 `Vary: Accept-Encoding`，告诉缓存服务器同一个 URL 可能有压缩和非压缩两个版本。
- `gzip_min_length` 避免压缩太小的响应，减少 CPU 和头部开销。
- `gzip_comp_level` 越高越耗 CPU；静态站点通常 5 左右够用，具体要测量。

检查：

```shell
curl -I -H 'Accept-Encoding: gzip' http://localhost:8080/assets/style.css
```

响应头应包含 `Content-Encoding: gzip` 和 `Vary: Accept-Encoding`。如果不带 `Accept-Encoding` 请求，通常不会压缩。

`gzip_static on;` 可以优先发送预压缩的 `.gz` 文件，适合构建时生成压缩产物的站点；它需要模块支持，不是所有构建都默认包含。

### sendfile 与文件传输

主配置里的：

```nginx
sendfile on;
tcp_nopush on;
tcp_nodelay on;
```

让 nginx 在合适的平台上用更高效的方式发送文件。`sendfile` 减少用户态和内核态之间的数据复制；`tcp_nopush` 和 `tcp_nodelay` 影响 TCP 包的发送时机。它们不是“越大越好”的开关，默认配置通常已经适合大多数静态站点。

大文件下载还可以关注：

- `output_buffers`、`sendfile_max_chunk`：控制单次发送的块大小。
- `aio`：某些平台上的异步文件 I/O，需要结合系统支持。
- `open_file_cache`：缓存文件描述符和元数据，适合大量重复访问的静态文件；配置不当会延迟文件更新生效。

初学阶段先把 `sendfile on;` 和合理的缓存头做好，不要一开始就堆性能参数。

### 隐藏文件与权限

实验配置：

```nginx
location ~ /\. {
    deny all;
}
```

它会拒绝 `/.git`、`/.env`、`/.secret` 这类路径。注意这个正则会连 `/.well-known/acme-challenge/` 一起拒绝；如果要用 ACME HTTP-01 签发证书，需要为这个目录单独放行。

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/certbot;
}
```

权限问题也很常见。nginx worker 需要对文件有读权限，对所在目录有执行权限。文件存在但返回 403 时，先看：

```shell
docker compose -f labs/compose.yaml exec nginx ls -l /usr/share/nginx/html
docker compose -f labs/compose.yaml exec nginx id
```

再对照 error.log 里的 `Permission denied`。SELinux、容器挂载权限和 Windows 共享目录也可能造成类似现象，排查时要分清是文件权限、目录权限还是安全策略。

### 实验

查看首页和资源：

```shell
curl -I http://localhost:8080/
curl -I http://localhost:8080/assets/style.css
curl -I http://localhost:8080/about.html
```

检查 404、内部错误页和隐藏文件：

```shell
curl -i http://localhost:8080/missing
curl -i http://localhost:8080/404.html

printf 'secret' > labs/site/.secret
curl -i http://localhost:8080/.secret
rm labs/site/.secret
```

检查压缩和范围请求：

```shell
curl -I -H 'Accept-Encoding: gzip' http://localhost:8080/assets/style.css
curl -s -o /dev/null -w '%{http_code}\n' -r 0-99 http://localhost:8080/assets/style.css
```

范围请求正常时返回 `206 Partial Content`。

做一个目录列表实验：

1. 在 `00-static.conf` 增加：

   ```nginx
   location ^~ /listing/ {
       alias /usr/share/nginx/html/assets/;
       autoindex on;
   }
   ```

2. reload 后请求 `http://localhost:8080/listing/`，观察目录列表。
3. 把 `autoindex on;` 改成 `autoindex off;`，再请求一次。生产环境通常保持关闭。

### 练习

- 请求 `/assets/style.css`，记录 `Content-Type`、`Cache-Control`、`ETag` 和 `Last-Modified`。再用 `If-None-Match` 请求一次，确认 304。
- 为什么直接请求 `/404.html` 返回 404，而不是显示错误页内容？如果去掉 `internal` 会怎样？
- 写一个 location，让 `/download/` 下的文件强制以附件形式下载。提示：`add_header Content-Disposition "attachment"`。
- 把 CSS 的缓存时间改成 1 年，思考：如果以后修改了 `style.css` 但没有改文件名，用户会看到什么？

<details>
<summary>参考答案</summary>

- `Content-Type` 应为 `text/css`，`Cache-Control` 包含 `max-age=3600`，同时有 `ETag` 和 `Last-Modified`。带上相同的 `If-None-Match` 后返回 304，正文为空。
- 因为 `location = /404.html` 带了 `internal;`，nginx 只允许内部跳转访问它；客户端直接请求会被拒绝为 404。去掉 `internal` 后，客户端可以直接打开这个页面，状态码会变成 200，这通常不是想要的。
- 片段：`location ^~ /download/ { alias /usr/share/nginx/html/files/; add_header Content-Disposition "attachment" always; }`。注意 `alias` 末尾斜杠、目录存在和权限；如果文件名要动态设置，需要更复杂的配置或由上游返回头。
- 浏览器会在一年内直接使用本地缓存，不再请求服务器。即使服务器上的 `style.css` 已经更新，用户仍可能看到旧版本。解决办法是给文件名加内容哈希、改文件名，或缩短缓存时间；单纯改文件内容而不改 URL 不够。

</details>
