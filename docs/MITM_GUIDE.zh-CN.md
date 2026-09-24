# sing-box for Apple MITM 使用指南

## 1. 工程组成

- Apple 客户端：官方 `sing-box-for-apple` 提交 `64470f9`（1.15.0-alpha.7）。
- sing-box 内核：基于 `v1.15.0-alpha.7` 的 MITM 移植版本；当前工作区包含完整的 Surge MITM 修复层。
- App 实际链接根目录的 `Libbox.xcframework`；该框架由上述 MITM 内核生成。
- 附件中的 `.p12` 是 Apple 应用签名证书，不是 MITM 根 CA。两者不能混用。

## 2. 构建 MITM 内核

先安装 Xcode 和 Go 1.24，并准备上游固定版本的 gomobile：

```bash
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.5
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.5
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build-mitm-libbox.sh
```

脚本会生成 `Libbox.xcframework`，并确认二进制中存在 TLS 解密、URL/Header/Body rewrite 和 Apple CA 描述文件端点。

## 3. 可视化设置界面

App 内已内置 MITM 可视化设置，不需要手写 JSON。

入口：`Profiles -> 选择本地或 iCloud Profile -> Edit -> MITM Settings`。

界面分为四部分：

- **Core**：`Enable MITM`（全局开关）、`HTTP/2`（是否解密 HTTP/2 流量）。
- **Certificate Authority**：根 CA 管理。
  - `Generate CA`：在设备端直接生成 RSA 根 CA，自动填入配置并开启 MITM。
  - `Import P12`：导入已有的 `.p12` CA（需同时填写密码）。
  - `Export Certificate`：导出 `.cer` 根证书，可通过分享发送到其他设备。
  - `Install Certificate`：自动保存配置并打开系统的描述文件安装流程（见第 6 节）。
  - `Remove CA`：从配置中移除 CA。
- **Rules**：按域名匹配的规则列表。每条规则可配置：
  - `Enabled` / `Print Traffic`（把解密后的明文请求/响应写入日志）。
  - `Exact Domains` / `Domain Suffixes`：匹配范围。
  - `URL Rewrite` / `Header Rewrite` / `Body Rewrite` / `Map Local`：Surge 风格的改写规则，格式见第 8 节。
  - `Scripts`：绑定 Surge 脚本，可设置事件（Request / Response / Both）、URL Patterns、Timeout、Requires Body、Binary Body、Full Header Mode、Maximum Size 和 Arguments。
- **Scripts**：脚本定义。每个脚本有 Tag、Source（`Local` 填设备内文件路径，`Remote` 填 URL，可附加 Download Detour 和 Update Interval）。

点右上角 `Save` 保存。保存时会调用内核的 `LibboxCheckConfig` 校验，格式错误会直接弹出错误提示，不会写入无效配置。保存后需重启 VPN 生效。

`Diagnostics -> View Logs` 可跳转到日志页面查看解密流量。

## 4. 生成自己的 MITM 根 CA（命令行方式）

如果不想在 App 内生成，也可以在 Mac 上生成：

```bash
MITM_P12_PASSWORD='换成强密码' ./Scripts/generate-mitm-ca.sh
```

输出位于 `MITM/private/`：

- `config.json`：已经嵌入 P12，可直接导入 App。
- `mitm-ca.cer`：根证书。
- `mitm-ca.p12` 和 `mitm-ca.key.pem`：根私钥材料，不能发送给其他人。
- `mitm-ca.password.txt`：P12 密码。

整个 `MITM/private/` 已被 Git 忽略。

## 5. 导入并启动

1. 打开 SFI，在 Profiles 中导入 `MITM/private/config.json`（或新建空白 Profile 后用第 3 节的可视化界面配置）。
2. 示例配置默认只对 `example.com` 启用 MITM，并打印解密后的 HTTP 请求/响应。
3. 启动该 Profile，允许系统创建 VPN。
4. 首次验证前不要把匹配范围改成所有域名，先确认单一测试域名工作正常。

## 6. 在 iPhone 安装并信任根 CA

启动配置后，在同一台 iPhone 的 Safari 打开：

```text
http://127.0.0.1:9090/mitm/mobileconfig
```

也可以直接在 MITM Settings 里点 `Install Certificate`，它会保存配置并自动打开上面的地址。

然后完成两步系统操作：

1. `设置 -> 通用 -> VPN 与设备管理`，安装下载的描述文件。
2. `设置 -> 通用 -> 关于本机 -> 证书信任设置`，为 `sing-box MITM Root CA` 开启完全信任。

也可以把导出的 `.cer` 传到设备后手动安装。只安装证书还不够，必须再开启“完全信任”。

## 7. 验证 MITM

1. 保持 VPN 开启，用 Safari 访问 `https://example.com/`。
2. 回到 SFI 的 Logs 页面（或 MITM Settings -> Diagnostics -> View Logs）。
3. 能看到该请求的 URL、Headers 等明文信息，即表示 TLS 已由 sing-box MITM 内核解密后再转发。
4. 若出现证书不受信任，重新检查第 6 节的第二步。

## 8. 规则与改写格式

