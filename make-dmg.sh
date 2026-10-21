#!/bin/zsh
# make-dmg.sh —— 打包发布盘：双击打开就是「App + 应用程序快捷目录 + 使用说明」，
# 把 App 拖进「应用程序」即完成安装。
#
#   ./make-dmg.sh            生成 dist/YunShuSwitch.dmg（盘内卷名仍是「云枢开关」）
#
# 依赖：build.sh 已构建（或本脚本自动构建一次）；macOS 自带 hdiutil / diskutil。
set -e
emulate -L zsh
set -e            # emulate -L 会把选项复位，这里再开一次，否则中途失败不会中断

ROOT="${0:A:h}"
VOL="云枢开关"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/ui/Info.plist" 2>/dev/null || print 0.0.0)"
# 成品用 ASCII 文件名：下载链接不会因为中文被 URL 转义搞坏；显示名（卷名）仍是中文
DMG="$ROOT/dist/YunShuSwitch.dmg"
STAGE="$ROOT/build/dmg-root"
RW="$ROOT/build/${VOL}-rw.dmg"
MNT="$ROOT/build/dmg-mnt"

# 1. 确保 App 是新构建的
if [[ ! -d "$ROOT/build/YunshuSwitch.app" ]] || [[ bin/ysctl -nt build/YunshuSwitch.app/Contents/Resources/ysctl ]]; then
  echo "▶ 构建 App"
  "$ROOT/build.sh"
fi
if [[ ! -f "$ROOT/build/artwork" ]]; then
  echo "▶ 编译绘图工具"
  xcrun swiftc -O "$ROOT/tools/Artwork.swift" -o "$ROOT/build/artwork"
fi
if [[ ! -f "$ROOT/ui/AppIcon.icns" ]]; then
  echo "▶ 生成图标"
  "$ROOT/build/artwork" icon "$ROOT/build/AppIcon-1024.png"
  rm -rf "$ROOT/build/AppIcon.iconset"
  mkdir -p "$ROOT/build/AppIcon.iconset"
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$ROOT/build/AppIcon-1024.png" \
      --out "$ROOT/build/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
    d=$((sz * 2))
    sips -z $d $d "$ROOT/build/AppIcon-1024.png" \
      --out "$ROOT/build/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/ui/AppIcon.icns"
fi
if [[ ! -f "$ROOT/build/dmg-bg.png" ]]; then
  "$ROOT/build/artwork" dmg "$ROOT/build/dmg-bg.png"
fi

# 2. 组装拖拽目录（三个条目 + 隐藏的背景图目录）
echo "▶ 组装拖拽目录"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$ROOT/build/YunshuSwitch.app" "$STAGE/云枢开关.app"
ln -s /Applications "$STAGE/应用程序"
cp "$ROOT/assets/使用说明.txt" "$STAGE/使用说明.txt"
cp "$ROOT/build/dmg-bg.png" "$STAGE/.background/bg.png"

# 3. 先做一个空白可写镜像，再挂到工作区里的目录
#    ⚠️ 三处坑（新版 macOS 都踩过）：
#    ① `hdiutil create -srcfolder` 默认压成 UDZO 只读，写 .DS_Store 会报
#       「Read-only file system」——所以自己建 UDRW 空白盘再往上拷；
#    ② `hdiutil attach -mountpoint` 已废弃且常被忽略，转挂到 /Volumes/<卷名>，
#       在 /Volumes 下写盘容易触发系统/Finder 的权限拦截，所以改用
#       `diskutil image attach --mountPoint`，挂在工作区内；
#    ③ `emulate -L zsh` 会复位选项，`set -e` 要在它之后再开一次。
echo "▶ 创建空白镜像"
mkdir -p "${DMG:h}" "$MNT"
rm -f "$RW"
hdiutil create -size 40m -fs HFS+ -volname "$VOL" "$RW" >/dev/null

echo "▶ 挂载并拷入"
diskutil image attach "$RW" --mountPoint "$MNT" --mountOptions nobrowse >/dev/null
trap "hdiutil detach '$MNT' -force >/dev/null 2>&1 || true" EXIT
cp -R "$STAGE/." "$MNT/"

# 4. 排版：窗口大小 / 图标大小 / 背景图 / 图标位置
#    直接写 .DS_Store（纯文件操作），不用 AppleScript —— 后者需要「自动化」授权，
#    在脚本里调用会静默失败（-1728），写出来的效果和 Finder 排完版完全一致。
echo "▶ 写入 .DS_Store 排版"
PY="$ROOT/.venv-artwork/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"
"$PY" "$ROOT/tools/mkdsstore.py" "$MNT" ".background/bg.png"

# 让 Finder 忘掉这个卷的旧视图缓存（否则可能沿用上次的窗口尺寸）
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes" 2>/dev/null || true

hdiutil detach "$MNT" >/dev/null 2>&1 || true
trap - EXIT

# 5. 转成压缩只读格式（先写临时名，成功后才替换成品）
echo "▶ 压缩镜像"
hdiutil convert "$RW" -format UDZO -o "${DMG%.dmg}-new.dmg" -ov >/dev/null
mv -f "${DMG%.dmg}-new.dmg" "$DMG"
rm -f "$RW"

echo "✅ 完成：$DMG（$(du -h "$DMG" | cut -f1)，版本 $VERSION）"
echo "   双击打开 → 把「云枢开关」拖进「应用程序」即安装完成。"
