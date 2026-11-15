## 配置模型

这一章解决三个问题：**配置写在哪个层级、一个请求怎样选中 `server` 和 `location`、文件路径和变量怎样参与结果**。`location` 的匹配细节放在下一章，这里先把配置的结构和常用概念立住。

### 配置的语法骨架

nginx 配置由**指令**(directive)组成。简单指令以分号结束，块指令用花括号包住一组指令：

```nginx
worker_processes auto;

http {
    server {
        listen 80;
        server_name example.com;

        location / {
            return 200 "hello\n";
        }
    }
}
```

几条基本规则：

- `#` 开始注释，直到行尾。
- 指令名和参数用空白分隔；含空格的值要加引号。
- 大多数指令以 `;` 结束；忘记分号是最常见的语法错误。
- 变量以 `$` 开头，例如 `$host`、`$uri`、`$request_time`。
- 大小写：指令名通常小写；域名匹配不区分大小写；Linux 上的文件路径区分大小写；正则 `~` 区分大小写，`~*` 不区分。

大小和时间有单位：

```nginx
client_max_body_size 10m;      # 10 MiB
proxy_read_timeout   30s;      # 30 秒
keepalive_timeout    65;       # 默认单位是秒
```

大小单位可用 `k`/`K`、`m`/`M`；时间单位可用 `ms`、`s`、`m`、`h`、`d`、`w`。写单位比写裸数字更清楚。

### 上下文与合法位置

同一个指令放在不同上下文，作用范围不同；放错位置会直接报错。初学阶段先记住这张表：

| 上下文 | 典型内容 | 说明 |
| --- | --- | --- |
| `main` | `user`、`worker_processes`、`error_log`、`pid` | 进程级 |
| `events` | `worker_connections`、`multi_accept` | 事件循环 |
| `http` | `include`、`log_format`、`gzip`、`upstream`、`map` | 所有 HTTP 服务的公共部分 |
| `server` | `listen`、`server_name`、`root`、`ssl_certificate` | 一个虚拟主机 |
| `location` | `try_files`、`proxy_pass`、`return`、`rewrite` | 一类 URI |
| `upstream` | `server`、`least_conn`、`keepalive` | 一组上游节点 |

`include` 不是上下文，它把目标文件的内容插入当前位置。实验的主配置在 `http` 里包含 `conf.d/*.conf`，所以这些文件顶层的 `server`、`upstream`、`limit_req_zone` 都处于 `http` 上下文。

### server_name 怎样匹配

一个请求到达某个监听端口后，nginx 用请求的 `Host` 头去匹配该端口上的 `server_name`。顺序大致是：

| 优先级 | 形式 | 例子 | 说明 |
| --- | --- | --- | --- |
| 最高 | 精确名称 | `www.example.com` | 完全相等时命中 |
| 高 | 以 `*` 开头的通配符 | `*.example.com` | 匹配 `a.example.com`、`a.b.example.com`，不匹配 `example.com`；多个匹配时取最长 |
| 较高 | 以 `*` 结尾的通配符 | `www.example.*` | 匹配 `www.example.com`、`www.example.org`；多个匹配时取最长 |
| 中 | 正则 | `~^api[0-9]+\.example\.com$` | 按配置中出现顺序，第一个命中者生效 |
| 低 | 默认 server | `listen 80 default_server;` | 没有其他匹配时兜底 |

几个容易踩的点：

- `server_name _;` 不是通配符。`_` 只是一个几乎不可能匹配的普通名称；它常被当作“兜底”，真正让它兜底的原因是它通常是该监听端口上的第一个 server，或者显式加了 `default_server`。
- 同一个 `listen` 上只能有一个 `default_server`；重复会报 `duplicate default server`。
- 先有监听端口，后有 `Host` 匹配。请求打到 `8081` 不会因为 `Host` 写了 `example.com` 就跑到 `80` 的 server。
- TLS 的 SNI 在 HTTP 之前参与证书选择；没有 SNI 或客户端不支持时，会落到该端口的默认 server。初学阶段先记住“HTTPS 先握手，再按 Host 选 server”。

实验里的静态站点用 `server_name _;` 作为默认 server，另外有一个 `server_name example.com;` 的虚拟主机。访问 `localhost`、`127.0.0.1` 或未匹配的 `Host` 会落到默认站点；把 `Host` 改成 `example.com`，会命中精确匹配的 server。这适合演示单站点与多域名的差异，但生产环境要明确每个域名的证书、默认站点和 404 行为。

