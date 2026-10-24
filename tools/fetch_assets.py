#!/usr/bin/env python3
"""构建期抓取游戏资源到 www/（纯标准库，macOS runner 上直接可用）。

为什么放在构建期而不是提交进仓库：
  资源带 build hash，站点每次发版都会变。若把 www/ 提交进仓库，
  一星期后就全是过期文件，反而要人工同步。构建时按当前首页现场抓，
  永远对得上线上版本。

抓什么：
  index.html / version.json / favicon / manifest，加上从 index.html 出发
  沿 JS、CSS 依赖图能走到的 /assets/*，再补上 JS 里硬编码的 data/*.json。
  静态图、模型这些大件不抓——运行时由本地服务回源拿，不影响能不能玩。

抓不全会怎样：
  脚本对单个文件失败只警告不退出；只有首页拿不到才返回 1。
  缺的文件客户端会回源代理，最坏情况是「没加速但能玩」。
"""

import os
import re
import sys
import time
import urllib.request
import urllib.error

BASE = os.environ.get("PB_BASE", "https://pokebonk.com").rstrip("/")
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")

MAX_TEXT = 6 * 1024 * 1024      # 超过这个体积的 JS 不做扫描
TOTAL_BUDGET = 40 * 1024 * 1024  # 总下载量上限，防止意外抓成几百 MB
MAX_FONTS = 20                   # 字体按 unicode-range 切片，动辄上千个，只留少量
MAX_FILES = 260                  # 总文件数上限

# 首页/chunk 里出现的资源引用
RE_ASSETS = re.compile(
    r"(?:\./|/|https://pokebonk\.com/)?assets/"
    r"([A-Za-z0-9._@%\-]+\.(?:js|css|json|webmanifest|woff2?|ttf))")
RE_REL = re.compile(r"[\"']\./([A-Za-z0-9._@%\-]+\.(?:js|css))[\"']")
RE_CSS_URL = re.compile(r"url\(\s*[\"']?\.?/?([A-Za-z0-9._@%\-]+\.(?:woff2?|ttf|png|jpg|svg))[\"']?\s*\)")
# data/ 下允许子目录：国际化文案在 data/i18n/<lang>.json，早期正则只认 data/xxx.json
RE_DATA = re.compile(r"[\"'](?:\./)?(data/[A-Za-z0-9._@%\-/]+\.json)[\"']")

# 动态 import 出来的 chunk 在 main chunk 里是「裸名」字符串（zh-e36HqkoY-mvmmkftc.js），
# 既没有 ./ 也没有 assets/ 前缀，上面几条正则都匹配不到 —— 语言包就是这么漏掉的。
# 这里按当前 build 现场拼正则，只认本版命名的文件，避免误抓同名静态资源。
RE_CHUNK = re.compile(r"^$")

ALWAYS = ["/", "/version.json", "/favicon.ico", "/manifest.webmanifest"]

# 可选：显式指定代理（本地调试用；GitHub runner 直连，不需要）
_proxy = os.environ.get("PB_PROXY")
if _proxy:
    urllib.request.install_opener(urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": _proxy, "https": _proxy})))


def get(path, timeout=45, retries=3):
    url = BASE + path
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={
                "User-Agent": UA,
                "Accept": "*/*",
                "Accept-Encoding": "identity",   # 不让 CDN 压缩，省掉解压
            })
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last = "HTTP %s" % e.code
            if e.code == 404:
                break
        except Exception as e:                   # noqa: BLE001
            last = "%s: %s" % (type(e).__name__, e)
        time.sleep(1.5 * attempt)
    print("    ! %-58s %s" % (path, last), flush=True)
    return None


def save(root, path, data):
    rel = "index.html" if path == "/" else path.lstrip("/")
    full = os.path.join(root, rel)
    os.makedirs(os.path.dirname(full) or root, exist_ok=True)
    with open(full, "wb") as f:
        f.write(data)
    return rel


