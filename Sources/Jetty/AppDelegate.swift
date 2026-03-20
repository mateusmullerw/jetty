import AppKit
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var currentProjects: [Project] = []
    private var isMenuOpen = false
    private var lastRefreshDate = Date()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        startRefreshTimer()
        refresh()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: "brakesignal.dashed", accessibilityDescription: "Jetty") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "J"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuildMenu()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - Timer

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let projects = PortScanner.scanProjects()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.currentProjects = projects
                self.lastRefreshDate = Date()
                if self.isMenuOpen { self.rebuildMenu() }
            }
        }
    }

    @objc private func manualRefresh() {
        refresh()
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Header: title + refresh button + timestamp in one compact custom view
        let headerView = MenuHeaderView(lastUpdated: lastRefreshDate) { [weak self] in
            self?.manualRefresh()
        }
        let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let devProjects    = currentProjects.filter { !$0.isSystem }
        let systemProjects = currentProjects.filter {  $0.isSystem }

        if devProjects.isEmpty && systemProjects.isEmpty {
            let empty = NSMenuItem(title: "No processes listening", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            if devProjects.isEmpty {
                let empty = NSMenuItem(title: "No user processes listening", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            } else {
                for project in devProjects {
                    addProjectEntry(to: menu, project: project)
                }
            }

            if !systemProjects.isEmpty {
                menu.addItem(.separator())
                let othersSubmenu = NSMenu()
                for project in systemProjects {
                    addProjectEntry(to: othersSubmenu, project: project)
                }
                let count = systemProjects.flatMap(\.entries).count
                let othersItem = NSMenuItem(title: "Others (\(count))", action: nil, keyEquivalent: "")
                othersItem.submenu = othersSubmenu
                menu.addItem(othersItem)
            }
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Jetty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let icon = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit") {
            quitItem.image = icon
        }
        menu.addItem(quitItem)
    }

    // MARK: - Project Entry

    private func addProjectEntry(to menu: NSMenu, project: Project) {
        let submenu = NSMenu()

        for entry in project.entries {
            let entryView = PortEntryView(entry: entry)
            entryView.onKill = { [weak self] in
                self?.kill(pid: entry.pid)
            }
            let entryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            entryItem.view = entryView
            submenu.addItem(entryItem)
        }

        if project.entries.count > 1 {
            submenu.addItem(.separator())
            let killAllItem = NSMenuItem(title: "Kill all", action: #selector(killAllProcesses(_:)), keyEquivalent: "")
            killAllItem.target = self
            killAllItem.representedObject = project.entries.map { NSNumber(value: $0.pid) } as NSArray
            submenu.addItem(killAllItem)
        }

        // Project title: normal menu font — the "Jetty" header is the prominent one
        let projectItem = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
        projectItem.submenu = submenu
        menu.addItem(projectItem)
    }

    // MARK: - Kill

    private func kill(pid: Int32) {
        switch attemptKill(pid: pid_t(pid)) {
        case .success:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.refresh()
            }
        case .permissionDenied:
            showAlert(
                title: "Permission Denied",
                message: "Process \(pid) requires elevated privileges.\n\nTo force-kill it, run:\n\nsudo kill -9 \(pid)"
            )
        case .notFound:
            refresh()
        case .unknown(let code):
            showAlert(title: "Kill Failed", message: "Could not terminate process \(pid). errno: \(code)")
        }
    }

    @objc private func killAllProcesses(_ sender: NSMenuItem) {
        guard let pids = sender.representedObject as? NSArray else { return }
        for pidNumber in pids {
            guard let n = pidNumber as? NSNumber else { continue }
            _ = attemptKill(pid: pid_t(n.int32Value))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Kill Logic

    enum KillResult {
        case success, permissionDenied, notFound, unknown(Int32)
    }

    private func attemptKill(pid: pid_t) -> KillResult {
        var result = Darwin.kill(pid, SIGTERM)
        if result == 0 { return .success }
        let termerr = errno
        if termerr == EPERM { return .permissionDenied }
        if termerr == ESRCH { return .notFound }

        result = Darwin.kill(pid, SIGKILL)
        if result == 0 { return .success }
        let killerr = errno
        if killerr == EPERM { return .permissionDenied }
        if killerr == ESRCH { return .notFound }
        return .unknown(killerr)
    }

    // MARK: - Alert Helper

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - MenuHeaderView

/// Top header row: "Jetty · Listening ports" + refresh button + last-updated timestamp.
private class MenuHeaderView: NSView {
    static let viewHeight: CGFloat = 52

    private let titleLabel  = NSTextField(labelWithString: "Jetty · Listening ports")
    private let timeLabel   = NSTextField(labelWithString: "")
    private let clockView   = NSImageView()
    private let refreshBtn  = NSButton(title: "", target: nil, action: nil)

    var onRefresh: (() -> Void)?

    init(lastUpdated: Date, onRefresh: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.viewHeight))
        self.onRefresh = onRefresh

        // Title: semibold, 2pt larger than default menu font
        let fontSize = NSFont.menuFont(ofSize: 0).pointSize + 2
        titleLabel.font            = .systemFont(ofSize: fontSize, weight: .semibold)
        titleLabel.isEditable      = false
        titleLabel.isBordered      = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode   = .byTruncatingTail

        // Refresh button: arrow.clockwise, borderless
        let btnCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let icon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") {
            refreshBtn.image = icon.withSymbolConfiguration(btnCfg)
        }
        refreshBtn.isBordered = false
        refreshBtn.target     = self
        refreshBtn.action     = #selector(refreshTapped)

        // Clock icon beside the timestamp
        let clockCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        if let icon = NSImage(systemSymbolName: "clock", accessibilityDescription: "Updated") {
            clockView.image = icon.withSymbolConfiguration(clockCfg)
        }
        clockView.contentTintColor = .secondaryLabelColor

        // Timestamp label
        let fmt = DateFormatter()
        fmt.timeStyle = .medium
        timeLabel.stringValue     = fmt.string(from: lastUpdated)
        timeLabel.font            = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timeLabel.isEditable      = false
        timeLabel.isBordered      = false
        timeLabel.drawsBackground = false
        timeLabel.textColor       = .secondaryLabelColor

        addSubview(titleLabel)
        addSubview(refreshBtn)
        addSubview(clockView)
        addSubview(timeLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let w               = bounds.width
        let h               = bounds.height
        let hPad: CGFloat   = 14
        let vPad: CGFloat   = 8
        let titleH: CGFloat = 20
        let timeH:  CGFloat = 14
        let clockSz: CGFloat = 11

        // Refresh button — right-aligned, vertically centred on the title row
        refreshBtn.sizeToFit()
        let btnSz = refreshBtn.fittingSize
        let titleRowY = h - vPad - titleH
        refreshBtn.frame = NSRect(x: w - hPad - btnSz.width,
                                  y: titleRowY + (titleH - btnSz.height) / 2,
                                  width: btnSz.width, height: btnSz.height)

        // Title — left of title row, stops before refresh button
        titleLabel.frame = NSRect(x: hPad, y: titleRowY,
                                  width: refreshBtn.frame.minX - hPad - 6, height: titleH)

        // Clock icon — left of time row, vertically centred
        clockView.frame = NSRect(x: hPad, y: vPad + (timeH - clockSz) / 2,
                                 width: clockSz, height: clockSz)

        // Timestamp — right of clock icon
        timeLabel.frame = NSRect(x: hPad + clockSz + 4, y: vPad,
                                 width: w - (hPad + clockSz + 4) - hPad, height: timeH)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // Header row is never highlighted — it's informational, not selectable
    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect) }

    @objc private func refreshTapped() {
        // Do NOT call cancelTracking — menu stays open while data refreshes
        onRefresh?()
    }
}

// MARK: - PortEntryView

/// Custom NSMenuItem view: process info on the left, red kill button on the right.
private class PortEntryView: NSView {

    // Dynamic height: header row + one row per port
    static func height(forPortCount n: Int) -> CGFloat {
        let vPad:      CGFloat = 8
        let headerH:   CGFloat = 20
        let headerGap: CGFloat = 5
        let rowH:      CGFloat = 16
        let rowGap:    CGFloat = 3
        return vPad + headerH + headerGap
             + CGFloat(n) * rowH + CGFloat(max(n - 1, 0)) * rowGap
             + vPad
        // 1 port → 57 pt  |  2 ports → 76 pt  |  3 ports → 95 pt
    }

    private let headerLabel = NSTextField(labelWithString: "")  // "Bun  ·  PID 36429"
    private var portLabels: [NSTextField] = []                  // one per port
    private let killButton  = NSButton(title: "Kill", target: nil, action: nil)

    var onKill: (() -> Void)?

    // MARK: Interface binding label

    private static func interfaceLabel(_ address: String) -> String {
        switch address {
        case "*", "0.0.0.0", "::", "0:0:0:0:0:0:0:0": return "All interfaces"
        case "127.0.0.1", "[::1]", "::1":              return "Local only"
        default:                                         return address
        }
    }

    // MARK: Init

    init(entry: ProjectEntry) {
        let portCount = entry.ports.count
        super.init(frame: NSRect(x: 0, y: 0, width: 290,
                                 height: Self.height(forPortCount: portCount)))

        // Header: "Bun  ·  PID 36429"
        headerLabel.stringValue     = "\(entry.displayName)  ·  PID \(entry.pid)"
        headerLabel.font            = .menuFont(ofSize: 0)
        headerLabel.isEditable      = false
        headerLabel.isBordered      = false
        headerLabel.drawsBackground = false
        headerLabel.lineBreakMode   = .byTruncatingTail

        // Port rows: ":3000  ·  Local only"
        portLabels = entry.ports.sorted { $0.port < $1.port }.map { p in
            let lbl = NSTextField(labelWithString:
                ":\(p.port)  ·  \(Self.interfaceLabel(p.address))")
            lbl.font            = .systemFont(ofSize: NSFont.smallSystemFontSize)
            lbl.isEditable      = false
            lbl.isBordered      = false
            lbl.drawsBackground = false
            return lbl
        }

        // Kill button: red filled pill, white icon + label
        let symCfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let icon = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Kill") {
            killButton.image = icon.withSymbolConfiguration(symCfg)
        }
        killButton.imagePosition    = .imageLeading
        killButton.isBordered       = false
        killButton.wantsLayer       = true
        killButton.layer?.cornerRadius = 5
        killButton.contentTintColor = .white
        // White title to match the icon on the red background
        killButton.attributedTitle  = NSAttributedString(
            string: "Kill",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
            ]
        )
        killButton.target           = self
        killButton.action           = #selector(killTapped)

        addSubview(headerLabel)
        portLabels.forEach { addSubview($0) }
        addSubview(killButton)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w              = bounds.width
        let hPad:  CGFloat = 14
        let vPad:  CGFloat = 8
        let headerH:   CGFloat = 20
        let headerGap: CGFloat = 5
        let rowH:  CGFloat = 16
        let rowGap: CGFloat = 3

        // Kill button — red filled pill, right-aligned on the header row
        killButton.sizeToFit()
        let ks       = killButton.fittingSize
        let btnW     = ks.width  + 14   // 7 pt padding each side
        let btnH     = ks.height +  4   // 2 pt padding top/bottom
        let killX    = w - hPad - btnW
        let headerY  = bounds.height - vPad - headerH
        killButton.frame = NSRect(x: killX,
                                  y: headerY + (headerH - btnH) / 2,
                                  width: btnW, height: btnH)
        killButton.layer?.cornerRadius = btnH / 2   // pill shape

        // Header label
        let availW = killX - hPad - 8
        headerLabel.frame = NSRect(x: hPad, y: headerY, width: availW, height: headerH)

        // Port rows stacked below the header
        var y = headerY - headerGap - rowH
        for lbl in portLabels {
            lbl.frame = NSRect(x: hPad, y: y, width: availW, height: rowH)
            y -= (rowH + rowGap)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: Drawing — highlight state

    override func draw(_ dirtyRect: NSRect) {
        let hi = enclosingMenuItem?.isHighlighted ?? false
        if hi { NSColor.selectedContentBackgroundColor.setFill(); bounds.fill() }

        headerLabel.textColor = hi ? .selectedMenuItemTextColor : .labelColor
        let portColor: NSColor = hi
            ? .selectedMenuItemTextColor.withAlphaComponent(0.75)
            : .secondaryLabelColor
        portLabels.forEach { $0.textColor = portColor }

        // Inside draw(_:) the correct appearance context is active,
        // so cgColor resolves to the right red for light / dark mode.
        killButton.layer?.backgroundColor = NSColor.systemRed.cgColor

        super.draw(dirtyRect)
    }

    // MARK: Kill action

    @objc private func killTapped() {
        enclosingMenuItem?.menu?.cancelTracking()
        onKill?()
    }
}