### root 与 alias

这两个指令都决定“URI 对应磁盘上的哪个文件”，但拼接方式不同。

| 配置 | 请求 | 实际文件 |
| --- | --- | --- |
| `root /usr/share/nginx/html;` | `/about.html` | `/usr/share/nginx/html/about.html` |
| `location /static/ { alias /usr/share/nginx/html/assets/; }` | `/static/style.css` | `/usr/share/nginx/html/assets/style.css` |
| `location /static/ { alias /usr/share/nginx/html/assets; }` | `/static/style.css` | `/usr/share/nginx/html/assetsstyle.css`，通常 404 |

`root` 保留完整 URI 再拼到目录后面；`alias` 用 alias 的值**替换**匹配到的 location 前缀。`alias` 末尾的斜杠要和 location 的斜杠对应，否则很容易拼出错误路径。

实验配置里的 `/static/` 用了 `^~`：

```nginx
location ^~ /static/ {
    alias /usr/share/nginx/html/assets/;
}
```

`^~` 表示“前缀匹配成功后跳过后面的正则检查”。如果不写 `^~`，`/static/style.css` 会先被静态资源正则 `\.(css|js|...)$` 抢走，然后按 `root` 去找 `/usr/share/nginx/html/static/style.css`，结果 404。这是 `location` 顺序问题的典型例子，下一章会展开。

### 观察 server_name

实验台在 `labs/nginx/conf.d/40-vhost.conf` 里放了一个只匹配 `example.com` 的虚拟主机：

```nginx
server {
    listen 80;
    server_name example.com;

    location / {
        default_type text/plain;
        return 200 "vhost example.com\n";
    }
}
```

用 `Host` 头切换命中：

```shell
curl -i http://localhost:8080/
curl -i -H 'Host: example.com' http://localhost:8080/
curl -i -H 'Host: other.example' http://localhost:8080/
```

第一个和第三个请求落到默认的静态站点，第二个返回 `vhost example.com`。这说明 `server_name` 匹配的是 HTTP `Host`，而不是 URL 里的 IP 或端口；端口先决定连接落到哪个 `listen`，然后才轮到 `Host` 选 server。

### 常用变量

变量让配置能引用请求和响应的信息。先掌握这些：

| 变量 | 含义 | 注意 |
| --- | --- | --- |
| `$uri` | 当前规范化后的 URI | 不含查询串；rewrite 或内部跳转后可能变化 |
| `$request_uri` | 客户端最初请求的 URI | 含查询串；通常不随 rewrite 变化 |
| `$args` | 查询串 | 不含 `?` |
| `$host` | 规范化后的主机名 | 小写、通常不含端口；可能来自请求行、`Host` 或 `server_name` |
| `$http_host` | 原始 `Host` 请求头 | 可能含端口，也可能为空 |
| `$scheme` | `http` 或 `https` | 反向代理时注意 `X-Forwarded-Proto` |
| `$remote_addr` | 直接连接的客户端地址 | 经过代理时是代理地址，除非配置了 `real_ip` |
| `$server_port` | 接收请求的端口 | 容器内端口，不一定等于宿主机发布端口 |
| `$request_method` | `GET`、`POST` 等 | 大小写按客户端发送 |
| `$status` | 响应状态码 | 主要用于日志 |
| `$request_time` | 请求总耗时 | 秒，带毫秒精度 |
| `$upstream_addr` | 本次请求连接的上游地址 | 静态请求为 `-` |
| `$upstream_response_time` | 上游响应耗时 | 可能包含多次重试，用逗号分隔 |

实验里有一个观察入口：

```shell
curl -i 'http://localhost:8080/vars?x=1'
```

预期正文包含 `uri=/vars`、`request_uri=/vars?x=1`、`args=x=1`。再指定一个带端口和大写字母的 Host：

```shell
curl -i -H 'Host: Example.test:8080' 'http://localhost:8080/vars?x=1'
```

对比 `host=example.test` 和 `http_host=Example.test:8080`，就能看出规范化与原始值的差别。这里用 `.test` 而不是 `example.com`，是因为后者会命中前面演示的虚拟主机；这也说明 `server_name` 的选择会先于 location。

### include 与文件组织

常见组织方式：

