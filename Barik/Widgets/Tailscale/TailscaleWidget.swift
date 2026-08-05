import Foundation
import SwiftUI

struct TailscaleWidget: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = TailscaleStatusManager.shared
    @State private var widgetFrame = CGRect.zero

    var body: some View {
        TailscaleMark(color: manager.statusColor)
            .frame(width: 15, height: 15)
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { widgetFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in
                        widgetFrame = frame
                    }
            }
        )
        .background(.black.opacity(0.001))
        .onAppear { manager.startUpdating() }
        .onTapGesture {
            manager.refresh(probeHome: true)
            MenuBarPopup.show(
                rect: widgetFrame, id: "tailscale-home", colorScheme: colorScheme
            ) {
                TailscalePopup()
            }
        }
        .help(manager.helpText)
        .accessibilityLabel("Home Tailscale")
        .accessibilityValue(manager.connectionTitle)
    }
}

private struct TailscaleMark: View {
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<3) { row in
                ForEach(0..<3) { column in
                    Circle()
                        .fill(
                            row == 1 && column == 1
                                ? color
                                : Color.foregroundOutside.opacity(0.72)
                        )
                        .frame(
                            width: row == 1 && column == 1 ? 4.5 : 2.8,
                            height: row == 1 && column == 1 ? 4.5 : 2.8
                        )
                        .position(
                            x: CGFloat(column) * 5.5 + 2,
                            y: CGFloat(row) * 5.5 + 2
                        )
                }
            }
        }
    }
}

