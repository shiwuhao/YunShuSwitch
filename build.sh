#!/bin/zsh
# 构建菜单栏小工具 YunshuSwitch.app（arm64）
# 注意：`emulate -L zsh` 会把 shell 选项复位，所以 set -e 必须写在它之后。
emulate -L zsh
set -e

ROOT="${0:A:h}"
APP="$ROOT/build/YunshuSwitch.app"

echo "▶ 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ 编译 Swift"
xcrun swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework ApplicationServices \
  -o "$APP/Contents/MacOS/YunshuSwitch" \
  "$ROOT/ui/YunshuSwitch.swift"

echo "▶ 写入 Info.plist"
cp "$ROOT/ui/Info.plist" "$APP/Contents/Info.plist"
plutil -convert binary1 "$APP/Contents/Info.plist"

echo "▶ 内置 ysctl 副本（App 自包含，拖到「应用程序」就能用）"
cp "$ROOT/bin/ysctl" "$APP/Contents/Resources/ysctl"
cp "$ROOT/lib/ui.applescript" "$APP/Contents/Resources/ui.applescript"
cp "$ROOT/lib/yunshu-priv" "$APP/Contents/Resources/yunshu-priv"
chmod +x "$APP/Contents/Resources/ysctl" "$APP/Contents/Resources/yunshu-priv"

echo "▶ 生成图标（可选）"
if [[ -f "$ROOT/ui/AppIcon.icns" ]]; then
  cp "$ROOT/ui/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▶ 签名（优先用本机开发证书，保证「辅助功能」授权在重编译后不失效）"
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --deep --sign "$SIGN_ID" --identifier com.shiwuhao.yunshuswitch "$APP" && \
    echo "  已用证书签名：$SIGN_ID"
else
  codesign --force --deep --sign - --identifier com.shiwuhao.yunshuswitch "$APP" 2>/dev/null && \
    echo "  未找到开发证书，已使用临时签名（重编译后需重新授权）"
fi

echo "✅ 构建完成：$APP"
echo "   安装到 ~/Applications：./install.sh"
