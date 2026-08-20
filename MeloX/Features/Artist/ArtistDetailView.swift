import SwiftUI

struct ArtistDetailView: View {
    let id: Int

    @Environment(NeteaseAPI.self) private var api
    @Environment(PlayerStore.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var artist: Artist?
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var phase: LoadingPhase = .loading
    @State private var reloadToken = 0

    var body: some View {
        Group {
            switch phase {
            case .loading where artist == nil:
                ProgressView("ui.artist.loading")
            case .failed(let message) where artist == nil:
                ConnectionUnavailableView(message: message) {
                    reloadToken += 1
                }
            default:
                if let artist {
                    content(artist)
                }
            }
        }
        .navigationTitle(artist?.name ?? L10n.string("ui.common.artist"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadToken) {
            guard artist == nil else { return }
            await load()
        }
    }

    private func content(_ artist: Artist) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkImage(url: artist.artworkURL, cornerRadius: 1_000)
                        .frame(width: 150, height: 150)
                    Text(artist.name)
                        .font(.title.bold())
                    if !artist.aliases.isEmpty {
                        Text(
                            L10n.joined(
                                artist.aliases,
                                separatorKey: "ui.common.artist_separator"
                            )
                        )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await player.playAll(songs, sourceID: artist.id) }
                    } label: {
                        Text("ui.artist.play_popular_songs")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songs.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("ui.artist.popular_songs") {
                ForEach(Array(songs.prefix(20).enumerated()), id: \.element.id) { index, song in
                    Button {
                        Task {
                            await player.play(song, in: songs, sourceID: artist.id)
                        }
                    } label: {
                        TrackRowView(song: song, index: index)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            library.toggle(song: song)
                        } label: {
                            Label(
                                library.contains(song: song)
                                    ? L10n.string("ui.common.unfavorite")
                                    : L10n.string("ui.common.favorite"),
                                systemImage: library.contains(song: song) ? "heart.slash" : "heart"
                            )
                        }
                        .tint(.pink)
                    }
                }
            }

            Section("ui.common.albums") {
                ForEach(albums) { album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        HStack(spacing: 12) {
                            ArtworkImage(url: album.artworkURL, cornerRadius: 7)
                                .frame(width: 54, height: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(album.name)
                                    .lineLimit(1)
                                Text(album.type ?? L10n.string("ui.common.album"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .musicMatchedTransitionSource(for: MusicRoute.album(album))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        phase = .loading
        do {
            (artist, songs, albums) = try await api.artist(id: id)
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
