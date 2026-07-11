import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - Config
let apiBase = "http://127.0.0.1:8099"
let notifiableEvents: Set<String> = [
    "battery.full", "battery.low", "battery.charging_started",
    "battery.charging_stopped", "charger.connected", "charger.disconnected",
    "ride.completed", "firmware.changed",
]

// MARK: - Models
struct Bike: Decodable { let id: String; let brand: String?; let drive_unit: String? }
struct RangeMode: Decodable { let mode: String?; let range_km: Double? }
struct Battery: Decodable {
    let level_percent: Int?
    let is_charging: Bool?
    let charger_connected: Bool?
    let total_capacity_wh: Double?
    let charge_cycles: Double?
    let odometer_km: Double?
    let range_per_mode: [RangeMode]?
    let last_update: String?
    let live: Bool?
    let remaining_charging_time: Double?   // minutes to full (while charging)
}
struct Ride: Decodable {
    let id: String; let start: String?; let distance_km: Double?
    let avg_speed_kmh: Double?; let has_gps: Bool?
}

// MARK: - Store
@MainActor
final class BikeStore: ObservableObject {
    @Published var bikeName = "Bosch Flow"
    @Published var battery: Battery?
    @Published var rides: [Ride] = []
    @Published var serverUp = false
    @Published var lastError: String?
    @Published var chargeEta: Date?   // when charging, anchored full-charge time

    private var bikeID: String?
    private var lastEventSeen: Double = Date().timeIntervalSince1970
    private var baselined = false

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 12
        return URLSession(configuration: c)
    }()

    private func get(_ path: String) async -> Data? {
        guard let url = URL(string: apiBase + path) else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return nil }
            return data
        } catch { return nil }
    }

    func refresh() async {
        // resolve bike id once
        if bikeID == nil {
            if let d = await get("/api/bikes"),
               let bikes = try? JSONDecoder().decode([Bike].self, from: d), let b = bikes.first {
                bikeID = b.id
                bikeName = "\(b.brand ?? "eBike") \(b.drive_unit ?? "")".trimmingCharacters(in: .whitespaces)
            } else {
                serverUp = false
                lastError = "Can't reach \(apiBase) — is the server running?"
                return
            }
        }
        guard let id = bikeID else { return }

        if let d = await get("/api/bikes/\(id)/battery"),
           let bat = try? JSONDecoder().decode(Battery.self, from: d) {
            battery = bat; serverUp = true; lastError = nil
            // anchor a live countdown to Bosch's latest "minutes to full" estimate
            if (bat.is_charging ?? false), let mins = bat.remaining_charging_time, mins > 0 {
                chargeEta = Date().addingTimeInterval(mins * 60)
            } else {
                chargeEta = nil
            }
        }
        if let d = await get("/api/bikes/\(id)/rides?gps=1"),
           let r = try? JSONDecoder().decode([Ride].self, from: d) {
            rides = Array(r.prefix(5))
        }
        await checkEvents()
    }

    /// Poll the server event log and surface new events as native notifications.
    private func checkEvents() async {
        guard let d = await get("/api/events?limit=50"),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        // events come newest-first
        let events = arr.compactMap { e -> (String, Double, [String: Any])? in
            guard let ev = e["event"] as? String, let at = e["at"] as? Double else { return nil }
            return (ev, at, e["data"] as? [String: Any] ?? [:])
        }
        if !baselined {                    // first run: don't replay history
            lastEventSeen = events.map { $0.1 }.max() ?? lastEventSeen
            baselined = true
            return
        }
        let fresh = events.filter { $0.1 > lastEventSeen && notifiableEvents.contains($0.0) }
        for (ev, _, data) in fresh.reversed() {   // oldest first
            Notifier.post(for: ev, data: data, bike: bikeName)
        }
        if let newest = events.map({ $0.1 }).max() { lastEventSeen = max(lastEventSeen, newest) }
    }

    // menu bar title — shows a live countdown while charging
    var menuTitle: String {
        guard serverUp, let b = battery, let lvl = b.level_percent else { return "—" }
        if (b.is_charging ?? false), let eta = chargeEta {
            return "⚡︎\(lvl)% · \(fmtCountdown(eta.timeIntervalSinceNow))"
        }
        let bolt = (b.is_charging ?? false) ? "⚡︎" : ""
        return "\(bolt)\(lvl)%"
    }
}

func fmtCountdown(_ secs: TimeInterval) -> String {
    let m = max(0, Int(secs / 60))
    return m >= 60 ? "\(m/60)h\(m%60)m" : "\(m)m"
}

