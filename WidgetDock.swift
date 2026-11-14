import SwiftUI
import Combine
import AppKit
import IOKit.ps
import EventKit
import CoreLocation
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Models

struct Todo: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var done = false
}

struct AppFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var apps: [String]
}

enum DockItem: Codable, Identifiable, Equatable {
    case app(String)
    case folder(AppFolder)

    var id: String {
        switch self {
        case .app(let p): return p
        case .folder(let f): return f.id.uuidString
        }
    }
}

struct Weather {
    var temp: Double
    var high: Double
    var low: Double
    var code: Int
    var isDay: Bool

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var playing: Bool
    var playerID: String
    var artURL: String?
}

struct NextEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var joinURL: URL?
}

/// Tokens used by Claude Code, counted from its session logs on this Mac.
struct Usage: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var messages = 0
    /// Cache reads are left out of the headline number: they are cheap and would swamp everything else.
    var tokens: Int { input + output + cacheWrite }
    mutating func add(_ r: UsageRow) {
        input += r.input; output += r.output; cacheWrite += r.cacheWrite; cacheRead += r.cacheRead; messages += 1
    }
}

struct UsageRow {
    var date: Date
    var input: Int
    var output: Int
    var cacheWrite: Int
    var cacheRead: Int
}

func shortCount(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return "\(n / 1_000)K"
    default: return "\(n)"
    }
}

struct BrowserProfile: Hashable {
    let dir: String
    let name: String
}

struct TileInfo {
    let id: String
    let name: String
    static let all: [TileInfo] = [
        .init(id: "clock", name: "Clock"),
        .init(id: "weather", name: "Weather"),
        .init(id: "calendar", name: "Next event"),
        .init(id: "apps", name: "Apps and folders"),
        .init(id: "stats", name: "System stats"),
        .init(id: "music", name: "Now playing"),
        .init(id: "todos", name: "Todos"),
        .init(id: "pomodoro", name: "Focus timer"),
        .init(id: "notes", name: "Notes"),
        .init(id: "clipboard", name: "Clipboard history"),
        .init(id: "screenshot", name: "Screenshot"),
        .init(id: "downloads", name: "Downloads"),
        .init(id: "controls", name: "Sound and display"),
        .init(id: "claude", name: "Claude usage"),
        .init(id: "trash", name: "Trash"),
    ]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

func appName(_ path: String) -> String {
    FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
}

func promptText(title: String, info: String, value: String = "") -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = info
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = value
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let t = field.stringValue.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// Private IOKit HID calls used to read Apple Silicon temperature sensors (same approach as TempBar, no root needed).
@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> OpaquePointer?
@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: OpaquePointer, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: OpaquePointer) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: OpaquePointer, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: OpaquePointer, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: OpaquePointer, _ field: Int32) -> Double

final class TempSensors {
    private static let temperatureEvent: Int64 = 15
    private let client: OpaquePointer?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)
        if let client {
            _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        }
    }

    /// CPU die temperature in °C: hottest "tdie" sensor, falling back to the hottest of anything.
    func cpuTemp() -> Double? {
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]
        else { return nil }
        var dies: [Double] = [], all: [Double] = []
        for obj in services {
            let service = OpaquePointer(Unmanaged.passUnretained(obj).toOpaque())
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = IOHIDEventGetFloatValue(OpaquePointer(Unmanaged.passUnretained(event).toOpaque()),
                                                Int32(Self.temperatureEvent << 16))
            guard value > 0 && value < 150 else { continue }
            all.append(value)
            if name.lowercased().contains("tdie") { dies.append(value) }
        }
        return (dies.isEmpty ? all : dies).max()
    }
}

/// Asks macOS for the Mac's rough location (about 1 km) so the weather follows you when you travel.
final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    var onFailure: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: onFailure?()
        default: manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: onFailure?()
        default: m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last { onLocation?(loc) }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { onFailure?() }
}

// MARK: - Store

final class DockStore: ObservableObject {
    /// Demo mode renders a sample dock to an image (see `--screenshot`); it never touches real settings.
    static var demo = false
    static let shared = DockStore()
    private let d: UserDefaults = DockStore.demo ? (UserDefaults(suiteName: "local.widgetdock.demo") ?? .standard) : .standard

    func loadDemo() {
        let apps = [
            "/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Mail.app",
            "/System/Applications/Messages.app", "/System/Applications/Calendar.app", "/System/Applications/Notes.app",
            "/System/Applications/Music.app", "/System/Applications/Photos.app", "/System/Applications/System Settings.app",
        ].filter { FileManager.default.fileExists(atPath: $0) }
        items = apps.map { .app($0) }
        running = Set(apps.prefix(2) + apps.dropFirst(6).prefix(1))
        badges = ["/System/Applications/Mail.app": "3", "/System/Applications/Messages.app": "1"]
        todos = [Todo(title: "Ship it"), Todo(title: "Water the plants")]
        locCity = "San Francisco"
        weatherAt = Date()
        weather = Weather(temp: fahrenheit ? 68 : 20, high: fahrenheit ? 72 : 22, low: fahrenheit ? 55 : 13, code: 1, isDay: true)
        nextEvent = NextEvent(title: "Team standup", start: Date().addingTimeInterval(12 * 60 + 30),
                              end: Date().addingTimeInterval(42 * 60), joinURL: URL(string: "https://meet.google.com/demo"))
        cpu = 0.14; mem = 0.62; cpuTemp = 41; battery = 0.86
        usageToday = Usage(input: 210_000, output: 96_000, cacheWrite: 540_000, cacheRead: 9_800_000, messages: 212)
        usageWeek = Usage(input: 1_300_000, output: 610_000, cacheWrite: 3_900_000, cacheRead: 71_000_000, messages: 1480)
        track = Track(title: "Midnight Drive", artist: "Example Artist", playing: true, playerID: "demo", artURL: nil)
        UserDefaults.standard.removePersistentDomain(forName: "local.widgetdock.demo")
    }