- 单文件：所有配置放在 `/etc/nginx/nginx.conf`，适合极小站点。
- `conf.d/*.conf`：主配置在 `http` 里 include，每个文件放一个站点或一组功能。
- Debian 风格：`sites-available/` 存候选配置，`sites-enabled/` 用符号链接启用。
- 容器：把配置目录挂载到 `/etc/nginx/conf.d`，镜像保持通用。

实验使用第二种：

```nginx
http {
    include /etc/nginx/conf.d/*.conf;
}
```

`include` 的文件按 glob 顺序加载，但业务上不要依赖多个 `server` 的先后顺序。需要默认站点时写 `default_server`；需要共享片段时用 `snippets/` 并在需要的 `server`/`location` 里显式 include。

### 配置检查与生效

改完配置先检查：

```shell
docker compose -f labs/compose.yaml exec nginx nginx -t
```

通过后再平滑重载：

```shell
bash scripts/lab.sh reload
```

查看 nginx 实际加载的完整配置：

```shell
docker compose -f labs/compose.yaml exec nginx nginx -T
```

`-t` 只能证明语法和它能检查到的文件依赖没问题，不能证明：

- 上游服务一定可达。
- 运行用户一定有权读取文件。
- 证书一定匹配当前域名。
- 业务路径一定符合预期。

这些要在运行时用 `curl`、日志和浏览器验证。

### 常见配置错误

| 现象 | 常见原因 | 检查 |
| --- | --- | --- |
| `unexpected end of file, expecting ";"` | 少了分号或括号 | 看报错行前后的块结构 |
| `directive is not allowed here` | 指令放错上下文 | 查官方文档的 Context |
| `duplicate default server` | 同一端口写了两个 `default_server` | 搜 `default_server` |
| 访问所有域名都进同一个站点 | 只有一个 server，或它被设为默认 | `nginx -T` 看 server 列表 |
| `alias` 路径 404 | 末尾斜杠不匹配 | 对比 location 与 alias 的结尾 |
| 改了 `add_header` 后安全头消失 | 子层级写了新的 `add_header` 覆盖继承 | 检查该 location 是否有 `add_header` |
| 变量形式的 `proxy_pass` 报 `no resolver defined` | 使用了变量但没有 `resolver` | 在 `http` 或 `location` 配 `resolver` |

### 练习

- 请求 `http://localhost:8080/vars?x=1`，记录 `uri`、`request_uri`、`args` 三个值。再用 `curl -H 'Host: Example.com:8080'` 请求一次，解释 `host` 与 `http_host` 的差异。
- 请求 `http://localhost:8080/static/style.css` 和 `http://localhost:8080/assets/style.css`，确认两者内容一致。把 `00-static.conf` 里的 `^~` 去掉，reload 后再请求 `/static/style.css`，观察结果并解释。
- 在 `00-static.conf` 里增加一个精确匹配的 `/hello`，返回 `hello from nginx`，reload 后验证。写出你修改的片段。
- 故意删掉一条指令末尾的分号，运行 `nginx -t`，记录报错。恢复后再次检查。这个过程中旧配置是否还在服务？

<details>
<summary>参考答案</summary>

- `/vars` 的 `uri` 是 `/vars`，`request_uri` 是 `/vars?x=1`，`args` 是 `x=1`。带 `Host: Example.test:8080` 时，`$host` 规范化为 `example.test`，`$http_host` 保留原始 `Example.test:8080`。如果改成 `example.com`，请求会先命中虚拟主机，不会到达 `/vars`。
- 去掉 `^~` 后，`/static/style.css` 会先命中静态资源正则，按 `root` 去找 `/usr/share/nginx/html/static/style.css`，该文件不存在，返回 404。加回 `^~` 后，前缀匹配直接生效，`alias` 把 `/static/` 替换为 `/assets/`，返回 CSS。
- 片段：`location = /hello { default_type text/plain; return 200 "hello from nginx\n"; }`。`=` 表示精确匹配，只有 `/hello` 命中，`/hello/` 和 `/hello/x` 不会命中。
- `nginx -t` 会报 `unexpected end of file, expecting ";" or "}"` 一类的错误。`reload` 在配置校验失败时不会替换旧 worker，旧配置继续服务；这正是先 `-t` 再 reload 的价值。恢复配置后重新 `-t` 和 reload。

</details>
