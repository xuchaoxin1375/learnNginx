## 负载均衡

当一个上游不够用，或者希望一台机器故障时服务不中断，就需要把请求分给多个上游。nginx 的 `upstream` 块提供了一组节点和分配策略；这一章讲清楚默认轮询、权重、健康检查、连接复用和常见误区。

### upstream 块

实验配置：

```nginx
upstream api_backend {
    server api1:8000 max_fails=2 fail_timeout=10s;
    server api2:8000 max_fails=2 fail_timeout=10s;
    keepalive 16;
}
```

`upstream` 必须放在 `http` 上下文。`server` 后面的地址可以是主机名、IP、端口或 Unix socket。`max_fails` 和 `fail_timeout` 是**被动健康检查**：nginx 只在真实请求失败时记账，不会在后台主动探测。

使用这个 upstream：

```nginx
location /api/ {
    proxy_pass http://api_backend/;
    proxy_set_header Connection "";
}
```

注意 `proxy_pass` 写的是 upstream 的名字，不是某个具体节点。

### 分配算法

| 算法 | 写法 | 适合 | 注意 |
| --- | --- | --- | --- |
| 轮询 | 默认 | 节点性能相近、请求耗时均匀 | 不看当前连接数 |
| 权重 | `server api2:8000 weight=2;` | 机器配置不同 | 权重是相对值，不是百分比 |
| 最少连接 | `least_conn;` | 请求耗时差异大 | 长请求多的节点会少接新请求 |
| IP 哈希 | `ip_hash;` | 需要按客户端 IP 粘性 | **NAT**(Network Address Translation, 网络地址转换) 或代理后大量用户共享 IP，会集中到一台 |
| 一致性哈希 | `hash $request_uri consistent;` | 缓存分片、按 key 粘性 | key 设计不好会倾斜 |
| 随机二选一 | `random two least_conn;` | 大规模节点、避免羊群效应 | 需要较新版本 |

默认轮询在实验里最容易观察：

```shell
for i in {1..6}; do
  curl -s http://localhost:8082/api/ | grep -o '"instance": "[^"]*"'
done
```

预期会看到 `api1` 和 `api2` 交替出现。实际生产中的请求耗时、连接复用和重试会改变分布，不能只用几条 `curl` 判断算法是否“公平”。

### 权重与最少连接

权重适合“新机器配置高、旧机器配置低”：

```nginx
upstream api_backend {
    server api1:8000 weight=1;
    server api2:8000 weight=2;
}
```

在两个节点都健康、请求都很快时，长期分布大致是 1:2。把 `api2` 的权重调大后 reload，连续请求观察比例；样本太小会有波动，不要用 6 次请求下结论。

`least_conn` 把新请求交给当前活动连接数最少的节点，并考虑权重。它对“有的请求很慢、有的很快”的场景更有意义：

```nginx
upstream api_backend {
    least_conn;
    server api1:8000;
    server api2:8000;
}
```

如果所有请求都在 10 毫秒内完成，`least_conn` 和轮询看起来可能差不多；差异要在并发和慢请求下观察。

### 健康检查与故障转移

实验里：

```nginx
server api1:8000 max_fails=2 fail_timeout=10s;
```

含义是：在 `fail_timeout` 时间内失败达到 `max_fails` 次，nginx 会把该节点标记为不可用，持续 `fail_timeout`；之后会再尝试。失败包括连接失败、超时等，具体还受 `proxy_next_upstream` 影响。

`backup` 标记备用节点，只在主节点不可用时使用：

```nginx
upstream api_backend {
    server api1:8000;
    server api2:8000 backup;
}
```

`down` 是管理员手动摘除：

```nginx
server api1:8000 down;
```

注意：

- nginx 开源版只有**被动**健康检查；主动健康检查是 NGINX Plus 的能力。OpenResty 可以用 Lua 生态做主动检查。
- 被动检查意味着故障要被真实请求“撞上”才会被发现；流量很低的节点可能很久不被标记。
- `max_fails=0` 会关闭失败计数，不适合想要自动摘除的场景。
- 重试次数和超时预算要一起看，否则一次请求可能在多个节点上重复等待。

### 连接复用

`keepalive 16;` 是 upstream 块里的指令，表示每个 worker 最多保留 16 个空闲的上游连接，不是客户端的 `keepalive_timeout`。要让它生效，代理请求需要 HTTP/1.1，并清掉默认的 `Connection: close`：

```nginx
location /api/ {
    proxy_pass http://api_backend/;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
}
```

实验的 `proxy-headers.conf` 已经设置了 `proxy_http_version 1.1;`，所以 upstream 位置只需要补 `Connection ""`。没有连接复用时，每个请求都要重新建立 TCP 连接，高并发下会增加延迟和端口消耗。

