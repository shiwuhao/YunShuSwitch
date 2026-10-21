#!/bin/zsh
# 安装 / 卸载 云枢开关
#   ./install.sh             安装命令行工具 + 菜单栏 App，并立即启动
#   ./install.sh --autostart 额外让它开机自启（登录时自动出现菜单栏图标）
#   ./install.sh --uninstall 卸载（不动云枢本体）
set -e
emulate -L zsh

ROOT="${0:A:h}"
SHARE="$HOME/.local/share/yunshu-switch"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/Applications"
APP_SRC="$ROOT/build/YunshuSwitch.app"
APP_DST="$APPS_DIR/云枢开关.app"
APP_LEGACY="$APPS_DIR/YunshuSwitch.app"     # 旧版英文名，安装时顺手清掉
AGENT_PLIST="$HOME/Library/LaunchAgents/com.shiwuhao.yunshuswitch.plist"

AUTOSTART=0
[[ ${1:-} == "--autostart" ]] && AUTOSTART=1

if [[ ${1:-} == "--uninstall" ]]; then
  echo "▶ 卸载云枢开关"
  if [[ -f /usr/local/sbin/yunshu-priv ]]; then
    echo "⚠️  免密助手还在系统里，请先执行：$BIN_DIR/ysctl unsetup"
    exit 1
  fi
  pkill -f "Contents/MacOS/YunshuSwitch" 2>/dev/null || true
  launchctl bootout "gui/$UID/com.shiwuhao.yunshuswitch" 2>/dev/null || true
  rm -f "$AGENT_PLIST" "$BIN_DIR/ysctl"
  rm -rf "$SHARE" "$APP_DST" "$APP_LEGACY"
  echo "✅ 已卸载（云枢本体与系统守护进程未做改动）"
  exit 0
fi

# 1. 编译（若尚未构建）
if [[ ! -d "$APP_SRC" ]]; then
  echo "▶ 未发现构建产物，先编译"
  "$ROOT/build.sh"
fi

# 2. 安装 CLI 共享目录
echo "▶ 安装命令行工具到 $SHARE"
mkdir -p "$SHARE" "$BIN_DIR" "$APPS_DIR"
cp "$ROOT/bin/ysctl" "$SHARE/ysctl"
cp "$ROOT/lib/ui.applescript" "$SHARE/ui.applescript"
cp "$ROOT/lib/yunshu-priv" "$SHARE/yunshu-priv"
chmod +x "$SHARE/ysctl" "$SHARE/yunshu-priv"
ln -sf "$SHARE/ysctl" "$BIN_DIR/ysctl"

# 3. 安装菜单栏 App（cp -R 会保留 build.sh 做好的临时签名）
echo "▶ 安装菜单栏 App 到 $APP_DST"
pkill -f "Contents/MacOS/YunshuSwitch" 2>/dev/null || true
sleep 1
rm -rf "$APP_DST" "$APP_LEGACY"
cp -R "$APP_SRC" "$APP_DST"

# 记下 App 实际位置，供 ysctl 定位（App 被挪走也能找到）
mkdir -p "$HOME/Library/Application Support/YunshuSwitch"
printf '%s\n' "$APP_DST" > "$HOME/Library/Application Support/YunshuSwitch/app.path"

# 4. 可选：登录自启
if (( AUTOSTART )); then
  echo "▶ 配置登录自启"
  mkdir -p "${AGENT_PLIST:h}"
  cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.shiwuhao.yunshuswitch</string>
  <key>ProgramArguments</key>
  <array><string>$APP_DST/Contents/MacOS/YunshuSwitch</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$UID/com.shiwuhao.yunshuswitch" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null || true
fi

# 5. 立即启动（菜单栏工具装完就该能看见）
echo "▶ 启动菜单栏工具"
pkill -f "Contents/MacOS/YunshuSwitch" 2>/dev/null || true
sleep 1
open "$APP_DST"

# 6. 校验
echo "▶ 自检"
sleep 2
"$BIN_DIR/ysctl" doctor || true

# 免密助手是否落后于随包版本（改过 lib/yunshu-priv 又没 setup 时会命中）
if [[ -x /usr/local/sbin/yunshu-priv ]] && ! cmp -s /usr/local/sbin/yunshu-priv "$SHARE/yunshu-priv"; then
  echo ""
  echo "⚠️  系统里的免密助手是旧版，执行这一条同步（一次性密码）："
  echo "      $BIN_DIR/ysctl setup --force"
fi

if pgrep -f "Contents/MacOS/YunshuSwitch" >/dev/null; then
  echo ""
  echo "✅ 菜单栏工具已在运行——看屏幕右上角菜单栏的「网络」图标"
else
  echo ""
  echo "⚠️  菜单栏工具没启动起来，请手动打开：$APP_DST"
fi

cat <<EOF

✅ 安装完成

  命令行：$BIN_DIR/ysctl  (up / down / toggle / status / setup)
  应用  ：$APP_DST
  日志  ：~/Library/Logs/YunshuSwitch/  （ysctl.log 操作日志，app.log 启动/图标日志）

下一步（只需做一次）：
  0) 免密提权——让 up/down 不再反复弹密码框（只需输一次密码）：
       $BIN_DIR/ysctl setup
  1) 授权「辅助功能」——自动点“连接网络/断开网络”靠它：
       - 刚启动的菜单栏 App 会弹出系统授权提示，点「打开系统设置」并勾选 YunshuSwitch
       - 或者执行：$BIN_DIR/ysctl ax
     （注意：授权对象是「云枢开关」（YunshuSwitch.app），不是终端，也不是 osascript）
  2) 若 \`ysctl\` 提示 command not found，把这一行加进 ~/.zshrc：
       export PATH="\$HOME/.local/bin:\$PATH"
  3) 想开机自动出现菜单栏图标：./install.sh --autostart

卸载：$ROOT/install.sh --uninstall
EOF
