import SwiftUI

struct CodexLimitsPopup: View {
    @ObservedObject private var manager = CodexLimitsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = manager.snapshot {
                titleBar(snapshot)
                Divider().background(Color.primary.opacity(0.2))
                limitSection(
                    icon: "calendar",
                    title: "Weekly",
                    window: snapshot.weekly
                )
                Divider().background(Color.primary.opacity(0.2))
                footer(snapshot)
            } else {
                unavailableView
            }
        }
        .frame(width: 270)
        .onAppear {
            manager.refresh()
        }
    }

    private func titleBar(_ snapshot: CodexLimitsSnapshot) -> some View {
        HStack(spacing: 8) {
            Image("CodexIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text("Codex Usage")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(snapshot.plan)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(planColor(snapshot.plan).opacity(0.3))
                .foregroundColor(planColor(snapshot.plan))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func limitSection(
        icon: String,
        title: String,
        window: CodexLimitWindow?
    ) -> some View {
        let remaining = window?.remainingPercent

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .opacity(0.6)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(remaining.map { "\($0)% left" } ?? "Unavailable")
                    .font(.system(size: remaining == nil ? 13 : 19, weight: .semibold))
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 6)
                    if let remaining {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(progressColor(remaining))
                            .frame(
                                width: geometry.size.width
                                    * CGFloat(remaining) / 100,
                                height: 6
                            )
                            .animation(.easeOut(duration: 0.3), value: remaining)
                    }
                }
            }
            .frame(height: 6)

            if let resetDate = window?.resetsAt {
                Text("Resets \(resetTimeString(resetDate))")
                    .font(.system(size: 11))
                    .opacity(0.5)
            } else if window == nil {
                Text("Not reported by Codex")
                    .font(.system(size: 11))
                    .opacity(0.5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private func footer(_ snapshot: CodexLimitsSnapshot) -> some View {
        HStack {
            Text("Usage data \(timeAgoString(snapshot.updatedAt))")
                .font(.system(size: 11))
                .opacity(0.4)
            Spacer()
            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .opacity(0.65)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var unavailableView: some View {
        VStack(spacing: 13) {
            Image("CodexIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .opacity(0.7)

            Text(manager.isAuthenticated ? "No usage data yet" : "Codex sign-in needed")
                .font(.system(size: 13, weight: .semibold))

            Text(
                manager.errorMessage
                    ?? "Run a Codex task, then refresh this widget."
            )
            .font(.system(size: 11))
            .opacity(0.55)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button("Check Again") {
                manager.refresh()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Text("Reads the latest rate-limit snapshot from ~/.codex/sessions. Credentials never leave your Mac.")
                .font(.system(size: 9.5))
                .opacity(0.3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
    }

    private func progressColor(_ remaining: Int) -> Color {
        if remaining <= 20 { return .red }
        if remaining <= 40 { return .orange }
        return .white
    }

    private func planColor(_ plan: String) -> Color {
        switch plan.lowercased() {
        case "pro": return .orange
        case "plus": return .green
        case "team": return .blue
        case "business", "enterprise": return .purple
        case "free": return .gray
        default: return .blue
        }
    }

    private func resetTimeString(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "soon" }

        let hours = Int(interval) / 3_600
        let minutes = (Int(interval) % 3_600) / 60
        if hours > 24 {
            let formatter = DateFormatter()
            formatter.dateFormat = "E h:mm a"
            return formatter.string(from: date)
        }
        return hours > 0 ? "in \(hours)h \(minutes)m" : "in \(minutes)m"
    }

    private func timeAgoString(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}