private struct TailscalePopup: View {
    @ObservedObject private var manager = TailscaleStatusManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            topology
                .padding(18)
            Divider().opacity(0.25)
            summary
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
            Divider().opacity(0.25)
            peers
            Divider().opacity(0.25)
            footer
        }
        .frame(width: 390)
        .onAppear {
            manager.startUpdating()
            manager.refresh(probeHome: true)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            TailscaleMark(color: manager.statusColor)
                .frame(width: 22, height: 22)
                .scaleEffect(1.25)

            VStack(alignment: .leading, spacing: 2) {
                Text("Home Network")
                    .font(.system(size: 15, weight: .semibold))
                Text(manager.connectionSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(manager.statusColor)
                    .frame(width: 7, height: 7)
                Text(manager.connectionTitle)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(manager.statusColor.opacity(0.13), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var topology: some View {
        HStack(spacing: 10) {
            endpoint(
                icon: "laptopcomputer",
                title: "This Mac",
                detail: manager.snapshot.selfNode?.ipv4Address ?? "—",
                color: manager.snapshot.selfNode?.online == true ? .green : .gray
            )

            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(manager.pathColor.opacity(0.6))
                        .frame(height: 1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(manager.pathColor)
                }
                Text(manager.pathTitle)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(manager.pathColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            endpoint(
                icon: "house.and.flag.fill",
                title: "Home LAN",
                detail: manager.snapshot.homeRoute ?? "192.168.0.0/24",
                color: manager.snapshot.isHomeConnected ? .green : .gray
            )
        }
        .padding(13)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
    }

    private func endpoint(
        icon: String,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 105)
    }

    private var summary: some View {
        HStack(spacing: 0) {
            metric(
                title: "PATH",
                value: manager.pathMetric,
                color: manager.pathColor
            )
            metric(
                title: "ROUTER",
                value: manager.snapshot.homePeer?.online == true ? "ONLINE" : "OFFLINE",
                color: manager.snapshot.homePeer?.online == true ? .green : .red
            )
            metric(
                title: "DEVICES",
                value: "\(manager.snapshot.onlinePeerCount)/\(manager.snapshot.peers.count)",
                color: manager.snapshot.onlinePeerCount == manager.snapshot.peers.count
                    ? .green : .orange
            )
        }
    }

    private func metric(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var peers: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TAILNET")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            if manager.snapshot.peers.isEmpty {
                Text(manager.errorMessage ?? "Waiting for Tailscale…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.snapshot.sortedPeers) { peer in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(peer.online ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Image(systemName: peer.icon)
                            .font(.system(size: 12))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(peer.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(peer.role)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(peer.ipv4Address ?? "—")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var footer: some View {
        HStack {
            if let updatedAt = manager.snapshot.updatedAt {
                Text("Updated \(updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                Text("Personal Tailscale daemon")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(
                "VPN",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }
                )
            )
            .font(.system(size: 10, weight: .medium))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(manager.isRefreshing)

            Button {
                manager.refresh(probeHome: true)
            } label: {
                if manager.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Test path", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .disabled(manager.isRefreshing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

@MainActor
private final class TailscaleStatusManager: ObservableObject {
    static let shared = TailscaleStatusManager()

    @Published private(set) var snapshot = TailscaleSnapshot.empty
    @Published private(set) var latencyMS: Int?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?

    private var timer: Timer?

    private init() {
        assert(Self.parserSelfCheck())
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(probeHome: true) }
        }
    }

    var isEnabled: Bool {
        snapshot.backendState == "Running"
    }

    var statusColor: Color {
        if snapshot.isHomeConnected { return .green }
        if snapshot.selfNode?.online == true { return .orange }
        return snapshot.updatedAt == nil ? .gray : .red
    }

    var connectionTitle: String {
        if snapshot.isHomeConnected { return "Connected" }
        if snapshot.selfNode?.online == true { return "Home offline" }
        return snapshot.updatedAt == nil ? "Checking…" : "Disconnected"
    }

    var connectionSubtitle: String {
        if let latencyMS, snapshot.isHomeConnected {
            return "Personal Tailscale · \(latencyMS) ms \(snapshot.path.description.lowercased())"
        }
        if snapshot.isHomeConnected {
            return "Personal Tailscale · home subnet available"
        }
        return errorMessage ?? "Personal Tailscale is unavailable"
    }

    var helpText: String {
        snapshot.isHomeConnected
            ? "Home Tailscale connected · click for path and devices"
            : "\(connectionTitle) · click for details"
    }

    var pathTitle: String {
        switch snapshot.path {
        case .direct:
            return latencyMS.map { "DIRECT · \($0) MS" } ?? "DIRECT"
        case let .relay(region):
            return latencyMS.map { "RELAY · \($0) MS" } ?? "RELAY · \(region.uppercased())"
        case .ready:
            return "READY"
        case .unavailable:
            return "NO PATH"
        }
    }

    var pathMetric: String {
        switch snapshot.path {
        case .direct: return latencyMS.map { "\($0) MS" } ?? "DIRECT"
        case .relay: return latencyMS.map { "\($0) MS" } ?? "RELAY"
        case .ready: return "READY"
        case .unavailable: return "OFFLINE"
        }
    }

    var pathColor: Color {
        switch snapshot.path {
        case .direct: .green
        case .relay: .orange
        case .ready: .blue
        case .unavailable: .red
        }
    }

    func startUpdating() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh(probeHome: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true

        Task {
            let result = await Task.detached(priority: .utility) {
                Self.load(probeHome: probeHome)
            }.value
            apply(result)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled, !isRefreshing else { return }
        isRefreshing = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.changeConnection(to: enabled)
            }.value
            apply(result)
        }
    }

    private func apply(_ result: Result<TailscaleUpdate, Error>) {
        switch result {
        case let .success(update):
            snapshot = update.snapshot
            if let measuredLatency = update.latencyMS {
                latencyMS = measuredLatency
            } else if !update.snapshot.isHomeConnected {
                latencyMS = nil
            }
            errorMessage = nil
        case let .failure(error):
            snapshot = .offline
            latencyMS = nil
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    nonisolated private static func changeConnection(
        to enabled: Bool
    ) -> Result<TailscaleUpdate, Error> {
        do {
            _ = try runTailscale([enabled ? "up" : "down"], timeout: 12)
            return load(probeHome: enabled)
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func load(
        probeHome: Bool
    ) -> Result<TailscaleUpdate, Error> {
        do {
            var status = try loadStatus()
            var latency: Int?

            if probeHome, let homePeer = status.homePeer, homePeer.online {
                if let output = try? runTailscale(
                    ["ping", "--c", "1", "--timeout", "3s", homePeer.hostName],
                    timeout: 5
                ) {
                    latency = parseLatency(output)
                    status = (try? loadStatus()) ?? status
                }
            }

            return .success(TailscaleUpdate(snapshot: status, latencyMS: latency))
        } catch {
            return .failure(error)
        }
    }

    nonisolated private static func loadStatus() throws -> TailscaleSnapshot {
        let data = try runTailscaleData(["status", "--json"], timeout: 4)
        let status = try JSONDecoder().decode(TailscaleStatus.self, from: data)
        return TailscaleSnapshot(status: status, updatedAt: Date())
    }

    nonisolated private static func runTailscale(
        _ arguments: [String],
        timeout: TimeInterval
    ) throws -> String {
        let data = try runTailscaleData(arguments, timeout: timeout)
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func runTailscaleData(
        _ arguments: [String],
        timeout: TimeInterval
    ) throws -> Data {
        let binary = "/opt/homebrew/bin/tailscale"
        let socket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Tailscale Personal/tailscaled.sock"
            ).path

        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw TailscaleError("Tailscale CLI not found")
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            throw TailscaleError("Personal Tailscale daemon is not running")
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--socket=\(socket)"] + arguments
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { _ in finished.signal() }

        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            throw TailscaleError("Tailscale command timed out")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TailscaleError(message.isEmpty ? "Tailscale is unavailable" : message)
        }
        return data
    }

    nonisolated private static func parseLatency(_ output: String) -> Int? {
        output.components(separatedBy: " in ")
            .dropFirst()
            .compactMap { part in Int(part.prefix(while: \.isNumber)) }
            .last
    }

    nonisolated private static func parserSelfCheck() -> Bool {
        let sample = """
            {
              "BackendState":"Running",
              "Self":{"HostName":"personal-mac","TailscaleIPs":["100.64.0.10"],"Online":true},
              "Peer":{"node":{"HostName":"home-subnet-router","DNSName":"router.example.ts.net.","TailscaleIPs":["100.64.0.20"],"Online":true,"Active":true,"CurAddr":"192.168.0.2:41641","PrimaryRoutes":["192.168.0.0/24"]}}
            }
            """
        guard let status = try? JSONDecoder().decode(
            TailscaleStatus.self, from: Data(sample.utf8)
        ) else { return false }
        let snapshot = TailscaleSnapshot(status: status, updatedAt: .distantPast)
        return snapshot.isHomeConnected
            && snapshot.homePeer?.hostName == "home-subnet-router"
            && snapshot.path == .direct
            && parseLatency("pong from home via 192.168.0.2:41641 in 7ms") == 7
    }
}

private struct TailscaleUpdate: Sendable {
    let snapshot: TailscaleSnapshot
    let latencyMS: Int?
}

private struct TailscaleSnapshot: Sendable {
    let backendState: String
    let selfNode: TailscaleNode?
    let peers: [TailscaleNode]
    let updatedAt: Date?

    static let empty = TailscaleSnapshot(
        backendState: "Checking", selfNode: nil, peers: [], updatedAt: nil
    )
    static let offline = TailscaleSnapshot(
        backendState: "Stopped", selfNode: nil, peers: [], updatedAt: Date()
    )

    init(
        backendState: String,
        selfNode: TailscaleNode?,
        peers: [TailscaleNode],
        updatedAt: Date?
    ) {
        self.backendState = backendState
        self.selfNode = selfNode
        self.peers = peers
        self.updatedAt = updatedAt
    }

    init(status: TailscaleStatus, updatedAt: Date) {
        backendState = status.backendState
        selfNode = status.selfNode
        peers = Array(status.peers.values)
        self.updatedAt = updatedAt
    }

    var homePeer: TailscaleNode? {
        peers.first { !($0.primaryRoutes ?? []).isEmpty }
            ?? peers.first { $0.hostName == "home-subnet-router" }
    }

    var homeRoute: String? {
        homePeer?.primaryRoutes?.first
    }

    var isHomeConnected: Bool {
        backendState == "Running"
            && selfNode?.online == true
            && homePeer?.online == true
            && homeRoute != nil
    }

    var onlinePeerCount: Int {
        peers.filter(\.online).count
    }

    var sortedPeers: [TailscaleNode] {
        peers.sorted {
            let firstIsRouter = $0.primaryRoutes?.isEmpty == false
            let secondIsRouter = $1.primaryRoutes?.isEmpty == false
            if firstIsRouter != secondIsRouter { return firstIsRouter }
            if $0.online != $1.online { return $0.online }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    var path: TailscalePath {
        guard isHomeConnected, let homePeer else { return .unavailable }
        if !(homePeer.currentAddress ?? "").isEmpty { return .direct }
        if homePeer.active, let relay = homePeer.relay, !relay.isEmpty {
            return .relay(relay)
        }
        return .ready
    }
}

private enum TailscalePath: Sendable, Equatable {
    case direct
    case relay(String)
    case ready
    case unavailable

    var description: String {
        switch self {
        case .direct: "direct"
        case let .relay(region): "relay via \(region.uppercased())"
        case .ready: "ready"
        case .unavailable: "unavailable"
        }
    }
}

private struct TailscaleStatus: Decodable {
    let backendState: String
    let selfNode: TailscaleNode?
    let peers: [String: TailscaleNode]

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case peers = "Peer"
    }
}

private struct TailscaleNode: Decodable, Identifiable, Sendable {
    let hostName: String
    let dnsName: String?
    let tailscaleIPs: [String]
    let online: Bool
    let active: Bool
    let relay: String?
    let currentAddress: String?
    let primaryRoutes: [String]?

    var id: String { dnsName ?? hostName }
    var ipv4Address: String? { tailscaleIPs.first { $0.contains(".") } }
    var displayName: String {
        hostName == "home-subnet-router" ? "Home subnet router" : hostName
    }
    var role: String {
        if primaryRoutes?.isEmpty == false { return primaryRoutes?.first ?? "Subnet router" }
        if hostName.lowercased().contains("immich") { return "Photos server" }
        return online ? "Available" : "Offline"
    }
    var icon: String {
        if primaryRoutes?.isEmpty == false { return "server.rack" }
        if hostName.lowercased().contains("immich") { return "photo.stack" }
        return "desktopcomputer"
    }

    enum CodingKeys: String, CodingKey {
        case hostName = "HostName"
        case dnsName = "DNSName"
        case tailscaleIPs = "TailscaleIPs"
        case online = "Online"
        case active = "Active"
        case relay = "Relay"
        case currentAddress = "CurAddr"
        case primaryRoutes = "PrimaryRoutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostName = try container.decode(String.self, forKey: .hostName)
        dnsName = try container.decodeIfPresent(String.self, forKey: .dnsName)
        tailscaleIPs = try container.decodeIfPresent(
            [String].self, forKey: .tailscaleIPs
        ) ?? []
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        relay = try container.decodeIfPresent(String.self, forKey: .relay)
        currentAddress = try container.decodeIfPresent(
            String.self, forKey: .currentAddress
        )
        primaryRoutes = try container.decodeIfPresent(
            [String].self, forKey: .primaryRoutes
        )
    }
}

private struct TailscaleError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct TailscaleWidget_Previews: PreviewProvider {
    static var previews: some View {
        TailscaleWidget()
            .frame(width: 65, height: 30)
            .background(.black)
    }
}
