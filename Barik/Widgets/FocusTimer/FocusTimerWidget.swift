import SwiftUI
import AppKit

struct FocusTimerWidget: View {
    @ObservedObject private var manager = FocusTimerManager.shared
    @State private var bounceOffset: CGFloat = 0

    var isFullWidth: Bool = false

    private let green = Color(red: 20 / 255, green: 160 / 255, blue: 65 / 255)

    var body: some View {
        Group {
            if manager.isActive {
                timerContent
                    .background {
                        if manager.isBouncing {
                            Rectangle()
                                .fill(.regularMaterial)
                                .padding(.top, -6)
                        }
                    }
                    .offset(y: bounceOffset)
                    .offset(y: manager.isDismissing ? -6 : 0)
                    .opacity(manager.isDismissing ? 0 : 1)
                    .animation(.easeOut(duration: 0.3), value: manager.isDismissing)
                    .overlay(
                        ClickHandler(
                            onLeftClick: handleLeftClick,
                            onRightClick: { manager.restart() }
                        )
                    )
                    .onChange(of: manager.bouncePhase) { _, _ in
                        guard manager.isBouncing else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            bounceOffset = 6
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.interpolatingSpring(stiffness: 300, damping: 10)) {
                                bounceOffset = 0
                            }
                        }
                    }
                    .onChange(of: manager.isBouncing) { _, newValue in
                        if !newValue { bounceOffset = 0 }
                    }
            }
        }
    }

    private var timerContent: some View {
        Group {
            if isFullWidth {
                fullWidthTimerContent
            } else {
                compactTimerContent
            }
        }
    }

    private var timerTextContent: some View {
        HStack(spacing: 6) {
            Text(formattedTime)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .lineLimit(1)

            Text(manager.taskName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .opacity(0.7)
        }
        .foregroundStyle(.foregroundOutside)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(height: 3)
                Rectangle()
                    .fill(progressFillColor)
                    .frame(width: fillWidth(geo.size.width), height: 3)
                    .animation(manager.isRunning ? .linear(duration: 1) : .linear(duration: 0.05), value: manager.progress)
                    .animation(.easeInOut(duration: 0.4), value: manager.isFinished)
                    .animation(.easeInOut(duration: 0.45), value: manager.isFlashing)
            }
            .overlay(alignment: .leading) {
                if !manager.isFinished {
                    TimelineView(.animation(paused: !manager.isRunning && !manager.isCometParking)) { context in
                        let phase = manager.cometPhase(at: context.date)
                        let travelPhase = min(phase / 0.94, 1)
                        let angle = travelPhase * .pi * 2
                        let easedPhase = travelPhase - sin(angle) / (4 * .pi)
                        let position = (geo.size.width + 38) * CGFloat(easedPhase)
                        let colorPhase = (1 - cos(angle)) / 2
                        let shotColor = Color(
                            hue: 0.24 + 0.12 * Double(colorPhase),
                            saturation: 0.9,
                            brightness: 1
                        )
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, shotColor.opacity(0.3), shotColor.opacity(0.9)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 36, height: 3)
                            Rectangle()
                                .fill(shotColor)
                                .frame(width: 2, height: 3)
                        }
                        .blendMode(.plusLighter)
                        .shadow(color: shotColor, radius: 2)
                        .offset(x: position - 38)
                        .frame(width: geo.size.width, height: 3, alignment: .leading)
                        .clipped()
                    }
                }
            }
        }
        .frame(height: 3)
    }

    private var compactTimerContent: some View {
        timerTextContent
            .experimentalConfiguration(cornerRadius: 15)
            .frame(maxHeight: .infinity)
            .background(.black.opacity(0.001))
            .overlay(alignment: .top) {
                progressBar
            }
    }

    private var fullWidthTimerContent: some View {
        timerTextContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.001))
            .overlay(alignment: .bottom) {
                progressBar
            }
    }

    private func fillWidth(_ total: CGFloat) -> CGFloat {
        if manager.isFinished { return total }
        return total * (1 - manager.progress)  // elapsed fraction: 0→1 as time runs out
    }

    private var progressFillColor: Color {
        if manager.isFinished {
            return manager.isFlashing ? .red : .red.opacity(0.4)
        }
        return green
    }

    private var formattedTime: String {
        let total = Int(manager.isFinished ? manager.totalDuration : manager.remainingTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func handleLeftClick() {
        if manager.isFinished {
            manager.complete()
        } else {
            manager.togglePauseResume()
        }
    }
}

// MARK: - Unified click handler (NSView-based for reliable left + right click)

private struct ClickHandler: NSViewRepresentable {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> _View {
        let v = _View()
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ v: _View, context: Context) {
        v.onLeftClick = onLeftClick
        v.onRightClick = onRightClick
    }

    class _View: NSView {
        var onLeftClick: (() -> Void)?
        var onRightClick: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            onLeftClick?()
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }
    }
}
