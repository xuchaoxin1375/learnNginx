## 性能与缓存

性能优化最容易犯的错，是在没有测量的情况下改参数。nginx 的配置项很多，但真正影响当前站点的通常只有少数几个：连接数、上游耗时、缓冲区、缓存和压缩。这一章先建立测量方法，再讲代理缓存和常见调优项。

### 先测量，再调参

至少记录四个量：

- **状态码**：请求是否成功，错误是否被重试掩盖。
- **总耗时**：客户端从发请求到收完响应的时间。
- **首字节时间**(Time To First Byte, TTFB)：反映 nginx 和上游开始响应的速度。
- **上游耗时**：访问日志里的 `$upstream_response_time`。

`curl` 自带计时：

```shell
curl -s -o /dev/null -w 'dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total}\n' \
  http://localhost:8082/api/
```

| 字段 | 含义 |
| --- | --- |
| `time_namelookup` | DNS 解析耗时 |
| `time_connect` | TCP 连接建立耗时 |
| `time_appconnect` | TLS 握手完成耗时 |
| `time_starttransfer` | 收到第一个响应字节 |
| `time_total` | 整个请求完成 |

如果 `time_total` 高但 `time_starttransfer` 低，慢可能在传输大响应；如果 `time_starttransfer` 高，慢在 nginx 等待上游或上游本身。

并发压测工具可选 `ab`、`wrk`、`hey`、`k6`。它们不是本教程的依赖；没有安装时不要为了“跑个分”引入一整套工具链。压测要在隔离环境进行，避免影响共享机器和真实用户。

### worker 与连接

主配置：

```nginx
worker_processes auto;

events {
    worker_connections 1024;
    multi_accept on;
}
```

- `worker_processes auto;` 通常按 CPU 核心数设置。CPU 密集型场景不是越多越好，worker 太多会增加上下文切换。
- `worker_connections` 是每个 worker 的连接上限。客户端连接和上游连接都占文件描述符；只调大这个值而不调系统限制，可能报 `Too many open files`。
- `worker_rlimit_nofile` 可以调高 nginx 进程的文件描述符上限，但系统 `ulimit`、容器限制和内核参数也要匹配。
- `multi_accept on;` 让 worker 一次接受多个新连接，适合突发流量；是否有效要测量。
- `reuseport` 让多个 worker 各自监听同一个端口，可能改善多核下的连接分配；不是所有平台和版本都一样。

不要只改 `worker_connections` 就宣称“并发提高了”。先看状态页的 `accepts`/`handled`、错误日志和系统文件描述符使用情况。

### 缓冲区与超时

常见缓冲区：

```nginx
client_body_buffer_size 16k;
client_max_body_size    10m;
large_client_header_buffers 4 16k;

proxy_buffer_size       8k;
proxy_buffers           8 8k;
proxy_busy_buffers_size 16k;
```

- `client_body_buffer_size` 是读取客户端请求体时先放在内存里的部分；超过后可能写临时文件。
- `client_max_body_size` 是硬上限，超过返回 413。它不是性能参数，但会直接影响上传。
- `large_client_header_buffers` 控制大请求头的缓冲区数量和大小。太大浪费内存，太小会返回 400/414。
- `proxy_buffer_size` 用于上游响应头；`proxy_buffers` 用于响应体；`proxy_busy_buffers_size` 控制忙时缓冲区。
- `proxy_max_temp_file_size` 控制代理响应写临时文件的上限；设为 `0` 会禁用临时文件，可能让大响应占用更多内存或直接失败。

超时要和业务匹配：

```nginx
proxy_connect_timeout 3s;
proxy_send_timeout    30s;
proxy_read_timeout    30s;
client_header_timeout 10s;
client_body_timeout   10s;
send_timeout          30s;
```

超时太短会误杀慢请求，太长会让故障连接长期占用 worker。先用访问日志和上游指标确定正常 P99，再留出合理余量。

### 代理缓存

静态文件有浏览器缓存和 nginx 的 `expires`；反向代理的响应还可以缓存在 nginx 本地，减少上游压力。

实验配置：

```nginx
proxy_cache_path /var/cache/nginx/api levels=1:2 keys_zone=api_cache:10m
                 max_size=100m inactive=10m use_temp_path=off;

location = /api/cache-test {
    proxy_cache api_cache;
    proxy_cache_valid 200 2s;
    proxy_cache_key "$scheme$request_method$host$request_uri";
    proxy_cache_lock on;
    add_header X-Cache-Status $upstream_cache_status always;
    proxy_pass http://api1:8000/cache-test;
}
```

关键指令：

| 指令 | 作用 |
| --- | --- |
| `proxy_cache_path` | 定义缓存目录、内存键区、最大容量和过期清理 |
| `proxy_cache` | 在某个 location 启用哪个缓存区 |
| `proxy_cache_valid` | 按状态码设置缓存时间 |
| `proxy_cache_key` | 缓存键；默认包含 scheme、方法、Host、URI 等 |
| `proxy_cache_lock` | 同一个 key 只允许一个请求回源，避免缓存击穿 |
| `proxy_cache_use_stale` | 上游出错时是否使用旧缓存 |
| `X-Cache-Status` | 观察 MISS/HIT/EXPIRED/STALE 等状态 |

