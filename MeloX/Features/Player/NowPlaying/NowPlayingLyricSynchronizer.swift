import SwiftUI

struct NowPlayingLyricSynchronizer: View {
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    let lyrics: [LyricLine]
    @Binding var highlightedLyricID: LyricLine.ID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: player.lyricsTimingRevision) {
                synchronizeImmediately()
            }
            .onChange(of: player.seekRevision) {
                // Seek is a hard timeline discontinuity. Re-evaluate the
                // highlighted lyric immediately instead of waiting for the
                // next 16 ms task iteration.
                synchronizeImmediately()
            }
            .task(id: synchronizationTrigger) {
                await synchronizeAtLyricTransitions()
            }
    }

    private var synchronizationTrigger: LyricSynchronizationTrigger {
        let advanceTime = settings.effectiveLyricsAdvanceTime(
            for: lyrics
        )
        return LyricSynchronizationTrigger(
            songID: player.currentSong?.id,
            seekRevision: player.seekRevision,
            isPlaying: player.isPlaying,
            advanceTime: advanceTime,
            lyricCount: lyrics.count,
            firstLyricID: lyrics.first?.id,
            lastLyricID: lyrics.last?.id
        )
    }

    private func synchronizeImmediately() {
        let advanceTime = settings.effectiveLyricsAdvanceTime(
            for: lyrics
        )
        let position = LyricPlaybackTimeline.position(
            at: player.estimatedProgress() + advanceTime,
            in: lyrics
        )
        updateHighlightedLyric(to: position.highlightedLyricID)
    }

    private func synchronizeAtLyricTransitions() async {
        let synchronizedLyrics = lyrics
        let advanceTime = settings.effectiveLyricsAdvanceTime(
            for: synchronizedLyrics
        )

        while !Task.isCancelled {
            let playbackTime = player.estimatedProgress(
                at: Date.now
            )
            let adjustedProgress = playbackTime + advanceTime
            let position = LyricPlaybackTimeline.position(
                at: adjustedProgress,
                in: synchronizedLyrics
            )
            updateHighlightedLyric(to: position.highlightedLyricID)

            guard player.isPlaying else { return }

            do {
                // Always derive the next state from the shared playback clock.
                // Never sleep until a lyric timestamp because rate changes,
                // buffering, pause/resume, and seeks can invalidate that wait.
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }
    }

    private func updateHighlightedLyric(to lyricID: LyricLine.ID?) {
        guard highlightedLyricID != lyricID else { return }
        highlightedLyricID = lyricID
    }
}

private struct LyricSynchronizationTrigger: Hashable {
    let songID: Int?
    let seekRevision: Int
    let isPlaying: Bool
    let advanceTime: TimeInterval
    let lyricCount: Int
    let firstLyricID: LyricLine.ID?
    let lastLyricID: LyricLine.ID?
}
