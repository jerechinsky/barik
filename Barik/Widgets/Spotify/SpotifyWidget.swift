import SwiftUI
import AppKit

private struct ClickHandler: NSViewRepresentable {
    let onLeftClick: () -> Void
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView { ClickView(onLeftClick: onLeftClick, onRightClick: onRightClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ClickView else { return }
        view.onLeftClick = onLeftClick
        view.onRightClick = onRightClick
    }

    class ClickView: NSView {
        var onLeftClick: () -> Void
        var onRightClick: () -> Void
        init(onLeftClick: @escaping () -> Void, onRightClick: @escaping () -> Void) {
            self.onLeftClick = onLeftClick
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with event: NSEvent) { onLeftClick() }
        override func rightMouseDown(with event: NSEvent) { onRightClick() }
    }
}

struct SpotifyWidget: View {
    @ObservedObject private var manager = SpotifyManager.shared

    var body: some View {
        Group {
            if let track = manager.track {
                HStack(spacing: 4) {
                    if let albumArt = manager.albumArt {
                        Image(nsImage: albumArt)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 26, height: 26)
                            .clipShape(Rectangle())
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 10, weight: .regular))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .overlay(ClickHandler(
                        onLeftClick: { manager.togglePlayPause() },
                        onRightClick: { manager.nextTrack() }
                    ))

                    ZStack {
                        if manager.isGem {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                            Image(systemName: "heart")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                        } else {
                            Image(systemName: manager.isLiked ? "heart.fill" : "heart")
                                .font(.system(size: 13))
                                .foregroundStyle(manager.isLiked ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color.foregroundOutside)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: manager.isLiked)
                    .animation(.easeInOut(duration: 0.15), value: manager.isGem)
                    .onTapGesture {
                        manager.toggleLike()
                    }
                }
                .foregroundStyle(.foregroundOutside)
                .transition(.blurReplace)
            }
        }
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .overlay(alignment: .top) {
            if let track = manager.track, track.isPlaying {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.55))
                            .frame(height: 3)
                        Rectangle()
                            .fill(Color(red: 0.11, green: 0.73, blue: 0.31))
                            .frame(width: geo.size.width * manager.progressRatio, height: 3)
                            .animation(.linear(duration: 0.1), value: manager.progressRatio)
                    }
                }
                .frame(height: 3)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: manager.track?.id)
    }
}

struct SpotifyWidget_Previews: PreviewProvider {
    static var previews: some View {
        SpotifyWidget()
            .frame(width: 200, height: 30)
            .background(.gray)
    }
}
