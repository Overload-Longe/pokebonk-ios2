"""从本地镜像刷新 seed/（把「稳定命名」的资源同步进仓库）。

游戏里大量资源是按 ID 动态请求的（assets/models/<id>.glb、assets/pmd/<id>.png …），
名字里没有 build hash，跨版本基本不变。桌面版客户端跑一段时间后，mirror/ 里会攒下
玩家真正用到过的那些 —— 用它来刷新 seed，iOS 包就更接近「装完即全本地」。

用法（在仓库根目录）：
    python3 tools/sync_seed.py "C:/Users/Longe/Desktop/PokeBonk-Desktop-win64/mirror"

只同步这几个目录，其余（带 hash 的 js/css/字体）一律不进 seed —— 那些由构建期抓。
"""

import os
import shutil
import sys

STABLE_DIRS = ["models", "pmd", "portraits", "items", "icons", "ui", "env", "cries", "music"]


def main():
    if len(sys.argv) < 2:
        print("用法: python3 tools/sync_seed.py <mirror 目录>")
        raise SystemExit(2)

    mirror = os.path.join(sys.argv[1], "assets")
    if not os.path.isdir(mirror):
        print("找不到 %s" % mirror)
        raise SystemExit(1)

    seed = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "seed", "assets")

    added = updated = 0
    for d in STABLE_DIRS:
        src_dir = os.path.join(mirror, d)
        if not os.path.isdir(src_dir):
            continue
        for root, _dirs, files in os.walk(src_dir):
            for f in files:
                src = os.path.join(root, f)
                rel = os.path.relpath(src, mirror)
                dst = os.path.join(seed, rel)
                if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src):
                    continue
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
                if os.path.exists(dst):
                    added += 1

    total = sum(len(f) for _, _, f in os.walk(seed))
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(seed) for f in fs)
    print("seed 同步完成：本次新增/更新 %d 个，当前共 %d 个 / %.1f MB"
          % (added, total, size / 1048576.0))


main()
