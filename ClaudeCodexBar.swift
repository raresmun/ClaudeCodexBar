// ClaudeCodexBar: shows how much of your weekly Claude and Codex limits you've used, in the menu bar.
// It asks the official `claude` and `codex` CLIs (which handle their own sign-in) every 5 minutes.
import AppKit
import ServiceManagement

struct Failure: Error { let message: String }

struct Reading {
    let percent: Int
    let resetsAt: Date?
}

final class Source {
    let name: String
    let fetch: () throws -> Reading
    var reading: Reading?  // last good value; kept when a refresh fails
    var updated: Date?
    var error: String?
    var busy = false

    init(_ name: String, _ fetch: @escaping () throws -> Reading) {
        self.name = name
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
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",  // no update checks or telemetry from 288 polls a day
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
    guard let week = (usage["rate_limits"] as? [String: Any])?["seven_day"] as? [String: Any],
          let used = week["utilization"] as? Double else {
        throw Failure(message: "no weekly limit reported (is claude signed in to a Claude plan?)")
    }
    return Reading(percent: Int(used.rounded()), resetsAt: parseISODate(week["resets_at"] as? String))
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
    // The weekly window is "primary" or "secondary" depending on the plan, so find it by its length.
    let limits = (reply["result"] as? [String: Any])?["rateLimits"] as? [String: Any] ?? [:]
    guard let week = ["primary", "secondary"].compactMap({ limits[$0] as? [String: Any] })
            .first(where: { $0["windowDurationMins"] as? Int == 7 * 24 * 60 }),
          let used = week["usedPercent"] as? Int else {
        throw Failure(message: "no weekly limit reported (is codex signed in with ChatGPT?)")
    }
    return Reading(percent: used, resetsAt: (week["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
}

func parseISODate(_ string: String?) -> Date? {
    // Claude sends microseconds, which ISO8601DateFormatter can't parse, and its reset times land just
    // either side of the minute (22:59:59.9 or 23:00:00.1), so drop the fraction and round to the minute.
    guard let string, let date = ISO8601DateFormatter().date(
        from: string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) else { return nil }
    return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
}

/// Small caption over the value, like the Stats app's "RAM / 75%".
func barImage(_ columns: [(caption: String, value: String)]) -> NSImage {
    let captionFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7, weight: .semibold)]
    let valueFont: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
    let widths = columns.map { max(($0.caption as NSString).size(withAttributes: captionFont).width,
                                   ($0.value as NSString).size(withAttributes: valueFont).width).rounded(.up) }
    let gap: CGFloat = 8
    let size = NSSize(width: widths.reduce(0, +) + gap * CGFloat(columns.count - 1), height: 22)
    let image = NSImage(size: size, flipped: true) { _ in
        var x: CGFloat = 0
        for (column, width) in zip(columns, widths) {
            let caption = column.caption as NSString, value = column.value as NSString
            caption.draw(at: NSPoint(x: x + (width - caption.size(withAttributes: captionFont).width) / 2, y: 1),
                         withAttributes: captionFont)
            value.draw(at: NSPoint(x: x + (width - value.size(withAttributes: valueFont).width) / 2, y: 8),
                       withAttributes: valueFont)
            x += width + gap
        }
        return true
    }
    image.isTemplate = true  // follows the menu bar's light/dark text color
    return image
}

final class ClaudeCodexBar: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sources = [Source("Claude", fetchClaude), Source("Codex", fetchCodex)]
    let resetFormat = DateFormatter(), timeFormat = DateFormatter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        resetFormat.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        timeFormat.timeStyle = .short
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in self?.refresh() }
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
        let values = sources.map { ($0.name, $0.reading.map { "\($0.percent)%" } ?? "–") }
        statusItem.button?.image = barImage(values.map { ($0.0.uppercased(), $0.1) })
        statusItem.button?.setAccessibilityLabel(values.map { "\($0.0) \($0.1)" }.joined(separator: ", "))  // the image has no text for VoiceOver

        let menu = NSMenu()
        for source in sources {
            menu.addItem(withTitle: "\(source.name): " + (source.reading.map { "\($0.percent)% of weekly limit" } ?? "no data yet"),
                         action: nil, keyEquivalent: "")
            if let resets = source.reading?.resetsAt {
                menu.addItem(withTitle: "    Resets \(resetFormat.string(from: resets))", action: nil, keyEquivalent: "")
            }
            if let updated = source.updated {
                menu.addItem(withTitle: "    Updated \(timeFormat.string(from: updated))", action: nil, keyEquivalent: "")
            }
            if let error = source.error {
                menu.addItem(withTitle: "    ⚠︎ \(error)", action: nil, keyEquivalent: "")
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
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
