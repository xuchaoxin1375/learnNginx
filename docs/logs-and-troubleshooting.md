## 日志与排障

nginx 排障的核心不是背错误码，而是把一次失败拆成几个可观察的环节：**请求有没有到 nginx、选中了哪个 server/location、有没有转发到上游、上游返回了什么、客户端有没有等到最后**。日志和配置转储就是这些环节的证据。

### 访问日志

实验主配置的格式：

```nginx
log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                '$status $body_bytes_sent "$http_referer" '
                '"$http_user_agent" "$http_x_forwarded_for" '
                'rt=$request_time ua=$upstream_addr urt=$upstream_response_time';
```

一次代理请求可能长这样：

```shell
172.18.0.1 - - [15/Nov/2026:10:00:00 +0000] "GET /api/ HTTP/1.1" 200 132 "-" "curl/8.5.0" "-" rt=0.003 ua=172.18.0.3:8000 urt=0.002
```

关键字段：

| 字段 | 含义 | 排障用途 |
| --- | --- | --- |
| `$status` | 最终状态码 | 先看 4xx/5xx 的分布 |
| `$request_time` | 从读到客户端请求到写完响应的总时间 | 判断慢在 nginx、上游还是客户端 |
| `$upstream_addr` | 实际连接的上游地址 | 确认请求去了哪个实例；静态请求是 `-` |
| `$upstream_response_time` | 上游响应耗时 | 与总耗时对比，判断上游是否慢 |
| `$body_bytes_sent` | 响应正文大小 | 判断是否被截断或为空 |
| `$http_x_forwarded_for` | 客户端传来的 **XFF**(X-Forwarded-For) | 注意它可能被伪造 |

`$upstream_addr` 和 `$upstream_response_time` 在发生重试时可能出现多个值。不要假设它们永远只有一个地址或一个数字；看日志时结合重试配置。

### 错误日志

```nginx
error_log /var/log/nginx/error.log notice;
```

常见级别从低到高：

`debug`、`info`、`notice`、`warn`、`error`、`crit`、`alert`、`emerg`。

`debug` 需要 nginx 编译时带调试支持，而且日志量很大；不要在生产环境长期打开。排查上游连接问题时，`error` 级别通常已经包含关键信息。

在实验里查看：

```shell
docker compose -f labs/compose.yaml logs --tail=50 nginx
```

官方 nginx 镜像把访问日志和错误日志链接到容器标准输出/错误输出，所以 `docker compose logs` 能看到它们。如果你把日志写到了自定义文件，进入容器查看：

```shell
docker compose -f labs/compose.yaml exec nginx tail -n 50 /var/log/nginx/error.log
```

### 配置检查与重载

| 命令 | 作用 | 注意 |
| --- | --- | --- |
| `nginx -t` | 检查语法和可检查的文件依赖 | 不代表上游可达 |
| `nginx -T` | 打印主配置和所有 include 的完整配置 | 最适合确认“实际加载了什么” |
| `nginx -s reload` | 平滑重载 | 校验失败时旧配置继续服务 |
| `nginx -s reopen` | 重新打开日志文件 | 配合 logrotate 使用 |
| `nginx -s quit` | 优雅停止 | 处理完现有请求再退出 |
| `nginx -s stop` | 快速停止 | 可能中断请求 |

在实验里：

```shell
docker compose -f labs/compose.yaml exec nginx nginx -t
docker compose -f labs/compose.yaml exec nginx nginx -T
bash scripts/lab.sh reload
```

### stub_status

实验在负载均衡入口暴露了状态页：

```nginx
location = /nginx_status {
    stub_status;
    access_log off;
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    deny all;
}
```

请求：

```shell
curl -s http://localhost:8082/nginx_status
```

输出类似：

```shell
Active connections: 1
server accepts handled requests
 10 10 20
Reading: 0 Writing: 1 Waiting: 0
```

| 字段 | 含义 |
| --- | --- |
| `Active connections` | 当前活动连接数，通常约等于 Reading + Writing + Waiting |
| `accepts` | 累计接受的连接数 |
| `handled` | 累计成功处理的连接数；明显小于 accepts 时可能有资源限制 |
| `requests` | 累计请求数；一个 keepalive 连接可以有多个请求 |
| `Reading` | 正在读取请求头的连接数 |
| `Writing` | 正在写响应的连接数 |
| `Waiting` | 空闲的 keepalive 连接数 |

状态页本身不应暴露到公网。实验用私有网段放行，是为了让宿主机通过 Docker 网关访问；生产环境应限制到监控系统或本机。

### 状态码与先查什么

| 状态码 | 含义 | 先查什么 |
| --- | --- | --- |
| `400` | 请求格式错误 | 请求行、Host、头部是否合法；是否有代理篡改 |
| `401` | 需要认证 | `auth_basic`、上游认证、Token |
| `403` | 拒绝访问 | 文件/目录权限、`deny`、隐藏文件规则、SELinux |
| `404` | 文件或路由不存在 | `root`/`alias` 拼接、`try_files`、location |
| `405` | 方法不允许 | 静态文件收到 POST、上游只允许特定方法 |
| `413` | 请求体太大 | `client_max_body_size`、上游限制 |
| `429` | 请求过多 | `limit_req`/`limit_conn`、上游限流 |
| `499` | 客户端提前关闭 | 客户端超时、上游太慢；nginx 日志专有 |
| `500` | 上游内部错误 | 应用日志，不是 nginx 配置 |
| `502` | 上游连接失败或提前断开 | 上游进程、端口、DNS、容器网络 |
| `503` | 服务不可用 | 上游全不可用、限流、维护模式 |
| `504` | 上游超时 | `proxy_read_timeout`、上游慢查询、线程池 |

