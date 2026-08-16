from pathlib import Path

path = Path('MeloX/Core/Playback/Session/PlayerStore.swift')
text = path.read_text(encoding='utf-8')

property_marker = '''    @ObservationIgnored
    private var currentLoadShouldAutoplay = false
'''
property_addition = property_marker + '''
    @ObservationIgnored
    private var playbackRecoveryTask: Task<Void, Never>?

    @ObservationIgnored
    private var playbackRecoveryAttempt = 0
'''
if 'private var playbackRecoveryTask:' not in text:
    if property_marker not in text:
        raise SystemExit('PlayerStore property marker not found')
    text = text.replace(property_marker, property_addition, 1)

start = text.index('    private func handleEngineFailure(_ error: Error) async {')
end = text.index('\n    private func stopAtQueueEnd()', start)

replacement = '''    private func schedulePlaybackRecovery() {
        guard let song = currentSong,
              currentLoadShouldAutoplay else {
            return
        }

        playbackRecoveryTask?.cancel()
        playbackRecoveryAttempt = min(playbackRecoveryAttempt + 1, 5)
        let initialAttempt = playbackRecoveryAttempt

        playbackIssue = nil
        isLoading = true
        isPlaying = false
        updateNowPlayingState()

        playbackRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = initialAttempt

            while !Task.isCancelled {
                let delayNanoseconds: UInt64
                switch attempt {
                case 1: delayNanoseconds = 500_000_000
                case 2: delayNanoseconds = 1_000_000_000
                case 3: delayNanoseconds = 2_000_000_000
                case 4: delayNanoseconds = 4_000_000_000
                case 5: delayNanoseconds = 8_000_000_000
                default: delayNanoseconds = 30_000_000_000
                }

                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    break
                }

                guard !Task.isCancelled,
                      self.currentSong?.id == song.id,
                      self.currentLoadShouldAutoplay else {
                    break
                }

                self.playbackRecoveryAttempt = attempt
                await self.loadCurrentSong(
                    autoplay: true,
                    startAt: self.estimatedProgress()
                )

                guard !Task.isCancelled,
                      self.currentSong?.id == song.id,
                      self.currentLoadShouldAutoplay else {
                    break
                }

                if self.engine.hasCurrentItem,
                   self.engine.expectsPlaybackToContinue,
                   self.playbackIssue == nil {
                    self.playbackRecoveryAttempt = 0
                    self.playbackRecoveryTask = nil
                    return
                }

                attempt = min(attempt + 1, 6)
            }

            self.playbackRecoveryTask = nil
        }
    }

    private func handleEngineFailure(_ error: Error) async {
        if let playbackError = error as? AudioPlaybackError,
           case .itemFailed = playbackError,
           isUsingDownloadedSource,
           let song = currentSong {
            let resumePosition = estimatedProgress()
            let shouldAutoplay = currentLoadShouldAutoplay
            isUsingDownloadedSource = false
            downloads.discardInvalidDownload(songID: song.id)
            await loadCurrentSong(
                autoplay: shouldAutoplay,
                startAt: resumePosition
            )
            return
        }

        if let playbackError = error as? AudioPlaybackError,
           case .itemFailed = playbackError,
           currentSong != nil,
           currentLoadShouldAutoplay {
            schedulePlaybackRecovery()
            return
        }

        if let song = currentSong {
            playbackIssue = PlaybackIssue(song: song, error: error)
        }
        isLoading = false
        isPlaying = false
        updateNowPlayingState()

        if let playbackError = error as? AudioPlaybackError,
           case .itemFailed = playbackError {
            engine.unload()
        }
        persistSnapshot()
    }
'''

text = text[:start] + replacement + text[end:]

pause_old = '''            if isPlaying {
                engine.pause()
                persistSnapshot()
            } else {'''
pause_new = '''            if isPlaying {
                playbackRecoveryTask?.cancel()
                playbackRecoveryTask = nil
                playbackRecoveryAttempt = 0
                currentLoadShouldAutoplay = false
                engine.pause()
                persistSnapshot()
            } else {'''
if pause_old not in text:
    raise SystemExit('togglePlayback pause block not found')
text = text.replace(pause_old, pause_new, 1)

if r'\n    private func schedulePlaybackRecovery()' in text:
    raise SystemExit('escaped recovery block detected')
if text.count('private func schedulePlaybackRecovery()') != 1:
    raise SystemExit('schedulePlaybackRecovery count invalid')
if text.count('private func handleEngineFailure(_ error: Error) async') != 1:
    raise SystemExit('handleEngineFailure count invalid')

path.write_text(text, encoding='utf-8')
print('Playback recovery patch prepared successfully')