    // Saved settings
    @Published var items: [DockItem] {
        didSet { if let data = try? JSONEncoder().encode(items) { d.set(data, forKey: "items") } }
    }
    @Published var todos: [Todo] {
        didSet { if let data = try? JSONEncoder().encode(todos) { d.set(data, forKey: "todos") } }
    }
    @Published var city: String { didSet { d.set(city, forKey: "city"); refreshWeather() } }
    @Published var fahrenheit: Bool { didSet { d.set(fahrenheit, forKey: "fahrenheit"); refreshWeather() } }
    @Published var tileOrder: [String] { didSet { d.set(tileOrder, forKey: "tileOrder") } }
    @Published var hiddenTiles: [String] {
        didSet {
            d.set(hiddenTiles, forKey: "hiddenTiles")
            if !hiddenTiles.contains("calendar") { startCalendar() }
            refreshUsage()
        }
    }
    /// The size picked in Settings; `fitScale` shrinks it further when the bar would not fit the screen.
    @Published var userScale: Double { didSet { d.set(userScale, forKey: "scale") } }
    @Published var fitScale: Double = 1
    var scale: Double { userScale * fitScale }
    @Published var allDisplays: Bool { didSet { d.set(allDisplays, forKey: "allDisplays") } }
    @Published var showBadges: Bool { didSet { d.set(showBadges, forKey: "showBadges") } }
    @Published var badges: [String: String] = [:]
    @Published var opacity: Double { didSet { d.set(opacity, forKey: "opacity") } }
    @Published var showRunning: Bool { didSet { d.set(showRunning, forKey: "showRunning") } }
    @Published var replaceDock: Bool {
        didSet { d.set(replaceDock, forKey: "replaceDock"); applySystemDock(hidden: replaceDock) }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var autoLocation: Bool { didSet { d.set(autoLocation, forKey: "autoLocation"); refreshWeather() } }
    @Published var keepWindowsClear: Bool {
        didSet {
            d.set(keepWindowsClear, forKey: "keepWindowsClear")
            if keepWindowsClear { DockStore.askForWindowControl() }
        }
    }
    // Tools
    static let focusLength: TimeInterval = 25 * 60
    static let breakLength: TimeInterval = 5 * 60
    @Published var note: String { didSet { d.set(note, forKey: "note") } }
    /// Recent copied text. Kept in memory only, never written to disk.
    @Published var clips: [String] = []
    private var clipCount = NSPasteboard.general.changeCount
    @Published var pomoEnd: Date?
    @Published var pomoLeft: TimeInterval = DockStore.focusLength
    @Published var pomoBreak = false
    @Published var usageToday = Usage()
    @Published var usageWeek = Usage()
    private let usageQueue = DispatchQueue(label: "widgetdock.usage", qos: .utility)
    /// Parsed log files by path, so only files that changed are read again. Used on `usageQueue` only.
    private var usageFiles: [String: (stamp: Date, rows: [String: UsageRow])] = [:]
    @Published var volume: Double = 50
    @Published var muted = false
    @Published var locCity: String?
    private var lastCoord: (Double, Double)?
    private let geocoder = CLGeocoder()
    private lazy var locator: Locator = {
        let l = Locator()
        l.onLocation = { [weak self] loc in self?.located(loc) }
        l.onFailure = { [weak self] in
            self?.locCity = nil
            self?.lastCoord = nil
            self?.fetchWeather(lat: nil, lon: nil)
        }
        return l
    }()

    var placeName: String { autoLocation ? (locCity ?? city) : city }

    /// Moving other apps' windows needs the Accessibility permission; this shows the macOS prompt if it's missing.
    @discardableResult
    static func askForWindowControl() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // Live data
    @Published var weather: Weather?
    @Published var cpu: Double = 0
    @Published var mem: Double = 0
    @Published var battery: Double?
    @Published var charging = false
    @Published var cpuTemp: Double?
    private let sensors = TempSensors()
    @Published var track: Track?
    @Published var art: NSImage?
    @Published var running: Set<String> = []
    @Published var runningExtra: [String] = []
    @Published var nextEvent: NextEvent?
    @Published var calendarDenied = false
    private var watchdogStarted = false
    /// When the weather last loaded, and why it could not if it didn't.
    @Published var weatherAt: Date?
    @Published var weatherNote: String?
    var weatherStale: Bool { weather != nil && Date().timeIntervalSince(weatherAt ?? .distantPast) > 45 * 60 }

    private var prevTicks: (UInt32, UInt32, UInt32, UInt32)?
    private let scriptQueue = DispatchQueue(label: "widgetdock.music")
    private var timers: [Timer] = []
    private let events = EKEventStore()
    private var calendarStarted = false
    private var artKey = ""

    private init() {
        if let data = d.data(forKey: "items"), let saved = try? JSONDecoder().decode([DockItem].self, from: data) {
            items = saved
        } else if let old = d.stringArray(forKey: "apps") {
            items = old.map { .app($0) }
        } else {
            let candidates = [
                "/System/Library/CoreServices/Finder.app",
                "/Applications/Safari.app",
                "/Applications/Google Chrome.app",
                "/System/Applications/Mail.app",
                "/System/Applications/Messages.app",
                "/System/Applications/Calendar.app",
                "/System/Applications/Notes.app",
                "/System/Applications/Utilities/Terminal.app",
                "/System/Applications/System Settings.app",
            ]
            items = candidates.filter { FileManager.default.fileExists(atPath: $0) }.prefix(7).map { .app($0) }
        }
        if let data = d.data(forKey: "todos"), let t = try? JSONDecoder().decode([Todo].self, from: data) {
            todos = t
        } else {
            todos = []
        }
        // Backup city when location is off: a rough guess from the time zone until one is typed in Settings.
        city = d.string(forKey: "city")
            ?? (TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "Chicago")
        autoLocation = d.object(forKey: "autoLocation") != nil ? d.bool(forKey: "autoLocation") : true
        keepWindowsClear = d.bool(forKey: "keepWindowsClear")
        fahrenheit = d.object(forKey: "fahrenheit") != nil ? d.bool(forKey: "fahrenheit") : Locale.current.measurementSystem == .us
        var order = d.stringArray(forKey: "tileOrder") ?? []
        // New tiles go in just before the Trash.
        for t in TileInfo.all where !order.contains(t.id) {
            if let i = order.firstIndex(of: "trash") { order.insert(t.id, at: i) } else { order.append(t.id) }
        }
        note = d.string(forKey: "note") ?? ""
        tileOrder = order.filter { id in TileInfo.all.contains { $0.id == id } }
        hiddenTiles = d.stringArray(forKey: "hiddenTiles") ?? []
        userScale = d.object(forKey: "scale") != nil ? d.double(forKey: "scale") : 1
        allDisplays = d.object(forKey: "allDisplays") != nil ? d.bool(forKey: "allDisplays") : true
        showBadges = d.object(forKey: "showBadges") != nil ? d.bool(forKey: "showBadges") : true
        opacity = d.object(forKey: "opacity") != nil ? d.double(forKey: "opacity") : 1
        showRunning = d.object(forKey: "showRunning") != nil ? d.bool(forKey: "showRunning") : true
        replaceDock = d.bool(forKey: "replaceDock")
    }

    /// Every tile uses the same two text styles, so the bar reads as one piece.
    var titleFont: Font { .system(size: 16 * scale, weight: .semibold, design: .rounded) }
    var captionFont: Font { .system(size: 10 * scale, weight: .medium, design: .rounded) }
    /// Icons that sit beside a title line.
    var inlineIcon: Font { .system(size: 15 * scale, weight: .medium) }

    var visibleTiles: [String] { tileOrder.filter { !hiddenTiles.contains($0) } }

    func start() {
        tick()
        refreshWeather()
        if !hiddenTiles.contains("calendar") { startCalendar() }
        if replaceDock { applySystemDock(hidden: true) }
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshEvents() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in self?.refreshWeather() })
        // Timers pause while the Mac sleeps, so catch up as soon as it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWeather()
            self?.refreshEvents()
            self?.refreshUsage()
        }
        refreshUsage()
        timers.append(Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsage() })
    }

    private func tick() {
        cpu = readCPU()
        mem = readMemory()
        readBattery()
        cpuTemp = sensors.cpuTemp()
        refreshRunning()
        refreshBadges()
        refreshMusic()
        checkPomodoro()
        checkClipboard()
    }

    // MARK: Claude usage (read from Claude Code's session logs in ~/.claude/projects)

    func refreshUsage() {
        guard !DockStore.demo, !hiddenTiles.contains("claude") else { return }
        usageQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
            let weekAgo = Date().addingTimeInterval(-7 * 86400)
            let midnight = Calendar.current.startOfDay(for: Date())
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let marker = Data("\"usage\"".utf8)
            var seen: [String: (stamp: Date, rows: [String: UsageRow])] = [:]

            let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "jsonl",
                      let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      stamp >= weekAgo else { continue }
                if let old = self.usageFiles[url.path], old.stamp == stamp { seen[url.path] = old; continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                var rows: [String: UsageRow] = [:]
                for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let msg = obj["message"] as? [String: Any],
                          let u = msg["usage"] as? [String: Any],
                          let when = (obj["timestamp"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
                    // One reply can be logged on several lines; the id keeps it from being counted twice.
                    let id = (msg["id"] as? String ?? "") + (obj["requestId"] as? String ?? (obj["uuid"] as? String ?? ""))
                    rows[id] = UsageRow(date: when,
                                        input: u["input_tokens"] as? Int ?? 0,
                                        output: u["output_tokens"] as? Int ?? 0,
                                        cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                                        cacheRead: u["cache_read_input_tokens"] as? Int ?? 0)
                }
                seen[url.path] = (stamp, rows)
            }
            self.usageFiles = seen

            var all: [String: UsageRow] = [:]
            for file in seen.values { all.merge(file.rows) { a, _ in a } }
            var today = Usage(), week = Usage()
            for r in all.values where r.date >= weekAgo {
                week.add(r)
                if r.date >= midnight { today.add(r) }
            }
            DispatchQueue.main.async {
                if self.usageToday != today { self.usageToday = today }
                if self.usageWeek != week { self.usageWeek = week }
            }
        }
    }

    // MARK: Tools (focus timer, clipboard, sound and display)

    func pomoToggle() {
        if let end = pomoEnd {
            pomoLeft = max(0, end.timeIntervalSinceNow)
            pomoEnd = nil
        } else {
            pomoEnd = Date().addingTimeInterval(pomoLeft)
        }
    }

    func pomoReset() {
        pomoEnd = nil
        pomoBreak = false
        pomoLeft = Self.focusLength
    }

    /// When focus time runs out a break starts by itself; when the break ends the timer waits for a click.
    private func checkPomodoro() {
        guard let end = pomoEnd, end <= Date() else { return }
        NSSound(named: "Glass")?.play()
        pomoBreak.toggle()
        pomoLeft = pomoBreak ? Self.breakLength : Self.focusLength
        pomoEnd = pomoBreak ? Date().addingTimeInterval(pomoLeft) : nil
    }

    private func checkClipboard() {
        guard !hiddenTiles.contains("clipboard") else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != clipCount else { return }
        clipCount = pb.changeCount
        // Password managers mark what they copy; those are never kept.
        let secret = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        guard !(pb.types ?? []).contains(where: { secret.contains($0.rawValue) }),
              let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clips.removeAll { $0 == text }
        clips.insert(text, at: 0)
        if clips.count > 12 { clips.removeLast(clips.count - 12) }
    }

    func copyClip(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func script(_ source: String) {
        scriptQueue.async { NSAppleScript(source: source)?.executeAndReturnError(nil) }
    }

    func readVolume() {
        scriptQueue.async { [weak self] in
            let src = "set v to get volume settings\nreturn ((output volume of v) as text) & \",\" & ((output muted of v) as text)"
            let out = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue ?? ""
            let parts = out.components(separatedBy: ",")
            guard parts.count == 2, let v = Double(parts[0]) else { return }
            DispatchQueue.main.async { self?.volume = v; self?.muted = parts[1] == "true" }
        }
    }

    func setVolume(_ v: Double) { volume = v; script("set volume output volume \(Int(v))") }
    func setMuted(_ m: Bool) { muted = m; script("set volume output muted \(m)") }
    func toggleDarkMode() {
        script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
    }
    func sleepDisplay() { DispatchQueue.global().async { run("/usr/bin/pmset", ["displaysleepnow"]) } }

    // MARK: Apps and folders

    var pinnedPaths: Set<String> {
        var s = Set<String>()
        for item in items {
            switch item {
            case .app(let p): s.insert(p)
            case .folder(let f): s.formUnion(f.apps)
            }
        }
        return s
    }

    var folders: [AppFolder] {
        items.compactMap { if case .folder(let f) = $0 { return f } else { return nil } }
    }

    private func refreshRunning() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let paths = apps.compactMap { $0.bundleURL?.path }
        let set = Set(paths)
        if set != running { running = set }
        let pinned = pinnedPaths
        var seen = Set<String>()
        let extra = paths.filter { !pinned.contains($0) && seen.insert($0).inserted }
        if extra != runningExtra { runningExtra = extra }
    }

    /// Unread counts come from Apple's Dock (still running while hidden), read through Accessibility.
    private func refreshBadges() {
        guard showBadges, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            if !badges.isEmpty { badges = [:] }
            return
        }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var out: [String: String] = [:]
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXChildrenAttribute as CFString, &v) == .success, let lists = v as? [AXUIElement] else { return }
        for list in lists {
            var c: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &c) == .success, let entries = c as? [AXUIElement] else { continue }
            for entry in entries {
                var label: CFTypeRef?, url: CFTypeRef?
                guard AXUIElementCopyAttributeValue(entry, "AXStatusLabel" as CFString, &label) == .success,
                      let text = label as? String, !text.isEmpty,
                      AXUIElementCopyAttributeValue(entry, kAXURLAttribute as CFString, &url) == .success,
                      let u = url as? URL else { continue }
                out[(u.path as NSString).standardizingPath] = text
            }
        }
        if out != badges { badges = out }
    }

    /// Clicking the app you're already in hides it; otherwise it opens or comes to the front.
    // MARK: Browser profiles (Chrome and its relatives list them in a "Local State" file)

    private static let browserFolders: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]
    private var profileCache: [String: (at: Date, list: [BrowserProfile])] = [:]

    /// The browser's profiles, by name. Empty for apps that are not a supported browser. Re-read at most once a minute.
    func browserProfiles(_ path: String) -> [BrowserProfile] {
        if let hit = profileCache[path], Date().timeIntervalSince(hit.at) < 60 { return hit.list }
        var list: [BrowserProfile] = []
        if let id = Bundle(path: path)?.bundleIdentifier, let folder = Self.browserFolders[id],
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let data = try? Data(contentsOf: support.appendingPathComponent(folder).appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] {
            list = cache.map { BrowserProfile(dir: $0.key, name: ($0.value["name"] as? String) ?? $0.key) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        profileCache[path] = (Date(), list)
        return list
    }

    func openProfile(_ path: String, _ profile: BrowserProfile) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.arguments = ["--profile-directory=\(profile.dir)"]
        // A second launch hands the request to the browser that is already open, which shows that profile's window.
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg)
    }

    func activate(_ path: String) {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleURL?.path == path {
            front.hide()
        } else {
            launch(path)
        }
    }

    func moveItem(_ id: String, by offset: Int) {
        guard offset != 0, let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(items.count - 1, i + offset))
        guard i != j else { return }
        let item = items.remove(at: i)
        items.insert(item, at: j)
    }

    func addApp(_ path: String) {
        guard path.hasSuffix(".app"), !pinnedPaths.contains(path) else { return }
        items.append(.app(path))
        refreshRunning()
    }

    func removeApp(_ path: String) {
        items.removeAll { $0 == .app(path) }
        refreshRunning()
    }

    func launch(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
    }

    func quit(_ path: String) {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }?.terminate()
    }

    func newFolder(with path: String) {
        guard let name = promptText(title: "New folder", info: "Name this folder of apps.", value: "Folder") else { return }
        let folder = AppFolder(name: name, apps: [path])
        if let i = items.firstIndex(of: .app(path)) {
            items[i] = .folder(folder)
        } else {
            items.append(.folder(folder))
        }
    }

    func move(_ path: String, to folderID: UUID) {
        items.removeAll { $0 == .app(path) }
        updateFolder(folderID) { if !$0.apps.contains(path) { $0.apps.append(path) } }
    }

    func moveOut(_ path: String, of folderID: UUID) {
        updateFolder(folderID) { $0.apps.removeAll { $0 == path } }
        items.append(.app(path))
    }

    func renameFolder(_ folderID: UUID) {
        guard let current = folders.first(where: { $0.id == folderID }),
              let name = promptText(title: "Rename folder", info: "", value: current.name) else { return }
        updateFolder(folderID) { $0.name = name }
    }

    /// Removing a folder puts its apps back on the dock.
    func removeFolder(_ folderID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == folderID.uuidString }), case .folder(let f) = items[i] else { return }
        items.replaceSubrange(i...i, with: f.apps.map { .app($0) })
    }

    private func updateFolder(_ id: UUID, _ change: (inout AppFolder) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id.uuidString }), case .folder(var f) = items[i] else { return }
        change(&f)
        items[i] = .folder(f)
    }

    // MARK: Tiles

    func moveTile(_ id: String, by offset: Int) {
        guard let i = tileOrder.firstIndex(of: id) else { return }
        let j = i + offset
        guard tileOrder.indices.contains(j) else { return }
        tileOrder.swapAt(i, j)
    }

    func setTile(_ id: String, visible: Bool) {
        if visible { hiddenTiles.removeAll { $0 == id } } else if !hiddenTiles.contains(id) { hiddenTiles.append(id) }
    }

    // MARK: System Dock and login

    /// Hides the stock Dock by giving it a very long auto-hide delay; turning this off restores the old setting.
    private func applySystemDock(hidden: Bool) {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let alreadyHidden = (dock?.double(forKey: "autohide-delay") ?? 0) >= 1000 && (dock?.bool(forKey: "autohide") ?? false)
        if hidden {
            guard !alreadyHidden else { startDockWatchdog(); return }
            if d.object(forKey: "prevAutohide") == nil { d.set(dock?.bool(forKey: "autohide") ?? false, forKey: "prevAutohide") }
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"])
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", "1000"])
            startDockWatchdog()
        } else {
            guard d.object(forKey: "prevAutohide") != nil || alreadyHidden else { return }
            let prev = d.bool(forKey: "prevAutohide")
            run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", prev ? "true" : "false"])
            run("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
            d.removeObject(forKey: "prevAutohide")
        }
        run("/usr/bin/killall", ["Dock"])
    }

    /// A small shell script that outlives the app. If WidgetDock dies without quitting cleanly (a crash or a
    /// force quit) and does not come back within 10 seconds, it brings Apple's Dock back, so the Mac is never
    /// left without a Dock. A restart during an update comes back in time and is left alone.
    private func startDockWatchdog() {
        guard !watchdogStarted else { return }
        watchdogStarted = true
        let prev = d.bool(forKey: "prevAutohide") ? "true" : "false"
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 2; done
        sleep 10
        pgrep -x WidgetDock >/dev/null && exit 0
        case "$(defaults read com.apple.dock autohide-delay 2>/dev/null)" in 1000*) ;; *) exit 0 ;; esac
        defaults write com.apple.dock autohide -bool \(prev)
        defaults delete com.apple.dock autohide-delay
        defaults delete local.widgetdock prevAutohide
        killall Dock
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func restoreSystemDockOnQuit() {
        if replaceDock { applySystemDock(hidden: false) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("WidgetDock login item: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: System stats

    private func readCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        defer { prevTicks = t }
        guard let p = prevTicks else { return 0 }
        let user = Double(t.0 &- p.0), sys = Double(t.1 &- p.1), idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total : 0
    }

    private func readMemory() -> Double {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pages = Double(s.active_count) + Double(s.wire_count) + Double(s.compressor_page_count)
        return min(1, pages * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory))
    }

    private func readBattery() {
        let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let level = Double(cur) / Double(max)
            if battery != level { battery = level }
            let chg = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            if charging != chg { charging = chg }
            return
        }
        if battery != nil { battery = nil }
    }

    // MARK: Music (Spotify / Apple Music via AppleScript, only while they are running)

    private static let spotify = "com.spotify.client"
    private static let appleMusic = "com.apple.Music"

    private func refreshMusic() {
        guard !hiddenTiles.contains("music") else { return }
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let active = [Self.spotify, Self.appleMusic].filter { runningIDs.contains($0) }
        guard !active.isEmpty else {
            if track != nil { track = nil; art = nil; artKey = "" }
            return
        }
        scriptQueue.async { [weak self] in
            var found: Track?
            for id in active {
                let artLine = id == Self.spotify ? "(artwork url of current track)" : "\"\""
                let src = """
                tell application id "\(id)"
                    if player state is playing or player state is paused then
                        return (name of current track) & "\n" & (artist of current track) & "\n" & (player state as text) & "\n" & \(artLine)
                    end if
                end tell
                return ""
                """
                guard let out = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue else { continue }
                let parts = out.components(separatedBy: "\n")
                guard parts.count >= 3 else { continue }
                let url = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
                let t = Track(title: parts[0], artist: parts[1], playing: parts[2] == "playing", playerID: id, artURL: url)
                if found == nil || t.playing { found = t }
                if t.playing { break }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.track != found { self.track = found }
                self.refreshArt()
            }
        }
    }

    private func refreshArt() {
        guard let t = track else { art = nil; artKey = ""; return }
        let key = t.playerID + t.title + t.artist
        guard key != artKey else { return }
        artKey = key
        art = nil
        if let s = t.artURL, let url = URL(string: s) {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { if self?.artKey == key { self?.art = img } }
            }.resume()
        } else if t.playerID == Self.appleMusic {
            scriptQueue.async { [weak self] in
                let src = "tell application id \"\(Self.appleMusic)\" to get raw data of artwork 1 of current track"
                guard let data = NSAppleScript(source: src)?.executeAndReturnError(nil).data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { if self?.artKey == key { self?.art = img } }
            }
        }
    }

    func musicCommand(_ command: String) {
        guard let id = track?.playerID else { return }
        scriptQueue.async { [weak self] in
            NSAppleScript(source: "tell application id \"\(id)\" to \(command)")?.executeAndReturnError(nil)
            DispatchQueue.main.async { self?.refreshMusic() }
        }
    }

    // MARK: Calendar (events from the macOS Calendar app)

    func startCalendar() {
        guard !calendarStarted else { return }
        calendarStarted = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
            self?.refreshEvents()
        }
        events.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.calendarDenied = !granted
                self?.refreshEvents()
            }
        }
    }

    func refreshEvents() {
        guard calendarStarted else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            // Access was turned off after launch: say so instead of leaving the last event on screen.
            if status != .notDetermined {
                if nextEvent != nil { nextEvent = nil }
                if !calendarDenied { calendarDenied = true }
            }
            return
        }
        if calendarDenied { calendarDenied = false }
        let now = Date()
        let pred = events.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(7 * 86400), calendars: nil)
        let upcoming = events.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        // Long blocks (over 3 hours) would hide real meetings, so they only show when nothing else is coming.
        let next = upcoming.first { $0.endDate.timeIntervalSince($0.startDate) <= 3 * 3600 } ?? upcoming.first
        let ev = next.map {
            NextEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate, joinURL: Self.joinLink(in: $0))
        }
        if ev != nextEvent { nextEvent = ev }
    }

    private static func joinLink(in e: EKEvent) -> URL? {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)[^\s<>"]*"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[r]))
    }

    // MARK: Weather (open-meteo.com, no account needed)

    private struct Geo: Decodable {
        struct Place: Decodable { let latitude: Double; let longitude: Double }
        let results: [Place]?
    }
    private struct Forecast: Decodable {
        struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
        struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
        let current: Current
        let daily: Daily
    }

    func refreshWeather() {
        guard !DockStore.demo else { return }
        if autoLocation {
            locator.request()
            if let c = lastCoord { fetchWeather(lat: c.0, lon: c.1) }
        } else {
            fetchWeather(lat: nil, lon: nil)
        }
    }

    private func located(_ loc: CLLocation) {
        let lat = (loc.coordinate.latitude * 100).rounded() / 100
        let lon = (loc.coordinate.longitude * 100).rounded() / 100
        lastCoord = (lat, lon)
        fetchWeather(lat: lat, lon: lon)
        guard !geocoder.isGeocoding else { return }
        geocoder.reverseGeocodeLocation(loc) { [weak self] marks, _ in
            guard let name = marks?.first?.locality else { return }
            DispatchQueue.main.async { self?.locCity = name }
        }
    }

    /// With no coordinates, looks up the typed city instead.
    private func fetchWeather(lat: Double?, lon: Double?) {
        let city = self.city, unit = fahrenheit ? "fahrenheit" : "celsius"
        Task {
            do {
                var latitude = lat, longitude = lon
                if latitude == nil || longitude == nil {
                    var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                    geo.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
                    let (gData, _) = try await URLSession.shared.data(from: geo.url!)
                    guard let place = try JSONDecoder().decode(Geo.self, from: gData).results?.first else {
                        await MainActor.run { self.weather = nil; self.weatherNote = "City not found" }
                        return
                    }
                    latitude = place.latitude
                    longitude = place.longitude
                }
                var fc = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                fc.queryItems = [
                    .init(name: "latitude", value: String(latitude!)),
                    .init(name: "longitude", value: String(longitude!)),
                    .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                    .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
                    .init(name: "temperature_unit", value: unit),
                    .init(name: "timezone", value: "auto"),
                    .init(name: "forecast_days", value: "1"),
                ]
                let (fData, _) = try await URLSession.shared.data(from: fc.url!)
                let f = try JSONDecoder().decode(Forecast.self, from: fData)
                let w = Weather(temp: f.current.temperature_2m,
                                high: f.daily.temperature_2m_max.first ?? f.current.temperature_2m,
                                low: f.daily.temperature_2m_min.first ?? f.current.temperature_2m,
                                code: f.current.weather_code,
                                isDay: f.current.is_day == 1)
                await MainActor.run { self.weather = w; self.weatherAt = Date(); self.weatherNote = nil }
            } catch {
                // Keep the last reading when offline; the tile marks it as old after 45 minutes.
                await MainActor.run { self.weatherNote = "Can't reach the weather service" }
            }
        }
    }
}

