import Foundation

/// Compatibility bridge for the quality-source labels used by the Now Playing UI.
/// The clean upstream PlayerStore keeps the active PlaybackSource private, so this
/// bridge reads that value without copying the rest of the fork's PlayerStore changes.
extension PlayerStore {
    var currentPlaybackSourceHost: String? {
        Mirror(reflecting: self).children
            .first(where: { $0.label == "currentPlaybackSource" })
            .flatMap { child in
                (child.value as? PlaybackSource)?.url.host?.lowercased()
            }
    }
}
