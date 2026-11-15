## 服务器软件对比

nginx 很常见，但不是所有场景的唯一答案。选型时不要只看“谁更快”，而要看**配置方式、动态服务发现、TLS 自动化、扩展能力、团队技能和运维成本**。这一章把常见的 Web 服务器、反向代理和负载均衡器放在同一组维度下比较，并给出按场景的推荐。下文用 **L4/L7**(Layer 4/7, 四层/七层) 区分传输层和 HTTP 层的代理能力。

### 一张表看定位

| 软件 | 实现/模型 | 配置方式 | 强项 | 主要代价 |
| --- | --- | --- | --- | --- |
| nginx | C，事件驱动 | 配置文件，reload | 静态文件、反向代理、TLS、负载均衡、成熟生态 | 动态逻辑要模块/OpenResty；开源版主动健康检查有限 |
| OpenResty | nginx + LuaJIT | nginx 配置 + Lua | 可编程网关、动态路由、鉴权、限流 | 需要 Lua 与 OpenResty 生态经验 |
| Apache httpd | C，多 MPM | 配置文件、`.htaccess` | 模块生态、目录级配置、传统 PHP 集成 | 进程/线程模型和 `.htaccess` 有额外开销 |
| Caddy | Go，事件驱动 | Caddyfile / JSON | 自动 HTTPS、配置简洁、HTTP/2/3 | 可调参数和模块生态与 nginx 不同 |
| Traefik | Go | 动态配置 + 标签 | 容器/K8s 服务发现、自动 TLS、中间件 | 抽象层多，排障要理解 provider 与路由链 |
| Envoy | C++ | xDS 动态配置 | L7 代理、服务网格、gRPC、可观测性 | 需要控制面，运维复杂度高 |
| HAProxy | C | 配置文件 | L4/L7 负载均衡、ACL、主动健康检查、统计页 | 不是通用 Web 服务器；动态配置需要生态支持 |
| IIS | Windows 组件 | GUI / XML 配置 | ASP.NET、Windows 集成、企业管理 | 平台绑定、许可与 Linux/云原生适配 |

这张表是定位，不是性能排名。静态文件、TLS 握手、上游延迟、连接复用和业务逻辑都可能成为瓶颈，必须用自己的流量模型测量。

### nginx

适合：

- 一个入口后面挂静态站点和多个上游服务。
- 需要成熟的 `location`、`proxy_pass`、`upstream`、缓存、限流和日志。
- 团队已经熟悉 nginx 配置，或平台默认提供 nginx（云厂商、Kubernetes Ingress）。
- 希望配置可版本化、可评审、可 reload。

边界：

- 开源版没有内置的主动健康检查；被动检查要等真实请求失败。
- 复杂动态逻辑需要 Lua（OpenResty）或 C 模块。
- 服务发现、证书自动续期通常要额外组件（Consul、certbot、Ingress Controller）。
- 配置表达力强，但 `if`、`rewrite`、`alias` 等细节容易踩坑。

### OpenResty

适合：

- API 网关：JWT 校验、动态路由、按业务限流、灰度分流。
- 需要在入口层改写请求/响应，但不想改应用。
- 团队愿意维护 Lua 代码和 OpenResty 生态。

边界：

- Lua 代码也是代码，需要测试、评审、错误处理和可观测性。
- 阻塞调用会拖垮 worker；必须使用 cosocket 和非阻塞 API。
- 第三方 `lua-resty-*` 库的质量和安全要评估。
- 简单的静态站点或纯反代不需要它。

### Apache httpd

适合：

- 历史项目大量依赖 `.htaccess` 和 Apache 模块。
- 需要目录级配置、传统 PHP 集成或特定模块。
- 团队已有 Apache 运维经验。

边界：

- `.htaccess` 方便，但每次请求都可能触发目录配置查找，生产环境常建议关闭并集中配置。
- 不同 MPM（prefork/worker/event）行为不同，调优要理解进程/线程模型。
- 高并发静态场景通常不是它的首选，但“Apache 一定慢”是过度简化；要看 MPM、模块和负载。

### Caddy

适合：

- 小型站点、内部工具、开发环境，希望**自动 HTTPS**、配置越少越好。
- 需要 HTTP/2、HTTP/3 和简洁的反向代理配置。
- 团队不想维护 certbot 和证书续期脚本。

边界：

- Caddyfile 简洁，但复杂路由和极端调优的可控项与 nginx 不同。
- Go 插件生态与 nginx C 模块生态不通用。
- 大规模、多租户、复杂缓存/限流场景仍要评估具体能力。

一个最小 Caddyfile：

```caddyfile
example.com {
    root * /srv
    file_server
    reverse_proxy /api/* api1:8000
}
```

Caddy 会自动申请和续期证书；这能省掉很多运维步骤，但也意味着你要理解 ACME、端口 80/443 和 DNS 的前提。

### Traefik

适合：

- Docker Compose、Kubernetes 或多种 provider 下的大量服务。
- 希望按容器标签自动发现路由，而不是每次手改 nginx 配置。
- 需要自动 TLS、中间件（认证、限流、重写）和 dashboard。

边界：

- 路由由 provider 动态生成，出问题时要同时看容器标签、provider 状态和 Traefik 路由链。
- 抽象层提高了自动化，也降低了“直接读一份配置文件就知道全部行为”的直观性。
- 极端性能或多租户隔离要单独验证。