// MARK: - Dock views

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Tile<Content: View>: View {
    @EnvironmentObject var store: DockStore
    var pad: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, pad * store.scale)
            .frame(height: 60 * store.scale)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14 * store.scale, style: .continuous))
    }
}

struct ClockTile: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Tile {
                VStack(alignment: .leading, spacing: 2 * store.scale) {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(store.titleFont)
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .font(store.captionFont)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
    }
}

struct WeatherTile: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 2 * store.scale) {
                HStack(spacing: 5 * store.scale) {
                    Image(systemName: store.weather?.symbol ?? "cloud.slash")
                        .symbolRenderingMode(.multicolor)
                        .font(store.inlineIcon)
                    Text(store.weather.map { "\(Int($0.temp.rounded()))°" } ?? "--°")
                        .font(store.titleFont)
                        .opacity(store.weatherStale ? 0.5 : 1)
                }
                Text(subtitle)
                    .font(store.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .help(store.weatherNote.map { "Weather for \(store.placeName): \($0)" } ?? "Weather for \(store.placeName)")
    }

    /// Says so when the reading is old or missing, instead of showing old numbers as if they were current.
    private var subtitle: String {
        guard let w = store.weather else { return store.weatherNote ?? store.placeName }
        if store.weatherStale, let at = store.weatherAt {
            let mins = Int(Date().timeIntervalSince(at) / 60)
            return "\(store.placeName) · \(mins < 120 ? "\(mins) min" : "\(mins / 60) hr") old"
        }
        return "\(store.placeName) · \(Int(w.high.rounded()))° / \(Int(w.low.rounded()))°"
    }
}

