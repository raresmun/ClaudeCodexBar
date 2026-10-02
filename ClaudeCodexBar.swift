// ClaudeCodexBar: shows how much of your weekly Claude and Codex limits you've used, in the menu bar.
// It asks the official `claude` and `codex` CLIs (which handle their own sign-in) every 5 minutes.
import AppKit
import ServiceManagement
import SwiftUI

struct Failure: Error { let message: String }

struct Window {
    let percent: Int
    let resetsAt: Date?
}

struct Reading {
    let week: Window
    let session: Window?  // 5-hour limit, when the service reports one
}

final class Source {
    let name: String
    let logo: NSImage
    let tint: Color  // logo color in the dropdown
    let fetch: () throws -> Reading
    var reading: Reading?  // last good value; kept when a refresh fails
    var updated: Date?
    var error: String?
    var busy = false

    init(_ name: String, logo: String, tint: Color, _ fetch: @escaping () throws -> Reading) {
        self.name = name
        self.logo = NSImage(named: logo) ?? NSImage()  // icons/*.pdf, copied into the app by build.sh
        self.tint = tint
        self.fetch = fetch
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser.path

// Fixed, minimal environment for the CLIs, so they behave the same however this app was launched.
let childEnvironment = [
    "HOME": home,
    "USER": NSUserName(),
    "LOGNAME": NSUserName(),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",  // npm-installed CLIs need `node`
    "LANG": "en_US.UTF-8",
    "TMPDIR": NSTemporaryDirectory(),
    // No update checks or telemetry from 288 polls a day. Not CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: that also
    // skips the usage request, and Claude Code then silently returns its last saved reading.
    "DISABLE_AUTOUPDATER": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
]

func findTool(_ name: String) -> String? {
    ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Runs a CLI, writes `messages` to its stdin as JSON lines, and returns the first stdout JSON line
/// that `isAnswer` accepts. Stdin stays open until then: both CLIs quit without replying if it closes early.
func ask(_ tool: String, _ arguments: [String], messages: [[String: Any]],
         isAnswer: ([String: Any]) -> Bool) throws -> [String: Any] {
    guard let path = findTool(tool) else { throw Failure(message: "\(tool) CLI not found") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = childEnvironment
    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()

    let timeout = DispatchWorkItem { process.terminate() }  // a hung CLI must not block later refreshes
    DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: timeout)
    defer {
        timeout.cancel()
        try? input.fileHandleForWriting.close()
        let deadline = Date() + 3  // give it a moment to exit on its own
        while process.isRunning && Date() < deadline { usleep(100_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    for message in messages {
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + [0x0A])
    }
    var buffer = Data()
    while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], isAnswer(json) {
                return json
            }
        }
    }
    throw Failure(message: "no reply from \(tool)")
}

func fetchClaude() throws -> Reading {
    let reply = try ask("claude", ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                   // don't save a session or start your hooks, plugins and MCP servers
                                   "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"],
                        messages: [["type": "control_request", "request_id": "init", "request": ["subtype": "initialize"]],
                                   ["type": "control_request", "request_id": "usage", "request": ["subtype": "get_usage"]]],
                        isAnswer: { ($0["response"] as? [String: Any])?["request_id"] as? String == "usage" })
    let response = reply["response"] as? [String: Any] ?? [:]
    guard let usage = response["response"] as? [String: Any] else {
        throw Failure(message: response["error"] as? String ?? "unexpected reply from claude")
    }
    let limits = usage["rate_limits"] as? [String: Any]
    guard let week = claudeWindow(limits?["seven_day"]) else {
        throw Failure(message: "no weekly limit reported (is claude signed in to a Claude plan?)")
    }
    return Reading(week: week, session: claudeWindow(limits?["five_hour"]))
}

/// Claude reports each limit as {"utilization": 88, "resets_at": "2026-10-01T22:59:59.579+00:00"}.
func claudeWindow(_ value: Any?) -> Window? {
    guard let limit = value as? [String: Any], let used = limit["utilization"] as? Double else { return nil }
    return Window(percent: Int(used.rounded()), resetsAt: parseISODate(limit["resets_at"] as? String))
}

func fetchCodex() throws -> Reading {
    let reply = try ask("codex", ["app-server"],
                        messages: [["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "claudecodexbar", "version": "1.0"]]],
                                   ["method": "initialized"],
                                   ["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]]],
                        isAnswer: { $0["id"] as? Int == 2 })
    if let error = reply["error"] as? [String: Any] {
        throw Failure(message: error["message"] as? String ?? "error from codex")
    }
    // Limits come as "primary" and "secondary" in an order that depends on the plan, so find them by length.
    let limits = (reply["result"] as? [String: Any])?["rateLimits"] as? [String: Any] ?? [:]
    let windows = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
    func window(minutes: Int) -> Window? {
        guard let limit = windows.first(where: { $0["windowDurationMins"] as? Int == minutes }),
              let used = limit["usedPercent"] as? Int else { return nil }
        return Window(percent: used, resetsAt: (limit["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }
    guard let week = window(minutes: 7 * 24 * 60) else {
        throw Failure(message: "no weekly limit reported (is codex signed in with ChatGPT?)")
    }
    return Reading(week: week, session: window(minutes: 5 * 60))  // Codex has a 5-hour limit only on some plans and days
}

func parseISODate(_ string: String?) -> Date? {
    // Claude sends microseconds, which ISO8601DateFormatter can't parse, and its reset times land just
    // either side of the minute (22:59:59.9 or 23:00:00.1), so drop the fraction and round to the minute.
    guard let string, let date = ISO8601DateFormatter().date(
        from: string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) else { return nil }
    return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
}

/// Each tool's logo followed by its percentage, on one line, with a cup in front while the Mac is kept awake.
func barImage(_ items: [(logo: NSImage, value: String)], awake: Bool) -> NSImage {
    let font: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)]
    let logoSize: CGFloat = 15, logoGap: CGFloat = 3, itemGap: CGFloat = 9, height: CGFloat = 22
    let cup = awake ? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) : nil
    let cupWidth = cup.map { $0.size.width + itemGap } ?? 0
    let widths = items.map { logoSize + logoGap + ($0.value as NSString).size(withAttributes: font).width.rounded(.up) }
    let size = NSSize(width: cupWidth + widths.reduce(0, +) + itemGap * CGFloat(items.count - 1), height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        if let cup {
            cup.draw(in: NSRect(x: 0, y: (height - cup.size.height) / 2, width: cup.size.width, height: cup.size.height))
        }
        var x = cupWidth
        for (item, width) in zip(items, widths) {
            item.logo.draw(in: NSRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize))
            let value = item.value as NSString
            value.draw(at: NSPoint(x: x + logoSize + logoGap, y: (height - value.size(withAttributes: font).height) / 2),
                       withAttributes: font)
            x += width + itemGap
        }
        return true
    }
    image.isTemplate = true  // follows the menu bar's light/dark text color
    return image
}

let menuWidth: CGFloat = 290
let resetFormat: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEjmm"); return f }()
let timeFormat: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
let countdownFormat: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.allowedUnits = [.day, .hour, .minute]
    f.maximumUnitCount = 2
    return f
}()

/// One tool in the dropdown: logo, name, weekly percentage with a bar colored by how close it is to the limit,
/// the reset time, and the 5-hour session limit when the service reports one.
struct UsageCard: View {
    let source: Source

    var body: some View {
        let week = source.reading?.week
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: source.logo).renderingMode(.template).resizable()
                    .frame(width: 22, height: 22).foregroundStyle(source.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.system(size: 13, weight: .semibold))
                    Text("Weekly limit").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(week.map { "\($0.percent)%" } ?? "–").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            }
            UsageBar(percent: week?.percent ?? 0, height: 6)
            Group {
                if let resets = week?.resetsAt {
                    Text("Resets in \(countdown(to: resets)) · \(resetFormat.string(from: resets))")
                } else if source.reading == nil && source.error == nil {
                    Text("Checking…")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if let session = source.reading?.session {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text("5-hour session").font(.system(size: 11, weight: .medium))
                        if let resets = session.resetsAt {
                            Text("· resets in \(countdown(to: resets))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(session.percent)%").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    UsageBar(percent: session.percent, height: 4)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .padding(.top, 2)
            }
            if let error = source.error {
                Label(error + (source.updated.map { " · last updated \(timeFormat.string(from: $0))" } ?? ""),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: menuWidth)
    }
}

/// A capsule filled to `percent`, colored by how close it is to the limit.
struct UsageBar: View {
    let percent: Int
    let height: CGFloat

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(levelColor(percent).gradient).frame(width: bar.size.width * CGFloat(min(percent, 100)) / 100)
            }
        }
        .frame(height: height)
    }
}

func countdown(to date: Date) -> String {
    countdownFormat.string(from: max(0, date.timeIntervalSinceNow)) ?? ""
}

/// Green, then yellow, orange and red as usage gets closer to the limit.
func levelColor(_ percent: Int) -> Color {
    switch percent {
    case ..<50: return .green
    case ..<75: return .yellow
    case ..<90: return .orange
    default: return .red
    }
}

func menuItem<Content: View>(_ view: Content) -> NSMenuItem {
    let host = NSHostingView(rootView: view)
    host.frame.size = host.fittingSize
    let item = NSMenuItem()
    item.view = host
    return item
}

final class ClaudeCodexBar: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sources = [Source("Claude", logo: "claude", tint: Color(red: 0.85, green: 0.47, blue: 0.34), fetchClaude),  // Claude orange
                   Source("Codex", logo: "openai", tint: .primary, fetchCodex)]
    var caffeinate: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Keep Mac Awake: runs `caffeinate -dimsu` while on.
    @objc func toggleKeepAwake() {
        if caffeinate?.isRunning == true {
            caffeinate?.terminate()
            caffeinate = nil
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            // -w: caffeinate also stops by itself if this app quits or crashes
            process.arguments = ["-dimsu", "-w", String(ProcessInfo.processInfo.processIdentifier)]
            try? process.run()
            caffeinate = process
        }
        render()
    }

    @objc func refresh() {
        for source in sources where !source.busy {
            source.busy = true
            DispatchQueue.global().async {
                let result = Result(catching: source.fetch)
                DispatchQueue.main.async {
                    source.busy = false
                    switch result {
                    case .success(let reading):
                        source.reading = reading
                        source.updated = Date()
                        source.error = nil
                    case .failure(let error):
                        source.error = (error as? Failure)?.message ?? error.localizedDescription
                    }
                    self.render()
                }
            }
        }
    }

    func render() {
        let values = sources.map { ($0, $0.reading.map { "\($0.week.percent)%" } ?? "–") }
        let awake = caffeinate?.isRunning == true
        statusItem.button?.image = barImage(values.map { ($0.0.logo, $0.1) }, awake: awake)
        statusItem.button?.setAccessibilityLabel(  // the image has no text for VoiceOver
            values.map { "\($0.0.name) \($0.1)" }.joined(separator: ", ") + (awake ? ", keeping your Mac awake" : ""))

        let menu = NSMenu()
        for source in sources {
            menu.addItem(menuItem(UsageCard(source: source)))
        }
        if let updated = sources.compactMap(\.updated).max() {
            menu.addItem(menuItem(Text("Updated \(timeFormat.string(from: updated)) · refreshes every 5 minutes")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.bottom, 6).frame(width: menuWidth, alignment: .leading)))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        let keepAwake = menu.addItem(withTitle: "Keep Mac Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwake.target = self
        keepAwake.state = awake ? .on : .off
        let openAtLogin = menu.addItem(withTitle: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        openAtLogin.target = self
        openAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit ClaudeCodexBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            SMAppService.openSystemSettingsLoginItems()  // e.g. turned off in System Settings: let the user allow it there
        }
        render()
    }
}

signal(SIGPIPE, SIG_IGN)  // a CLI that exits early must not take us down when we write to its stdin
let app = NSApplication.shared
let claudeCodexBar = ClaudeCodexBar()
app.delegate = claudeCodexBar
app.run()
