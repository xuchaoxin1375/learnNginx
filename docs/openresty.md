## OpenResty

OpenResty 不是另一个从零写起的 Web 服务器，而是**nginx + LuaJIT + 一组 Lua 库**的发行版。它保留 nginx 的配置、事件模型和反向代理能力，同时允许你在请求处理的各个阶段写 Lua，做动态路由、鉴权、限流、A/B 测试和响应改写。

这一章适合已经理解 nginx 基本配置的读者。不会 Lua 也能读懂示例，但要把 OpenResty 用在生产，至少需要能写简单的 Lua 并理解阻塞/非阻塞的差别。

### 它和 nginx 的关系

| 能力 | nginx | OpenResty |
| --- | --- | --- |
| 静态文件、反向代理、负载均衡 | 有 | 有，配置基本兼容 |
| 配置文件驱动 | 是 | 是，额外支持 Lua 指令 |
| 请求阶段编程 | 需要 C 模块 | LuaJIT + `*_by_lua_block` |
| 共享内存字典 | 部分模块 | `lua_shared_dict` 常用 |
| 生态 | 官方模块、第三方模块 | `lua-resty-*`、`opm` 包管理 |

可以把 OpenResty 看成“可编程的 nginx”。它仍然需要 `nginx.conf`，也仍然用 `nginx -t`/`-s reload` 那套生命周期；只是多了 Lua 这个扩展点。

### 请求阶段

nginx 处理请求分成多个阶段，OpenResty 允许在不同阶段插入 Lua：

| 阶段/指令 | 典型用途 | 注意 |
| --- | --- | --- |
| `init_by_lua_block` | 加载配置、初始化全局数据 | master 启动时执行 |
| `init_worker_by_lua_block` | 每个 worker 的定时器、健康检查 | 每个 worker 各执行一次 |
| `rewrite_by_lua_block` | URI 重写、动态路由 | 不要做阻塞操作 |
| `access_by_lua_block` | 鉴权、限流、IP 黑白名单 | 常用 `ngx.exit` 提前返回 |
| `content_by_lua_block` | 直接生成响应 | 和 `proxy_pass` 等内容处理器互斥 |
| `header_filter_by_lua_block` | 修改响应头 | 在响应头生成后执行 |
| `body_filter_by_lua_block` | 修改响应体 | 可能分块执行，注意拼接 |
| `log_by_lua_block` | 自定义日志、指标 | 不要阻塞请求 |

实验的 `/lua/hello` 用 `content_by_lua_block` 直接返回 JSON：

```nginx
location = /lua/hello {
    content_by_lua_block {
        local cjson = require "cjson.safe"
        ngx.say(cjson.encode({
            message = "hello from OpenResty",
            host = ngx.var.host,
            time = ngx.now()
        }))
    }
}
```

`ngx.say` 写正文并换行；`ngx.exit(ngx.HTTP_UNAUTHORIZED)` 可以提前结束请求；`ngx.var` 读取 nginx 变量；`ngx.req.get_headers()` 和 `ngx.req.get_uri_args()` 读取请求。

### 共享字典与计数器

`lua_shared_dict` 在所有 worker 之间共享一小块内存：

```nginx
http {
    lua_shared_dict counters 1m;

    server {
        location = /lua/counter {
            content_by_lua_block {
                local dict = ngx.shared.counters
                local hits, err = dict:incr("hits", 1, 0)
                if not hits then
                    ngx.log(ngx.ERR, "incr failed: ", err)
                    return ngx.exit(500)
                end
                ngx.say('{"hits":' .. hits .. '}')
            }
        }
    }
}
```

`incr` 是原子的，适合计数、简单的限流和缓存元数据。但它不是数据库：

- 重启后丢失。
- 只在单个 OpenResty 实例内共享，不跨机器。
- 容量有限，写满后 `incr` 可能失败。
- 不适合存大对象或需要持久化的数据。

实验的 `/lua/ab` 用共享计数器做确定性的 A/B 分支：奇偶交替返回 `A` 和 `B`。这比 `math.random` 更容易观察，但真实 A/B 测试通常按用户 ID 哈希并记录曝光。

### 常用库与场景

OpenResty 生态里的 `lua-resty-*` 库覆盖了很多网关需求：

- `lua-resty-http`：非阻塞 HTTP 客户端。
- `lua-resty-limit-traffic`：限速、限连接。
- `lua-resty-lrucache`：worker 内 LRU 缓存。
- `lua-resty-redis`、`lua-resty-mysql`：非阻塞数据库客户端。
- `lua-resty-jwt`：JWT 校验。
- `lua-resty-healthcheck`：主动健康检查。
- `lua-resty-openidc`：OIDC 认证。

典型场景：

