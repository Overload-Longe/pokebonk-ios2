#!/usr/bin/env bash
# 在 macOS 上生成未签名的 ipa（不需要 Xcode 工程，不需要开发者账号）。
# 用法：bash build-ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Payload/PokeBonk.app"
OUT="$ROOT/PokeBonk-unsigned.ipa"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "!! 找不到 xcrun：这个脚本必须在 macOS 上跑（装了 Xcode 或 Command Line Tools）"
  exit 1
fi

if [ ! -d "$ROOT/www" ]; then
  echo "!! 缺少 www/ 目录（游戏资源）。先在项目根目录准备好资源。"
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$APP"

echo "=== 编译 (arm64, iOS 14.0+) ==="
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "    SDK: $SDK_PATH"
xcrun --sdk iphoneos swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-ios14.0 \
  -parse-as-library \
  -O -whole-module-optimization \
  -framework UIKit -framework WebKit -framework Network -framework Foundation \
  -o "$APP/PokeBonk" \
  "$ROOT/Sources/App.swift"

echo "=== 校验二进制 ==="
file "$APP/PokeBonk"
xcrun vtool -show-build "$APP/PokeBonk" | head -12

echo "=== 组装 bundle ==="
cp "$ROOT/Info.plist" "$APP/Info.plist"
if [ -d "$ROOT/Resources" ]; then
  cp "$ROOT/Resources"/*.png "$APP/" 2>/dev/null || true
fi
cp -R "$ROOT/www" "$APP/www"
find "$APP" -name ".DS_Store" -delete
find "$APP" -name "__MACOSX" -type d -exec rm -rf {} + 2>/dev/null || true

echo "    资源：$(find "$APP/www" -type f | wc -l | tr -d ' ') 个文件 / $(du -sh "$APP/www" | cut -f1)"

echo "=== 打包 ipa ==="
rm -f "$OUT"
(cd "$BUILD" && zip -qry "$OUT" Payload)

echo "=== 结果 ==="
ls -lh "$OUT"
unzip -l "$OUT" | head -8
echo
echo "✅ 未签名 ipa：$OUT"
echo "   接下来用 Sideloadly / AltStore / TrollStore 自己签，或者直接喂给你的签名工具。"
