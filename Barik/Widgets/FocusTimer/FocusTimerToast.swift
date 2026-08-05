import AppKit
import SwiftUI

class FocusTimerToast {
    static let shared = FocusTimerToast()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    private init() {}

    func show(taskName: String) {
        DispatchQueue.main.async {
            self.dismissWork?.cancel()
            self.panel?.orderOut(nil)

            guard let screen = NSScreen.main else { return }

            let width: CGFloat = 300
            let height: CGFloat = 68
            let x = screen.frame.midX - width / 2
            let y = screen.frame.midY - height / 2

            let newPanel = NSPanel(
                contentRect: NSRect(x: x, y: y, width: width, height: height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.isOpaque = false
            newPanel.collectionBehavior = [.canJoinAllSpaces]
            newPanel.alphaValue = 0

            newPanel.contentView = NSHostingView(rootView: ToastView(taskName: taskName))
            newPanel.orderFront(nil)
            self.panel = newPanel

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                newPanel.animator().alphaValue = 1
            }

            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    newPanel.animator().alphaValue = 0
                }) {
                    newPanel.orderOut(nil)
                }
            }
            self.dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }
}

private struct ToastView: View {
    let taskName: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color(red: 20 / 255, green: 175 / 255, blue: 75 / 255))

            VStack(alignment: .leading, spacing: 3) {
                Text("Time's up!")
                    .font(.system(size: 14, weight: .semibold))
                Text(taskName)
                    .font(.system(size: 12))
                    .opacity(0.65)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(width: 300, height: 68)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 4)
    }
}