MITM 必须同时满足两个条件：全局 `mitm.enabled` 为 `true`，且命中的 `route.rules` 使用 `route-options` 并设置 `mitm.enabled`。可视化界面保存时会自动维护这两个条件。

只查看明文流量：

```json
{
  "domain_suffix": ".example.org",
  "action": "route-options",
  "mitm": {
    "enabled": true,
    "print": true
  }
}
```

以下改写字段都放在规则的 `mitm` 对象内，每行是一条 Surge 风格的规则。请求处理顺序与 Surge 对齐：Header Rewrite → URL Rewrite → Body Rewrite → HTTP Request Script → Map Local；响应处理顺序为 Header Rewrite → Body Rewrite → HTTP Response Script。修改后先保存 Profile，再停止并重新启动 VPN。

### URL Rewrite

格式：`<正则> <目标URL|_> [header|301|302|307|308|reject]`

```json
"surge_url_rewrite": [
  "^https://old\\.example\\.org/(.*) https://new.example.org/$1 header",
  "^https://ads\\.example\\.org/ _ reject"
]
```

`header`（默认）直接改写请求并同步 Host、目标端口和 TLS SNI；`301`/`302`/`307`/`308` 返回重定向；`reject` 拒绝请求。透明改写只接受 `http`、`https`、`ws`、`wss` 目标。

### Header Rewrite

格式：`<http-request|http-response> <正则> <header-add|header-del|header-replace|header-replace-regex> <Header名> [值] [匹配正则]`

```json
"surge_header_rewrite": [
  "http-request ^https://api\\.example\\.org/ header-add X-MITM enabled",
  "http-response ^https://api\\.example\\.org/ header-del X-Internal",
  "http-response ^https://api\\.example\\.org/ header-replace-regex Location ^http:// https://"
]
```

### Body Rewrite

格式：`<http-request|http-response> <正则> <匹配正则> <替换文本>`（匹配/替换可成对出现多次）

```json
"surge_body_rewrite": [
  "http-response ^https://api\\.example\\.org/ old-value new-value"
]
```

Body Rewrite 会先解压 gzip、deflate 或 brotli，再按 UTF-8 文本处理，修改后重新生成 Content-Length 并移除旧 Content-Encoding。请求正文上限为 32 MiB，响应正文上限为 1 MiB；超限或非 UTF-8 正文会跳过响应修改，请求修改超限会失败。正则支持多行模式，`^` 和 `$` 可匹配每一行。

Surge 模块中的 `http-request-jq` 与 `http-response-jq` 会由内置 gojq 引擎执行，可使用 `getpath`、`setpath`、`delpaths`、`map`、`select`、`as`、`contains` 等完整 jq 语法。输入必须是 JSON，表达式必须产生单个 JSON 结果；解析或执行失败时仅跳过该次改写，不中断请求。

### Map Local

格式：`<正则> data-type=<file|text|tiny-gif|base64> [data=...] [status-code=...] [header=Key:Value|Key2:Value2]`

```json
"surge_map_local": [
  "^https://api\\.example\\.org/mock data-type=text data=hello status-code=200",
  "^https://api\\.example\\.org/pixel data-type=tiny-gif"
]
```

命中后直接由内核返回本地数据，不访问真实服务器。`file` 类型使用 sing-box 文件管理器读取，文件大小上限为 4 MiB；合成响应会自动重建 Content-Length 并过滤 hop-by-hop headers。

### Surge 脚本

脚本定义在配置顶层的 `scripts` 数组（可视化界面的 `Scripts` 部分）：

```json
"scripts": [
  {
    "type": "surge",
    "tag": "my-script",
    "source": "local",
    "path": "script.js"
  }
]
```

`source` 为 `remote` 时改用 `url`，可选 `download_detour` 和 `update_interval`（如 `1d`）。

在规则的 `mitm.surge_script` 中绑定脚本：

```json
"surge_script": [
  {
    "tag": "my-script",
    "type": ["http-request"],
    "pattern": ["^https://api\\.example\\.org/"],
    "timeout": "10s",
    "requires_body": true,
    "max_size": 131072
  }
]
```

脚本通过全局 `request` / `response`（同时提供 `$request` / `$response`）对象读取内容，调用 `done({...})` 返回修改结果。`$done()` 或 `$done({})` 表示原样继续，只有 `$done({abort:true})` 才会中断连接：

```js
// http-request：改写请求
done({ url: request.url, headers: request.headers, body: request.body });

// http-response：改写响应
done({ status: response.status, headers: response.headers, body: response.body.replace('foo', 'bar') });
```

`bodyBytes` 与 `binary_body_mode` 可用于 protobuf、图片等二进制正文；`full_header_mode` 使用 `{field, value}` 数组保留重复 Header。脚本中的 `$httpClient` 会沿用 sing-box 的 HTTP 出站和路由，并支持异步回调、Promise、定时器、持久化存储和 `setTimeout`。`$httpAPI` 仅返回明确的“不支持”结果，不会伪装成 Surge 控制接口。

