## location 与 URI 处理

`location` 是 nginx 配置里最容易“看起来写了却没生效”的部分。原因通常不是 nginx 随机选了一个块，而是匹配顺序、URI 规范化或 `try_files` 的最后一跳与预期不同。这一章把顺序讲清楚，并用实验台里的 `/match/` 路径逐个验证。

### URI 不是文件路径

同一个请求里常出现三个容易混淆的值：

- **请求行里的原始 URI**：客户端发来的 `/a/b?x=1`。
- **规范化后的 URI**：nginx 会解码百分号转义、合并多余的斜杠、处理 `.` 和 `..`，得到用于匹配的路径。
- **文件路径**：`root` 或 `alias` 把 URI 拼到磁盘目录后得到的路径。

变量对应关系：

| 变量 | 是否含查询串 | 是否随 rewrite 变化 | 用途 |
| --- | --- | --- | --- |
| `$request_uri` | 含 | 通常不变 | 日志、原始请求追踪 |
| `$uri` | 不含 | 可能变化 | `location`、`try_files`、`root`/`alias` |
| `$args` | 只有查询串 | 可能变化 | 参数处理、缓存键 |

实验入口：

```shell
curl -i 'http://localhost:8080/vars?x=1'
```

正文里的 `uri=/vars`、`request_uri=/vars?x=1`、`args=x=1` 就是这三个值的直接对照。

### location 的匹配顺序

nginx 选择 `location` 时，按下面的顺序思考：

1. **精确匹配** `location = /path`。命中就立即使用，不再看其他。
2. **前缀匹配**：找出所有匹配的前缀，记住最长的一个。
3. 如果最长前缀带 `^~`，使用它，并跳过后面的正则检查。
4. 否则按配置中出现顺序检查正则 `location ~` / `~*`，第一个命中者生效。
5. 如果没有任何正则命中，使用第 2 步记住的最长前缀。
6. 如果连前缀也没有，通常落到 `location /`；没有 `location /` 时可能 404。

这个顺序可以压缩成一句话：**精确最优先；最长前缀先记住；`^~` 跳过正则；正则按顺序抢先；最后回落到最长前缀。**

实验配置里有四个相关块：

```nginx
location = /match/exact { ... }

location /match/prefix/ { ... }

location /match/prefix/deep/ { ... }

location ~ ^/match/prefix/deep/[0-9]+$ { ... }
```

请求与结果：

| 请求 | 命中 | 原因 |
| --- | --- | --- |
| `/match/exact` | 精确 | `=` 命中后立即结束 |
| `/match/prefix/foo` | 前缀 | 只有普通前缀匹配 |
| `/match/prefix/deep/abc` | 更长的前缀 | 正则要求末尾是数字，不匹配；回落到最长前缀 |
| `/match/prefix/deep/42` | 正则 | 最长前缀先被记住，但普通前缀不会跳过正则；正则命中 |
| `/match/prefix/deep/42/` | 更长的前缀 | 正则的 `$` 不允许末尾斜杠；回落到最长前缀 |

用 `curl -i` 逐个请求，观察正文和状态码：

```shell
curl -i http://localhost:8080/match/exact
curl -i http://localhost:8080/match/prefix/foo
curl -i http://localhost:8080/match/prefix/deep/abc
curl -i http://localhost:8080/match/prefix/deep/42
```

### ^~ 什么时候有用

`^~` 只对前缀匹配生效，作用是“这个前缀一旦是最长匹配，就不要再看正则”。实验里的 `/static/` 是典型场景：

```nginx
location ^~ /static/ {
    alias /usr/share/nginx/html/assets/;
}
```

如果去掉 `^~`，请求 `/static/style.css` 会先被静态资源正则命中：

```nginx
location ~* \.(?:css|js|mjs|svg|png|jpe?g|gif|ico|woff2?)$ {
    expires 1h;
    try_files $uri =404;
}
```

这个正则按 `root` 去找 `/usr/share/nginx/html/static/style.css`，文件不存在，返回 404。正则并不会“知道”你想用 `alias`，它只按自己的规则匹配。

需要限制某类路径不要被通用正则抢走时，用 `^~`；需要在正则之间分先后时，把更具体的正则写在前面。

### 正则的写法与陷阱

```nginx
location ~  \.php$        { ... }   # 区分大小写
location ~* \.(jpg|png)$  { ... }   # 不区分大小写
location ~  ^/item/([0-9]+)$ {
    return 200 "item $1\n";
}
```

- 正则按配置出现顺序匹配，**第一个命中就停**，不是“最具体的赢”。
- 捕获组可以在 `return`、`rewrite`、`proxy_pass` 等位置用 `$1`、`$2` 引用。
- 正则里的 `.` 要转义成 `\.` 才能匹配字面点号。
- 正则 location 里使用 `alias` 时，路径替换容易出错；初学者优先用前缀 + `root`/`alias`，或者把正则限制在 `return`/`proxy_pass`。
- 正则不是越多越好。能用精确匹配或前缀匹配表达的路由，通常更易读、也更快。

### try_files 的最后一跳

`try_files` 按顺序检查文件或目录，最后一个参数是“都没找到时怎么办”：

```nginx
location / {
    try_files $uri $uri/ =404;
}
```