### 常见错误日志

| 日志片段 | 含义 | 处理方向 |
| --- | --- | --- |
| `open() ... failed (13: Permission denied)` | nginx 读不到文件 | 文件/目录权限、运行用户、SELinux |
| `connect() failed (111: Connection refused) while connecting to upstream` | 上游端口没监听 | 上游是否启动、端口、容器网络 |
| `upstream timed out (110: Connection timed out)` | 上游响应超时 | 上游性能、`proxy_read_timeout` |
| `no live upstreams` | upstream 里没有可用节点 | 健康检查、`max_fails`、节点状态 |
| `client intended to send too large body` | 请求体超过限制 | `client_max_body_size` |
| `limiting requests, excess: ... by zone` | 触发限速 | `limit_req` 参数、是否误伤正常用户 |
| `rewrite or internal redirection cycle` | 重写循环 | `rewrite`/`try_files` 的最后一跳 |
| `conflicting server name` | 同一端口有重复 `server_name` | `nginx -T` 搜重复项 |
| `worker_connections are not enough` | 连接数超过上限 | `worker_connections`、文件描述符、上游连接 |
| `Too many open files` | 文件描述符耗尽 | `worker_rlimit_nofile`、系统 ulimit |

### 排障顺序

遇到“打不开”时，按这个顺序缩小范围：

1. **确认请求到了 nginx**：访问日志有没有新增一行？没有的话，先查 DNS、端口、防火墙、负载均衡器。
2. **看状态码**：4xx 是路由/权限/请求问题，5xx 是上游或 nginx 运行时问题。
3. **看选中的配置**：`nginx -T` 确认 server/location 是否符合预期；注意 include 顺序和 `server_name`。
4. **看上游**：从 nginx 容器里直接请求上游，排除应用和网络；`docker compose exec nginx wget -qO- http://api1:8000/health`。
5. **看错误日志**：找 `connect()`、`timed out`、`Permission denied` 等关键词。
6. **最小复现**：用 `curl -v` 固定方法、Host、路径和请求头；一次只改一个变量。
7. **恢复与验证**：修复后重跑 `nginx -t`、`verify.sh` 和目标业务请求，不要只看“容器起来了”。

`curl -v` 能看到请求头、响应头、TLS 握手和连接过程；比只看浏览器“打不开”更有信息。

### 实验：制造并定位故障

先记录正常状态：

```shell
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
docker compose -f labs/compose.yaml logs --tail=20 nginx
```

制造 404、403：

```shell
curl -i http://localhost:8080/missing

printf 'secret' > labs/site/.secret
curl -i http://localhost:8080/.secret
rm labs/site/.secret
```

制造 413：

```shell
dd if=/dev/zero bs=1024 count=2048 2>/dev/null \
  | curl -i -X POST --data-binary @- http://localhost:8082/api/echo
```

制造 429：

```shell
for i in {1..12}; do
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8082/api/limited
done
```

制造 504：

```shell
time curl -i http://localhost:8081/api/slow-timeout
```

制造 502：

```shell
docker compose -f labs/compose.yaml stop api1
curl -i http://localhost:8081/api/
docker compose -f labs/compose.yaml logs --tail=20 nginx
docker compose -f labs/compose.yaml start api1
```

制造 499：

```shell
curl --max-time 1 -i http://localhost:8081/api/slow?ms=5000
```

客户端 1 秒后主动断开，nginx 可能在访问日志里记录 499。随后查看：

```shell
docker compose -f labs/compose.yaml logs --tail=30 nginx
```

每次只做一个故障，记录访问日志和错误日志的变化，再恢复。这样能把“状态码、日志、配置、上游状态”对应起来。

### 练习

- 访问日志里 `$request_time=2.5`、`$upstream_response_time=2.4`，说明慢在哪？如果 `$upstream_response_time` 是 `-` 呢？
- 502 和 504 都可能和上游有关，怎样用日志和直接请求区分？
- 为什么 `nginx -t` 通过后，网站仍可能 502？列出至少两个原因。
- 499 是谁产生的？它和 504 的区别是什么？

<details>
<summary>参考答案</summary>

- 总耗时 2.5 秒，上游耗时 2.4 秒，说明大部分时间花在等待上游；剩余 0.1 秒可能是 nginx 处理、网络或客户端写入。`$upstream_response_time` 为 `-` 通常表示请求没有走 upstream，例如静态文件、`return` 或内部错误。
- 502 是连接失败/上游提前断开，504 是等待上游响应超时。先看 error.log：`connect() failed` 偏 502，`upstream timed out` 偏 504；再用 `docker compose exec nginx wget` 直接请求上游，确认端口和响应。
- `nginx -t` 只检查配置语法和它能检查的文件依赖，不保证上游进程在运行、DNS 能解析、网络能连通、上游业务不返回 500，也不保证运行用户有权限读取所有文件。
- 499 是 nginx 记录“客户端在响应完成前关闭连接”，通常因为客户端超时或主动取消；504 是 nginx 等上游超时后主动返回。499 的责任可能在客户端或上游太慢，504 明确是上游在超时预算内没有响应。

</details>
