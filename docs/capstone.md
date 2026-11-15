## 综合项目：把入口组合起来

前面的章节分别讲了静态站点、`location`、反向代理、负载均衡、HTTPS、日志、缓存、限速和安全。这个项目要求你在**不复制整份答案**的前提下，把这些能力组合成一个可以验收的统一入口。

### 场景

你要为一个名为 “Notes” 的小应用做入口：

- 前端是静态站点，**SPA**(Single Page Application, 单页应用) 路由需要回退到 `index.html`。
- API 有两个实例 `api1`、`api2`，希望轮询并复用上游连接。
- 公开的配置接口可以缓存 5 秒。
- 登录/限流接口需要限制请求速率。
- 上传接口最大 2 MiB。
- 隐藏文件和常见的敏感路径不能访问。
- 上游全挂时返回自定义 502 页面。
- 入口要有安全响应头、健康检查和可观察的访问日志。
- HTTPS 入口继续使用现有的 8443 自签名配置。

实验台已经把容器的 `8082` 端口映射到宿主机 `8084`，但没有默认监听。你的任务是创建 `labs/nginx/conf.d/90-capstone.conf`，让 `http://localhost:8084/` 成为这个统一入口。

### 验收条件

完成后，下面这些检查应通过：

| 检查 | 预期 |
| --- | --- |
| `curl -i http://localhost:8084/` | 200，返回静态首页 |
| `curl -i http://localhost:8084/app/users/42` | 200，返回 SPA 页面 |
| 连续请求 `/api/` | `instance` 在 `api1` 和 `api2` 之间分配 |
| `curl -I http://localhost:8084/` | 含 `X-Content-Type-Options: nosniff` |
| 快速请求 `/api/limited` | 出现 429 |
| 两次请求 `/api/cache-test` | `X-Cache-Status` 出现 `MISS`/`HIT` |
| 3 MiB 上传到 `/api/echo` | 413（上限是 2 MiB，恰好 2 MiB 会被允许） |
| 请求 `/missing` | 404，返回自定义 404 页面 |
| 停掉两个 API 后请求 `/api/` | 502，返回自定义 50x 页面 |
| `docker compose ... exec nginx nginx -t` | 配置通过 |
| `curl -k -I https://localhost:8443/` | 200，原有 HTTPS 入口不受影响 |

### 起步

先确认端口映射已经生效：

```shell
bash scripts/lab.sh down
bash scripts/lab.sh up
```

`http://localhost:8084/` 此时应该连接失败或没有响应，因为还没有 server 监听容器的 `8082`。

参考实现放在：

`examples/capstone/90-capstone.conf.example`

它不会被自动加载。建议先自己写一版，再对照参考实现；如果直接复制，至少逐行解释每个 location 为什么这样排。

### 建议的推进顺序

1. **先让静态站点和 SPA 回退工作**：只写 `server`、`root`、`location /`、`location /app/`，reload 后用 `curl` 验证。不要一开始就把代理、缓存、限速全塞进去。
2. **加 API 代理**：定义 `upstream`，把 `/api/` 转到两个实例，验证 `instance` 分布。
3. **加缓存和限速**：为 `/api/cache-test` 和 `/api/limited` 写独立 location，确认它们的优先级高于 `/api/`。
4. **加错误页和安全头**：自定义 404/50x，确认状态码没有被错误地改成 200。
5. **加请求体限制和隐藏文件规则**：验证 413 和 403。
6. **回归**：跑 `nginx -t`、`curl` 清单和 `verify.sh`（`verify.sh` 不检查 8084，但能确认其他入口没有被改坏）。

每次只改一类配置，reload 后验证，再进入下一步。这样出错时容易定位。

### 设计提示

- `/api/cache-test` 和 `/api/limited` 是精确匹配，应该优先于 `/api/` 前缀；不要把它们的逻辑塞进 `/api/` 里用一堆 `if`。
- `upstream` 和 `limit_req_zone`、`proxy_cache_path` 要放在 `http` 上下文，也就是 `conf.d` 文件的顶层。
- 上游 keepalive 需要 `proxy_http_version 1.1;` 和 `proxy_set_header Connection "";`；后者要覆盖共享片段或默认值。
- 缓存 location 里如果写了 `add_header X-Cache-Status`，server 级安全头不会自动继承；需要重复 include 安全头片段。
- 静态资源 location 只用 `expires`，不要写 `add_header Cache-Control`，避免覆盖安全头。
- 隐藏文件正则要放在静态资源正则之前，否则 `/.secret.css` 可能先命中资源规则。
- 自定义 50x 页面要 `internal`，`error_page` 才会保留原始 502/504 状态码。
- 不要为了让 `curl` 通过而把 `proxy_intercept_errors` 或 `error_page` 配成所有错误都返回 200。

### 参考实现

参考文件：

[90-capstone.conf.example](../examples/capstone/90-capstone.conf.example)

使用方式：

```shell
cp examples/capstone/90-capstone.conf.example labs/nginx/conf.d/90-capstone.conf
bash scripts/lab.sh reload
```

如果端口被占用或你想改端口，先改 `compose.yaml` 的映射和配置里的 `listen`，不要只改一边。

### 验收命令

```shell
curl -i http://localhost:8084/
curl -i http://localhost:8084/app/users/42
curl -s http://localhost:8084/api/ | grep -o '"instance": "[^"]*"'
curl -I http://localhost:8084/
curl -s -D - -o /dev/null http://localhost:8084/api/cache-test | grep -i x-cache-status
```

限速：

```shell
for i in {1..10}; do
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8084/api/limited
done
```

请求体限制：

```shell
dd if=/dev/zero bs=1024 count=3072 2>/dev/null \
  | curl -i -X POST --data-binary @- http://localhost:8084/api/echo
```

故障页：

```shell
docker compose -f labs/compose.yaml stop api1 api2
curl -i http://localhost:8084/api/
docker compose -f labs/compose.yaml start api1 api2
```

隐藏文件：

```shell
printf 'secret' > labs/site/.secret
curl -i http://localhost:8084/.secret
rm labs/site/.secret
```

### 自评

能独立完成并解释以下问题，才算真正掌握：

- 为什么 `/api/cache-test` 不会被 `/api/` 前缀吞掉？
- 为什么缓存 location 要重复安全头，而静态资源 location 不用？
- 为什么 502 页面返回后状态码仍然是 502，而不是 200？
- 停掉 api2 后，请求为什么还能成功？停掉两个 API 后，nginx 的 error.log 会写什么？
- 如果把 `proxy_pass` 末尾的 `/` 去掉，上游收到的路径会怎样变化？
- 如果把 `limit_req` 的 `nodelay` 去掉，客户端观察到的现象会有什么不同？

### 可扩展方向

完成基础验收后，可以按兴趣加：

- 给 capstone 入口加 Basic Auth 或 IP 允许列表。
- 把访问日志改成 JSON 格式，接入日志平台。
- 用 `proxy_cache_use_stale` 在上游故障时返回旧缓存。
- 用 `resolve` 和 Docker DNS 做动态上游。
- 用 OpenResty 在入口层做 JWT 校验或 A/B 分流。
- 把 8084 的 HTTP 入口接到 8443 的 HTTPS，或反过来做统一跳转。

每加一项，都补一条验收命令和一条失败时的排查路径。不要只验证成功路径。