远程脚本首次下载失败（例如源站返回 403）时会 fail-open：记录错误并暂时禁用该脚本，但不会阻止 VPN 和其他脚本启动。已有缓存会优先使用；下载请求会携带脚本加载器 User-Agent 与 JavaScript Accept Header。

## 9. 常见限制

- 使用证书固定（certificate pinning）的 App 会拒绝 MITM 证书，这是目标 App 的安全策略。
- HTTP/3/QUIC 使用 UDP，不经过当前 TLS-over-TCP MITM；命中 MITM 的 TCP/443 域名会自动拒绝 QUIC，促使客户端回退到 HTTP/2 或 HTTP/1.1。
- 只给必要域名启用 MITM。`print` 会把敏感 Header 和正文写入日志，完成调试后应关闭。
- HTTP/2 每个 stream 使用独立目标和 TLS 状态；多个模块命中同一域名时，MITM 规则会合并，而不是后一个模块覆盖前一个模块。
- 为控制内存（Network Extension 上限约 50 MB)，所有 body 缓存（含 gzip/brotli 解码后的副本）共享 6 MiB 全局预算。高并发下预算耗尽时，该请求跳过 body 重写和 `requires_body` 脚本、按原始内容透传，日志会出现 `body buffer budget exhausted` WARN;header 重写、URL 重写等不依赖 body 的功能不受影响。
- 本地和远程 Profile 会完整备份到 `文件 App -> 我的 iPhone -> sing-box -> Profiles`，并在运行目录中的 `configs/config_N.json` 缺失时自动恢复。备份包含 MITM CA 私钥和 P12 密码，必须按敏感文件保管。正常覆盖更新会保留该目录；卸载 App 仍可能由 iOS 删除它，卸载前应再复制到 Downloads 或其他文件夹。
- 删除根 CA：`设置 -> 通用 -> VPN 与设备管理` 删除描述文件，并在证书信任设置中确认已移除。

## 10. 构建可安装的 IPA

需要一个 ad-hoc 类型的描述文件（覆盖主 App ID 和目标设备），以及对应的 iPhone Distribution 证书（P12）。

一条命令完成 Release 构建、签名和打包：

```bash
SIGNING_IDENTITY='iPhone Distribution: Your Name (TEAMID)' ./Scripts/build-ipa.sh
```

首次运行需要 P12 密码来建立专用签名钥匙串（之后不再需要）：

```bash
SIGNING_P12_PASSWORD='附件的P12密码' ./Scripts/build-ipa.sh
```

产物为项目根目录的 `sing-box-mitm.ipa`，可通过爱思助手、AltStore 等工具安装到已登记的设备。

签名方式说明：

- 描述文件只精确覆盖主 App ID，因此主 App 和全部扩展（Packet Tunnel、Intents、Widget）统一使用该描述文件自带的权限集合签名，每个组件内嵌同一份描述文件。
- 描述文件未授予 iCloud 容器权限，因此这个签名版本里 iCloud 配置同步不可用；本地配置和 MITM 功能不受影响。
- 专用签名钥匙串位于 `build/signing.keychain-db`，密码保存在 `build/.signing-keychain-password`（均已被 Git 忽略），不会改动系统登录钥匙串。

## 11. 配置持久化

配置有三条独立的"被覆盖"路径，对应三种处理：

**订阅更新（自动或手动）**

订阅配置更新时不再是整文件覆盖。更新下载新内容后，会自动把本地 MITM 层重放回去，保留：

- `mitm_modules` 模块列表及其展开的规则和脚本（模块元数据内嵌完整展开内容，无需重新下载）；
- MITM Settings 里手工添加的 Rules 和 Scripts；
- 顶层 `mitm` 开关、`certificate.tls_decryption`（CA 证书）；有 CA 时自动补齐 `experimental.clash_api`。

直接在 JSON 里手加的普通路由规则不在保留范围，自定义内容请全部通过 MITM Settings 管理。合并结果会先过内核校验，失败时退回纯订阅内容，不会把 VPN 弄坏。MITM Settings 入口已对订阅（remote）配置开放：Edit Profile -> MITM Settings。

**IPA 覆盖更新**

运行配置保存在固定 App Group，不在 `.app` 安装包内。每次保存还会生成两份完整恢复副本：App Group 的 `Backups/Profiles/`，以及文件 App 的 `我的 iPhone/sing-box/Profiles/`。若更新后运行路径中的 `configs/config_N.json` 缺失，App 会在读取时自动从恢复副本重建。

Bundle ID、App Group 和签名权限必须保持一致。iOS 卸载 App 时仍可能删除 App 容器及“我的 iPhone”目录；需要卸载时，应先把 Files 中的备份复制到 Downloads、iCloud Drive 或其他位置。

**文件 App 镜像（备份）**

每次保存配置、订阅更新或 App 启动时，本地和远程 Profile 会自动复制到文件 App 的 `我的 iPhone/sing-box/Profiles/`，文件名沿用 `config_N.json`。该目录是恢复源之一；直接编辑它不会立即修改正在运行的配置，但主配置缺失时会读取它进行恢复。备份包含 `certificate.tls_decryption.key_pair_p12` 和密码，可完整恢复 MITM CA，因此不得把文件发送给不可信对象。