// MARK: - Notifications
enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func message(for ev: String, data: [String: Any], bike: String) -> (String, String, String)? {
        let lvl = data["level"] as? Int ?? Int(data["level"] as? Double ?? -1)
        switch ev {
        case "battery.full": return ("🔋 Battery fully charged", "\(bike) is at 100%", "default")
        case "battery.low": return ("🪫 Battery low — \(lvl)%", "\(bike) needs a charge", "default")
        case "battery.charging_started": return ("⚡ Charging started", "\(bike) at \(lvl)%", "default")
        case "battery.charging_stopped": return ("🔌 Charging stopped", "\(bike) at \(lvl)%", "default")
        case "charger.connected": return ("🔌 Charger connected", bike, "default")
        case "charger.disconnected": return ("🔌 Charger unplugged", bike, "default")
        case "ride.completed":
            let km = data["distance_km"] as? Double ?? 0
            return ("🚲 Ride logged", String(format: "%.1f km on %@", km, bike), "default")
        case "firmware.changed":
            let comp = data["component"] as? String ?? "component"
            let to = data["to"] as? String ?? ""
            return ("🔧 \(comp) updated", "→ \(to)", "default")
        default: return nil
        }
    }

    static func post(for ev: String, data: [String: Any], bike: String) {
        guard let (title, body, _) = message(for: ev, data: data, bike: bike) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Popover UI
struct DetailView: View {
    @ObservedObject var store: BikeStore
    @AppStorage("useImperial") private var useImperial = false

    private func dist(_ km: Double) -> String {
        useImperial ? String(format: "%.1f mi", km*0.621371) : String(format: "%.1f km", km)
    }
    private func rangeVal(_ km: Double) -> Int { Int((useImperial ? km*0.621371 : km).rounded()) }
    private var distUnit: String { useImperial ? "mi" : "km" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.bikeName).font(.headline)

            if !store.serverUp {
                Label(store.lastError ?? "Server unreachable", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let b = store.battery {
                HStack(spacing: 10) {
                    Image(systemName: (b.is_charging ?? false) ? "battery.100.bolt" : "battery.100")
                        .font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(b.level_percent ?? 0)%").font(.title2).bold()
                        Text(statusLine(b)).font(.caption).foregroundStyle(.secondary)
                        if (b.is_charging ?? false), let eta = store.chargeEta {
                            Text("~\(fmtCountdown(eta.timeIntervalSinceNow)) to full")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                if let ranges = b.range_per_mode, !ranges.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(ranges.indices, id: \.self) { i in
                            VStack(spacing: 1) {
                                Text("\(rangeVal(ranges[i].range_km ?? 0))").font(.callout).bold()
                                Text(ranges[i].mode ?? "").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                }
                if let odo = b.odometer_km {
                    Label("\(dist(odo)) odometer", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .font(.caption)
                }
            }

            if let latest = store.rides.first {
                Divider()
                Text("Latest ride").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(shortDate(latest.start)).font(.caption)
                    Spacer()
                    Text(dist(latest.distance_km ?? 0)).font(.caption).bold()
                    if latest.has_gps ?? false { Image(systemName: "location.fill").font(.system(size: 9)).foregroundStyle(.green) }
                }
            }

            Divider()
            HStack {
                Button("Dashboard") { NSWorkspace.shared.open(URL(string: apiBase)!) }
                Button("Refresh") { Task { await store.refresh() } }
                Button(distUnit) { useImperial.toggle() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.font(.caption)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func statusLine(_ b: Battery) -> String {
        if b.is_charging ?? false { return "charging" }
        if b.charger_connected ?? false { return "plugged in" }
        let live = (b.live ?? false) ? "live" : "last-known"
        return "unplugged · \(live)"
    }
    private func shortDate(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f.string(from: d)
    }
}

// MARK: - Status bar
@MainActor
final class StatusBarController: NSObject {
    private let store = BikeStore()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        popover.behavior = .transient
        popover.animates = true

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &cancellables)

        updateButton()
        Notifier.requestAuth()
        Task { await store.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }
        // ticks the charge countdown between polls
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateButton() }
        }
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let title = store.menuTitle
        let attr = NSMutableAttributedString()
        if let icon = NSImage(systemSymbolName: "bicycle", accessibilityDescription: "bike") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            let att = NSTextAttachment(); att.image = icon.withSymbolConfiguration(cfg) ?? icon
            attr.append(NSAttributedString(attachment: att))
            attr.append(NSAttributedString(string: " "))
        }
        attr.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
        button.attributedTitle = attr
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        let host = NSHostingController(rootView: DetailView(store: store))
        host.sizingOptions = .preferredContentSize   // lets the popover anchor to the button
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: StatusBarController?
    func applicationDidFinishLaunching(_ n: Notification) {
        controller = StatusBarController()
    }
}

// Bootstrap (top-level code, so no @main). .accessory = menu bar only, no Dock.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
