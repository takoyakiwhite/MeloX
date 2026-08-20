import SwiftUI

struct LibraryPlaylistsView: View {
    let searchQuery: String

    @Environment(LibraryStore.self) private var library

    var body: some View {
        List {
            if !isSearching, let userID = library.profile?.id {
                Section("ui.library.section.mine") {
                    NavigationLink {
                        UserListeningRankView(userID: userID)
                    } label: {
                        Label(
                            "ui.library.my_listening_rank",
                            systemImage: "chart.bar.xaxis"
                        )
                    }
                    .accessibilityHint("ui.library.my_listening_rank.hint")
                }
            }

            Section(
                isSearching
                    ? L10n.string("ui.common.search_results")
                    : L10n.string("ui.common.playlists")
            ) {
                ForEach(displayedPlaylists) { playlist in
                    NavigationLink(value: MusicRoute.playlist(playlist)) {
                        LibraryPlaylistRow(playlist: playlist)
                    }
                    .musicMatchedTransitionSource(
                        for: MusicRoute.playlist(playlist)
                    )
                    .swipeActions(edge: .trailing) {
                        if library.canUnsubscribe(playlist) {
                            Button(role: .destructive) {
                                library.toggle(playlist: playlist)
                            } label: {
                                Label(
                                    L10n.string("ui.common.unfavorite"),
                                    systemImage: "heart.slash"
                                )
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await library.refresh(force: true)
        }
        .overlay {
            Group {
                if displayedPlaylists.isEmpty {
                    if isSearching {
                        ContentUnavailableView.search(
                            text: normalizedSearchQuery
                        )
                    } else {
                        ContentUnavailableView(
                            "ui.library.no_favorite_playlists",
                            systemImage: "music.note.list",
                            description: Text(
                                "ui.library.no_favorite_playlists.message"
                            )
                        )
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var normalizedSearchQuery: String {
        normalizedLibrarySearchQuery(searchQuery)
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var displayedPlaylists: [Playlist] {
        filterLibraryPlaylists(
            library.favoritePlaylists,
            query: normalizedSearchQuery
        )
    }
}

private struct LibraryPlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: playlist.artworkURL, cornerRadius: 7)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .lineLimit(1)
                Text(L10n.format("ui.common.song_count", playlist.trackCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
