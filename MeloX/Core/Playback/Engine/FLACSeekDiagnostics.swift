import AVFoundation

enum FLACSeekDiagnostics {
    static let acceptanceTolerance: Double = 0.025
    static let maximumRetryCount = 1

    static func needsRetry(currentTime: CMTime, target: CMTime) -> Bool {
        let current = currentTime.seconds
        let requested = target.seconds
        guard current.isFinite, requested.isFinite else { return true }
        return abs(current - requested) > acceptanceTolerance
    }
}
