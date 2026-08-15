import Foundation

/// Compatibility bridge for the quality-source labels used by the Now Playing UI.
/// The clean upstream PlayerStore keeps the active PlaybackSource private, so this
/// bridge reads that value without copying the rest of the fork's PlayerStore changes.
extension PlayerStore {
    var currentPlaybackSourceHost: String? {
        // `currentPlaybackSource` itself is intentionally not an observed property
        // in the upstream PlayerStore. Observe the loading lifecycle instead:
        // source resolution starts/stops when a song is loaded, a quality is changed,
        // or a fallback source is resolved. This refreshes the label when the actual
        // source can change without tying the view to the continuously changing
        // playback progress.
        _ = isLoading
        _ = effectivePlaybackQuality

        return Mirror(reflecting: self).children
            .first(where: { $0.label == "currentPlaybackSource" })
            .flatMap { child in
                (child.value as? PlaybackSource)?.url.host?.lowercased()
            }
    }
}
