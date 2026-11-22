// TokenTide — tiny always-on-top meter for your Claude plan usage, macOS 13+.
// Unofficial; not affiliated with or endorsed by Anthropic.
//
// Security model (see SECURITY.md):
//   - Reads Claude Code's OAuth token the same way Claude Code does
//     (`security find-generic-password`), so there is no extra permission prompt.
//   - The token lives only in memory. It is never logged, displayed or written.
//   - The only network peer is https://api.anthropic.com. The URL session is
//     ephemeral (no disk cache, no cookies) and refuses redirects, so the
//     Authorization header can't be forwarded to another host.
//   - Persisted state (UserDefaults): widget position, and the last limit
//     percentages + reset times. Nothing else.
//
// Data sources:
//   1. Plan limits (% used / reset time): GET https://api.anthropic.com/api/oauth/usage
//      using the OAuth token Claude Code stores in Keychain ("Claude Code-credentials").
//      Same data as /usage in Claude Code and Settings > Usage on claude.ai.
//      Undocumented endpoint — may change. Only known limit keys are shown;
//      internal codename fields are ignored.
//   2. Token counts + per-model share: summed from Claude Code's local logs
//      (~/.claude/projects/**/*.jsonl). Only Claude Code traffic is logged locally;
//      claude.ai web/desktop chats are not. Token share != limit share
//      (Opus/Fable tokens weigh more against limits than Sonnet tokens).
//
// Build: ./build.sh   (needs Xcode Command Line Tools)

import SwiftUI
import AppKit
import Combine
import QuartzCore
import ServiceManagement

@main
struct TokenTideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Window

private let windowMargin: CGFloat = 10   // transparent room around the shape for its shadow

// Hosting view that (a) lets you drag the window from anywhere and (b) reports
// hover even though the panel never becomes key (.activeAlways tracking).
// The hover rect excludes the transparent shadow margin.
final class DragHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (@MainActor (Bool) -> Void)?
    private var area: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds.insetBy(dx: windowMargin, dy: windowMargin),
                               options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

