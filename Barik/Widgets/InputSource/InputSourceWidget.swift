import SwiftUI
import AppKit

private struct InputSourceClickHandler: NSViewRepresentable {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        ClickView(onLeftClick: onLeftClick, onRightClick: onRightClick)
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
    }

    final class ClickView: NSView {
        var onLeftClick: () -> Void
        var onRightClick: () -> Void

        init(onLeftClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
            self.onLeftClick = onLeftClick
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onLeftClick() }
        override func rightMouseDown(with event: NSEvent) { onRightClick() }
    }
}

struct InputSourceWidget: View {
    @ObservedObject private var manager = InputSourceManager.shared

    var body: some View {
        Group {
            switch manager.sourceID {
            case "com.apple.keylayout.US":
                USFlag()
            case "com.apple.keylayout.Czech-QWERTY":
                CZFlag()
            case "com.apple.keylayout.Ukrainian-QWERTY":
                UAFlag()
            default:
                Text(manager.label)
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundStyle(.foregroundOutside)
            }
        }
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .padding(.trailing, 1)
        .background(.black.opacity(0.001))
        .overlay(InputSourceClickHandler(
            onLeftClick: { manager.cycleLatinScript() },
            onRightClick: { manager.cycleCyrillicScript() }
        ))
        .help("Left-click: next Latin input source. Right-click: next Cyrillic input source.")
        .animation(.easeInOut(duration: 0.15), value: manager.sourceID)
    }
}

private let flagSize = CGSize(width: 20, height: 13)

private struct FlagFrame<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(width: flagSize.width, height: flagSize.height)
            .overlay(
                Rectangle()
                    .strokeBorder(Color.foregroundOutside, lineWidth: 0.5)
            )
    }
}

private struct USFlag: View {
    var body: some View {
        FlagFrame {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let stripeH = h / 9
                ZStack(alignment: .topLeading) {
                    ForEach([0, 2, 4, 6, 8], id: \.self) { i in
                        Rectangle()
                            .fill(Color.foregroundOutside)
                            .frame(width: w, height: stripeH)
                            .offset(y: CGFloat(i) * stripeH)
                    }
                    Rectangle()
                        .fill(Color.foregroundOutside)
                        .frame(width: 10, height: stripeH * 4)
                }
            }
        }
    }
}

private struct CZFlag: View {
    var body: some View {
        FlagFrame {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.clear)
                        Rectangle().fill(Color.foregroundOutside.opacity(0.45))
                    }
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 0))
                        p.addLine(to: CGPoint(x: w / 2, y: h / 2))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.foregroundOutside)
                }
            }
        }
    }
}

private struct UAFlag: View {
    var body: some View {
        FlagFrame {
            VStack(spacing: 0) {
                Rectangle().fill(Color.foregroundOutside)
                Rectangle().fill(Color.clear)
            }
        }
    }
}

struct InputSourceWidget_Previews: PreviewProvider {
    static var previews: some View {
        InputSourceWidget()
            .frame(width: 60, height: 30)
            .background(.gray)
    }
}
