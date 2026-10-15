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
    @ObservedObject private var displayManager = DisplayManager.shared

    var body: some View {
        Group {
            if displayManager.usesCompactMusic {
                compactWidget
            } else if let track = manager.track {
                HStack(spacing: 4) {
                    playbackArtwork

                    Group {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.system(size: 10, weight: .regular))
                                .opacity(0.7)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 100, maxWidth: 160,
                               alignment: .leading)
                        .overlay(playbackClickHandler)
                    }

                    heartButton(size: 13)
                }
                .foregroundStyle(.foregroundOutside)
                .transition(.blurReplace)
            } else {
                spotifyIcon
                    .frame(width: 26, height: 26)
                    .onTapGesture { NSWorkspace.shared.launchApplication("Spotify") }
                    .help("Open Spotify")
            }
        }
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .overlay(alignment: .top) {
            if !displayManager.usesCompactMusic, let track = manager.track, track.isPlaying {
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

    private func heartButton(size: CGFloat) -> some View {
        Button { manager.toggleLike() } label: {
            ZStack {
                Image(systemName: manager.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: size))
                    .foregroundStyle(manager.isGem ? Color.red :
                        (manager.isLiked ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color.foregroundOutside))
                if manager.isGem {
                    Image(systemName: "heart")
                        .font(.system(size: size, weight: .heavy))
                        .foregroundStyle(Color(red: 0.11, green: 0.73, blue: 0.33))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if manager.likeRequestInFlight {
                    ProgressView().controlSize(.mini).scaleEffect(0.5).frame(width: 6, height: 6)
                }
            }
            .frame(width: size + 6, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.libraryTrackID == nil || manager.likeRequestInFlight)
        .opacity(manager.likeRequestInFlight ? 0.5 : 1)
        .help(manager.likeError ?? (manager.libraryTrackID == nil
            ? "Waiting for Spotify track identity"
            : (manager.isLiked ? "Remove from Liked Songs" : "Save to Liked Songs")))
        .accessibilityLabel(manager.isLiked ? "Unlike song" : "Like song")
        .animation(.easeInOut(duration: 0.15), value: manager.isLiked)
    }

    private var spotifyIcon: some View {
        Canvas { context, size in
            context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(.foregroundOutside))
            for row in 0..<3 {
                let y = size.height * (0.34 + Double(row) * 0.18)
                var wave = Path()
                wave.move(to: CGPoint(x: size.width * 0.24, y: y))
                wave.addQuadCurve(to: CGPoint(x: size.width * 0.77, y: y + size.height * 0.06),
                                  control: CGPoint(x: size.width * 0.51, y: y - size.height * 0.13))
                context.stroke(wave, with: .color(.black), style: StrokeStyle(lineWidth: size.width * 0.07, lineCap: .round))
            }
        }
        .frame(width: 15, height: 15)
    }

    private var compactWidget: some View {
        HStack(spacing: 4) {
            compactPlaybackContent
            if manager.track != nil { heartButton(size: 11) }
        }
    }

    private var compactPlaybackContent: some View {
        HStack(spacing: 4) {
            if let art = manager.albumArt, manager.track != nil {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                spotifyIcon
            }
            if let track = manager.track {
                Text(String(track.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 15, alignment: .leading)
                Image(systemName: track.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 7)
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.foregroundOutside)
        .frame(height: 26)
        .contentShape(Rectangle())
        .overlay {
            if manager.track != nil {
                playbackClickHandler
            } else {
                ClickHandler(onLeftClick: { NSWorkspace.shared.launchApplication("Spotify") },
                             onRightClick: { NSWorkspace.shared.launchApplication("Spotify") })
            }
        }
        .help(manager.track.map { "\($0.name) - \($0.artist) • \($0.isPlaying ? "Playing" : "Paused") • Click to play/pause; right-click to skip" } ?? "Open Spotify")
        .accessibilityLabel(manager.track.map { "Spotify: \($0.name), \($0.artist)" } ?? "Open Spotify")
    }

    @ViewBuilder
    private var playbackArtwork: some View {
        Group {
            if let albumArt = manager.albumArt {
                Image(nsImage: albumArt)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                spotifyIcon
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Rectangle())
        .overlay(playbackClickHandler)
    }

    private var playbackClickHandler: some View {
        ClickHandler(
            onLeftClick: { manager.togglePlayPause() },
            onRightClick: { manager.nextTrack() }
        )
    }
}

struct SpotifyWidget_Previews: PreviewProvider {
    static var previews: some View {
        SpotifyWidget()
            .frame(width: 200, height: 30)
            .background(.gray)
    }
}