// Window geometry model:
// - `home` is the origin of the collapsed circle (content rect, without margin). It is
//   the single source of truth for position and only changes when the user drags.
// - The expanded panel is anchored at the circle's corner nearest the screen corner,
//   so it grows toward the screen center and collapsing returns to exactly `home`.
//
// Animation: resizing an NSWindow every frame (and re-rendering its blur + shadow)
// is what made the previous version stutter. Now the window is resized exactly once
// per transition, and the morph itself is a SwiftUI animation of a shape inside the
// window, which Core Animation composites on the GPU at display refresh rate.
//   expand:   grow window to panel size instantly (circle stays pinned in its
//             corner, so nothing visibly moves) -> animate shape circle -> panel
//   collapse: animate shape panel -> circle -> shrink window to circle size
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var host: DragHostingView<MeterView>!
    private var measurer: NSHostingView<ExpandedPanel>!   // off-screen, sizes the expanded panel
    private let store = Store()
    private var bag: AnyCancellable?
    private var collapseTask: Task<Void, Never>?

    private var home = NSPoint.zero
    private var lastGauge = gaugeSize
    private var updaterBag: AnyCancellable?
    private var windowIsExpanded = false
    private var programmaticMove = false
    private var gen = 0
    private static let homeKey = "TokenTide.home"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar

        host = DragHostingView(rootView: MeterView(store: store))
        host.sizingOptions = []                  // we own the window size, not SwiftUI
        host.onHover = { [weak self] inside in self?.hover(inside) }
        measurer = NSHostingView(rootView: ExpandedPanel(store: store))

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: gaugeSize, height: gaugeSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar                 // above normal floating windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                  // SwiftUI draws the shadow so it animates with the shape
        panel.contentView = host

        home = loadHome()
        setWindow(content: circleRect)
        panel.orderFrontRegardless()

        // queue: nil -> delivered synchronously during setFrame, so programmaticMove is accurate.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowMoved() }
        }

        bag = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change; yield so SwiftUI has applied it.
            Task { @MainActor in
                await Task.yield()
                self?.relayout()
            }
        }
        updaterBag = Updater.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.relayout()
            }
        }
        store.start()
    }

    // MARK: Geometry

    private var visibleFrame: NSRect {
        (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private var circleRect: NSRect {
        NSRect(origin: home, size: NSSize(width: gaugeSize, height: gaugeSize))
    }

    // Corner of the circle that stays put while the panel grows.
    private func pickCorner() -> Corner {
        let c = circleRect, vf = visibleFrame
        switch (c.midY > vf.midY, c.midX > vf.midX) {
        case (true, true):   return .topTrailing
        case (true, false):  return .topLeading
        case (false, true):  return .bottomTrailing
        case (false, false): return .bottomLeading
        }
    }

    private func measuredPanelSize() -> CGSize {
        measurer.layoutSubtreeIfNeeded()
        return measurer.fittingSize
    }

    private func panelRect(_ size: CGSize) -> NSRect {
        let c = circleRect, vf = visibleFrame
        var r = NSRect(origin: .zero, size: size)
        r.origin.x = store.corner.isRight ? c.maxX - size.width : c.minX
        r.origin.y = store.corner.isTop ? c.maxY - size.height : c.minY
        r.origin.x = min(max(r.origin.x, vf.minX), vf.maxX - size.width)
        r.origin.y = min(max(r.origin.y, vf.minY), vf.maxY - size.height)
        return r
    }

    private var contentRect: NSRect {
        panel.frame.insetBy(dx: windowMargin, dy: windowMargin)
    }

    private func setWindow(content r: NSRect) {
        let f = r.insetBy(dx: -windowMargin, dy: -windowMargin)
        guard panel.frame != f else { return }
        programmaticMove = true
        panel.setFrame(f, display: true)
        programmaticMove = false
    }

    private func loadHome() -> NSPoint {
        let vf = visibleFrame
        var p = NSPoint(x: vf.maxX - gaugeSize - 12, y: vf.maxY - gaugeSize - 12)
        if let s = UserDefaults.standard.string(forKey: Self.homeKey) {
            let q = NSPointFromString(s)
            if q != .zero { p = q }
        }
        p.x = min(max(p.x, vf.minX), vf.maxX - gaugeSize)
        p.y = min(max(p.y, vf.minY), vf.maxY - gaugeSize)
        return p
    }

    // Only user drags get here. Re-derive `home` from the anchored corner and persist.
    // Ring size changed: keep the corner nearest the screen corner fixed, so the
    // ring grows toward the middle of the screen, then persist the new origin.
    private func resizeGauge() {
        let old = NSRect(origin: home, size: NSSize(width: lastGauge, height: lastGauge))
        let vf = visibleFrame, new = gaugeSize
        home.x = old.midX > vf.midX ? old.maxX - new : old.minX
        home.y = old.midY > vf.midY ? old.maxY - new : old.minY
        home.x = min(max(home.x, vf.minX), vf.maxX - new)
        home.y = min(max(home.y, vf.minY), vf.maxY - new)
        lastGauge = new
        UserDefaults.standard.set(NSStringFromPoint(home), forKey: Self.homeKey)
        if !windowIsExpanded { setWindow(content: circleRect) }
    }

    private func windowMoved() {
        guard !programmaticMove else { return }
        let r = contentRect
        if windowIsExpanded {
            home.x = store.corner.isRight ? r.maxX - gaugeSize : r.minX
            home.y = store.corner.isTop ? r.maxY - gaugeSize : r.minY
        } else {
            home = r.origin
        }
        UserDefaults.standard.set(NSStringFromPoint(home), forKey: Self.homeKey)
    }

    // MARK: Expand / collapse

    // Expand immediately on hover; collapse after a short grace period so the
    // widget doesn't flicker when the pointer brushes the edge.
    private func hover(_ inside: Bool) {
        collapseTask?.cancel()
        if inside {
            if !store.open { expand() }
        } else {
            collapseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    private func expand() {
        gen += 1
        if !windowIsExpanded {
            store.corner = pickCorner()
            store.panelSize = measuredPanelSize()
            setWindow(content: panelRect(store.panelSize))
            windowIsExpanded = true
        }
        store.scanTokens()        // freshest model mix the moment you look
        store.refreshIfStale()    // and limits, if they're more than a few minutes old
        // Let SwiftUI lay out once at the new window size (circle still pinned in its
        // corner), then morph.
        Task { @MainActor [weak self] in
            await Task.yield()
            withAnimation(morph) { self?.store.open = true }
        }
    }

    private func collapse() {
        guard store.open else { return }
        gen += 1
        let g = gen
        withAnimation(morph) { store.open = false }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)   // let the spring settle
            guard let self, self.gen == g, !self.store.open else { return }
            self.setWindow(content: self.circleRect)
            self.windowIsExpanded = false
        }
    }

    // Keeps the window matched to content changes (e.g. a new limit row appears while
    // open). Skips mid-transition.
    private func relayout() {
        if gaugeSize != lastGauge { resizeGauge() }
        guard store.open == windowIsExpanded else { return }
        if windowIsExpanded {
            let size = measuredPanelSize()
            if size != store.panelSize {
                store.panelSize = size
                setWindow(content: panelRect(size))
            }
        } else {
            setWindow(content: circleRect)
        }
    }
}

let morph = Animation.spring(response: 0.34, dampingFraction: 0.86)

enum Corner {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isRight: Bool { self == .topTrailing || self == .bottomTrailing }

    var alignment: Alignment {
        switch self {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

// MARK: - Model

struct UsageWindow: Identifiable, Codable {
    let id: String          // API key, e.g. "five_hour"
    let pct: Double         // % used, 0–100
    let resetsAt: Date?

    // Per-model weekly limits (7d Fable, 7d Opus, …) are secondary: they only
    // appear in the panel once more than half used, never on the ring, and don't
    // drive the mood. The plan-wide 5h/7d limits are what actually stop you.
    var isScoped: Bool { id != "five_hour" && id != "seven_day" }
    var isVisible: Bool { !isScoped || pct > 50 }

    var label: String {
        switch id {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "seven_day_sonnet": return "7d Son."
        default:
            if id.hasPrefix("seven_day_") { return "7d " + id.dropFirst(10).capitalized }
            return id
        }
    }
}

struct TokenStats: Equatable {
    var total5h = 0
    var totalDay = 0
    var by5h: [String: Int] = [:]
    var byDay: [String: Int] = [:]
    var lastActivity: Date?      // newest Claude Code API call seen in the logs
    // Prompt caching: tokens read from cache vs all input tokens
    // (uncached input + cache writes + cache reads).
    var cacheRead5h = 0, input5h = 0
    var cacheReadDay = 0, inputDay = 0

    // Share of input served from the prompt cache; nil when there's no input yet.
    static func hitRate(_ read: Int, _ input: Int) -> Int? {
        input > 0 ? Int((Double(read) / Double(input) * 100).rounded()) : nil
    }
}

enum Family {
    // Known families keep a fixed position and color. Anything else is named from
    // its model id ("claude-<family>-…"), so a new model appears as its own family
    // instead of disappearing into "Other".
    static let known = ["Opus", "Sonnet", "Fable", "Haiku"]
    static let modelWords: Set<String> = ["opus", "sonnet", "fable", "mythos", "haiku"]

    static func of(_ model: String?) -> String {
        let m = (model ?? "").lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("fable") || m.contains("mythos") { return "Fable" }
        if m.contains("haiku") { return "Haiku" }
        // claude-<family>-5-2, claude-<family>-5-2-20261101, …
        if let r = m.range(of: #"^claude-([a-z]+)-"#, options: .regularExpression) {
            let fam = m[r].dropFirst(7).dropLast()
            if !fam.isEmpty { return fam.capitalized }
        }
        return "Other"
    }

    // Known first, then new families by usage, "Other" last.
    static func ordered(_ fams: [String], weight: (String) -> Int) -> [String] {
        let new = fams.filter { !known.contains($0) && $0 != "Other" }.sorted { weight($0) > weight($1) }
        return known.filter(fams.contains) + new + (fams.contains("Other") ? ["Other"] : [])
    }

    static func color(_ f: String) -> Color {
        switch f {
        // Observable 10 palette (designed to stay distinct on light and dark
        // backgrounds and for color-vision deficiency).
        case "Opus":   return hex(0xA463F2)   // purple
        case "Sonnet": return hex(0x4269D0)   // blue
        case "Fable":  return hex(0xEFB118)   // yellow
        case "Haiku":  return hex(0x6CC5B0)   // teal
        case "Other":  return hex(0x9498A0)   // gray
        default:
            // Unknown family: a stable pick from the rest of the palette.
            let rest: [UInt32] = [0xFF725C, 0x3CA951, 0xFF8AB7, 0x97BBF5, 0x9C6B4E]
            let h = f.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
            return hex(rest[h % rest.count])
        }
    }
}

func hex(_ v: UInt32) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255,
          green: Double((v >> 8) & 0xFF) / 255,
          blue: Double(v & 0xFF) / 255)
}

enum Mood {
    case loading, happy, ok, worried, dead, offline

    var caption: String {
        switch self {
        case .loading: return "Checking…"
        case .happy:   return "All good"
        case .ok:      return "Pace yourself"
        case .worried: return "Running low"
        case .dead:    return "Limit hit"
        case .offline: return "Can't connect"
        }
    }

}

@MainActor
final class Store: ObservableObject {
    @Published var windows: [UsageWindow] = []
    @Published var stats = TokenStats()
    @Published var status: String?
    @Published var updatedAt: Date?
    @Published var plan: String?
    @Published var open = false                       // visual state (drives the morph)
    @Published var corner: Corner = .topTrailing
    @Published var panelSize = CGSize(width: 250, height: 150)

    private var token: String?
    private var profileAt = Date.distantPast           // last /api/oauth/profile check
    private static let planKey = "TokenTide.plan"
    private static let profileAtKey = "TokenTide.profileAt"
    private var timer: Timer?
    private var tokenTimer: Timer?
    private var busy = false
    private var notBefore = Date.distantPast           // backoff after a 429
    private var backoffLevel = 0                       // consecutive 429s
    private var lastAttempt = Date.distantPast
    private var apiWindows: [UsageWindow] = []         // last good API result (has per-model windows)
    private var apiFetchedAt = Date.distantPast
    private var bridgeAt = Date.distantPast            // mtime of the last status-line snapshot used
    @Published var bridgeEnabled = StatusLineBridge.isEnabled
    @Published var size = WidgetSize.current {
        didSet { WidgetSize.current = size }
    }
    private static let cacheKey = "TokenTide.limits"   // minimal: [{id, pct, resetsAt}]
    private static let cacheTimeKey = "TokenTide.limitsAt"
    // Persisted so a relaunch (or rebuild) neither refetches fresh data nor
    // escapes an active backoff.
    private static let apiAtKey = "TokenTide.apiFetchedAt"
    private static let notBeforeKey = "TokenTide.notBefore"
    private static let backoffKey = "TokenTide.backoffLevel"

    // Timing policy. The usage endpoint's throttle is per account, shared with
    // Claude Code's own /usage, and once tripped it tends to stay tripped for a
    // long time, so everything here errs on the side of asking rarely.
    private enum Policy {
        static let pollActive: TimeInterval = 600       // Claude Code used in the last 15 min
        static let pollIdle: TimeInterval = 1800
        static let pollWithBridge: TimeInterval = 3600  // status line already gives live 5h/7d
        static let hoverStale: TimeInterval = 900       // opening the panel refetches only if older
        static let minGap: TimeInterval = 120           // between any two automatic attempts
        static let manualGap: TimeInterval = 60         // between two manual Refreshes
        static let backoffBase: TimeInterval = 600      // 429: 10, 20, 40, then 60 min
        static let backoffMax: TimeInterval = 3600
        static let quietFor: TimeInterval = 3600        // don't complain while data is younger than this
    }
    private var scanning = false
    private let logIndex = LogIndex()

    // Driven by the tightest plan-wide limit (per-model limits don't stop you).
    var mood: Mood {
        let main = windows.filter { !$0.isScoped }
        guard let minLeft = (main.isEmpty ? windows : main).map({ 100 - $0.pct }).min() else {
            return status == nil ? .loading : .offline
        }
        switch minLeft {
        case ..<0.5: return .dead
        case ..<20:  return .worried
        case ..<50:  return .ok
        default:     return .happy
        }
    }

    func start() {
        // Show the last good response immediately (reset times are absolute, so
        // they stay correct); relaunching no longer means a blank widget.
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([UsageWindow].self, from: data) {
            windows = cached
            apiWindows = cached
            updatedAt = UserDefaults.standard.object(forKey: Self.cacheTimeKey) as? Date
        }
        let d = UserDefaults.standard
        plan = d.string(forKey: Self.planKey)
        profileAt = d.object(forKey: Self.profileAtKey) as? Date ?? .distantPast
        apiFetchedAt = d.object(forKey: Self.apiAtKey) as? Date ?? .distantPast
        notBefore = d.object(forKey: Self.notBeforeKey) as? Date ?? .distantPast
        backoffLevel = d.integer(forKey: Self.backoffKey)
        expireWindows()
        readBridge()
        scanTokens()
        tick()
        // One cheap 5s loop: tail the local logs, pick up status-line snapshots, and
        // decide whether a network fetch is due. The network side is rate-limited
        // hard by Anthropic, so it is adaptive (see pollInterval) and backs off.
        tokenTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        Updater.shared.checkIfDue()
        expireWindows()
        readBridge()
        scanTokens()
        if Date().timeIntervalSince(apiFetchedAt) >= pollInterval { refresh() }
    }

    // How long a fetched result is good for.
    //  - Status-line bridge is feeding fresh 5h/7d numbers: the API is only needed for
    //    the plan and per-model weekly windows, so 30 min.
    //  - Claude Code active in the last 15 min: numbers are moving, 5 min.
    //  - Otherwise (idle, or only using claude.ai): 15 min.
    private var pollInterval: TimeInterval {
        let now = Date()
        if now.timeIntervalSince(bridgeAt) < 600 { return Policy.pollWithBridge }
        if let a = stats.lastActivity, now.timeIntervalSince(a) < 900 { return Policy.pollActive }
        return Policy.pollIdle
    }

    // Called when the panel opens: fetch only if what's on screen is getting old.
    func refreshIfStale() {
        if Date().timeIntervalSince(max(apiFetchedAt, bridgeAt)) > Policy.hoverStale { refresh() }
    }

    // MARK: Status-line bridge

    private func readBridge() {
        guard bridgeEnabled, let snap = StatusLineBridge.read(), snap.at > bridgeAt else { return }
        bridgeAt = snap.at
        merge(snap.windows, at: snap.at)
    }

    // Status-line windows (5h/7d, fresher) override the API's; per-model windows
    // only come from the API.
    //
    // Within one window (same reset time) usage only goes up, so never let a lower
    // reading replace a higher one. Two sources lag each other: the status line runs
    // when you send a message (prefill) with the rate_limits from that session's
    // *previous* response, other Claude Code sessions carry older numbers too, and
    // the usage endpoint trails the response headers. Without this the ring jumped
    // back up during a request and then fell again.
    private func merge(_ fresh: [UsageWindow], at: Date) {
        var byId = Dictionary(uniqueKeysWithValues: apiWindows.map { ($0.id, $0) })
        for w in fresh { byId[w.id] = w }
        for (id, w) in byId {
            if let cur = windows.first(where: { $0.id == id }), Self.sameWindow(cur, w), cur.pct > w.pct {
                byId[id] = cur
            }
        }
        let merged = byId.values.filter { Parser.isShown($0.id) }
            .sorted { (Parser.rank($0.id), $0.id) < (Parser.rank($1.id), $1.id) }
        guard !merged.isEmpty else { return }
        windows = merged
        updatedAt = max(updatedAt ?? .distantPast, at)
        if let enc = try? JSONEncoder().encode(merged) {
            UserDefaults.standard.set(enc, forKey: Self.cacheKey)
            UserDefaults.standard.set(updatedAt, forKey: Self.cacheTimeKey)
        }
        if Date().timeIntervalSince(at) < 600, status?.hasPrefix("Rate limited") == true || status?.hasPrefix("Can't reach") == true { status = nil }
    }

    // Same window = both have a reset time and they agree to within 2 min (the API
    // and the status line round differently). A new reset time means a new window,
    // where a lower number is real.
    private static func sameWindow(_ a: UsageWindow, _ b: UsageWindow) -> Bool {
        guard let ra = a.resetsAt, let rb = b.resetsAt else { return false }
        return abs(ra.timeIntervalSince(rb)) < 120
    }

    func toggleBridge() {
        do {
            if bridgeEnabled { try StatusLineBridge.disable() } else { try StatusLineBridge.enable() }
            bridgeEnabled = StatusLineBridge.isEnabled
            status = bridgeEnabled ? "Connected to Claude Code status line" : nil
            readBridge()
        } catch {
            status = "Couldn't update Claude Code settings: \(error.localizedDescription)"
        }
    }

    // A window whose reset time has passed is, by definition, fresh again. Show it as
    // 0% used instead of the stale pre-reset number, and fetch the new state.
    // Applied to the API copy too: otherwise the next merge() would bring the stale
    // pre-reset value back, re-trigger this, and retry every minute.
    private func expireWindows() {
        let now = Date()
        func expire(_ ws: [UsageWindow]) -> [UsageWindow] {
            ws.map { ($0.resetsAt ?? .distantFuture) <= now ? UsageWindow(id: $0.id, pct: 0, resetsAt: nil) : $0 }
        }
        guard windows.contains(where: { ($0.resetsAt ?? .distantFuture) <= now }) else { return }
        windows = expire(windows)
        apiWindows = expire(apiWindows)
        // One fetch for the new window's reset time, but only if it can't trip the throttle.
        if now >= notBefore && now.timeIntervalSince(lastAttempt) > Policy.hoverStale { refresh() }
    }

    // Throttling is normal and mostly invisible: while the numbers on screen are
    // under an hour old we just keep showing them (the footer says how old). Only
    // a long outage, or a manual Refresh, surfaces it.
    private func rateLimitedStatus(force: Bool = false) -> String? {
        let age = updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard force || age > Policy.quietFor else { return nil }
        let mins = max(1, Int((notBefore.timeIntervalSinceNow / 60).rounded(.up)))
        var s = "Rate limited by Anthropic, next try in \(mins) min"
        if !bridgeEnabled { s += " · Tip: right-click → Use Claude Code Status Line" }
        return s
    }

    // The plan in Claude Code's stored credentials is written at login and goes
    // stale after an upgrade, so the profile endpoint is the source of truth.
    // It changes rarely: check every 6 h, and on a manual Refresh after 10 min.
    private var forcePlanCheck = false
    private func refreshPlanIfDue(token: String) async {
        let age = Date().timeIntervalSince(profileAt)
        guard plan == nil || age > 6 * 3600 || (forcePlanCheck && age > 600) else { return }
        forcePlanCheck = false
        profileAt = Date()
        UserDefaults.standard.set(profileAt, forKey: Self.profileAtKey)
        if let p = await Profile.plan(token: token) {
            plan = p
            UserDefaults.standard.set(p, forKey: Self.planKey)
        }
    }

    private func persistTiming() {
        let d = UserDefaults.standard
        d.set(apiFetchedAt, forKey: Self.apiAtKey)
        d.set(notBefore, forKey: Self.notBeforeKey)
        d.set(backoffLevel, forKey: Self.backoffKey)
    }

    private func staleSuffix() -> String {
        guard let u = updatedAt else { return "" }
        return " · data from \(u.formatted(date: .omitted, time: .shortened))"
    }

    // manual = the user chose Refresh. It never skips a 429 backoff (retrying early
    // only extends the throttle), but it does skip the normal poll interval.
    func refresh(manual: Bool = false) {
        let now = Date()
        if manual { readBridge(); scanTokens(); forcePlanCheck = true }
        guard !busy else { return }
        guard now >= notBefore else {
            if manual { status = rateLimitedStatus(force: true) }
            return
        }
        guard now.timeIntervalSince(lastAttempt) >= (manual ? Policy.manualGap : Policy.minGap) else { return }
        lastAttempt = now
        busy = true
        Task {
            await fetchLimits()
            busy = false
            scanTokens()   // the 5h window start may have moved
        }
    }

    private func fetchLimits() async {
        if token == nil {
            // Read once and keep it in memory; re-read only after a 401.
            let c = await Task.detached(priority: .utility) { Credentials.read() }.value
            token = c?.token
            if plan == nil, let p = c?.plan { plan = p }   // fallback only; profile is authoritative
            if token == nil {
                status = "No Claude Code login — run `claude` once"
                return
            }
        }
        guard let t = token else { return }
        do {
            let (data, resp) = try await Net.get("/api/oauth/usage", token: t)
            let code = resp.statusCode
            switch code {
            case 200:
                let w = Parser.windows(from: try JSONSerialization.jsonObject(with: data))
                backoffLevel = 0
                notBefore = .distantPast
                apiFetchedAt = Date()
                apiWindows = w
                persistTiming()
                // A fresher status-line snapshot keeps priority for 5h/7d.
                if bridgeEnabled, let snap = StatusLineBridge.read(), snap.at > apiFetchedAt.addingTimeInterval(-60) {
                    merge(snap.windows, at: snap.at)
                } else {
                    merge([], at: apiFetchedAt)   // caches only what's displayed, never the raw response
                }
                await refreshPlanIfDue(token: t)
                status = w.isEmpty ? "No limit fields in response (API changed?)" : nil
            case 401, 403:
                token = nil   // re-read Keychain next round; Claude Code refreshes it when used
                status = "Token expired — open Claude Code to refresh" + staleSuffix()
            case 429:
                // The endpoint usually answers Retry-After: 0, which does NOT mean "retry
                // now": retrying early keeps the throttle tripped. Back off exponentially
                // (10, 20, 40, then 60 min), honoring a larger Retry-After if given.
                let ra = resp.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                let wait = max(ra, min(Policy.backoffBase * pow(2, Double(backoffLevel)), Policy.backoffMax))
                backoffLevel = min(backoffLevel + 1, 6)
                notBefore = Date().addingTimeInterval(wait)
                apiFetchedAt = Date()   // don't let the poll timer re-fire before notBefore
                persistTiming()
                status = rateLimitedStatus()
            default:
                apiFetchedAt = Date()
                persistTiming()
                if (updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity) > Policy.quietFor {
                    status = "Can't reach Anthropic (HTTP \(code))"
                }
            }
        } catch {
            if (updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity) > Policy.quietFor {
                status = "Can't reach Anthropic (offline?)"
            }
        }
    }

    // Independent of the network fetch. Reads only bytes appended to the logs since
    // the last scan, so a pass is milliseconds even with hundreds of MB of history.
    func scanTokens() {
        guard !scanning else { return }
        scanning = true
        let now = Date()
        var start5h = now.addingTimeInterval(-5 * 3600)
        if let r = windows.first(where: { $0.id == "five_hour" })?.resetsAt, r > now {
            start5h = r.addingTimeInterval(-5 * 3600)
        }
        let startDay = Calendar.current.startOfDay(for: now)
        let s5 = start5h
        let idx = logIndex
        Task {
            let s = await Task.detached(priority: .utility) { () -> TokenStats in
                idx.update(cutoff: min(s5, startDay))
                return idx.sum(since5h: s5, sinceDay: startDay)
            }.value
            if s != stats { stats = s }
            scanning = false
        }
    }
}

// MARK: - Updates

// Self-updater for release builds. Every 6 h it asks GitHub for the latest release
// of this repo; if it's newer, it downloads TokenTide-vX.Y.Z.zip, and installs it
// only if the new app passes `codesign --verify --deep --strict`, is signed by the
// same Developer ID team as the running app, and passes Gatekeeper (notarized).
// It then swaps the bundle in place and relaunches. Hosts: api.github.com,
// github.com, *.githubusercontent.com. Local builds (version 0.0.0-dev) never update.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "ychu824/TokenTide"

    @Published var available: String?      // newer version found, e.g. "0.1.4"
    @Published var message: String?        // shown in the panel
    @Published var busy = false
    @Published var autoInstall = UserDefaults.standard.object(forKey: "TokenTide.autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "TokenTide.autoUpdate") }
    }
    private var asset: URL?
    private var lastCheck = UserDefaults.standard.object(forKey: "TokenTide.updateCheckedAt") as? Date ?? .distantPast

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    static var isDevBuild: Bool { current.hasPrefix("0.0.0") }

    func checkIfDue() {
        guard !busy, !Self.isDevBuild, Date().timeIntervalSince(lastCheck) > 6 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !busy else { return }
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: "TokenTide.updateCheckedAt")
        if Self.isDevBuild {
            if manual { message = "Local build (\(Self.current)) — updates are off" }
            return
        }
        guard let rel = await UpdateNet.latestRelease(repo: Self.repo) else {
            if manual { message = "Couldn't check for updates" }
            return
        }
        let (tag, url) = rel
        let v = String(tag.drop { $0 == "v" })
        guard Self.isNewer(v, than: Self.current) else {
            available = nil
            if manual { message = "TokenTide \(Self.current) is up to date" }
            return
        }
        available = v
        asset = url
        message = nil
        if autoInstall || manual { await install() }
    }

    func install() async {
        guard let asset, let v = available, !busy else { return }
        let dest = Bundle.main.bundleURL
        if dest.path.contains("/AppTranslocation/") {
            message = "Move TokenTide to Applications to enable updates"
            return
        }
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            message = "Update \(v) available — no permission to replace \(dest.path)"
            return
        }
        busy = true
        message = "Installing \(v)…"
        let result = await Task.detached(priority: .utility) { () -> Result<URL, UpdateError> in
            Self.prepare(asset: asset, version: v, replacing: dest)
        }.value
        busy = false
        switch result {
        case .failure(let e):
            message = "Update \(v) failed: \(e.text)"
        case .success(let newApp):
            Self.swapAndRelaunch(newApp: newApp, dest: dest)
        }
    }

    struct UpdateError: Error { let text: String }

    // Download, unzip and verify. Runs off the main thread.
    nonisolated private static func prepare(asset: URL, version: String, replacing dest: URL) -> Result<URL, UpdateError> {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("TokenTide-update-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return .failure(UpdateError(text: "temp dir"))
        }
        let zip = dir.appendingPathComponent("u.zip")
        guard UpdateNet.download(asset, to: zip) else { return .failure(UpdateError(text: "download")) }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).0 == 0 else {
            return .failure(UpdateError(text: "unzip"))
        }
        let app = dir.appendingPathComponent("TokenTide.app")
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).0 == 0 else {
            return .failure(UpdateError(text: "signature invalid"))
        }
        guard let mine = teamID(dest), let theirs = teamID(app), mine == theirs else {
            return .failure(UpdateError(text: "not signed by the same developer"))
        }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).0 == 0 else {
            return .failure(UpdateError(text: "not notarized"))
        }
        let got = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? ""
        guard got == version else { return .failure(UpdateError(text: "version mismatch")) }
        return .success(app)
    }

    // Wait for this process to exit, swap the bundle (restoring the old one if the
    // move fails), relaunch.
    private static func swapAndRelaunch(newApp: URL, dest: URL) {
        let script = """
        i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
        old="$3.tokentide-old"; rm -rf "$old"
        if mv "$3" "$old"; then
          if mv "$2" "$3"; then rm -rf "$old"; else mv "$old" "$3"; fi
        fi
        open "$3"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "tokentide-update", String(ProcessInfo.processInfo.processIdentifier), newApp.path, dest.path]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }

    nonisolated private static func teamID(_ app: URL) -> String? {
        let (code, out) = run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        guard code == 0 else { return nil }
        for line in out.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let t = String(line.dropFirst("TeamIdentifier=".count))
            return t == "not set" ? nil : t
        }
        return nil
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// GitHub networking for the updater only. HTTPS to api.github.com / github.com /
// *.githubusercontent.com (release downloads redirect there); other redirects are refused.
enum UpdateNet {
    static func allowed(_ u: URL?) -> Bool {
        guard let u, u.scheme == "https", let h = u.host else { return false }
        return h == "api.github.com" || h == "github.com" || h.hasSuffix(".githubusercontent.com")
    }

    private final class Guard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(UpdateNet.allowed(request.url) ? request : nil)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["User-Agent": "TokenTide-Updater"]
        return URLSession(configuration: c, delegate: Guard(), delegateQueue: nil)
    }()

    static func latestRelease(repo: String) async -> (String, URL)? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let r = try? await session.data(for: req),
              (r.1 as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: r.0)) as? [String: Any],
              let tag = o["tag_name"] as? String,
              let assets = o["assets"] as? [[String: Any]],
              let a = assets.first(where: { ($0["name"] as? String) == "TokenTide-\(tag).zip" }),
              let s = a["browser_download_url"] as? String, let dl = URL(string: s), allowed(dl) else { return nil }
        return (tag, dl)
    }

    // Blocking download for use off the main thread.
    static func download(_ url: URL, to dest: URL) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = session.downloadTask(with: url) { tmp, resp, _ in
            defer { sem.signal() }
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200, allowed(resp?.url) else { return }
            ok = (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil
        }
        task.resume()
        sem.wait()
        return ok
    }
}

// Panel line: shown only while an update is pending, installing, or just checked.
struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let m = updater.message {
            Text(verbatim: m)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let v = updater.available, !updater.busy {
            HStack(spacing: 6) {
                Text(verbatim: "Update \(v) available")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Install") { Task { await updater.install() } }
                    .buttonStyle(.link)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
    }
}

// MARK: - Claude Code status-line bridge

// Claude Code passes `rate_limits` (5h/7d used % and reset time, taken from the
// headers of its own API responses) to the status-line command on stdin, on every
// update. With the bridge enabled, TokenTide's status-line script saves just that
// object to a file and then runs your original status-line command unchanged, so
// TokenTide gets live numbers without polling the rate-limited usage endpoint.
// Enabling edits `statusLine` in ~/.claude/settings.json (a backup is kept);
// disabling restores the original setting exactly.
enum StatusLineBridge {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dir = home.appendingPathComponent(".claude/tokentide")
    static let script = dir.appendingPathComponent("statusline.sh")
    static let snapshot = dir.appendingPathComponent("rate_limits.json")
    static let original = dir.appendingPathComponent("original-statusline.json")
    static let settings = home.appendingPathComponent(".claude/settings.json")

    struct Snapshot { let windows: [UsageWindow]; let at: Date }

    static var isEnabled: Bool {
        guard let cmd = (readSettings()?["statusLine"] as? [String: Any])?["command"] as? String else { return false }
        return cmd.contains(script.path)
    }

    static func read() -> Snapshot? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: snapshot.path),
              let at = attrs[.modificationDate] as? Date,
              let data = try? Data(contentsOf: snapshot),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [UsageWindow] = []
        for id in ["five_hour", "seven_day"] {
            guard let w = obj[id] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            out.append(UsageWindow(id: id, pct: pct, resetsAt: reset))
        }
        return out.isEmpty ? nil : Snapshot(windows: out, at: at)
    }

    static func enable() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = readSettings() ?? [:]
        let current = s["statusLine"] as? [String: Any]
        let currentCmd = current?["command"] as? String ?? ""
        if !currentCmd.contains(script.path) {
            // Remember whatever was there (possibly nothing) so disable() can restore it.
            let saved: Any = current ?? NSNull()
            try JSONSerialization.data(withJSONObject: ["statusLine": saved], options: [.prettyPrinted])
                .write(to: original, options: .atomic)
        }
        try scriptBody(originalCommand: currentCmd.contains(script.path) ? savedCommand() : currentCmd)
            .write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var line = current ?? [:]                      // keep padding / refreshInterval etc.
        line["type"] = "command"
        line["command"] = script.path
        s["statusLine"] = line
        try writeSettings(s)
    }

    static func disable() throws {
        var s = readSettings() ?? [:]
        let saved = (try? Data(contentsOf: original))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["statusLine"]
        if let line = saved as? [String: Any] { s["statusLine"] = line } else { s.removeValue(forKey: "statusLine") }
        try writeSettings(s)
        try? FileManager.default.removeItem(at: snapshot)
    }

    private static func savedCommand() -> String {
        let saved = (try? Data(contentsOf: original))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["statusLine"]
        return (saved as? [String: Any])?["command"] as? String ?? ""
    }

    private static func readSettings() -> [String: Any]? {
        guard let d = try? Data(contentsOf: settings) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func writeSettings(_ s: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settings.path) {
            let backup = settings.appendingPathExtension("tokentide-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settings, to: backup)
        }
        try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: settings, options: .atomic)
    }

    // POSIX sh + plutil only (both ship with macOS). Stores nothing but rate_limits.
    private static func scriptBody(originalCommand: String) -> String {
        let quoted = "'" + originalCommand.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Written by TokenTide. Saves Claude Code's rate_limits for TokenTide, then runs
        # your original status line. Disable from TokenTide's right-click menu.
        input=$(cat)
        dir="$HOME/.claude/tokentide"
        if printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o "$dir/.rl.tmp" - 2>/dev/null; then
          mv -f "$dir/.rl.tmp" "$dir/rate_limits.json"
        fi
        orig=\(quoted)
        if [ -n "$orig" ]; then
          printf '%s' "$input" | /bin/sh -c "$orig"
        else
          f=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits.five_hour.used_percentage raw -o - - 2>/dev/null)
          w=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits.seven_day.used_percentage raw -o - - 2>/dev/null)
          [ -n "$f$w" ] && printf '5h %s%% · 7d %s%% used\\n' "${f%%.*}" "${w%%.*}"
        fi
        exit 0
        """
    }
}

