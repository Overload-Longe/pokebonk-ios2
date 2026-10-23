"""把 seed/ 里「稳定命名」的资源合并进已经抓好的 www/。

为什么需要这一步：
    游戏的大量资源是按 ID 动态拼路径请求的（assets/models/<id>.glb、
    assets/pmd/<id>.png 等），扫描 JS 和 HTML 都发现不了。它们名字里没有
    build hash，跨版本基本不变，所以用「随仓库提交的种子目录」补上，
    这样 App 装完就是本地的，不用每次进游戏再慢慢下。

优先级：
    先 fetch_assets.py 抓当前版本（core：js/css/woff2/data），再合并 seed，
    已存在的文件不覆盖 —— 线上新版本永远优先，种子只负责补空缺。

用法：
    python3 tools/merge_seed.py seed www
"""

import os
import shutil
import sys


def main():
    seed = sys.argv[1] if len(sys.argv) > 1 else "seed"
    dst = sys.argv[2] if len(sys.argv) > 2 else "www"

    if not os.path.isdir(seed):
        print("没有 seed/ 目录，跳过合并")
        return

    added = 0
    kept = 0
    total_bytes = 0

    for root, _dirs, files in os.walk(seed):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, seed)
            out = os.path.join(dst, rel)
            if os.path.exists(out):
                kept += 1
                continue
            os.makedirs(os.path.dirname(out) or dst, exist_ok=True)
            shutil.copy2(src, out)
            added += 1
            total_bytes += os.path.getsize(out)

    print("seed 合并：新增 %d 个（%.1f MB），已存在跳过 %d 个"
          % (added, total_bytes / 1048576.0, kept))


main()
