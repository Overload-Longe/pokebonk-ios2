# PokeBonk iOS（未签名 ipa，GitHub Actions 云端编译）

把 <https://pokebonk.com>（Vite + Three.js 网页游戏）做成 iOS 客户端。
资源缓存在本地，网络只用来登录和补缺。

> 本仓库只放源码。游戏资源在**构建时**从官网现场抓取，不进仓库
> （资源名带 build hash，每周都会变，提交进仓库第二天就过期）。

## 一、怎么出 ipa

推送到 `main` 会自动开始编译（也可以到 Actions 页面点 `Run workflow`）。
macos-14 runner 上跑完约 3~5 分钟，在 Actions 运行详情页底部 **Artifacts** 下载
`PokeBonk-unsigned-ipa`，解压得到 `PokeBonk-unsigned.ipa`。

本地也可以手动跑（需要 macOS + Xcode / CLT）：

```bash
python3 tools/fetch_assets.py www   # 抓资源（约 5 MB / 46 个文件）
python3 make_icons.py               # 生成图标
bash build-ipa.sh                   # 出 PokeBonk-unsigned.ipa
```

## 二、签名

仓库产物是**未签名**的。用你自己的证书签：

| 工具 | 说明 |
| --- | --- |
| Sideloadly / AltStore | 用 Apple ID 免费签，7 天有效期，需要重签 |
| 自购证书 + zsign / ldid | 可长期使用（视描述文件有效期而定） |
| TrollStore | 仅特定系统版本可用，装完不过期 |

`zsign` 示例：

```bash
zsign -k cert.p12 -p 密码 -m app.mobileprovision -o PokeBonk-signed.ipa PokeBonk-unsigned.ipa
```

## 三、为什么不能像桌面版/安卓版那样直接拦截 https

三个平台的加速原理看着一样，实现完全不同：

| 平台 | 拦截 https 的手段 |
| --- | --- |
| Windows / WebView2 | `AddWebResourceRequestedFilter` |
| Android / WebView | `shouldInterceptRequest` |
| **iOS / WKWebView** | **没有**（`WKURLSchemeHandler` 只能拦自定义 scheme，`NSURLProtocol` 对 WKWebView 无效） |

所以 iOS 这版换了个架构：

```
App 启动
  └─ NWListener 在 127.0.0.1 起一个只监听回环的 HTTP 服务（端口随机）
       ├─ 命中包内 www/  → 直接返回文件（MIME 按扩展名给准）
       ├─ /__api__/*     → 反向代理到 api.pokebonk.com
       └─ 其它           → 反向代理到 pokebonk.com
  └─ WKWebView 加载 http://127.0.0.1:<port>/
```

**API 同源处理**：主 chunk 里是 `fetch(this.base + path)`，base 来自
`https://api.pokebonk.com`（全包只出现 1 次）。返回 JS 时把这个字符串替换成
`http://127.0.0.1:<port>/__api__`，于是 API 与页面同源，绕开 CORS。
端口运行时才知道，所以只能动态替换 —— 好处是资源文件保持原样，
和桌面版、安卓版共用同一份镜像。

**反向代理故意不透传 `origin` / `referer`**：带上去会暴露 `127.0.0.1`，
服务端做来源校验时会直接拒。只透传 `authorization`、`cookie`、`x-device` 等身份头。

**降级**：本地服务起不来（极少数机型/系统限制）就直接加载 `https://pokebonk.com/`，
没有加速但能玩，不会变砖。

## 四、构建期抓资源（`tools/fetch_assets.py`）

纯标准库，`python3` 直接跑。行为：

1. 取首页 `index.html` + `version.json` + `favicon.ico` + `manifest.webmanifest`
2. 从首页出发按依赖图广度优先展开：`assets/*.js|css` → chunk 内部 `"./xxx.js"` → CSS 里的字体
3. 补上 JS 里硬编码的 `data/*.json`（宝可梦、招式、道具等数据表）
4. 上限：6 层、260 个文件、40 MB；字体只留 20 个（按 unicode-range 切片有上千个，
   运行时用到的极少，其余回源）

单个文件失败只警告；**首页取不到才返回 1**（那时页面根本没法本地化）。
没抓到的文件客户端会回源代理，所以抓得少不影响能不能玩，只影响加载快不快。

## 五、文件

```
Sources/App.swift                本地 HTTP 服务 + WKWebView（全部逻辑，约 420 行）
Info.plist                       包信息、ATS 放行 127.0.0.1、图标声明、方向
build-ipa.sh                     swiftc 直接编译 → 手工组装 .app → zip 成 ipa
make_icons.py                    纯标准库生成 AppIcon（无 Pillow）
tools/fetch_assets.py            构建期抓取游戏资源
.github/workflows/build-ipa.yml  macos-14 上编译并上传 Artifact
```

## 六、已知风险

- **本工程未在真机验证过**。静态检查通过（plist 可解析、括号平衡、资源 0 缺失），
  但 `swiftc` 在 macos-14 上第一次跑可能出现编译错误，看 Actions 日志逐条修即可。
- 音频请求未实现 `Range`，若游戏用 `<audio>` 拖进度可能异常（音乐一般不受影响）。
- 手机上**必须能访问境外网络**（VPN/代理），否则登录和补资源都会卡住。
- 图标用 `CFBundleIcons → CFBundleIconFiles` 声明。个别签名工具要求
  `Assets.car`，若安装后图标空白，用 Sideloadly 重签一次通常就正常。

## 七、权利说明

游戏内容版权归 PokeBonk 官方所有。本仓库只是把网页包一层客户端做本地缓存加速，
不含任何破解、修改存档或绕过服务端校验的逻辑 —— 联机资格、账号体系仍由服务端判定。
