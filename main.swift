// MenuBarSqueeze — 菜单栏图标收纳（macOS 13+，原生 AppKit，无第三方依赖）
//
// 原理（与 Hidden Bar 的 LegacyLengthEngine 相同的公开技术）：
//   在菜单栏上放两个属于自己的状态栏项：
//     [被收纳的图标...] [separator 分隔符] [toggle 箭头] [要常显的图标...]
//   点箭头「收起」时，把 separator 的长度撑大到 min(屏宽×2, 10000)，
//   它左侧的图标就被挤出屏幕可视区域；再点一下恢复 20pt 即「展开」。
//   两个项都设置 autosaveName，用户按住 ⌘ 拖动它们的位置会被系统记住。
//
// MIT License
import AppKit

private let expandedLength: CGFloat = 20          // 展开时分隔符的宽度
private let maxCollapsedLength: CGFloat = 10_000  // macOS 对 NSStatusItem.length 的硬上限

final class SqueezeController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var toggleItem: NSStatusItem!
    private var separatorItem: NSStatusItem?     // 可选：只在开启「收起」功能时才创建（默认不创建）

    private let menu = NSMenu()
    private let allItemsMenu = NSMenu()          // 「全部菜单栏项」子菜单（动态重建）
    private var axItems: [AXTools.Item] = []     // AX 枚举结果缓存（点击时按 tag 索引）
    private var autoCollapseEnabled = UserDefaults.standard.bool(forKey: "autoCollapse")
    private var autoCollapseSeconds = UserDefaults.standard.object(forKey: "autoCollapseSeconds") as? Double ?? 30
    private var hoverExpandEnabled = UserDefaults.standard.bool(forKey: "hoverExpand")

    private var autoCollapseTimer: Timer?
    private var hoverPollTimer: Timer?
    private var mouseWasInMenuBar = false
    private var expandedByHover = false

    private var isCollapsed: Bool {
        guard let s = separatorItem else { return false }
        return s.length > expandedLength
    }

    /// 撑开长度要覆盖最宽的屏幕（菜单栏会在所有显示器上复制）
    private var collapsedLength: CGFloat {
        let widest = NSScreen.screens.map { $0.frame.width }.max() ?? 1440
        return max(500, min(widest * 2, maxCollapsedLength))
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认值：悬停自动展开 = 开
        UserDefaults.standard.register(defaults: ["hoverExpand": true])
        hoverExpandEnabled = UserDefaults.standard.bool(forKey: "hoverExpand")

        // 关键：先把「首选位置」写进偏好，系统在创建状态栏项时会按它排列。
        // 数值越小越靠右（实测：0/100 → 最右；2000 → 中间）。
        // 排到最右端后，分隔符左侧就是全部第三方图标 → 一收就全收走。
        applyPreferredPositions()

        // 先建箭头，再建分隔符：后创建的状态栏项会落在更左侧，
        // 默认：只创建 1 个图标 —— 三角符号，点一下下拉出「全部菜单栏图标」列表。
        // 收起功能（需要第二个"分隔符"图标）默认关闭，只在你于菜单里开启时才创建。
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggleItem.autosaveName = "MenuBarSqueeze.toggle"
        configure(toggleItem, symbol: "arrowtriangle.down.fill", tip: "MenuBarSqueeze：点击列出全部菜单栏图标")

        if UserDefaults.standard.bool(forKey: "showSeparator") {
            createSeparator()
        }

        buildMenu()
        startHoverMonitor()
        NSLog("MenuBarSqueeze started; collapsedLength=\(Int(collapsedLength))")
        startDiagnostics()

        // 自测用：defaults write local.menubarsqueeze startCollapsed -bool true
        if UserDefaults.standard.bool(forKey: "startCollapsed") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.collapse() }
        }

        // 「全部菜单栏项」需要辅助功能权限：启动就申请，并在拿到权限后自动导出诊断
        AXTools.dump()                      // 启动即写诊断（含未授权状态）
        if !AXTools.isTrusted { AXTools.requestPermission() }
        startAXWatch()
    }

    /// 轮询权限：拿到后导出 AX 枚举结果（便于验证），并刷新子菜单
    private func startAXWatch() {
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { return }
            tries += 1
            if AXTools.isTrusted {
                AXTools.dump()
                self.rebuildAXSubmenu()
                NSLog("MenuBarSqueeze: AX permission granted, dumped items")
                t.invalidate()
            } else if tries >= 24 {
                t.invalidate()
            }
        }
    }

    /// 创建"分隔符"（仅当开启收起功能时）—— 它的长度撑开时把左侧图标挤出屏幕
    private func createSeparator() {
        guard separatorItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: expandedLength)
        item.autosaveName = "MenuBarSqueeze.separator"
        configure(item, symbol: "arrow.left.and.right",
                  tip: "MenuBarSqueeze 分隔符：左键收起/展开，⌘拖动可调整收纳范围")
        item.button?.action = #selector(separatorPressed(_:))
        separatorItem = item
    }

    private func destroySeparator() {
        guard let item = separatorItem else { return }
        item.length = expandedLength
        NSStatusBar.system.removeStatusItem(item)
        separatorItem = nil
    }

    /// 写入状态栏项的首选位置（越小越靠右）：让图标自动落在最右端
    private func applyPreferredPositions() {
        let d = UserDefaults.standard
        guard d.object(forKey: "didSetPositions") == nil else { return }
        d.set(11, forKey: "NSStatusItem Preferred Position MenuBarSqueeze.separator")
        d.set(10, forKey: "NSStatusItem Preferred Position MenuBarSqueeze.toggle")
        d.set(true, forKey: "didSetPositions")
        d.synchronize()
    }

    /// 自诊断：把两个状态栏项的真实坐标写入 /tmp/menubarsqueeze-diag.txt
    /// 便于判断「没创建」还是「被挤出屏幕/刘海区」
    private func startDiagnostics() {
        writeDiag("launch")
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            guard let self else { return }
            ticks += 1
            self.writeDiag("tick\(ticks)")
            if ticks >= 5 { t.invalidate() }
        }
    }

    private func writeDiag(_ tag: String) {
        let screen = NSScreen.main?.frame ?? .zero
        let sep = separatorItem?.button?.window?.frame
        let tog = toggleItem.button?.window?.frame
        // 菜单栏可视区右边界 = 屏宽；左边界 0。含刘海的机型，刘海大约在中间偏左。
        let line = """
        [\(Date())] \(tag) screen=\(Int(screen.width))x\(Int(screen.height)) \
        collapsed=\(isCollapsed) \
        sep=\(fmt(sep)) toggle=\(fmt(tog)) \
        sepVisible=\(onScreen(sep, screen)) toggleVisible=\(onScreen(tog, screen)) \
        sepImage=\(separatorItem?.button?.image != nil) toggleImage=\(toggleItem.button?.image != nil) length=\(Int(separatorItem?.length ?? 0))
        """
        let url = URL(fileURLWithPath: "/tmp/menubarsqueeze-diag.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func fmt(_ r: CGRect?) -> String {
        guard let r else { return "nil" }
        return "(x=\(Int(r.minX)),y=\(Int(r.minY)),w=\(Int(r.width)),h=\(Int(r.height)))"
    }

    private func onScreen(_ r: CGRect?, _ screen: CGRect) -> Bool {
        guard let r else { return false }
        return r.maxX > screen.minX && r.minX < screen.maxX
    }

    private func configure(_ item: NSStatusItem, symbol: String, tip: String) {
        guard let button = item.button else { return }
        // 优先用 SF Symbol；若拿不到（以保证图标一定可见），退回文字标题
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            button.image = image
            button.image?.isTemplate = true
        } else {
            button.title = symbol.contains("arrow.left.and.right") ? "↔" : "‹"
        }
        button.toolTip = tip
        button.target = self
        button.action = #selector(itemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - 交互

    @objc private func itemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)          // 右键：设置菜单
        } else {
            showAllItems(from: sender)      // 左键：直接列出全部菜单栏图标
        }
    }

    /// 分隔符：左键直接收起/展开（右键仍是设置菜单）
    @objc private func separatorPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            toggle()
            scheduleAutoCollapse()
        }
    }

    /// 左键：弹出「全部菜单栏项」列表 —— 包括被刘海/溢出挤掉、屏幕上点不到的
    private func showAllItems(from button: NSStatusBarButton) {
        let listMenu = NSMenu()
        if !AXTools.isTrusted {
            listMenu.addItem(NSMenuItem(title: "⚠️ 需要辅助功能权限（右键 → 重新扫描）", action: nil, keyEquivalent: ""))
        } else {
            var items = AXTools.menuBarItems().filter { !$0.label.hasPrefix("控制中心 · 项") }
            items.sort { ($0.x ?? -9999) < ($1.x ?? -9999) }
            axItems = items
            let screenRight = NSScreen.main?.frame.maxX ?? 1470
            for (i, it) in items.enumerated() {
                let visible = (it.x ?? -1) >= 0 && (it.x ?? 0) < screenRight
                let mark = visible ? "  " : "⛔"
                let mi = NSMenuItem(title: "\(mark)\(it.label)   [x=\(Int(it.x ?? 0))]",
                                    action: #selector(pressAXItem(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = i
                mi.image = Self.icon(for: it)
                listMenu.addItem(mi)
            }
            listMenu.addItem(.separator())
            listMenu.addItem(NSMenuItem(title: "共 \(items.count) 项（⛔ = 屏幕上点不到的）",
                                        action: nil, keyEquivalent: ""))
        }
        listMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置 ▸", action: nil, keyEquivalent: "")
        settings.submenu = menu
        listMenu.addItem(settings)
        listMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func showMenu(from button: NSStatusBarButton) {
        menu.delegate = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func toggle() { isCollapsed ? expand() : collapse() }

    func collapse() {
        guard let sep = separatorItem else { return }
        sep.length = collapsedLength
        updateToggleIcon()
    }

    func expand() {
        guard let sep = separatorItem else { return }
        sep.length = expandedLength
        updateToggleIcon()
    }

    private func updateToggleIcon() {
        // 单图标模式（无分隔符）时保持三角符号不变
        guard separatorItem != nil else { return }
        let name = isCollapsed ? "chevron.right" : "chevron.left"
        toggleItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        toggleItem.button?.image?.isTemplate = true
    }

    // MARK: - 菜单

    private func buildMenu() {
        let stateItem = NSMenuItem(title: "点击图标即可查看全部菜单栏项", action: nil, keyEquivalent: "")
        stateItem.tag = 100
        menu.addItem(stateItem)
        menu.addItem(.separator())

        // 收起功能默认关闭：勾选后才会多出一个「↔ 分隔符」图标
        let sepToggle = NSMenuItem(title: "启用「收起」功能（会多出一个分隔符图标）",
                                   action: #selector(menuToggleSeparator), keyEquivalent: "")
        sepToggle.tag = 104
        menu.addItem(sepToggle)
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "闲置后自动收起", action: #selector(menuToggleAuto), keyEquivalent: "")
        auto.tag = 101
        auto.isHidden = true          // 需要先启用收起功能，刷新时再显示
        menu.addItem(auto)

        let hover = NSMenuItem(title: "鼠标移到菜单栏时自动展开", action: #selector(menuToggleHover), keyEquivalent: "")
        hover.tag = 102
        hover.isHidden = true
        menu.addItem(hover)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "开机自动启动", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.tag = 103
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "使用说明 / 自检", action: #selector(menuHelp), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "重新扫描菜单栏项 / 申请辅助功能权限", action: #selector(menuRescanAX), keyEquivalent: "r"))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MenuBarSqueeze", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let hasSeparator = separatorItem != nil
        menu.item(withTag: 100)?.title = hasSeparator
            ? (isCollapsed ? "当前：已收起（点分隔符展开）" : "当前：展开")
            : "点击图标即可查看全部菜单栏项"
        menu.item(withTag: 104)?.state = hasSeparator ? .on : .off
        // 只有启用收起功能后，这两个开关才有意义
        menu.item(withTag: 101)?.isHidden = !hasSeparator
        menu.item(withTag: 102)?.isHidden = !hasSeparator
        menu.item(withTag: 101)?.state = autoCollapseEnabled ? .on : .off
        menu.item(withTag: 102)?.state = hoverExpandEnabled ? .on : .off
        menu.item(withTag: 103)?.state = LoginItem.isEnabled ? .on : .off
        rebuildAXSubmenu()
    }

    @objc private func menuToggleSeparator(_ sender: NSMenuItem) {
        let enable = (separatorItem == nil)
        UserDefaults.standard.set(enable, forKey: "showSeparator")
        if enable {
            createSeparator()
        } else {
            destroySeparator()
        }
    }

    /// 重建「全部菜单栏项」子菜单
    private func rebuildAXSubmenu() {
        allItemsMenu.removeAllItems()
        guard AXTools.isTrusted else {
            allItemsMenu.addItem(NSMenuItem(title: "需要辅助功能权限（点下面“重新扫描”）", action: nil, keyEquivalent: ""))
            return
        }
        axItems = AXTools.menuBarItems()
        // 过滤掉「控制中心 · 项N」这类无名字的内部占位项，避免噪音
        axItems = axItems.filter { !($0.label.hasPrefix("控制中心 · 项") ) }
        if axItems.isEmpty {
            allItemsMenu.addItem(NSMenuItem(title: "未枚举到菜单栏项", action: nil, keyEquivalent: ""))
            return
        }
        // 按 x 坐标从右到左排序（贴合菜单栏实际顺序），屏幕外的排最前
        axItems.sort { ($0.x ?? -9999) < ($1.x ?? -9999) }
        let screenRight = NSScreen.main?.frame.maxX ?? 1470
        var offscreen = 0
        for (i, it) in axItems.enumerated() {
            let visible = (it.x ?? -1) >= 0 && (it.x ?? 0) < screenRight
            if !visible { offscreen += 1 }
            let mi = NSMenuItem(title: "\(visible ? "" : "⛔ ")[\(Int(it.x ?? 0))]  \(it.label)",
                                action: #selector(pressAXItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            allItemsMenu.addItem(mi)
        }
        allItemsMenu.addItem(.separator())
        allItemsMenu.addItem(NSMenuItem(title: "共 \(axItems.count) 项，其中 ⛔ 屏幕外 \(offscreen) 项 —— 点名字即可调出它的菜单",
                                        action: nil, keyEquivalent: ""))
    }

    /// 给列表项配图：第三方 App 用 App 自己的图标；控制中心的系统项按名字配 SF Symbol
    private static func icon(for item: AXTools.Item) -> NSImage? {
        let size = NSSize(width: 16, height: 16)

        // 系统项（控制中心）
        if item.appName.contains("控制中心") {
            let name = item.label
            let symbol: String
            switch true {
            case name.contains("电池"):   symbol = "battery.100"
            case name.contains("Wi‑Fi") || name.contains("Wi-Fi"): symbol = "wifi"
            case name.contains("时钟"):   symbol = "clock"
            case name.contains("声音"):   symbol = "speaker.wave.2"
            case name.contains("显示器"): symbol = "display"
            case name.contains("专注"):   symbol = "moon"
            case name.contains("控制中心"): symbol = "switch.2"
            case name.contains("聚焦") || name.contains("Spotlight"): symbol = "magnifyingglass"
            default: symbol = "gearshape"
            }
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                img.size = size
                return img
            }
        }

        // 第三方 App：用 App 图标
        if let app = NSRunningApplication(processIdentifier: item.pid), let appIcon = app.icon {
            let copy = NSImage(size: size)
            copy.lockFocus()
            appIcon.draw(in: NSRect(origin: .zero, size: size))
            copy.unlockFocus()
            return copy
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    @objc private func pressAXItem(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < axItems.count else { return }
        let item = axItems[sender.tag]
        let xText = item.x.map { String(Int($0)) } ?? "-"

        // 按住 ⌥ 点 = 直接打开/激活那个 App
        if NSEvent.modifierFlags.contains(.option) {
            let ok = AXTools.activate(pid: item.pid)
            AXTools.logAction("⌥激活 App: \(item.label) → \(ok ? "成功" : "失败")")
            return
        }

        // 关键：我们的菜单要先关掉，再动作 —— 否则目标 App 的菜单在菜单跟踪状态下弹不出来
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let bundleID = NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier

            // ① 已知不吃 AXPress 的 App → 直接合成点击
            if AXTools.needsSyntheticClick(bundleID) {
                if AXTools.syntheticClick(item.frame) {
                    AXTools.logAction("合成点击(名单内): \(item.label) [x=\(xText)]")
                } else {
                    _ = AXTools.activate(pid: item.pid)
                    AXTools.logAction("合成点击失败(无坐标)，改为打开 App: \(item.label)")
                }
                return
            }

            // ② 默认：AXPress（不动鼠标，最快）
            let err = AXTools.press(item.element)
            AXTools.logAction("AXPress: \(item.label) [x=\(xText)] err=\(err.rawValue)")

            if err != .success {
                AXTools.markNeedsSyntheticClick(bundleID)
                if !AXTools.syntheticClick(item.frame) { _ = AXTools.activate(pid: item.pid) }
                return
            }

            // ③ 0.35 秒后验证：菜单真的弹出来了吗？没弹 → 记入名单 + 补一次合成点击
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                if !AXTools.hasPopUpWindow(pid: item.pid) {
                    AXTools.logAction("  ↳ AXPress 没弹出菜单 → 改合成点击")
                    AXTools.markNeedsSyntheticClick(bundleID)
                    if !AXTools.syntheticClick(item.frame) { _ = AXTools.activate(pid: item.pid) }
                } else {
                    AXTools.logAction("  ↳ 菜单已弹出 ✅")
                }
                _ = self
            }
        }
    }

    @objc private func menuRescanAX() {
        if !AXTools.isTrusted {
            AXTools.requestPermission()
            let alert = NSAlert()
            alert.messageText = "需要「辅助功能」权限"
            alert.informativeText = """
            请到 系统设置 › 隐私与安全性 › 辅助功能 里勾选 MenuBarSqueeze，
            然后回到这里再点一次「重新扫描」。

            有了这个权限，我才能列出别的 App 的菜单栏图标（包括被刘海挤掉、屏幕上点不到的那些），
            点列表里的名字就等于替你点了那个图标。
            """
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        AXTools.dump()
        rebuildAXSubmenu()
    }

    @objc private func menuToggle() { toggle(); scheduleAutoCollapse() }

    @objc private func menuToggleAuto() {
        autoCollapseEnabled.toggle()
        UserDefaults.standard.set(autoCollapseEnabled, forKey: "autoCollapse")
        scheduleAutoCollapse()
    }

    @objc private func menuToggleHover() {
        hoverExpandEnabled.toggle()
        UserDefaults.standard.set(hoverExpandEnabled, forKey: "hoverExpand")
    }

    @objc private func menuToggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func menuHelp() {
        let arranged = isArrangementValid
        let alert = NSAlert()
        alert.messageText = arranged ? "排列正常 ✅" : "排列需要调整 ⚠️"
        alert.informativeText = """
        \(arranged ? "分隔符位于箭头左侧，收纳功能可用。" : "分隔符不在箭头左侧，收纳不会生效。请按住 ⌘ 把「↔ 分隔符」拖到「‹ 箭头」的左边。")

        用法：
        1. 按住 ⌘ 拖动菜单栏图标，把「不想常看」的排到 ↔ 分隔符左边；
        2. 把「想常看」的排在 ‹ 箭头右边；
        3. 点 ‹ 箭头收起/展开，右键出菜单。

        诊断：状态=\(isCollapsed ? "已收起" : "展开")，分隔符长度 \(Int(separatorItem?.length ?? 0))pt，撑开长度 \(Int(collapsedLength))pt
        """
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 分隔符是否真的位于箭头的左侧（被隐藏侧）
    private var isArrangementValid: Bool {
        guard let sep = separatorItem?.button?.window?.frame,
              let tog = toggleItem.button?.window?.frame else { return false }
        return sep.minX < tog.minX
    }

    // MARK: - 自动收起 / 悬停展开

    private func scheduleAutoCollapse() {
        autoCollapseTimer?.invalidate()
        guard autoCollapseEnabled, !isCollapsed else { return }
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: autoCollapseSeconds, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    private func startHoverMonitor() {
        // 只做「悬停展开」：鼠标碰到菜单栏且当前是收起状态 → 展开。
        // 不做任何自动收起（用户明确要求不要自动隐藏）。
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.hoverExpandEnabled else { return }
            let inside = Self.mouseIsInMenuBar()
            if inside, !self.mouseWasInMenuBar, self.isCollapsed {
                self.expand()
                self.expandedByHover = true
                AXTools.logAction("悬停自动展开")
            }
            self.mouseWasInMenuBar = inside
        }
    }

    private static func mouseIsInMenuBar() -> Bool {
        let loc = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(loc) {
            return loc.y >= screen.frame.maxY - NSStatusBar.system.thickness
        }
        return false
    }
}

// MARK: - 开机自启（用户级 LaunchAgent，无需管理员密码）

enum LoginItem {
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.menubarsqueeze.plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ enabled: Bool) {
        let uid = getuid()
        if enabled {
            let exe = Bundle.main.executablePath ?? "/Applications/MenuBarSqueeze.app/Contents/MacOS/MenuBarSqueeze"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>local.menubarsqueeze</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
              <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
            run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        } else {
            run("/bin/launchctl", ["bootout", "gui/\(uid)/local.menubarsqueeze"])
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - 辅助功能：枚举并触发其他 App 的菜单栏项（含被刘海/溢出挤掉的）

import ApplicationServices

enum AXTools {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    struct Item {
        let label: String
        let element: AXUIElement
        let x: CGFloat?
        let frame: CGRect?
        let pid: pid_t
        let appName: String
    }

    /// 遍历所有正在运行的 App，读它们的「菜单栏附加项」（AXExtrasMenuBar）
    static func menuBarItems() -> [Item] {
        var result: [Item] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited, app.processIdentifier > 0 else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &extrasRef) == .success,
                  let extras = extrasRef else { continue }
            let bar = extras as! AXUIElement
            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement], !kids.isEmpty else { continue }

            for (idx, kid) in kids.enumerated() {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(kid, kAXTitleAttribute as CFString, &titleRef)
                var descRef: CFTypeRef?
                AXUIElementCopyAttributeValue(kid, kAXDescriptionAttribute as CFString, &descRef)
                var posRef: CFTypeRef?
                var x: CGFloat? = nil
                var rect: CGRect? = nil
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &posRef) == .success,
                   let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    if AXValueGetValue(pv as! AXValue, .cgPoint, &point) { x = point.x }
                    if AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &sizeRef) == .success,
                       let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
                        var size = CGSize.zero
                        if AXValueGetValue(sv as! AXValue, .cgSize, &size) {
                            rect = CGRect(origin: point, size: size)
                        }
                    }
                }
                let appName = app.localizedName ?? "未知App"
                let raw = (titleRef as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let desc = (descRef as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let name = !raw.isEmpty ? raw : (!desc.isEmpty ? desc : "项\(idx)")
                result.append(Item(label: "\(appName) · \(name)", element: kid, x: x, frame: rect,
                                   pid: app.processIdentifier, appName: appName))
            }
        }
        return result
    }

    /// 判断某个 App 是否真的弹出了菜单（菜单窗口 layer ≥ 100 且有一定高度）
    static func hasPopUpWindow(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= 100,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Height"] ?? 0) > 40
            else { continue }
            return true
        }
        return false
    }

    // MARK: - 智能点击名单（哪些 App 不吃 AXPress，需要合成点击）

    private static let hostileKey = "syntheticClickBundleIDs"

    static func needsSyntheticClick(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        let list = UserDefaults.standard.stringArray(forKey: hostileKey) ?? []
        return list.contains(id)
    }

    static func markNeedsSyntheticClick(_ bundleID: String?) {
        guard let id = bundleID else { return }
        var list = UserDefaults.standard.stringArray(forKey: hostileKey) ?? []
        guard !list.contains(id) else { return }
        list.append(id)
        UserDefaults.standard.set(list, forKey: hostileKey)
        logAction("📝 记入名单（以后直接用合成点击）: \(id)")
    }

    /// 触发（相当于用鼠标点这个图标）
    @discardableResult
    static func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// 合成一次真实鼠标点击（对不吃 AXPress 的 App 也有效，如 Tauri/Electron 类）
    @discardableResult
    static func syntheticClick(_ frame: CGRect?) -> Bool {
        guard let f = frame, f.width > 1, f.height > 1, f.origin.x > 0 else { return false }
        let p = CGPoint(x: f.midX, y: f.midY)
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(90_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(70_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }

    /// 打开/激活所属 App（AXPress 无效时的兜底）
    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    /// 记录每次点击的结果，便于事后验证
    static func logAction(_ line: String, to path: String = "/tmp/menubarsqueeze-action.log") {
        let text = "[\(Date())] \(line)\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
        } else {
            try? text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
    }

    /// 诊断：把枚举结果写到文件，便于排查（无论是否已授权都写）
    static func dump(to path: String = "/tmp/menubarsqueeze-ax.txt") {
        let exe = Bundle.main.executablePath ?? "?"
        let head = "[\(Date())] trusted=\(isTrusted)\n  exe=\(exe)\n  bundleID=\(Bundle.main.bundleIdentifier ?? "?")\n"
        guard isTrusted else {
            try? (head + "  → 未获得辅助功能权限（请在 系统设置 › 隐私与安全性 › 辅助功能 中勾选）\n")
                .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            return
        }
        let items = menuBarItems()
        var text = head + "共枚举到 \(items.count) 个菜单栏项：\n"
        for it in items { text += "  x=\(it.x.map { String(Int($0)) } ?? "-")  \(it.label)\n" }
        try? text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let controller = SqueezeController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // 只驻留菜单栏，不占 Dock
app.run()
