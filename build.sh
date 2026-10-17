#!/bin/bash
# 编译并打包 MenuBarSqueeze.app（原生 AppKit，无第三方依赖）
#   用法: ./build.sh            → 构建到 ./build/MenuBarSqueeze.app
#         ./build.sh install    → 构建 + 装到 /Applications + 启动
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/MenuBarSqueeze.app"
BIN="$APP/Contents/MacOS/MenuBarSqueeze"

echo "==> 清理旧构建"
rm -rf "$DIR/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 复制 Info.plist"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

ARCH="$(uname -m)"          # arm64 / x86_64，CI 与本机都适用
echo "==> 编译（swiftc -O, target ${ARCH}-apple-macos13.0）"
swiftc -O \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit \
  -o "$BIN" \
  "$DIR/main.swift"

echo "==> 代码签名"
# 优先用 Apple Development 证书：指定要求(DR)基于证书+BundleID，跨重编译稳定，
# 「辅助功能」授权不会被撤销。没有证书才退回 ad-hoc（每次重编译都要重新授权）。
if [ "${FORCE_ADHOC:-0}" = "1" ]; then
  IDENTITY=""            # 发布/CI：强制 ad-hoc，不嵌入个人开发证书
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ && !/REVOKED/ {print $2; exit}')"
fi
if [ -n "${IDENTITY:-}" ]; then
  echo "    使用证书: $IDENTITY"
  if codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "    ✅ 证书签名成功（授权可跨重编译保留）"
  else
    echo "    ⚠️ 证书签名失败，退回 ad-hoc"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  fi
else
  echo "    未找到证书，使用 ad-hoc（注意：每次重编译需重新授权辅助功能）"
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> 完成: $APP"
ls -la "$BIN" | awk '{print "   可执行文件: "$5" 字节"}'

if [ "${1:-}" = "install" ]; then
  echo "==> 安装到 /Applications"
  [ -d "/Applications/MenuBarSqueeze.app" ] && { pkill -f "MenuBarSqueeze" 2>/dev/null || true; sleep 1; rm -rf "/Applications/MenuBarSqueeze.app"; }
  cp -R "$APP" /Applications/
  echo "==> 启动"
  open -a "/Applications/MenuBarSqueeze.app"
  sleep 2
  pgrep -fl MenuBarSqueeze | head -2 | sed 's/^/   /'
fi
