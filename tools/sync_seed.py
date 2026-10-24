"""从本地镜像刷新 seed/（把「稳定命名」的资源同步进仓库）。

游戏里大量资源是按 ID 动态请求的（assets/models/<id>.glb、assets/pmd/<id>.png …），
名字里没有 build hash，跨版本基本不变。桌面版客户端跑一段时间后，mirror/ 里会攒下
玩家真正用到过的那些 —— 用它来刷新 seed，iOS 包就更接近「装完即全本地」。

用法（在仓库根目录）：
    python3 tools/sync_seed.py "C:/Users/Longe/Desktop/PokeBonk-Desktop-win64/mirror"

只同步这几个目录，其余（带 hash 的 js/css/字体）一律不进 seed —— 那些由构建期抓。

coop/ 明确排除：那是站点某个旧版（0.8.34）的联机子应用快照，一直没跟着更新，
留着既占体积又可能让客户端加载到版本不匹配的素材。
"""

import os
import shutil
import sys

# 相对 mirror/assets 的目录，落到 seed/assets/ 下
STABLE_DIRS = ["models", "pmd", "portraits", "items", "icons", "ui", "env", "cries", "music"]

# 相对 mirror 根、需要原样保留路径的独立子树（entrenador 有自己的 assets 副本）
EXTRA_TREES = ["entrenador"]


def copy_tree(src_root, dst_root):
    """把 src_root 整棵树补进 dst_root；同名同大小视为已存在，不重复拷。"""
    n = 0
    if not os.path.isdir(src_root):
        return 0
    for root, _dirs, files in os.walk(src_root):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, src_root)
            dst = os.path.join(dst_root, rel)
            if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            n += 1
    return n


def main():
    if len(sys.argv) < 2:
        print("用法: python3 tools/sync_seed.py <mirror 目录>")
        raise SystemExit(2)

    mirror = sys.argv[1]
    if not os.path.isdir(os.path.join(mirror, "assets")):
        print("找不到 %s/assets" % mirror)
        raise SystemExit(1)

    seed_root = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "seed")

    added = 0
    for d in STABLE_DIRS:
        added += copy_tree(os.path.join(mirror, "assets", d),
                           os.path.join(seed_root, "assets", d))
    for t in EXTRA_TREES:
        added += copy_tree(os.path.join(mirror, t), os.path.join(seed_root, t))

    total = sum(len(f) for _, _, f in os.walk(seed_root))
    size = sum(os.path.getsize(os.path.join(r, f))
               for r, _, fs in os.walk(seed_root) for f in fs)
    print("seed 同步完成：本次新增/更新 %d 个，当前共 %d 个 / %.1f MB"
          % (added, total, size / 1048576.0))


main()