### 会话保持

有些应用把登录态放在单个进程的内存里。轮询到另一台机器时，用户会突然“掉登录”。可选做法：

- **应用改成无状态**：会话放数据库、Redis 或签名 Cookie。这是最推荐的方向。
- `ip_hash;`：按客户端 IP 粘性。问题是 NAT、公司代理、移动网络会让很多人共享出口 IP，导致分布严重倾斜。
- `hash $cookie_session consistent;`：按 Cookie 中的会话 ID 粘性。需要应用保证 Cookie 存在且分布均匀。
- 商业版或 OpenResty 的 sticky 模块：按 Cookie 插入路由信息；开源 nginx 没有内置的 sticky cookie 指令。

先判断“会话必须粘”是不是真需求。很多情况下，改应用的无状态化比在入口层做粘性更可靠。

### Docker 网络里的 DNS

Compose 用服务名 `api1`、`api2` 作为主机名。**DNS**(Domain Name System, 域名系统) 把这些名字解析成容器 IP；nginx 在启动或 reload 时解析，如果容器重启后 IP 变化，而 nginx 没有 reload，它可能继续连接旧 IP。

可选方案：

- 变更上游后手动 `bash scripts/lab.sh reload`。
- nginx 1.27.3+ 在 `upstream` 中使用 `resolve`：

  ```nginx
  resolver 127.0.0.11 valid=10s ipv6=off;

  upstream api_backend {
      zone api_backend 64k;
      server api1:8000 resolve;
      server api2:8000 resolve;
  }
  ```

  `zone` 为 upstream 提供共享内存，`resolve` 让 nginx 按 `resolver` 的 TTL 重新解析。旧版本没有这个参数，需要 reload 或使用变量形式的 `proxy_pass`。

- 变量形式的 `proxy_pass http://$backend;` 会触发运行时解析，但需要 `resolver`，并且会影响 keepalive 和部分优化，不能无脑替换。

生产环境还要考虑服务发现、滚动发布和连接 draining；不要只依赖一个 `upstream` 块。

### 实验

观察轮询：

```shell
for i in {1..6}; do
  curl -s http://localhost:8082/api/ | grep -o '"instance": "[^"]*"'
done
```

停掉 api2：

```shell
docker compose -f labs/compose.yaml stop api2
for i in {1..4}; do
  curl -s http://localhost:8082/api/ | grep -o '"instance": "[^"]*"'
done
docker compose -f labs/compose.yaml start api2
```

预期所有请求都落到 api1。恢复 api2 后，等 `fail_timeout` 过去或 reload，再观察是否重新参与。

调整权重：

1. 在 `20-lb.conf` 的 `upstream` 里给 `api2` 加 `weight=2`。
2. `bash scripts/lab.sh reload`。
3. 连续请求 9 次，统计实例分布。
4. 改回默认，reload。

观察最少连接（可选）：

1. 把 `upstream` 改成 `least_conn;`。
2. reload。
3. 同时发起几个 `/api/slow?ms=1000` 请求，再发普通 `/api/` 请求，观察慢请求占用连接时新请求的落点。

### 练习

- 默认轮询下，为什么 6 次请求不一定严格是 `api1, api2, api1, ...`？哪些因素会让分布偏移？
- 两个节点配置不同，一个 4 核、一个 2 核。你会用 `weight`、`least_conn` 还是两者组合？说明理由。
- 停掉 api2 后，为什么请求会转到 api1？`max_fails` 和 `fail_timeout` 在这个过程中分别起什么作用？
- 用了 `ip_hash` 后，公司 NAT 出口的所有用户都落到同一台，可能是什么原因？应该怎样改？

<details>
<summary>参考答案</summary>

- 轮询只是按顺序选择可用节点；连接复用、请求耗时、重试、健康检查和并发都会让实际分布看起来不均匀。少量请求不足以判断长期比例。
- 可以在 `least_conn` 基础上给高配节点更高权重，让它在连接数相同的情况下多接一些；也可以先用权重做静态比例，再用监控验证。没有一种算法适合所有场景，关键看请求耗时和节点差异。
- `max_fails` 达到阈值后，节点在 `fail_timeout` 内被标记不可用，nginx 把请求交给剩余节点。`fail_timeout` 结束后会重新尝试；如果节点仍不可用，会再次被摘除。
- `ip_hash` 按客户端地址做哈希，NAT 后很多用户共享同一个出口 IP，于是被分到同一台。可以改用按 Cookie/会话 key 的一致性哈希，或把应用改成无状态、共享会话存储。

</details>