// MARK: - Credentials

struct Creds {
    let token: String
    let plan: String?
}

enum Credentials {
    static func read() -> Creds? {
        if let s = keychain(), let c = parse(s) { return c }
        // Linux-style fallback some setups use.
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let s = try? String(contentsOf: f, encoding: .utf8), let c = parse(s) { return c }
        return nil
    }

    // "max" + "default_claude_max_20x" -> "Max 20x"; "pro" -> "Pro"; etc.
    // Plan family from either field, plus a usage multiplier if the tier carries one:
    // ("max", "default_claude_max_20x") -> "Max 20x"; ("ultra", …) -> "Ultra".
    // The family is never inferred from the multiplier alone, so a new tier
    // (e.g. Ultra) isn't mislabeled as Max.
    static func planName(sub: String?, tier: String?) -> String? {
        let t = (tier ?? "").lowercased()
        let s = (sub ?? "").lowercased()
        let both = s + " " + t
        let families = ["enterprise", "team", "ultra", "max", "pro", "free"]
        let family = families.first { both.contains($0) }?.capitalized
            ?? (s.isEmpty ? nil : s.replacingOccurrences(of: "_", with: " ").capitalized)
        guard let family else { return nil }
        let mult = t.range(of: #"\d+x"#, options: .regularExpression).map { " " + t[$0] } ?? ""
        return family + mult
    }

    // Same mechanism Claude Code itself uses, so the item's ACL already trusts it
    // and there's no permission prompt. The token is passed over a pipe (never
    // argv/env) and kept only in memory.
    private static func keychain() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // read before wait: no pipe deadlock
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ s: String) -> Creds? {
        guard let d = s.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let plan = planName(sub: oauth["subscriptionType"] as? String,
                            tier: oauth["rateLimitTier"] as? String)
        return Creds(token: token, plan: plan)
    }
}