struct CalendarTile: View {
    @EnvironmentObject var store: DockStore

    private func subtitle(_ e: NextEvent, now: Date) -> String {
        if e.start <= now { return "Now · ends \(e.end.formatted(date: .omitted, time: .shortened))" }
        let mins = Int(e.start.timeIntervalSince(now) / 60)
        if mins < 60 { return "in \(max(1, mins)) min" }
        if Calendar.current.isDateInToday(e.start) { return "Today \(e.start.formatted(date: .omitted, time: .shortened))" }
        return e.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func open(_ e: NextEvent?) {
        if let e, let url = e.joinURL, e.start.timeIntervalSinceNow < 15 * 60 {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let e = store.nextEvent
            let soon = e.map { $0.start.timeIntervalSince(ctx.date) < 15 * 60 } ?? false
            let canJoin = soon && e?.joinURL != nil
            Tile {
                VStack(alignment: .leading, spacing: 2 * store.scale) {
                    HStack(spacing: 5 * store.scale) {
                        Image(systemName: canJoin ? "video.fill" : "calendar")
                            .font(store.inlineIcon)
                            .foregroundStyle(soon ? Color.red : Color.primary)
                        Text(e?.title ?? (store.calendarDenied ? "No calendar access" : "No upcoming events"))
                            .font(store.titleFont)
                            .lineLimit(1)
                    }
                    Text((e.map { subtitle($0, now: ctx.date) } ?? (store.calendarDenied ? "Allow in System Settings" : "Next 7 days are clear"))
                         + (canJoin ? " · click to join" : ""))
                        .font(store.captionFont)
                        .foregroundStyle(soon ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 190 * store.scale, alignment: .leading)
                .fixedSize()
            }
            .contentShape(Rectangle())
            .onTapGesture { open(e) }
            .help(e?.joinURL != nil ? "Click to join when the meeting is within 15 minutes" : "Click to open Calendar")
            .contextMenu {
                if let url = e?.joinURL { Button("Join meeting") { NSWorkspace.shared.open(url) } }
                Button("Open Calendar") { open(nil) }
            }
        }
    }
}

struct AppIcon: View {
    @EnvironmentObject var store: DockStore
    let path: String
    var pinned = true
    var folder: UUID? = nil
    @State private var hover = false

    var body: some View {
        let name = appName(path)
        let size = 46 * store.scale
        VStack(spacing: 2) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: size, height: size)
                .scaleEffect(hover ? 1.18 : 1, anchor: .bottom)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
                .overlay(alignment: .topTrailing) {
                    if let badge = store.badges[path] {
                        Text(badge)
                            .font(.system(size: 9 * store.scale, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4 * store.scale)
                            .frame(minWidth: 16 * store.scale, minHeight: 16 * store.scale)
                            .background(Color.red, in: Capsule())
                            .offset(x: 4, y: -3)
                    }
                }
            Circle()
                .fill(Color.primary.opacity(store.running.contains(path) ? 0.7 : 0))
                .frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.activate(path) }
        .help(name)
        .contextMenu {
            Button("Open \(name)") { store.launch(path) }
            let profiles = store.browserProfiles(path)
            if profiles.count > 1 {
                Divider()
                ForEach(profiles, id: \.self) { p in Button(p.name) { store.openProfile(path, p) } }
                Divider()
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Divider()
            if let folder {
                Button("Move Out of Folder") { store.moveOut(path, of: folder) }
            } else if pinned {
                Menu("Move to Folder") {
                    ForEach(store.folders) { f in Button(f.name) { store.move(path, to: f.id) } }
                    if !store.folders.isEmpty { Divider() }
                    Button("New Folder…") { store.newFolder(with: path) }
                }
                Button("Remove from Dock") { store.removeApp(path) }
            } else {
                Button("Keep in Dock") { store.addApp(path) }
            }
            if store.running.contains(path) {
                Divider()
                Button("Quit") { store.quit(path) }
            }
        }
    }
}

struct FolderIcon: View {
    @EnvironmentObject var store: DockStore
    let folder: AppFolder
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let size = 46 * store.scale
        let mini = (size - 14) / 2
        VStack(spacing: 2) {
            VStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<2, id: \.self) { col in
                            let i = row * 2 + col
                            if i < folder.apps.count {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.apps[i])).resizable().frame(width: mini, height: mini)
                            } else {
                                Color.clear.frame(width: mini, height: mini)
                            }
                        }
                    }
                }
            }
            .frame(width: size - 4, height: size - 4)
            .background(Color.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 11 * store.scale, style: .continuous))
            .padding(2)
            .scaleEffect(hover ? 1.12 : 1, anchor: .bottom)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            Circle()
                .fill(Color.primary.opacity(folder.apps.contains { store.running.contains($0) } ? 0.7 : 0))
                .frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open.toggle() }
        .help(folder.name)
        .contextMenu {
            Button("Rename…") { store.renameFolder(folder.id) }
            Button("Remove Folder (keeps apps)") { store.removeFolder(folder.id) }
        }
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(spacing: 10) {
                Text(folder.name).font(.headline)
                if folder.apps.isEmpty {
                    Text("Empty. Right-click an app and choose Move to Folder.").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(76)), count: min(4, max(1, folder.apps.count))), spacing: 10) {
                    ForEach(folder.apps, id: \.self) { path in
                        VStack(spacing: 2) {
                            AppIcon(path: path, folder: folder.id)
                            Text(appName(path)).font(.caption2).lineLimit(1).frame(width: 72)
                        }
                    }
                }
            }
            .padding(14)
            .environmentObject(store)
        }
    }
}