常见状态：

- `MISS`：缓存没有，回源了。
- `HIT`：直接命中缓存。
- `EXPIRED`：缓存过期，重新回源。
- `STALE`：使用了旧缓存（需要配置 `use_stale`）。
- `UPDATING`：缓存正在后台更新。
- `BYPASS`：请求绕过了缓存。

不是所有响应都适合缓存：

- 带用户身份的 JSON、购物车、后台页面不应公共缓存。
- 带 `Set-Cookie` 的响应要谨慎；默认不缓存，但配置可能改变行为。
- 缓存键要考虑查询串、Host、语言、设备等维度；漏掉维度会把 A 用户的内容给 B。
- 缓存时间要与业务更新频率匹配；太短起不到作用，太长会看到旧数据。
- 缓存目录要可写，磁盘要有余量；`max_size` 是上限，不是预分配。

### 压缩

```nginx
gzip on;
gzip_vary on;
gzip_min_length 256;
gzip_comp_level 5;
gzip_types text/plain text/css application/json application/javascript application/xml image/svg+xml;
```

压缩能减少带宽，但会消耗 CPU。文本类资源收益大；图片、视频、压缩包通常不值得。`gzip_vary on;` 让缓存区分压缩与非压缩版本。

Brotli 通常压缩率更好，但 stock nginx 默认不包含 brotli 模块；需要额外编译或使用 OpenResty/第三方模块。不要假设 `brotli on;` 在所有 nginx 上可用。

### HTTP/2 与 HTTP/3

实验的 HTTPS server 开了 HTTP/2：

```nginx
listen 8443 ssl;
http2 on;
```

HTTP/2 的多路复用让一个连接上可以并行多个请求，减少连接建立开销。它不是“自动变快”：如果上游慢、响应大或客户端不支持，收益有限。

HTTP/3 基于 QUIC，nginx 1.25+ 提供实验性支持，通常需要额外的 `listen ... quic` 和构建选项。生产使用前要确认客户端覆盖、负载均衡器支持、UDP 防火墙和可观测性。本教程不把 HTTP/3 作为实验必做项。

### 静态文件的文件缓存

大量重复访问静态文件时，可以缓存文件描述符和元数据：

```nginx
open_file_cache          max=1000 inactive=20s;
open_file_cache_valid    30s;
open_file_cache_min_uses 2;
open_file_cache_errors   on;
```

代价是文件更新后可能延迟生效，缓存参数要和发布流程匹配。小站点通常不需要；先测量系统调用和磁盘压力，再决定是否开启。

### 实验

观察代理缓存：

```shell
curl -s -D - -o /dev/null http://localhost:8082/api/cache-test | grep -i x-cache-status
curl -s -D - -o /dev/null http://localhost:8082/api/cache-test | grep -i x-cache-status
```

第一次通常是 `MISS`，第二次是 `HIT`。再请求正文：

```shell
curl -s http://localhost:8082/api/cache-test
```

两次命中缓存时，正文里的 `counter` 应该相同；等待超过 2 秒后再请求，会看到 `EXPIRED` 或新的 `MISS`，`counter` 变化。

观察耗时：

```shell
curl -s -o /dev/null -w 'ttfb=%{time_starttransfer} total=%{time_total}\n' http://localhost:8082/api/
curl -s -o /dev/null -w 'ttfb=%{time_starttransfer} total=%{time_total}\n' http://localhost:8082/api/cache-test
```

命中缓存时，第二次的 TTFB 通常更低，但样本少、容器环境波动大，不要用单次结果下结论。

观察状态页：

```shell
curl -s http://localhost:8082/nginx_status
```

对比请求前后的 `requests`、`Reading`、`Writing`、`Waiting`。

### 练习

- 为什么 `curl` 的 `time_starttransfer` 高、`time_total` 也高，不一定是 nginx 配置问题？还要看哪些日志字段？
- `proxy_cache_valid 200 2s;` 只缓存 200 响应。如果上游返回 404，默认会缓存吗？怎样显式控制？
- 命中缓存时，`X-Cache-Status` 可能是哪些值？`STALE` 需要什么条件才会出现？
- 把 `gzip_comp_level` 从 5 调到 9，带宽和 CPU 会怎样变化？应该怎样验证？

<details>
<summary>参考答案</summary>

- `time_starttransfer` 高说明首字节来得慢，可能是上游处理慢、连接排队或 DNS/TLS 慢；看 `$upstream_response_time`、`$request_time`、error.log 和上游监控，不能只归因于 nginx。
- 默认 `proxy_cache_valid` 只对指定状态码生效；没有列出的状态码通常不缓存。可以用 `proxy_cache_valid 404 1m;` 显式缓存 404，或保持默认不缓存。
- 常见值有 `MISS`、`HIT`、`EXPIRED`、`STALE`、`UPDATING`、`BYPASS`。`STALE` 需要配置 `proxy_cache_use_stale`（例如 `error timeout`），并且缓存里有旧内容。
- 压缩级别提高通常减少响应体积、增加 CPU；是否值得要看资源类型、客户端带宽和服务器 CPU。用相同内容分别测压缩后大小、TTFB、CPU 使用率和吞吐，不要只看压缩率。

</details>