// MARK: - Network

// The only code that talks to the network. One host, HTTPS only, ephemeral session
// (no disk cache, cookies or credential storage), redirects refused.
enum Net {
    static let host = "api.anthropic.com"

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        guard let url = comps.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.url?.host == host else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// Fallback when the stored credentials carry no plan fields.
enum Profile {
    static func plan(token: String) async -> String? {
        guard let r = try? await Net.get("/api/oauth/profile", token: token),
              r.1.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: r.0) else { return nil }
        var found: [String: String] = [:]
        collect(obj, &found)
        let sub = found["subscription_type"] ?? found["subscriptionType"]
            ?? found["organization_type"] ?? found["plan"]
        let tier = found["rate_limit_tier"] ?? found["rateLimitTier"]
        return Credentials.planName(sub: sub, tier: tier)
    }

    private static let keys: Set<String> = ["subscription_type", "subscriptionType", "organization_type",
                                            "plan", "rate_limit_tier", "rateLimitTier"]

    private static func collect(_ obj: Any, _ out: inout [String: String]) {
        if let d = obj as? [String: Any] {
            for (k, v) in d {
                if keys.contains(k), let s = v as? String, out[k] == nil { out[k] = s }
                collect(v, &out)
            }
        } else if let a = obj as? [Any] {
            for v in a { collect(v, &out) }
        }
    }
}