struct AppsStrip: View {
    @EnvironmentObject var store: DockStore
    @State private var dragging: String?
    @State private var dragX: CGFloat = 0
    var body: some View {
        HStack(spacing: 6 * store.scale) {
            ForEach(store.items) { item in
                Group {
                    switch item {
                    case .app(let path): AppIcon(path: path)
                    case .folder(let f): FolderIcon(folder: f)
                    }
                }
                .offset(x: dragging == item.id ? dragX : 0)
                .zIndex(dragging == item.id ? 1 : 0)
                .gesture(
                    // Drag an icon sideways to reorder; it drops into the nearest slot.
                    DragGesture(minimumDistance: 8)
                        .onChanged { v in dragging = item.id; dragX = v.translation.width }
                        .onEnded { v in
                            let slot = 52 * store.scale
                            let shift = Int((v.translation.width / slot).rounded())
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                store.moveItem(item.id, by: shift)
                                dragging = nil
                                dragX = 0
                            }
                        }
                )
            }
            if store.showRunning && !store.runningExtra.isEmpty {
                if !store.items.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 36 * store.scale).padding(.horizontal, 2)
                }
                ForEach(store.runningExtra, id: \.self) { AppIcon(path: $0, pinned: false) }
            }
        }
        .padding(.horizontal, 4)
    }
}