- `$uri`：检查文件是否存在。
- `$uri/`：检查目录是否存在；如果存在，通常会触发目录索引或内部跳转。
- `=404`：返回 404，不再继续找。
- `/app/index.html`：内部跳转到这个 URI，浏览器地址栏不变。
- `@app`：跳到命名 location，适合交给上游处理。

SPA 回退：

```nginx
location /app/ {
    try_files $uri $uri/ /app/index.html;
}
```

请求 `/app/users/42` 时，磁盘上没有 `users/42` 这个文件，也没有对应目录，最后内部跳到 `/app/index.html`。浏览器仍然显示 `/app/users/42`，前端路由可以接管。

注意：`try_files` 的最后一个参数如果是 URI，会触发一次新的 location 查找；如果写成文件路径而不是 URI，行为可能不符合预期。需要返回状态码时用 `=404`、`=403` 这类形式。

### return 与 rewrite

简单跳转优先用 `return`：

```nginx
location = /legacy {
    return 301 /match/exact;
}
```

`return` 立即结束处理，不经过正则替换，语义清楚。需要把旧路径按规则改写成新路径时，才用 `rewrite`：

```nginx
rewrite ^/old/(.*)$ /new/$1 permanent;
```

常用 flag：

| flag | 行为 |
| --- | --- |
| `last` | 重写后停止当前 location 的 rewrite，重新开始 location 查找 |
| `break` | 重写后停止 rewrite，留在当前 location 继续处理 |
| `redirect` | 返回 302 临时重定向 |
| `permanent` | 返回 301 永久重定向 |

`rewrite` 的替换结果如果又匹配同一条规则，会形成循环。出现 `rewrite or internal redirection cycle` 时，先检查规则是否把新 URI 又送回了自己。调试时可以在 `server` 或 `location` 里临时打开：

```nginx
rewrite_log on;
error_log /var/log/nginx/error.log notice;
```

`if` 属于 rewrite 模块，简单条件加 `return` 通常没问题，但复杂嵌套、多个 `if`、在 `if` 里做 `proxy_pass` 容易产生意外行为。优先用 `map`、`try_files`、`return` 或拆分 `location` 来表达分支。

### 尾斜杠与目录

尾斜杠会改变匹配结果：

- `location /app` 匹配 `/app`、`/app/`、`/app/users`。
- `location /app/` 匹配 `/app/`、`/app/users`，不匹配 `/app`。
- 请求一个真实目录但 URL 没有尾斜杠时，`index` 模块通常会返回 301，让浏览器补上斜杠。

`proxy_pass` 的尾斜杠还会改变转发路径：

```nginx
location /api/ { proxy_pass http://api1:8000/; }   # /api/users -> /users
location /api/ { proxy_pass http://api1:8000; }    # /api/users -> /api/users
```

这个差异在反向代理章节会展开。初学阶段先记住：**location 的斜杠、alias 的斜杠、proxy_pass 的斜杠，三处要一起看。**

### 实验

先看匹配结果：

```shell
curl -i http://localhost:8080/match/exact
curl -i http://localhost:8080/match/prefix/foo
curl -i http://localhost:8080/match/prefix/deep/abc
curl -i http://localhost:8080/match/prefix/deep/42
```

再看 `^~` 和 `alias`：

```shell
curl -i http://localhost:8080/static/style.css
```

然后做一次对照实验：

1. 备份 `labs/nginx/conf.d/00-static.conf`。
2. 把 `location ^~ /static/` 改成 `location /static/`。
3. 运行 `bash scripts/lab.sh reload`。
4. 再请求 `/static/style.css`。
5. 记录结果，改回 `^~`，再 reload。

最后看 SPA 回退：

```shell
curl -i http://localhost:8080/app/users/42
```

### 练习

- 请求 `/match/prefix/deep/42/`，预测命中哪个 location，再用 `curl -i` 验证。为什么正则没有命中？
- 写一个正则 location，匹配 `/item/123` 这样的路径，返回 `item 123`。要求只匹配数字，不匹配 `/item/abc`。
- 把 `/legacy` 的 `return 301` 改成 `rewrite ^/legacy$ /match/exact permanent;`，验证行为是否一致。两种写法你更愿意维护哪一种？
- 解释为什么 `location /static/` 在去掉 `^~` 后会返回 404，而 `location ^~ /static/` 不会。

<details>
<summary>参考答案</summary>

- `/match/prefix/deep/42/` 命中 `location /match/prefix/deep/`。正则 `^/match/prefix/deep/[0-9]+$` 要求字符串在数字后结束，尾斜杠不满足 `$`，所以正则不命中，回落到最长普通前缀。
- 片段：`location ~ ^/item/([0-9]+)$ { default_type text/plain; return 200 "item $1\n"; }`。`([0-9]+)` 只匹配数字；`/item/abc` 不命中，会落到其他 location 或 404。
- 两种写法都能返回 301，但 `return` 更直接，不依赖正则；`rewrite` 更适合需要捕获组重排路径的场景。简单旧地址跳转优先 `return`。
- 去掉 `^~` 后，`/static/style.css` 仍是最长前缀 `/static/`，但普通前缀不会跳过后面的正则；静态资源正则先命中，按 `root` 找 `/usr/share/nginx/html/static/style.css`，文件不存在，返回 404。`^~` 让前缀匹配直接生效，`alias` 把 `/static/` 替换为 `/assets/`，所以能返回 CSS。

</details>