// MARK: - Parsing

enum Parser {
    // Only these keys are shown, in this order. Anything else in the response
    // (internal codenames like "iguana_necktie", extra_usage, ...) is ignored.
    // Plus seven_day_<model family> (opus, sonnet, fable, …). Other seven_day_*
    // keys are product codenames (omelette, cowork, oauth_apps) and stay hidden.
    static func isShown(_ id: String) -> Bool {
        if id == "five_hour" || id == "seven_day" { return true }
        guard id.hasPrefix("seven_day_") else { return false }
        return Family.modelWords.contains(String(id.dropFirst(10)))
    }

    static func rank(_ id: String) -> Int {
        switch id {
        case "five_hour": return 0
        case "seven_day": return 1
        case "seven_day_opus": return 2
        case "seven_day_sonnet": return 3
        default: return 4
        }
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    // Walks the whole response and treats any object carrying a numeric "utilization"
    // as a limit window (handles both the flat {five_hour:{...}} shape and an
    // array-of-limits shape), then keeps only known keys.
    static func windows(from obj: Any) -> [UsageWindow] {
        var out: [String: UsageWindow] = [:]
        walk(obj, key: nil, &out)
        scoped(obj, &out)
        return out.values.filter { isShown($0.id) }
            .sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
    }

    private static func walk(_ obj: Any, key: String?, _ out: inout [String: UsageWindow]) {
        if let d = obj as? [String: Any] {
            if let u = (d["utilization"] as? NSNumber)?.doubleValue {
                let name = (d["name"] as? String) ?? (d["type"] as? String) ?? (d["claim"] as? String)
                    ?? (d["id"] as? String) ?? key ?? "limit"
                if out[name] == nil {
                    out[name] = UsageWindow(id: name, pct: u, resetsAt: date(d["resets_at"] ?? d["reset_at"]))
                }
                return
            }
            for (k, v) in d { walk(v, key: k, &out) }
        } else if let a = obj as? [Any] {
            for v in a { walk(v, key: key, &out) }
        }
    }

    // Per-model weekly limits arrive as
    //   limits: [{ kind: "weekly_scoped", percent: 64, resets_at: "…",
    //              scope: { model: { display_name: "Fable" } } }, …]
    // (Max and Ultra: Fable may use up to half the weekly limit). Entries with a
    // null scope duplicate seven_day and are skipped.
    private static func scoped(_ obj: Any, _ out: inout [String: UsageWindow]) {
        guard let d = obj as? [String: Any], let limits = d["limits"] as? [[String: Any]] else { return }
        for l in limits where (l["kind"] as? String) == "weekly_scoped" {
            guard let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  let pct = ((l["percent"] ?? l["utilization"]) as? NSNumber)?.doubleValue else { continue }
            let id = "seven_day_" + model.lowercased().replacingOccurrences(of: " ", with: "_")
            out[id] = UsageWindow(id: id, pct: pct, resetsAt: date(l["resets_at"]))
        }
    }

    private static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let x = n.doubleValue
            return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
        }
        guard let s = v as? String else { return nil }
        return iso(s)
    }
}