def refs_of(text):
    out = set()
    for m in RE_ASSETS.finditer(text):
        out.add("/assets/" + m.group(1))
    for m in RE_REL.finditer(text):
        out.add("/assets/" + m.group(1))
    for m in RE_CSS_URL.finditer(text):
        out.add("/assets/" + m.group(1))
    for m in RE_CHUNK.finditer(text):
        out.add("/assets/" + m.group(1))
    for m in RE_DATA.finditer(text):
        out.add("/" + m.group(1))
    return out


def main():
    global RE_CHUNK
    root = sys.argv[1] if len(sys.argv) > 1 else "www"
    os.makedirs(root, exist_ok=True)

    print("=== 起点 %s ===" % BASE, flush=True)
    total = 0
    fetched = {}

    index = get("/")
    if index is None:
        print("!! 首页取不到：网络不通或站点已变更", flush=True)
        return 1
    save(root, "/", index)
    total += len(index)
    print("  OK  /  (%d B)" % len(index), flush=True)

    mb = re.search(r'pokebonk-build"\s+content="([^"]+)"', index.decode("utf-8", "ignore"))
    if mb:
        # 不锁定引号：语言包是反引号模板字符串（import(`./zh-xxx.js`)），单双引号都会漏。
        # 名字里不含 /，所以扫描时天然会跳过路径前缀，只取文件名本身。
        RE_CHUNK = re.compile(
            r"([A-Za-z0-9._@%\-]+-" + re.escape(mb.group(1)) + r"\.(?:js|css))")
        print("  当前 build = %s" % mb.group(1), flush=True)
    else:
        print("  ! 首页没有 pokebonk-build，跳过裸名 chunk 识别", flush=True)

    queue = list(refs_of(index.decode("utf-8", "ignore")))
    seen = set(queue)

    for p in ALWAYS[1:]:
        if p not in seen:
            seen.add(p)
            queue.append(p)

    # 广度优先展开依赖图（首页 → 入口 chunk → 主 chunk → 子 chunk/CSS/字体）
    round_no = 0
    fonts = 0
    skipped = 0
    while queue and round_no < 6:
        round_no += 1
        batch, queue = queue, []
        print("--- 第 %d 层：%d 个 ---" % (round_no, len(batch)), flush=True)

        for path in batch:
            if total > TOTAL_BUDGET or len(fetched) > MAX_FILES:
                print("  ! 已达下载上限，停止展开", flush=True)
                queue = []
                break

            # 字体在 CSS 里按 unicode-range 切成上千片，绝大部分永远用不到；
            # 留一小批常见的，其余运行时回源。
            if path.endswith((".woff", ".woff2", ".ttf")):
                fonts += 1
                if fonts > MAX_FONTS:
                    skipped += 1
                    continue

            data = get(path)
            if data is None:
                fetched[path] = None
                continue
            save(root, path, data)
            fetched[path] = len(data)
            total += len(data)
            print("  OK  %-58s %8d B" % (path, len(data)), flush=True)

            if path.endswith((".js", ".css", ".html")) and len(data) < MAX_TEXT:
                for r in refs_of(data.decode("utf-8", "ignore")):
                    if r not in seen:
                        seen.add(r)
                        queue.append(r)

    ok = sum(1 for v in fetched.values() if v)
    miss = [k for k, v in fetched.items() if v is None]

    files = sum(len(f) for _, _, f in os.walk(root))
    size = sum(os.path.getsize(os.path.join(d, f))
               for d, _, fs in os.walk(root) for f in fs)
    print("\n=== 完成：%d 个成功 / %d 个失败 / %d 个字体跳过，目录 %d 个文件 %.1f MB ==="
          % (ok, len(miss), skipped, files, size / 1048576.0), flush=True)
    if miss:
        for m in miss:
            print("  缺 %s（运行时回源）" % m, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