- **API**(Application Programming Interface, 应用程序接口) 网关：按路径、Header、**JWT**(JSON Web Token) 动态路由，统一鉴权和限流。
- **动态上游**：从注册中心/数据库读取后端列表，用 `balancer_by_lua_block` 选择节点。
- **响应改写**：给旧接口补字段、统一错误格式、做灰度标记。
- **边缘逻辑**：A/B 分流、灰度发布、防刷、签名校验。
- **自定义日志/指标**：按业务维度记录，不必改应用。

### 代价与边界

OpenResty 很强大，但不是所有项目都需要：

| 收益 | 代价 |
| --- | --- |
| 在入口层做动态逻辑，不改应用 | 需要 Lua 和 OpenResty 生态知识 |
| 减少一次网络跳转 | 调试比纯 nginx 配置复杂 |
| 共享字典、cosocket 等能力 | 阻塞调用会拖垮 worker，必须用非阻塞 API |
| 生态库丰富 | 第三方库质量、维护和安全要自己评估 |
| 配置仍是 nginx | 版本升级、模块兼容和可观测性要额外管理 |

几条实践底线：

- 不要在请求路径里调用阻塞的 `os.execute`、同步文件 I/O 或普通 socket；用 `ngx.sleep`、cosocket 和 `lua-resty-*`。
- 不要信任用户输入拼接 Lua 代码；Lua 是代码，不是模板字符串。
- 不要把共享字典当持久存储。
- `lua_code_cache off;` 只用于开发调试，生产必须开启，否则每个请求都重新加载代码。
- 复杂的业务逻辑优先放应用；入口层只做跨服务、轻量、稳定的策略。

### 实验

启动 OpenResty：

```shell
bash scripts/lab.sh up --with-openresty
```

请求各个端点：

```shell
curl -s http://localhost:8083/lua/hello
curl -s http://localhost:8083/lua/counter
curl -s http://localhost:8083/lua/counter
curl -s http://localhost:8083/lua/headers
curl -s 'http://localhost:8083/lua/echo?x=1&y=2'
curl -s http://localhost:8083/lua/ab
curl -s http://localhost:8083/lua/ab
```

预期：

- `/lua/hello` 返回 JSON，包含 `message`、`host`、`time`。
- `/lua/counter` 连续请求时 `hits` 递增。
- `/lua/headers` 返回请求头 JSON。
- `/lua/echo` 返回查询参数。
- `/lua/ab` 交替返回 `A` 和 `B`。

检查配置和重载：

```shell
docker compose -f labs/compose.yaml exec openresty openresty -t
docker compose -f labs/compose.yaml exec openresty openresty -s reload
```

修改 `labs/openresty/nginx.conf` 后，先 `-t` 再 reload。Lua 语法错误可能在首次请求时才暴露，改完要实际请求对应端点。

本仓库的 Lua 片段已做语法检查，但当前开发环境没有 Docker，OpenResty 容器未在本机实际启动；第一次运行时如果镜像标签或配置路径有差异，先看 `docker compose logs openresty`，再用 `openresty -t` 定位。

### 练习

- 增加一个 `/lua/sum`，读取查询参数 `a` 和 `b`，返回它们的和。要求参数缺失或不是数字时返回 400。
- 用 `header_filter_by_lua_block` 给所有响应加一个 `X-OpenResty: lab` 响应头。
- 解释 `lua_shared_dict` 与普通 Lua 模块级变量的区别。两个 worker 各自修改变量时，计数器会怎样？
- 为什么在 OpenResty 请求路径里调用 `os.execute` 很危险？应该用什么替代？

<details>
<summary>参考答案</summary>

- 片段：

  ```nginx
  location = /lua/sum {
      content_by_lua_block {
          local cjson = require "cjson.safe"
          local args = ngx.req.get_uri_args()
          local a = tonumber(args.a)
          local b = tonumber(args.b)
          if not a or not b then
              ngx.status = ngx.HTTP_BAD_REQUEST
              ngx.say(cjson.encode({ error = "a and b must be numbers" }))
              return
          end
          ngx.say(cjson.encode({ sum = a + b }))
      }
  }
  ```

  还要考虑参数是 table（重复参数）的情况；教学示例先按单值处理。

- 片段：`header_filter_by_lua_block { ngx.header["X-OpenResty"] = "lab" }`，放在 `server` 或 `location` 里。注意不要在 `content_by_lua_block` 已经发送响应后再改头。

- `lua_shared_dict` 在所有 worker 之间共享，`incr` 是原子的；普通模块级变量在每个 worker 的 Lua VM 里各有一份，两个 worker 的计数不会自动合并。需要跨 worker 计数时用共享字典。

- `os.execute` 是阻塞调用，会占住 worker 的事件循环，导致同一 worker 上的其他请求无法处理；还可能引入命令注入。应使用非阻塞的 cosocket、`ngx.sleep` 或把任务交给外部队列/服务。

</details>
