# 变更记录

版本号同时出现在 `bin/ysctl` 的 `VERSION` 与 `ui/Info.plist` 的 `CFBundleShortVersionString`。

## v1.3.1 — 2026-10-21

- 修复：**把别的 TUN 型 VPN 误判成"云枢已连接"**。原判定只看"某个 utun 上挂着大量路由"，
  如果同时开着 Clash / Surge 之类的 TUN 模式（fake-IP `198.18.0.0/15`），`ysctl up` 会直接
  报「已处于连接状态，无需操作」而根本不点连接 —— 这正是"一键连接不连"的一个真凶。
  现在判定要求：云枢的关键进程在跑 + 排除 RFC 2544 保留网段（198.18/198.19）；
- 修复：网关是 `link#N` 时，`status` 显示的"本地地址"改为该接口自己的 inet 地址；
- 说明：此前 `status` 在云枢完全停止时仍可能显示"已连接"，现与 `state` 一致。

## v1.3.0 — 2026-10-21

**面向新手的发布版本。**

- 新增：首次启动检测到免密助手缺失时，弹出「还差一步配置」，点一下即可完成 `ysctl setup`，
  不必再去终端敲命令（等价于 `ysctl setup`，只需一次开机密码）；
- 调整：DMG 产物改名 `dist/YunShuSwitch.dmg`（ASCII 文件名，下载链接不会被中文转义搞坏），卷名仍是「云枢开关」；
- 文档：README 重写为新手视角（下载 → 拖拽 → 两次授权 → 使用）；新增
  [编译与打包](docs/编译与打包.md)、[实现原理](docs/技术原理.md)、[排障手册](docs/排障.md)；
- 新增：GitHub Actions 工作流（`macos-14` 上编译 + 打包 + 上传 artifact）；
- 新增：MIT 许可证；
- 随 DMG 的《使用说明》同步更新。

## v1.2.0 — 2026-10-21

**修复"每次都要输密码"和"一键连接不连"。**

- 修复：`run_admin` 不再"助手执行失败就回退密码框"，改为以助手真实的返回码收尾，
  消除重复弹窗与 `up` 被误判失败（旧逻辑下 `up` 会在第 1 步就 `return`，根本走不到"点连接"）；
- 修复：`priv_ready` 的探测只用 `check` 子命令，导致 sudoers 漏了 `up`/`down` 时仍显示 ✅；
  现在 `priv_run` 会区分"sudo 自身没跑起来"与"助手执行了但返回非 0"；
- 新增：`ysctl fix` —— 重写免密规则 + 校正辅助功能 + 自检，一条命令修完；
- 新增：菜单栏「一键修复（免密/授权）」；
- 新增：3 次点击仍未连上时，自动**重启云枢主程序再点一次**（解决冷启动"静默空操作"）；
- 新增：`perform` 150 秒看门狗，避免卡在系统密码框时 `busy` 永真、之后点菜单没反应；
- 新增：日志记录 `PRIV ok=/why=/err=` 与 `ADMIN fallback`；
- 修复：`cmd_setup` 装完未清 `priv_ready` 缓存，导致"装好了却报无法复核"。

## v1.1.0 — 2026-10-20

**提速 + 打包。**

- 性能：AX 等待从"查一次睡 1 秒"改为 0.1 秒轮询；所有 `sleep` 换成墙钟 deadline 轮询；
  隧道探测聚合为单次 `netstat` + 0.6 秒缓存；日志时间戳改用内建 `strftime`；
- 修复：`wait_tunnel 45` 因循环次数算错实际只等 27 秒；
- 新增：用菜单文案（`连接网络` ⇄ `断开网络`）判断点击是否生效，4.5 秒未翻转就补点；
- 新增：`ysctl down -y` 跳过确认；
- 结果：`up` 脚本开销 5.1 s → 1.2 s（总时长 7.9 s → 5.4~6.5 s，差额是云枢建隧道）；
  `down` 开销 2.0 s → 0.9 s；`state` 0.45 s → 0.2 s；
- 新增：DMG 安装盘（App + 应用程序快捷方式 + 使用说明），图标与背景由 `tools/Artwork.swift` 绘制；
- 教训：**不要**让云枢先于守护进程启动——实测会稳定触发"点连接无效"，顺序必须严格串行。

## v1.0.0 — 2026-10-20

首个可用版本。

- `bin/ysctl`：`up` / `down` / `toggle` / `status` / `state` / `doctor` / `ax` / `setup` / `unsetup`；
- 菜单栏 App：`AXUIElement` + `AXPress` 点击云枢按钮，CLI 通过 `ax.request` / `ax.response` 借用其授权；
- 受限 root 助手 `yunshu-priv` + sudoers NOPASSWD，实现免密启停守护进程；
- 用 Apple Development 证书签名，使 TCC 授权在重编译后依然有效；
- 实测澄清：`defaults write com.eagleyun.sase CONNECT -bool true` **不是**自动连接开关（程序启动后会改回 0）。
