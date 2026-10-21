// 云枢开关 —— 菜单栏一键控制云枢（Yunshu / eagleyun SASE）
//
// 设计要点：
//   1. 界面动作（点「立即连接」/「断开连接」）由本 App 自己通过 Accessibility API 完成，
//      不再走 osascript。这样用户只需要给本 App 授予一次「辅助功能」权限，
//      且不依赖终端、也不依赖「自动化」权限。
//   2. 命令行 ysctl 通过 $SUPPORT/ax.request / ax.response 两个文件与本 App 通信，
//      因此终端里执行 ysctl up / down 也能复用同一份已授权的进程。
//   3. 本 App 定期把辅助功能授权状态写入 ax.status，供 ysctl status 读取（无需启动 App）。
//
// 编译：见 build.sh（arm64 / macOS 13+）

import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 属性

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var headerItem: NSMenuItem!
    private var detailItem: NSMenuItem!
    private var connectItem: NSMenuItem!
    private var disconnectItem: NSMenuItem!
    private var timer: Timer?
    private var axTimer: Timer?
    private var trustTimer: Timer?
    private var busy = false
    private var currentState = ""          // connected / idle / off
    private var trustWatchTicks = 0

    private let supportDir = NSHomeDirectory() + "/Library/Application Support/YunshuSwitch"
    private var reqPath: String { supportDir + "/ax.request" }
    private var resPath: String { supportDir + "/ax.response" }
    private var statusPath: String { supportDir + "/ax.status" }

    // 云枢主程序
    private let yunshuBundleID = "com.eagleyun.sase"
    private let yunshuPath = "/Applications/Yunshu.app"

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = symbol("network")
        buildMenu()
        statusItem.menu = menu
        if installCLILink() {
            logLine("CLI ready at \(cliLink)")
        }
        refresh()
        logLine("launched, ysctl=\(ysctlPath() ?? "nil") trusted=\(AXIsProcessTrusted())")

        if !AXIsProcessTrusted() {
            // 首次运行（或换了签名/安装位置后）：先清掉本 App 的旧授权记录，
            // 否则「辅助功能」列表里会留着指向旧副本的那一条 —— 用户勾了它，
            // 当前进程却依然不被信任，表现就是"明明打开了权限还一直提示"。
            resetAXTrust()
        }
        writeTrustStatus()

        // 图标是否真的被系统放进了菜单栏（菜单栏塞满时会被隐藏）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let visible = self.statusItem.button?.window != nil
            self.logLine("statusItem visible=\(visible)")
            if !visible { self.warnMenuBarFull() }
        }

        // 首次使用：免密助手没装就给一个「一键配置」入口，不把用户赶去终端敲命令
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.firstRunCheck()
        }

        timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)   // 弹窗/拖拽时也要能跑

        // 命令通道：每 0.1 秒看一次有没有 ysctl 发来的请求（一次 open+读文件，开销可忽略）
        axTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollRequest()
        }
        RunLoop.main.add(axTimer!, forMode: .common)
        logLine("supportDir=\(supportDir)")
    }

    /// 首次使用检查：`/usr/local/sbin/yunshu-priv` + sudoers 规则缺失时提示一键配置。
    /// 这一步等价于终端里的 `ysctl setup`，只需一次开机密码，之后 up / down 全免密。
    private func firstRunCheck() {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/usr/local/sbin/yunshu-priv"),
           fm.fileExists(atPath: "/etc/sudoers.d/yunshu-switch") {
            return
        }
        let alert = NSAlert()
        alert.messageText = "欢迎使用云枢开关 · 还差一步配置"
        alert.informativeText = """
        要一键启停云枢的守护进程，需要安装一个「免密提权助手」。只装这一次，之后连接/断开都不再问密码。

        点「立即配置」后，系统会要求输入一次开机密码（macOS 标准授权，本工具不接触你的密码）。
        若现在不方便，可以稍后在菜单里点「一键修复（免密/授权）」。
        """
        alert.addButton(withTitle: "立即配置")
        alert.addButton(withTitle: "稍后再做")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            perform(["setup"], name: "首次配置")
        }
    }

    private func warnMenuBarFull() {
        let alert = NSAlert()
        alert.messageText = "菜单栏图标没能显示出来"
        alert.informativeText = """
        程序已经在运行，但系统没有给图标分配位置——通常是菜单栏已经排满了（屏幕顶部空间不足）。
        可以：按住 ⌘ 拖动菜单栏图标调整顺序，或隐藏几个不常用的图标后重新打开本工具。
        你也可以先用命令行：ysctl up / ysctl down
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func logLine(_ text: String) {
        let dir = NSHomeDirectory() + "/Library/Logs/YunshuSwitch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/app.log"
        let line = "\(Date()) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self          // 每次展开菜单先刷一次，不用等 8 秒轮询

        headerItem = NSMenuItem(title: "云枢：状态读取中…", action: nil, keyEquivalent: "")
        headerItem.isEnabled = true       // 保持可用，否则系统会把彩色圆点一起置灰
        menu.addItem(headerItem)

        // 第二行只在已连接时显示：隧道 / 地址 / 路由条数
        detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        detailItem.isEnabled = true
        detailItem.isHidden = true
        menu.addItem(detailItem)

        menu.addItem(.separator())

        connectItem = NSMenuItem(title: "连接内网（启动并连接）", action: #selector(doUp), keyEquivalent: "")
        connectItem.target = self
        menu.addItem(connectItem)

        disconnectItem = NSMenuItem(title: "断开并禁用（彻底退出）", action: #selector(doDown), keyEquivalent: "")
        disconnectItem.target = self
        menu.addItem(disconnectItem)

        menu.addItem(.separator())

        add("刷新状态", #selector(doRefresh), "r")
        add("打开日志目录", #selector(openLogs), "")
        add("一键修复（免密/授权）", #selector(doFix), "")
        add("安装命令行工具（ysctl）", #selector(doInstallCLI), "")
        add("辅助功能权限设置…", #selector(openAXSettings), "")
        add("重置辅助功能授权（反复提示时用）", #selector(doResetAX), "")
        add("诊断：导出云枢界面元素", #selector(doDump), "")

        menu.addItem(.separator())
        add("退出", #selector(quit), "q")
    }

    private func add(_ title: String, _ sel: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "云枢")
        img?.isTemplate = true
        return img
    }

    // MARK: - 状态

    private func ysctlPath() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["YSCTL"] { candidates.append(env) }
        candidates.append(NSHomeDirectory() + "/.local/bin/ysctl")
        candidates.append("/usr/local/bin/ysctl")
        candidates.append(NSHomeDirectory() + "/.bin/ysctl")
        if let res = Bundle.main.resourcePath { candidates.append(res + "/ysctl") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @objc private func doRefresh() { refresh() }

    private func refresh() {
        guard !busy else { return }
        guard let ys = ysctlPath() else {
            headerItem.title = "未找到 ysctl，请先运行 install.sh"
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let line = self.capture([ys, "statusline"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = line.split(separator: " ").map(String.init)
            let state = parts.first ?? "off"
            DispatchQueue.main.async {
                self.currentState = state
                self.apply(state: state, parts: parts)
                self.writeTrustStatus()
            }
        }
    }

    /// 把状态映射到：菜单栏图标 + 提示 + 菜单首行文字 + 两个动作项的可点性
    private func apply(state: String, parts: [String]) {
        let green = NSColor.systemGreen
        let orange = NSColor.systemOrange
        let gray = NSColor.secondaryLabelColor

        var dot = gray
        var text = "已完全停用"
        var icon = "network.slash"
        var tint = gray

        switch state {
        case "connected":
            dot = green
            tint = green
            icon = "network"
            text = "已连接企业内网"
            if parts.count >= 4 {
                detailItem.attributedTitle = NSAttributedString(
                    string: "隧道 \(parts[1]) · \(parts[2]) · \(parts[3]) 条路由",
                    attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.systemFont(ofSize: 11)
                    ])
                detailItem.isHidden = false
            } else {
                detailItem.isHidden = true
            }
        case "idle":
            dot = orange
            tint = orange
            icon = "network"
            text = "云枢已启动，未连接内网"
            detailItem.isHidden = true
        default:
            text = "已完全停用（守护进程禁用）"
            detailItem.isHidden = true
        }

        // 图标：已连接＝实心云网 + 绿；未连接＝斜杠 + 灰
        statusItem.button?.image = symbol(icon)
        statusItem.button?.contentTintColor = tint
        statusItem.button?.toolTip = "云枢：\(text)"

        // 首行：彩色圆点 + 状态文字
        let title = NSMutableAttributedString(string: "● ", attributes: [
            .foregroundColor: dot,
            .font: NSFont.systemFont(ofSize: 12)
        ])
        title.append(NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]))
        headerItem.attributedTitle = title

        // 已连接时「连接内网」置灰，已停用时「断开并禁用」置灰
        let connected = (state == "connected")
        connectItem.isEnabled = !connected
        connectItem.title = connected ? "已连接内网（无需重复连接）" : "连接内网（启动并连接）"

        let off = (state == "off")
        disconnectItem.isEnabled = !off
        disconnectItem.title = off ? "云枢已完全停用" : "断开并禁用（彻底退出）"
    }

    // MARK: - 动作

    @objc private func doUp() {
        ensureTrust { granted in
            guard granted else { return }
            self.perform(["up"], name: "连接内网")
        }
    }

    @objc private func doFix() {
        perform(["fix"], name: "修复")
    }

    @objc private func doDown() {
        let alert = NSAlert()
        alert.messageText = "断开并禁用云枢？"
        alert.informativeText = "将断开企业内网、退出云枢主程序，并禁用它的 3 个守护进程。之后点「连接内网」可一键恢复。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() != .alertFirstButtonReturn { return }
        perform(["down", "--force"], name: "断开并禁用")
    }

    private func ensureTrust(_ completion: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() { completion(true); return }
        _ = requestTrust(prompt: true)

        let alert = NSAlert()
        alert.messageText = "还差「辅助功能」权限"
        alert.informativeText = """
        要在云枢界面里替你点「连接网络 / 断开网络」，需要「辅助功能」权限。

        ▸ 如果列表里「云枢开关」已经是勾上的，说明那条记录指向了旧位置
          （重装、换目录、或版本签名变化后很常见）。处理办法：
          1. 点下面的「重置并重新授权」，会清掉旧记录；
          2. 列表里只剩一条「云枢开关」，把它勾上即可。

        ▸ 授权完成后本工具会自动继续刚才的操作，不用再回来点一次。
        """
        alert.addButton(withTitle: "重置并重新授权")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "已授权，重试")
        alert.addButton(withTitle: "取消")
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resetAXTrust()
            openAXSettings()
            watchTrust { completion(true) }
        case .alertSecondButtonReturn:
            openAXSettings()
            watchTrust { completion(true) }
        case .alertThirdButtonReturn:
            if AXIsProcessTrusted() { completion(true) } else { watchTrust { completion(true) } }
        default:
            completion(false)
        }
    }

    /// 清掉本 App 的辅助功能授权记录（TCC），用于"勾了还提示"的旧记录错位。
    private func resetAXTrust() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", "com.shiwuhao.yunshuswitch"]
        try? p.run()
        p.waitUntilExit()
        logLine("tccutil reset Accessibility rc=\(p.terminationStatus)")
        _ = requestTrust(prompt: true)      // 让系统立刻把新的一条加进列表
    }

    /// 轮询等待用户去系统设置里授权，一旦生效就自动继续（最多 2 分钟）
    private func watchTrust(_ done: @escaping () -> Void) {
        trustTimer?.invalidate()
        trustWatchTicks = 0
        trustTimer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.trustWatchTicks += 1
            if AXIsProcessTrusted() {
                t.invalidate()
                self.logLine("trust granted after \(self.trustWatchTicks)s, 自动继续")
                self.writeTrustStatus()
                done()
                return
            }
            if self.trustWatchTicks >= 120 {
                t.invalidate()
                self.logLine("trust watch timeout (120s)")
                self.show("仍未获得「辅助功能」权限",
                          """
                          列表里那条记录可能指向了旧版本。点菜单「重置辅助功能授权（反复提示时用）」，\
                          再回到「辅助功能」里勾选新出现的那一条。
                          """,
                          isError: true)
            }
        }
        RunLoop.main.add(trustTimer!, forMode: .common)
    }

    @objc private func doResetAX() {
        resetAXTrust()
        openAXSettings()
        show("已清空旧的授权记录",
              """
              请在「辅助功能」里把「云枢开关」勾选（若列表里没有，点左下角 + 手动添加 \
              /Applications/云枢开关.app）。勾上后本工具会自动恢复可用。
              """,
              isError: false)
        watchTrust { [weak self] in
            self?.refresh()
        }
    }

    private func perform(_ args: [String], name: String) {
        guard !busy else { return }
        guard let ys = ysctlPath() else {
            show("未找到 ysctl", "请先运行 install.sh 安装命令行工具。", isError: true)
            return
        }

        busy = true
        headerItem.title = "\(name)中…（请稍候）"
        connectItem.isEnabled = false
        disconnectItem.isEnabled = false
        statusItem.button?.image = symbol("hourglass")
        logLine("perform start \(args.joined(separator: " ")) ys=\(ys)")

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [ys] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            // 看门狗：万一卡在系统密码框上不返回，150 秒后强制收尾，
            // 否则 busy 会一直为 true，之后点任何菜单都没反应（看起来就是"点了没动静"）。
            var finished = false
            let lock = NSLock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 150) {
                lock.lock()
                let done = finished
                lock.unlock()
                guard !done else { return }
                self.logLine("perform watchdog: 150s 未返回，终止子进程")
                p.terminate()
            }

            var output = ""
            var rc: Int32 = -1
            do {
                try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output = String(data: data, encoding: .utf8) ?? ""
                p.waitUntilExit()
                rc = p.terminationStatus
            } catch {
                output = "启动 ysctl 失败：\(error.localizedDescription)"
            }
            lock.lock(); finished = true; lock.unlock()

            self.logLine("perform done rc=\(rc) out=\(output.suffix(400).replacingOccurrences(of: "\n", with: " | "))")

            DispatchQueue.main.async {
                self.busy = false
                self.connectItem.isEnabled = true
                self.disconnectItem.isEnabled = true
                self.refresh()
                let detail = self.tail(output)
                if rc == 0 {
                    self.show("\(name)完成", detail.isEmpty ? "操作已完成。" : detail, isError: false)
                } else {
                    self.show("\(name)未成功（退出码 \(rc)）", detail.isEmpty ? "请查看日志。" : detail, isError: true)
                }
            }
        }
    }

    @objc private func doDump() {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = self.axDump()
            let path = NSHomeDirectory() + "/Library/Logs/YunshuSwitch/ax-dump.txt"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                self.show("界面元素已导出", text.isEmpty ? "没有读到任何元素。" : "文件：\(path)\n共 \(text.split(separator: "\n").count) 行", isError: false)
            }
        }
    }

    @objc private func openLogs() {
        let dir = NSHomeDirectory() + "/Library/Logs/YunshuSwitch"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 命令行工具（ysctl）

    private var cliLink: String { NSHomeDirectory() + "/.local/bin/ysctl" }
    private var cliSource: String { Bundle.main.resourcePath! + "/ysctl" }

    /// 把 App 内置的 ysctl 软链到 ~/.local/bin。
    /// 已存在（真文件或指向别处的软链）一律不动，尊重既有安装。
    @discardableResult
    private func installCLILink() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cliSource) else { return false }
        if fm.fileExists(atPath: cliLink) { return true }
        let dir = (cliLink as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: cliLink, withDestinationPath: cliSource)
            return true
        } catch {
            logLine("installCLILink failed: \(error.localizedDescription)")
            return false
        }
    }

    @objc private func doInstallCLI() {
        let ok = installCLILink()
        let alert = NSAlert()
        if ok {
            alert.messageText = "命令行工具已就绪"
            alert.informativeText = """
            ysctl 已就位于 ~/.local/bin/ysctl（由本 App 内置副本提供）

            常用命令：
              ysctl up        启动并连接内网
              ysctl down -y   断开 + 退出 + 禁用守护进程
              ysctl status    查看状态
              ysctl setup     免密授权（只需输一次密码）

            若终端提示找不到命令，把下面这行加进 ~/.zshrc：
              export PATH="$HOME/.local/bin:$PATH"
            """
        } else {
            alert.messageText = "命令行工具不可用"
            alert.informativeText = "App 内置副本缺失，或 ~/.local/bin 无法写入。详情见 ~/Library/Logs/YunshuSwitch/app.log"
        }
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 与 ysctl 的请求通道

    private func pollRequest() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: reqPath) else { return }
        guard let text = try? String(contentsOfFile: reqPath, encoding: .utf8) else { return }
        try? fm.removeItem(atPath: reqPath)   // 先取走，避免重复执行

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return }
        let nonce = lines[0].trimmingCharacters(in: .whitespaces)
        let cmd = lines[1].trimmingCharacters(in: .whitespaces)
        logLine("request nonce=\(nonce) cmd=\(cmd)")

        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.handle(cmd)
            self.logLine("handle \(cmd) -> \(out.prefix(60).replacingOccurrences(of: "\n", with: " | "))")
            let payload = nonce + "\n" + out + "\n"
            try? payload.write(toFile: self.resPath, atomically: true, encoding: .utf8)
        }
    }

    private func handle(_ cmd: String) -> String {
        switch cmd {
        case "trust":
            return AXIsProcessTrusted() ? "OK" : "NOAX"
        case "connect":
            guard AXIsProcessTrusted() else { return "NOAX" }
            return self.axPressConnect()
        case "disconnect":
            guard AXIsProcessTrusted() else { return "NOAX" }
            return self.axPressDisconnect()
        case "dump":
            guard AXIsProcessTrusted() else { return "NOAX" }
            return self.axDump()
        default:
            return "ERR:unknown command \(cmd)"
        }
    }

    private func writeTrustStatus() {
        let state = AXIsProcessTrusted() ? "trusted" : "untrusted"
        let body = "\(state)\n\(ProcessInfo.processInfo.processIdentifier)\n"
        if (try? String(contentsOfFile: statusPath, encoding: .utf8)) != body {
            try? body.write(toFile: statusPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Accessibility

    private func requestTrust(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func yunshuApp() -> NSRunningApplication? {
        let all = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == yunshuBundleID }
        if let exact = all.first(where: { $0.bundleURL?.path == yunshuPath }) { return exact }
        if let named = all.first(where: { $0.localizedName == "Yunshu" }) { return named }
        return all.first
    }

    private func axApp() -> AXUIElement? {
        guard let app = yunshuApp() else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)   // 卡住时最多阻塞 1 秒，别拖累轮询
        return el
    }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String) ?? ""
    }

    private func kids(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    /// 取单个 AXUIElement 类型的属性（CoreFoundation 类型需手动校验）
    private func axChild(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name) else { return nil }
        let cf = v as CFTypeRef
        guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(cf, to: AXUIElement.self)
    }

    private struct Node {
        let el: AXUIElement
        let role: String
        let label: String
        let depth: Int
    }

    /// 递归收集元素及其可读文本，用于关键词匹配
    private func collect(_ el: AXUIElement, depth: Int, into out: inout [Node]) {
        if out.count > 3000 || depth > 20 { return }
        let role = str(el, kAXRoleAttribute as String)
        let label = [
            str(el, kAXTitleAttribute as String),
            str(el, kAXDescriptionAttribute as String),
            str(el, kAXValueAttribute as String),
            str(el, kAXHelpAttribute as String),
            str(el, kAXIdentifierAttribute as String)
        ].joined(separator: "\u{1F}")
        out.append(Node(el: el, role: role, label: label, depth: depth))
        for c in kids(el) { collect(c, depth: depth + 1, into: &out) }
    }

    /// 全量快照：所有窗口 + 菜单栏附加图标 + 菜单栏图标展开后的菜单
    private func snapshot(_ axApp: AXUIElement) -> [Node] {
        var nodes: [Node] = []
        if let wins = attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement] {
            for w in wins { collect(w, depth: 0, into: &nodes) }
        }
        if let mb = axChild(axApp, kAXExtrasMenuBarAttribute as String) {
            for item in kids(mb) { collect(item, depth: 0, into: &nodes) }
        }
        return nodes
    }

    private let pressableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton"
    ]

    private func findAndPress(_ axApp: AXUIElement, keywords: [String], excludes: [String]) -> Bool {
        let nodes = snapshot(axApp)
        var fallback: AXUIElement?
        for n in nodes {
            if excludes.contains(where: { n.label.contains($0) }) { continue }
            guard keywords.contains(where: { n.label.contains($0) }) else { continue }
            if pressableRoles.contains(n.role) {
                if AXUIElementPerformAction(n.el, kAXPressAction as CFString) == .success { return true }
            } else if fallback == nil {
                fallback = n.el
            }
        }
        if let f = fallback, AXUIElementPerformAction(f, kAXPressAction as CFString) == .success {
            return true
        }
        return false
    }

    private func statusItemElement() -> AXUIElement? {
        guard let axApp = axApp() else { return nil }
        guard let mb = axChild(axApp, kAXExtrasMenuBarAttribute as String) else { return nil }
        return kids(mb).first
    }

    /// 点开菜单栏图标，露出面板里的按钮
    @discardableResult
    private func openStatusPanel() -> Bool {
        guard let item = statusItemElement() else { return false }
        let okPress = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        Thread.sleep(forTimeInterval: 0.3)
        return okPress
    }

    private func closeStatusPanel() {
        if let item = statusItemElement() {
            _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// 轮询查找并点击：0.1 秒一探，元素一出现就点，命中立即返回。
    /// 旧实现是「试一次 → 固定睡 1 秒 → 再试」，云枢冷启动那 3 秒里每次都在白睡，
    /// 光等待就多花 2~3 秒。
    private func axPress(_ keywords: [String], _ excludes: [String], timeout: Double = 20) -> String {
        guard yunshuApp() != nil else { return "NOUI" }
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var panelOpened = false
        var sawEmpty = 0

        while Date() < deadline {
            if let axApp = axApp() {
                let nodes = snapshot(axApp)
                if nodes.count != lastCount {
                    lastCount = nodes.count
                    logLine("axPress elements=\(nodes.count) panel=\(panelOpened)")
                }
                if nodes.isEmpty {
                    // 界面还没建起来（冷启动），只等，不去戳状态栏图标
                    sawEmpty += 1
                } else {
                    if findAndPress(axApp, keywords: keywords, excludes: excludes) {
                        if panelOpened { closeStatusPanel() }
                        return "OK"
                    }
                    if !panelOpened, let item = statusItemElement() {
                        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                            panelOpened = true
                        }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if panelOpened { closeStatusPanel() }
        logLine("axPress timeout, elements=\(lastCount) emptyRounds=\(sawEmpty)")
        return "NOBTN"
    }

    private func axPressConnect() -> String {
        let kws = ["连接网络", "立即连接企业内网", "立即连接", "一键连接", "连接企业内网", "连接内网", "点击连接"]
        let ex = ["断开", "取消", "注销", "退出", "申请", "权限", "诊断", "打开云枢"]
        let r = axPress(kws, ex, timeout: 20)
        guard r == "OK" else { return r }

        // 云枢冷启动时第一次点击可能被静默忽略：菜单不报错、隧道也不建立。
        // 文案只在隧道真正建立后才翻成「断开网络」，所以给 8 秒窗口（实测建隧道 2~5 秒）：
        // 翻了就立刻返回；窗口内没翻说明点空了，补点一次。窗口别设太短，
        // 否则会把「还在连接中」误判成点空，补点反而打断正在进行的那次连接。
        for round in 0..<2 {
            if extrasLabels().isEmpty { return "OK" }
            let deadline = Date().addingTimeInterval(8.0)
            while Date() < deadline {
                if !connectStillOffered() { return "OK" }
                Thread.sleep(forTimeInterval: 0.15)
            }
            logLine("verify round \(round + 1): 8 秒内菜单仍显示「连接网络」，补点一次")
            _ = axPress(kws, ex, timeout: 4)
        }
        logLine("verify: 多次点击后菜单仍是「连接网络」（可能需要二次认证）")
        return "OK"
    }

    /// 菜单栏图标下挂的菜单文案（面板不展开时也能读到，且随状态变化）
    private func extrasLabels() -> [String] {
        guard let axApp = axApp() else { return [] }
        guard let mb = axChild(axApp, kAXExtrasMenuBarAttribute as String) else { return [] }
        var nodes: [Node] = []
        for item in kids(mb) { collect(item, depth: 0, into: &nodes) }
        return nodes.map { $0.label }
    }

    private func connectStillOffered() -> Bool {
        extrasLabels().contains { $0.contains("连接网络") }
    }

    private func axPressDisconnect() -> String {
        axPress(
            ["断开网络", "断开连接内网", "断开连接", "断开内网", "立即断开", "退出网络"],
            ["取消", "退出", "诊断", "打开云枢"]
        )
    }

    private func axDump() -> String {
        guard yunshuApp() != nil else { return "NOUI" }
        guard let axApp = axApp() else { return "NOUI" }

        var nodes = snapshot(axApp)
        // 只有状态栏图标、没有可用按钮时，主动展开面板再读一次
        let hasPressable = nodes.contains { pressableRoles.contains($0.role) && !$0.label.isEmpty }
        var didOpen = false
        if !hasPressable {
            didOpen = openStatusPanel()
            nodes = snapshot(axApp)
        }
        if didOpen { closeStatusPanel() }   // 只收起自己打开的

        var lines: [String] = []
        let winCount = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? 0
        lines.append("windows: \(winCount)  elements: \(nodes.count)")
        for n in nodes.prefix(800) {
            let shown = n.label.replacingOccurrences(of: "\u{1F}", with: " | ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " |"))
            lines.append("\(String(repeating: "  ", count: min(n.depth, 6)))[\(n.role)] \(shown)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 辅助

    private func capture(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private func tail(_ text: String, lines: Int = 14) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return all.suffix(lines).joined(separator: "\n")
    }

    private func show(_ title: String, _ detail: String, isError: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = isError ? .warning : .informational
        alert.addButton(withTitle: "好")
        alert.window.level = .floating          // 置顶：accessory 应用的弹窗容易被别的窗口盖住
        NSApp.activate(ignoringOtherApps: true)
        if !isError {
            // 成功提示自动消失：模态框期间菜单栏图标是点不动的，
            // 弹窗藏在别的窗口后面时用户会以为“点了没反应”
            let w = alert.window
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if NSApp.modalWindow === w {
                    NSApp.abortModal()
                    w.orderOut(nil)
                }
            }
        }
        alert.runModal()
    }
}

// 每次展开菜单都先刷一次状态，避免"刚连上但菜单还显示未连接"
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