struct TrashIcon: View {
    @EnvironmentObject var store: DockStore
    @State private var hover = false
    var body: some View {
        let size = 46 * store.scale
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        VStack(spacing: 2) {
            Image(nsImage: NSImage(named: NSImage.trashEmptyName) ?? NSImage())
                .resizable()
                .frame(width: size, height: size)
                .scaleEffect(hover ? 1.18 : 1, anchor: .bottom)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            Color.clear.frame(width: 4, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(trash) }
        .help("Trash")
    }
}

struct Ring: View {
    @EnvironmentObject var store: DockStore
    let value: Double
    let label: String
    let color: Color
    var text: String? = nil
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                Circle().trim(from: 0, to: max(0.01, min(1, value)))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: value)
                Text(text ?? "\(Int((value * 100).rounded()))")
                    .font(store.captionFont.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: 32 * store.scale, height: 32 * store.scale)
            Text(label)
                .font(.system(size: 8 * store.scale, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatsTile: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        Tile {
            HStack(spacing: 10 * store.scale) {
                Ring(value: store.cpu, label: "CPU", color: .blue)
                Ring(value: store.mem, label: "MEM", color: .purple)
                if let c = store.cpuTemp {
                    // Ring fills toward 100°C; the number follows the weather unit setting.
                    let shown = store.fahrenheit ? c * 9 / 5 + 32 : c
                    Ring(value: c / 100, label: "TEMP", color: c > 85 ? .red : .orange, text: "\(Int(shown.rounded()))°")
                }
                if let b = store.battery {
                    Ring(value: b, label: store.charging ? "CHG" : "BAT", color: b < 0.2 ? .red : .green)
                }
            }
        }
    }
}

struct MusicTile: View {
    @EnvironmentObject var store: DockStore
    let track: Track
    var body: some View {
        let side = 38 * store.scale
        Tile {
            HStack(spacing: 10 * store.scale) {
                Group {
                    if let art = store.art {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note").font(.system(size: 16 * store.scale, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8 * store.scale, style: .continuous))
                .onTapGesture {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.playerID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
                VStack(alignment: .leading, spacing: 2 * store.scale) {
                    Text(track.title).font(store.titleFont).lineLimit(1)
                    Text(track.artist).font(store.captionFont).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 130 * store.scale, alignment: .leading)
                .fixedSize()
                HStack(spacing: 8 * store.scale) {
                    Button { store.musicCommand("previous track") } label: { Image(systemName: "backward.fill") }
                    Button { store.musicCommand("playpause") } label: {
                        Image(systemName: track.playing ? "pause.fill" : "play.fill").font(.system(size: 16 * store.scale))
                    }
                    Button { store.musicCommand("next track") } label: { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 12 * store.scale))
                .buttonStyle(.plain)
            }
        }
    }
}

struct TodoTile: View {
    @EnvironmentObject var store: DockStore
    @State private var open = false
    @State private var draft = ""

    private var remaining: Int { store.todos.filter { !$0.done }.count }

    var body: some View {
        Tile {
            VStack(spacing: 3) {
                Image(systemName: "checklist").font(.system(size: 18 * store.scale, weight: .medium))
                Text(remaining == 0 ? "Todos" : "\(remaining) left")
                    .font(store.captionFont)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 40 * store.scale)
        }
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
        .popover(isPresented: $open, arrowEdge: .top) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Todos").font(.headline)
            if store.todos.isEmpty {
                Text("Nothing yet. Add one below.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach($store.todos) { $todo in
                HStack {
                    Button { todo.done.toggle() } label: {
                        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(todo.done ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    Text(todo.title)
                        .strikethrough(todo.done)
                        .foregroundStyle(todo.done ? .secondary : .primary)
                    Spacer()
                    Button { store.todos.removeAll { $0.id == todo.id } } label: {
                        Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField("New todo", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let t = draft.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { store.todos.append(Todo(title: t)) }
                    draft = ""
                }
        }
        .padding(14)
        .frame(width: 260)
    }
}

// MARK: - Tool tiles

/// The small icon square the tool tiles share.
struct ToolFace: View {
    @EnvironmentObject var store: DockStore
    let icon: String
    var label: String? = nil
    var tint: Color = .primary
    var body: some View {
        Tile(pad: 9) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18 * store.scale, weight: .medium))
                    .foregroundStyle(tint)
                if let label {
                    Text(label)
                        .font(store.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 24 * store.scale)
        }
        .contentShape(Rectangle())
    }
}

/// A tool tile that opens a small panel when clicked.
struct ToolTile<Panel: View>: View {
    @EnvironmentObject var store: DockStore
    let icon: String
    let name: String
    var label: String? = nil
    @ViewBuilder var panel: Panel
    @State private var open = false
    var body: some View {
        ToolFace(icon: icon, label: label)
            .onTapGesture { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .top) { panel.environmentObject(store) }
            .help(name)
    }
}

struct PomodoroTile: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = store.pomoEnd.map { max(0, $0.timeIntervalSince(ctx.date)) } ?? store.pomoLeft
            let secs = Int(left.rounded(.up))
            let idle = store.pomoEnd == nil && !store.pomoBreak && left == DockStore.focusLength
            ToolFace(icon: store.pomoBreak ? "cup.and.saucer.fill" : "timer",
                     label: idle ? nil : String(format: "%d:%02d", secs / 60, secs % 60),
                     tint: store.pomoEnd == nil ? .primary : (store.pomoBreak ? .green : .orange))
        }
        .onTapGesture { store.pomoToggle() }
        .contextMenu {
            Button(store.pomoEnd == nil ? "Start" : "Pause") { store.pomoToggle() }
            Button("Reset") { store.pomoReset() }
        }
        .help("Focus timer: 25 minutes, then a 5 minute break. Click to start or pause, right-click to reset.")
    }
}

struct NotesPanel: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TextEditor(text: $store.note)
                .font(.body)
                .frame(width: 280, height: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        }
        .padding(14)
    }
}

struct ClipboardPanel: View {
    @EnvironmentObject var store: DockStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Clipboard").font(.headline)
                Spacer()
                if !store.clips.isEmpty { Button("Clear") { store.clips = [] }.buttonStyle(.link) }
            }
            if store.clips.isEmpty {
                Text("Text you copy shows up here. Click one to copy it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.clips, id: \.self) { clip in
                Button { store.copyClip(clip); dismiss() } label: {
                    Text(clip.trimmingCharacters(in: .whitespacesAndNewlines))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct DownloadsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    private static let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    private static func recent() -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.contentModificationDate ?? .distantPast
        }
        return Array(all.map { ($0, date($0)) }.sorted { $0.1 > $1.1 }.prefix(8).map(\.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Downloads").font(.headline).padding(.bottom, 4)
            if files.isEmpty { Text("Nothing here.").font(.caption).foregroundStyle(.secondary) }
            ForEach(files, id: \.self) { url in
                Button { NSWorkspace.shared.open(url); dismiss() } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4)
            Button("Open Downloads Folder") { NSWorkspace.shared.open(Self.folder); dismiss() }.buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { files = Self.recent() }
    }
}

struct UsagePanel: View {
    @EnvironmentObject var store: DockStore

    private func row(_ title: String, _ u: Usage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(shortCount(u.tokens)) tokens").font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Text("\(shortCount(u.input)) in · \(shortCount(u.output)) out · \(shortCount(u.cacheWrite)) cache written")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(u.messages) replies · \(shortCount(u.cacheRead)) read from cache")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Code usage").font(.headline)
            row("Today", store.usageToday)
            Divider()
            row("Last 7 days", store.usageWeek)
            Text("Counted from Claude Code's logs on this Mac. Chats in the Claude app are not included.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { store.refreshUsage() }
    }
}

struct ControlsPanel: View {
    @EnvironmentObject var store: DockStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound and display").font(.headline)
            HStack(spacing: 8) {
                Button { store.setMuted(!store.muted) } label: {
                    Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 22)
                }
                .buttonStyle(.plain)
                .help(store.muted ? "Unmute" : "Mute")
                Slider(value: $store.volume, in: 0...100) { editing in
                    if !editing { store.setVolume(store.volume) }
                }
            }
            HStack {
                Button("Light / Dark") { store.toggleDarkMode() }
                Button("Sleep Display") { store.sleepDisplay() }
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { store.readVolume() }
    }
}

struct DockView: View {
    @EnvironmentObject var store: DockStore

    @ViewBuilder private func tile(_ id: String) -> some View {
        switch id {
        case "clock": ClockTile()
        case "weather": WeatherTile()
        case "calendar": CalendarTile()
        case "apps": AppsStrip()
        case "stats": StatsTile()
        case "music": if let t = store.track { MusicTile(track: t) }
        case "todos": TodoTile()
        case "pomodoro": PomodoroTile()
        case "notes": ToolTile(icon: "note.text", name: "Notes") { NotesPanel() }
        case "clipboard": ToolTile(icon: "doc.on.clipboard", name: "Clipboard history") { ClipboardPanel() }
        case "screenshot":
            ToolFace(icon: "camera.viewfinder")
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")) }
                .help("Take a screenshot")
        case "downloads": ToolTile(icon: "arrow.down.circle", name: "Downloads") { DownloadsPanel() }
        case "controls": ToolTile(icon: "slider.horizontal.3", name: "Sound and display") { ControlsPanel() }
        case "claude":
            ToolTile(icon: "sparkles", name: "Claude Code tokens used today", label: shortCount(store.usageToday.tokens)) { UsagePanel() }
        case "trash": TrashIcon()
        default: EmptyView()
        }
    }

    var body: some View {
        // Menus and drag-and-drop can't be drawn off screen, so the sample image leaves them off.
        if DockStore.demo { bar } else { interactiveBar }
    }

    private var bar: some View {
        let radius = 24 * store.scale
        return HStack(spacing: 8 * store.scale) {
            ForEach(store.visibleTiles, id: \.self) { tile($0) }
            Button { (NSApp.delegate as? AppDelegate)?.openSettings() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14 * store.scale))
                    .foregroundStyle(.secondary)
                    .frame(width: 22 * store.scale, height: 60 * store.scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("WidgetDock Settings")
        }
        .padding(10 * store.scale)
        .background {
            if DockStore.demo {
                // The blur can't be drawn off screen, so the sample image uses a flat tint.
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(white: 0.13).opacity(0.82))
            } else {
                VisualEffect().opacity(store.opacity).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.18 * store.opacity), lineWidth: 1))
        .shadow(color: .black.opacity(0.3 * store.opacity), radius: 12, y: 5)
        .padding(20)
        .fixedSize()
    }