// MARK: - Local Claude Code logs

// Incremental index over Claude Code's session logs (~/.claude/projects/**/*.jsonl).
// Remembers a byte offset per file and parses only newly appended complete lines.
// Not thread-safe: Store calls it from one detached task at a time (`scanning` guard).
final class LogIndex: @unchecked Sendable {
    private struct Entry {
        let t: Date
        let fam: String
        let n: Int           // input + output + cache writes (what "tok" shows)
        let cacheRead: Int
        let input: Int       // input + cache writes + cache reads
        let key: String
    }

    private var offsets: [String: UInt64] = [:]
    private var entries: [String: Entry] = [:]     // one per API response (message id)
    private var lastCutoff = Date.distantPast
    private static let usageMarker = Data("\"usage\"".utf8)

    private static func roots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var r = [home.appendingPathComponent(".claude/projects"),
                 home.appendingPathComponent(".config/claude/projects")]
        if let c = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            r.insert(URL(fileURLWithPath: c).appendingPathComponent("projects"), at: 0)
        }
        return r
    }

    func update(cutoff: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for root in Self.roots() {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let rv = try? url.resourceValues(forKeys: Set(keys))
                let mod = rv?.contentModificationDate ?? .distantPast
                let size = UInt64(rv?.fileSize ?? 0)
                let path = url.path
                // Never-read files untouched since the cutoff hold nothing we need.
                if offsets[path] == nil && mod < cutoff { continue }
                var off = offsets[path] ?? 0
                if size < off { off = 0 }                  // truncated or rewritten
                guard size > off, let fh = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? fh.close() }
                guard (try? fh.seek(toOffset: off)) != nil,
                      let data = try? fh.readToEnd(),
                      let lastNL = data.lastIndex(of: 0x0A) else { continue }
                // Only consume complete lines; a half-written last line is read next time.
                let complete = data[data.startIndex...lastNL]
                for line in complete.split(separator: 0x0A) {
                    ingest(Data(line), cutoff: cutoff)
                }
                offsets[path] = off + UInt64(complete.count)
            }
        }
        if cutoff > lastCutoff {
            entries = entries.filter { $0.value.t >= cutoff }
            lastCutoff = cutoff
        }
    }

    // Counts input + output + cache-write tokens. Cache reads are excluded:
    // they dwarf everything else and don't reflect real work.
    private func ingest(_ d: Data, cutoff: Date) {
        guard d.range(of: Self.usageMarker) != nil,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let msg = o["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let ts = o["timestamp"] as? String,
              let t = Parser.iso(ts), t >= cutoff else { return }
        // One API response is written as several lines (one per content block), and
        // resumed/forked sessions copy earlier messages into new files. The message id
        // identifies the response everywhere, so count it once. Earlier lines can carry
        // a partial output_tokens, so keep the largest reading. Lines with no id can't
        // be deduplicated safely and are skipped rather than double-counted.
        guard let key = (msg["id"] as? String) ?? (o["requestId"] as? String), !key.isEmpty else { return }
        func int(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let n = int("input_tokens") + int("output_tokens") + int("cache_creation_input_tokens")
        let read = int("cache_read_input_tokens")
        guard n > 0 || read > 0 else { return }
        if let e = entries[key], e.n >= n { return }
        entries[key] = Entry(t: entries[key]?.t ?? t, fam: Family.of(msg["model"] as? String), n: n,
                             cacheRead: read,
                             input: int("input_tokens") + int("cache_creation_input_tokens") + read,
                             key: key)
    }

    func sum(since5h: Date, sinceDay: Date) -> TokenStats {
        var s = TokenStats()
        for e in entries.values {
            if s.lastActivity.map({ e.t > $0 }) ?? true { s.lastActivity = e.t }
            if e.t >= since5h {
                s.total5h += e.n
                s.by5h[e.fam, default: 0] += e.n
                s.cacheRead5h += e.cacheRead
                s.input5h += e.input
            }
            if e.t >= sinceDay {
                s.totalDay += e.n
                s.byDay[e.fam, default: 0] += e.n
                s.cacheReadDay += e.cacheRead
                s.inputDay += e.input
            }
        }
        return s
    }
}

// MARK: - UI

private let contentWidth: CGFloat = 230

// Collapsed ring size, from the right-click menu. Large/Extra Large are for big or
// far-away displays; the expanded panel stays the same size.
enum WidgetSize: String, CaseIterable, Identifiable {
    case small, medium, large, xlarge
    var id: String { rawValue }
    var points: CGFloat { [44, 58, 76, 100][Self.allCases.firstIndex(of: self)!] }
    var title: String { ["Small", "Medium", "Large", "Extra Large"][Self.allCases.firstIndex(of: self)!] }

    static let key = "TokenTide.size"
    static var current: WidgetSize {
        get { UserDefaults.standard.string(forKey: key).flatMap(WidgetSize.init) ?? .small }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

var gaugeSize: CGFloat { WidgetSize.current.points }

// Claude brand clay. Used for every healthy bar/ring; only a nearly-exhausted
// limit (<= 20% left) switches to red so the warning still reads at a glance.
let claudeAccent = hex(0xD97757)
let warnRed = hex(0xE5484D)

func leftColor(_ left: Double) -> Color {
    left > 20 ? claudeAccent : warnRed
}

// Root view. The window is resized once per transition; this view morphs a single
// shape between the 44pt circle and the panel size, pinned to the anchored corner,
// while the gauge and panel cross-fade. Shadow is drawn here so it tracks the shape.
struct MeterView: View {
    @ObservedObject var store: Store
    @ObservedObject var updater = Updater.shared   // so the menu's update toggle stays current

    var body: some View {
        let w = store.open ? store.panelSize.width : gaugeSize
        let h = store.open ? store.panelSize.height : gaugeSize
        let shape = RoundedRectangle(cornerRadius: store.open ? 10 : gaugeSize / 2, style: .continuous)

        ZStack(alignment: store.corner.alignment) {
            if store.open {
                ExpandedPanel(store: store)
                    .transition(.opacity)
            } else {
                Gauge(windows: store.windows.filter { !$0.isScoped }.isEmpty
                        ? store.windows : store.windows.filter { !$0.isScoped },
                      failed: store.windows.isEmpty && store.status != nil)
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: h, alignment: store.corner.alignment)
        .clipShape(shape)
        .background(
            // Shadow on the backing shape only, so text and rings don't get their own.
            // Claude-clay tinted glass: material for the blur, a clay wash on top.
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(claudeAccent.opacity(0.18))
            }
            .shadow(color: claudeAccent.opacity(0.25), radius: 6, y: 2)
        )
        .overlay(shape.strokeBorder(claudeAccent.opacity(0.6), lineWidth: 1))
        .contentShape(shape)
        .help(store.updatedAt.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "")
        .contextMenu {
            Button("Refresh") { store.refresh(manual: true) }
            Button(store.bridgeEnabled ? "✓ Use Claude Code Status Line" : "Use Claude Code Status Line") {
                store.toggleBridge()
            }
            Menu("Size") {
                ForEach(WidgetSize.allCases) { sz in
                    Button((store.size == sz ? "✓ " : "") + sz.title) { store.size = sz }
                }
            }
            Button(SMAppService.mainApp.status == .enabled ? "✓ Launch at Login" : "Launch at Login") { toggleLogin() }
            Divider()
            Text(verbatim: "TokenTide \(Updater.current)")     // disabled label: current version
            Button("Check for Updates…") { Task { await Updater.shared.check(manual: true) } }
            Button(updater.autoInstall ? "✓ Install Updates Automatically" : "Install Updates Automatically") {
                updater.autoInstall.toggle()
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.corner.alignment)
        .padding(windowMargin)
    }

    private func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            NSSound.beep()
        }
    }
}

// Expanded content at its natural size (no background). Also used off-screen to
// measure the expanded window size.
struct ExpandedPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var updater = Updater.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: store.plan ?? "Claude")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(claudeAccent)
                    Spacer(minLength: 0)
                    Text(verbatim: store.mood.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.windows.filter(\.isVisible)) { WindowRow(w: $0, now: ctx.date) }
                UpdateRow(updater: updater)
                if store.stats.totalDay > 0 {
                    Divider().opacity(0.4)
                    ModelShare(s: store.stats)
                }
                if let s = store.status {
                    Text(verbatim: s)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = cacheLine(store.stats) {
                    Text(verbatim: line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .help("Prompt cache hit rate = cache reads ÷ all input tokens (uncached + cache writes + cache reads), from Claude Code's logs. Cache reads are cheap and aren't included in \"tok\".")
                }
                Text(verbatim: "tok  5h \(fmt(store.stats.total5h)) · today \(fmt(store.stats.totalDay))" + ageText(store.updatedAt, now: ctx.date))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: contentWidth + 20, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// Collapsed state: up to two concentric rings, filled clockwise by % left, for
// the first two limits the account actually has (in order: 5h, 7d, 7d Opus,
// 7d Sonnet). Plans without a 5-hour limit (e.g. Ultra) get 7d on the outer ring.
// Center = % left of the outer ring.
struct Gauge: View {
    let windows: [UsageWindow]
    let failed: Bool

    private var outer: UsageWindow? { windows.first }
    private var inner: UsageWindow? { windows.dropFirst().first }

    // Everything is drawn at the chosen size (not scaled as a bitmap), so text and
    // rings stay crisp at Large / Extra Large.
    private var k: CGFloat { gaugeSize / 44 }

    var body: some View {
        ZStack {
            if inner == nil {
                ring(outer, diameter: 34 * k, width: 6 * k)   // single limit: one bolder ring
            } else {
                ring(outer, diameter: 36 * k, width: 4 * k)
                ring(inner, diameter: 24 * k, width: 4 * k)
            }
            Text(verbatim: center)
                .font(.system(size: 9 * k, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(failed ? Color.secondary : Color.primary)
        }
        .frame(width: gaugeSize, height: gaugeSize)
        .help(windows.prefix(2).map { "\($0.label): \(Int(left($0).rounded()))% left" }.joined(separator: " · "))
    }

    private var center: String {
        if failed { return "!" }
        guard let w = outer else { return "–" }
        return "\(Int(left(w).rounded()))"
    }

    private func left(_ w: UsageWindow) -> Double { min(100, max(0, 100 - w.pct)) }

    private func ring(_ w: UsageWindow?, diameter: CGFloat, width: CGFloat) -> some View {
        let l = w.map(left) ?? 0
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: width)
            Circle()
                .trim(from: 0, to: l / 100)
                .stroke(leftColor(l), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

// "cache 5h 94% · today 92% · read 20M"; nil before any Claude Code input today.
func cacheLine(_ s: TokenStats) -> String? {
    guard let day = TokenStats.hitRate(s.cacheReadDay, s.inputDay) else { return nil }
    let h5 = TokenStats.hitRate(s.cacheRead5h, s.input5h).map { "\($0)%" } ?? "–"
    return "cache 5h \(h5) · today \(day)% · read \(fmt(s.cacheReadDay))"
}

// " · 12m ago" for the panel footer; nothing when the data is fresh.
func ageText(_ d: Date?, now: Date) -> String {
    guard let d else { return "" }
    let m = Int(now.timeIntervalSince(d) / 60)
    switch m {
    case ..<2:   return ""
    case ..<60:  return " · \(m)m ago"
    default:     return " · \(m / 60)h ago"
    }
}

func fmt(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
    case 1_000...:     return String(format: "%.0fk", Double(n) / 1e3)
    default:           return "\(n)"
    }
}

struct WindowRow: View {
    let w: UsageWindow
    let now: Date

    var body: some View {
        let left = min(100, max(0, 100 - w.pct))
        // Per-model limits render quieter: smaller, secondary text, thinner bar.
        let sub = w.isScoped
        HStack(spacing: 6) {
            Text(verbatim: w.label)
                .frame(width: 60, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(sub ? 0.1 : 0.15))
                Capsule().fill(leftColor(left).opacity(sub ? 0.7 : 1)).frame(width: 48 * left / 100)
            }
            .frame(width: 48, height: sub ? 4 : 6)
            Text(verbatim: "\(Int(left.rounded()))% left")
                .frame(width: 60, alignment: .trailing)
            Text(verbatim: countdown())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: sub ? 10 : 11, weight: sub ? .regular : .medium, design: .monospaced))
        .foregroundStyle(sub ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
        .lineLimit(1)
    }

    private func countdown() -> String {
        guard let r = w.resetsAt else { return "" }
        let s = Int(r.timeIntervalSince(now))
        if s <= 0 { return "↻now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "↻\(d)d\(h)h" }
        if h > 0 { return "↻\(h)h\(m)m" }
        return "↻\(m)m"
    }
}

// Compact model mix: two thin stacked bars (5h, today) and a one-line legend
// with "5h% / today%" per model family.
struct ModelShare: View {
    let s: TokenStats
    private let barWidth: CGFloat = contentWidth - 40

    private var present: [String] {
        let fams = Set(s.byDay.keys).union(s.by5h.keys).filter { (s.byDay[$0] ?? 0) > 0 || (s.by5h[$0] ?? 0) > 0 }
        return Family.ordered(Array(fams)) { s.byDay[$0] ?? 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "Model mix · Claude Code only")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            bar("5h", s.by5h, s.total5h)
            bar("day", s.byDay, s.totalDay)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 1) {
                ForEach(present, id: \.self) { f in
                    HStack(spacing: 3) {
                        Circle().fill(Family.color(f)).frame(width: 5, height: 5)
                        Text(verbatim: "\(f) \(pct(s.by5h[f], s.total5h))/\(pct(s.byDay[f], s.totalDay))%")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .help("Share of Claude Code tokens by model (5h / today). Token share ≠ limit share: Opus and Fable tokens count more against limits. claude.ai chats aren't included.")
    }

    private func bar(_ label: String, _ by: [String: Int], _ total: Int) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .frame(width: 34, alignment: .leading)
            HStack(spacing: 0) {
                if total > 0 {
                    ForEach(present, id: \.self) { f in
                        Rectangle()
                            .fill(Family.color(f))
                            .frame(width: barWidth * CGFloat(by[f] ?? 0) / CGFloat(total))
                    }
                }
            }
            .frame(width: barWidth, height: 4, alignment: .leading)
            .background(Color.primary.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    private func pct(_ v: Int?, _ total: Int) -> String {
        guard total > 0 else { return "–" }
        return "\(Int((Double(v ?? 0) / Double(total) * 100).rounded()))"
    }
}
