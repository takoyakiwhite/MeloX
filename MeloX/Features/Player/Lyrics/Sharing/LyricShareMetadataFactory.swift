import LinkPresentation
import UIKit

enum LyricShareMetadataFactory {
    static func makeMetadata(
        payload: LyricSharePayload,
        artwork: UIImage?
    ) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        let firstLine = payload.lyrics.first?.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        metadata.title = if let firstLine, !firstLine.isEmpty {
            "歌词摘录：\(firstLine)"
        } else {
            "歌词摘录 · \(payload.song.name)"
        }
        metadata.url = payload.songURL
        metadata.originalURL = payload.songURL
        if let artwork {
            metadata.imageProvider = NSItemProvider(object: artwork)
        }
        return metadata
    }
}