    private var interactiveBar: some View {
        bar
        .contextMenu {
            Button("WidgetDock Settings…") { (NSApp.delegate as? AppDelegate)?.openSettings() }
            Button("Add App…") { (NSApp.delegate as? AppDelegate)?.addApp() }
            Button("Fit All Windows Above Dock") { (NSApp.delegate as? AppDelegate)?.fitAllWindows() }
            Divider()
            Button("Quit WidgetDock") { NSApp.terminate(nil) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { store.addApp(url.path) } }
                }
            }
            return true
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var store: DockStore
    @State private var cityDraft = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start WidgetDock at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                Toggle("Replace the system Dock", isOn: $store.replaceDock)
                Text("Hides Apple's Dock while WidgetDock is running. Turning this off, or quitting WidgetDock, brings it back.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show running apps that aren't pinned", isOn: $store.showRunning)
                Toggle("Show on every display", isOn: $store.allDisplays)
                Toggle("Show notification badges", isOn: $store.showBadges)
                Toggle("Keep windows above the dock", isOn: $store.keepWindowsClear)
                Text("Shrinks the window you're using when it would sit behind the dock. This and badges need Accessibility permission, which macOS will ask for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tiles") {
                ForEach(store.tileOrder, id: \.self) { id in
                    HStack {
                        Toggle(TileInfo.name(id), isOn: Binding(get: { !store.hiddenTiles.contains(id) }, set: { store.setTile(id, visible: $0) }))
                        Spacer()
                        Button { store.moveTile(id, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(store.tileOrder.first == id)
                        Button { store.moveTile(id, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(store.tileOrder.last == id)
                    }
                    .buttonStyle(.borderless)
                }
                Text("Top of this list is the left side of the dock.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Look") {
                HStack {
                    Text("Size")
                    Slider(value: $store.userScale, in: 0.7...1.5, step: 0.05)
                    Text("\(Int(store.userScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Background")
                    Slider(value: $store.opacity, in: 0...1)
                    Text("\(Int(store.opacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("The dock shrinks on its own if it gets wider than the screen.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Weather") {
                Toggle("Use my current location", isOn: $store.autoLocation)
                TextField(store.autoLocation ? "Backup city" : "City", text: $cityDraft)
                    .onSubmit { commitCity() }
                Picker("Units", selection: $store.fahrenheit) {
                    Text("°F").tag(true)
                    Text("°C").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Section("Apps") {
                Button("Add App…") { (NSApp.delegate as? AppDelegate)?.addApp() }
                Text("You can also drag an app onto the dock. Right-click an app to remove it or put it in a folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Fit All Windows Above Dock") { (NSApp.delegate as? AppDelegate)?.fitAllWindows() }
                Button("Quit WidgetDock") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)
        .onAppear { cityDraft = store.city }
        .onDisappear { commitCity() }
    }

    private func commitCity() {
        let c = cityDraft.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty, c != store.city { store.city = c }
    }
}

// MARK: - App

final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = DockStore.shared
    var panels: [DockPanel] = []
    var settingsWindow: NSWindow?
    private var displayWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ note: Notification) {
        // The bar is no longer draggable (dragging now reorders apps), so drop any old saved position.
        UserDefaults.standard.removeObject(forKey: "centerX")
        UserDefaults.standard.removeObject(forKey: "originY")

        rebuildPanels()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildPanels()
        }
        displayWatch = store.$allDisplays.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildPanels() }
        }
        // The usable screen area changes when the system Dock hides or shows.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.place() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.store.keepWindowsClear else { return }
            self.fitWindows(all: false)
        }

        store.start()
    }

    /// Opening WidgetDock again from Applications brings up Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panels.forEach { $0.orderFrontRegardless() }
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.restoreSystemDockOnQuit()
    }

    private func makePanel() -> DockPanel {
        let panel = DockPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingController(rootView: DockView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.orderFrontRegardless()
        return panel
    }

    /// One bar per display (or just the main display, depending on the setting).
    func rebuildPanels() {
        let wanted = store.allDisplays ? NSScreen.screens.count : min(1, NSScreen.screens.count)
        if wanted != panels.count {
            panels.forEach { $0.orderOut(nil) }
            panels = (0..<wanted).map { _ in makePanel() }
        }
        DispatchQueue.main.async { self.place() }
    }

    /// Each bar paired with its display; the first display is the main one.
    private var placed: [(panel: DockPanel, screen: NSScreen)] {
        Array(zip(panels, NSScreen.screens)).map { (panel: $0.0, screen: $0.1) }
    }

    /// Bottom-centre of each display, just above the system Dock if it is showing there.
    func place() {
        for (panel, screen) in placed {
            let size = panel.frame.size
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY - 14)
            if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
        }
        refit()
    }

    /// Shrinks the whole bar when it would be wider than the narrowest display it is on.
    private func refit() {
        let current = store.scale
        var fit = 1.0
        for (panel, screen) in placed {
            let natural = (panel.frame.width - 40) / current
            guard natural > 0 else { continue }
            fit = min(fit, (screen.frame.width - 56) / (natural * store.userScale))
        }
        fit = max(0.4, min(1, fit))
        if abs(fit - store.fitScale) > 0.01 { store.fitScale = fit }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = notification.object as? NSWindow, panels.contains(where: { $0 === w }) { place() }
    }

    @objc func fitAllWindows() {
        if DockStore.askForWindowControl() { fitWindows(all: true) }
    }

    /// Shrinks windows whose bottom edge would sit behind a dock.
    func fitWindows(all: Bool) {
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return }
        // Accessibility uses top-left coordinates measured from the main display; the visible bar starts 20pt inside its panel.
        let h = primary.frame.height
        let zones = placed.map { p in
            (frame: CGRect(x: p.screen.frame.minX, y: h - p.screen.frame.maxY, width: p.screen.frame.width, height: p.screen.frame.height),
             limit: h - (p.panel.frame.maxY - 20) - 6)
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = all
            ? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            : [NSWorkspace.shared.frontmostApplication].compactMap { $0 }
        for app in apps where app.processIdentifier != me {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            var value: CFTypeRef?
            var windows: [AXUIElement] = []
            if all {
                if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success {
                    windows = value as? [AXUIElement] ?? []
                }
            } else if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &value) == .success, let v = value {
                windows = [v as! AXUIElement]
            }
            for w in windows { fit(w, zones: zones) }
        }
    }

