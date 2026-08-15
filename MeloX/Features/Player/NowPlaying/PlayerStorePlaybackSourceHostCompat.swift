import Foundation

/// Compatibility bridge for the quality-source labels used by the Now Playing UI.
/// The clean upstream PlayerStore keeps the active PlaybackSource private, so this
/// bridge reads that value without copying the rest of the fork's PlayerStore changes.
extension PlayerStore {
    var currentPlaybackSourceHost: String? {
        // `currentPlaybackSource` itself is intentionally not an observed property
        // in the upstream PlayerStore. Reading an observed playback value here makes
        // SwiftUI re-evaluate this computed property while the current track plays,
        // so a newly resolved source host (e.g. 波点/酷我/酷狗) is reflected without
        // leaving and reopening Now Playing.
        _ = progress
        _ = effectivePlaybackQuality

        return Mirror(reflecting: self).children
            .first(where: { $0.label == "currentPlaybackSource" })
            .flatMap { child in
                (child.value as? PlaybackSource)?.url.host?.lowercased()
            }
    }
}