Compose 标签的形态：

```yaml
labels:
  - "traefik.http.routers.app.rule=Host(`example.com`)"
  - "traefik.http.services.app.loadbalancer.server.port=8000"
```

### Envoy

适合：

- 大型微服务、服务网格（如 Istio 的数据面）。
- 需要 **xDS**(x Discovery Service, x 发现服务) 动态配置、精细流量管理、gRPC、熔断、重试、可观测性。
- 平台团队能维护控制面和 Sidecar 生命周期。

边界：

- Envoy 通常不是“手写一个配置文件就上线”的工具，需要控制面或服务网格。
- 学习曲线和运维复杂度明显高于 nginx。
- 小项目直接用 Envoy，往往是用复杂方案解决简单问题。

### HAProxy

适合：

- 专门的 L4/L7 负载均衡层，尤其是 TCP、数据库代理或需要强健康检查的场景。
- 需要 ACL、stick tables、统计页、连接排空和成熟的负载均衡功能。
- 前面是 HAProxy、后面是 nginx/应用的分层架构。

边界：

- 它不是通用静态 Web 服务器；静态文件和复杂 URI 路由通常交给 nginx。
- 动态服务发现需要 Data Plane API、DNS 或配置管理配合。
- TLS 终止、HTTP/2 等能力要按版本确认。

### IIS

适合：

- Windows Server、ASP.NET/.NET 应用、Active Directory 集成。
- 企业已有 Windows 运维体系。

边界：

- 平台绑定 Windows；Linux/容器化环境通常不选它。
- 许可、补丁和 GUI 配置的自动化方式与 Linux 工具链不同。
- 公网高并发入口常在前面加 CDN、负载均衡或 nginx。

### 按场景选择

| 场景 | 优先考虑 | 理由 |
| --- | --- | --- |
| 单站点静态文件 + 反代 | nginx | 成熟、配置透明、资料多 |
| 小团队，想自动 HTTPS、少配置 | Caddy | ACME 和默认配置省事 |
| 多容器/多服务动态路由 | Traefik 或 nginx Ingress | 服务发现和自动路由 |
| 专门的四层/七层负载均衡 | HAProxy | 健康检查、ACL、统计和稳定性 |
| 服务网格/大规模微服务 | Envoy | xDS、可观测性和生态 |
| 入口层动态鉴权/改写 | OpenResty | Lua 可编程 |
| 传统 PHP/.htaccess | Apache | 兼容既有生态 |
| Windows/.NET | IIS | 平台集成 |

### 混合架构很常见

真实系统往往不是“二选一”：

- **CDN/WAF → nginx → 应用**：边缘缓存和防护，nginx 做统一入口。
- **HAProxy → nginx → 应用**：HAProxy 做四层负载均衡和健康检查，nginx 做七层路由。
- **Traefik/Ingress → 服务**：容器平台动态发现，服务内部再按需加 sidecar。
- **Envoy/Istio → 服务网格**：东西向流量交给网格，南北向入口仍可能是 nginx 或云负载均衡。

选型时先画清楚流量方向：**南北向**（客户端到入口）和**东西向**（服务之间）可以用不同工具。

### 性能比较的边界

不要用“某软件每秒多少请求”的二手数字做决策。至少确认：

- 请求是静态文件、TLS、反代还是动态应用？
- 响应大小、并发数、连接复用、HTTP 版本是什么？
- 测试机器、网络、磁盘、上游是否相同？
- 开启了多少模块、日志、压缩、缓存？
- 瓶颈在 CPU、内存、磁盘、网络还是上游？

同一台机器上，静态文件服务很容易被磁盘和网络限制；反向代理很容易被上游延迟限制。先测量自己的路径，再决定是否换工具。

### 练习

- 一个 5 人团队要部署 3 个静态站点和 2 个 API，希望自动 HTTPS、配置尽量少。你会选 nginx + certbot 还是 Caddy？说明取舍。
- 一个 Kubernetes 集群有几十个服务，需要按域名和路径自动路由、自动证书。Traefik、nginx Ingress 和 Envoy 各适合什么位置？
- 一个 TCP 数据库代理需要主动健康检查和连接统计，前面还有 HTTP 站点。你会怎样组合 HAProxy 和 nginx？
- 为什么“nginx 比 Apache 快”不能作为无条件结论？列出至少三个会影响结果的因素。

<details>
<summary>参考答案</summary>

- 如果团队不想维护证书续期和额外组件，Caddy 更省事；如果团队已经熟悉 nginx、需要复杂缓存/限流/模块或统一入口，nginx + certbot 也可行。关键看运维能力和长期可控性，不是单纯配置行数。
- Traefik 适合作为 Kubernetes Ingress/边缘路由，自动发现服务和证书；nginx Ingress 适合已有 nginx 生态和成熟 Ingress 控制器；Envoy 更适合作为服务网格数据面或需要 xDS 的大规模平台，而不是最简单的入口。
- 用 HAProxy 做 TCP 层的负载均衡和主动健康检查，后面挂多个数据库/代理节点；HTTP 站点继续由 nginx 做七层路由。两者职责分开，排障和扩容更清晰。
- 结果受 MPM/进程模型、模块、静态/动态内容、TLS、并发、缓存、磁盘、网络、配置和上游影响。“快”必须绑定具体工作负载和测试条件。

</details>