    private func fit(_ w: AXUIElement, zones: [(frame: CGRect, limit: CGFloat)]) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &value) == .success, (value as? Bool) == true { return }
        if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &value) == .success, (value as? Bool) == true { return }
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let mid = CGPoint(x: pos.x + size.width / 2, y: pos.y + min(size.height, 40) / 2)
        // Use the display the window's title bar is on; leave alone windows that start too low to shrink sensibly.
        guard let zone = zones.first(where: { $0.frame.contains(mid) }),
              pos.y < zone.limit - 200, pos.y + size.height > zone.limit + 1 else { return }
        var newSize = CGSize(width: size.width, height: zone.limit - pos.y)
        if let v = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(store)))
            w.title = "WidgetDock Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func addApp() {
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.allowedContentTypes = [.application]
        open.allowsMultipleSelection = true
        if open.runModal() == .OK { open.urls.forEach { store.addApp($0.path) } }
    }
}

@main
enum Main {
    @MainActor static func main() {
        // `WidgetDock --usage` prints the Claude Code token counts the usage tile shows, then exits.
        if CommandLine.arguments.contains("--usage") {
            let store = DockStore.shared
            store.refreshUsage()
            let giveUp = Date().addingTimeInterval(30)
            while store.usageWeek.messages == 0 && Date() < giveUp { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            for (name, u) in [("today", store.usageToday), ("7 days", store.usageWeek)] {
                print("\(name): \(u.tokens) tokens (\(u.input) in, \(u.output) out, \(u.cacheWrite) cache written, \(u.cacheRead) cache read), \(u.messages) replies")
            }
            exit(0)
        }
        // `WidgetDock --screenshot out.png` draws a sample dock (made-up data) to an image and exits.
        if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), i + 1 < CommandLine.arguments.count {
            DockStore.demo = true
            _ = NSApplication.shared
            let store = DockStore.shared
            store.loadDemo()
            let view = DockView().environmentObject(store)
                .padding(.horizontal, 30).padding(.top, 60).padding(.bottom, 6)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.25, blue: 0.55), Color(red: 0.55, green: 0.25, blue: 0.55), Color(red: 0.95, green: 0.55, blue: 0.35)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            // Convert to plain sRGB; the renderer can hand back an HDR image that looks washed out in browsers.
            guard let cg = renderer.cgImage,
                  let rep = NSBitmapImageRep(cgImage: cg).converting(to: .sRGB, renderingIntent: .default),
                  let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
