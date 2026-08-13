import LinkPresentation
import MXPrivateRuntime
import UIKit

/// Builds the lyric-aware LinkPresentation specialization observed in Music.
/// The private graph is all-or-nothing: a missing class, selector, changed ABI,
/// or Objective-C exception discards every candidate object and returns a
/// newly-created public metadata object instead.
enum AppleMusicLyricsShareMetadataFactory {
    static func makeMetadata(
        payload: LyricSharePayload,
        artwork: UIImage?
    ) -> LPLinkMetadata {
        if let enrichedMetadata = makePrivateMetadata(
            payload: payload,
            artwork: artwork
        ) {
            return enrichedMetadata
        }
        return makePublicMetadata(payload: payload, artwork: artwork)
    }

    /// This is also the capability gate for any future embedded private share
    /// controller. A selector probe alone is insufficient; a complete excerpt
    /// and specialization must be constructed successfully for this payload.
    static func makePrivateMetadata(
        payload: LyricSharePayload,
        artwork: UIImage?
    ) -> LPLinkMetadata? {
        guard let timingRange = payload.excerptRange,
              let excerpt = MXTryCreatePrivateInstance(
                "LPLyricExcerptMetadata"
              ) as? NSObject,
              setObject(
                payload.originalLyricsText as NSString,
                selector: "setLyrics:",
                on: excerpt
              ),
              setObject(
                NSNumber(value: timingRange.lowerBound),
                selector: "setStartTime:",
                on: excerpt
              ),
              setObject(
                NSNumber(value: timingRange.upperBound),
                selector: "setEndTime:",
                on: excerpt
              ),
              let songMetadata = MXTryCreatePrivateInstance(
                "LPiTunesMediaSongMetadata"
              ) as? NSObject,
              setObject(
                payload.song.name as NSString,
                selector: "setName:",
                on: songMetadata
              ),
              setObject(
                payload.song.artistText as NSString,
                selector: "setArtist:",
                on: songMetadata
              ),
              setOptionalAlbum(payload.song.album?.name, on: songMetadata),
              setObject(
                ["subscription"] as NSArray,
                selector: "setOffers:",
                on: songMetadata
              ),
              setOptionalPrivateArtwork(artwork, on: songMetadata),
              setObject(
                excerpt,
                selector: "setLyricExcerpt:",
                on: songMetadata
              ) else {
            return nil
        }

        let metadata = makePublicMetadata(
            payload: payload,
            artwork: artwork
        )
        guard setObject(
            payload.originalLyricsText as NSString,
            selector: "setSelectedText:",
            on: metadata
        ), setObject(
            songMetadata,
            selector: "setSpecialization:",
            on: metadata
        ) else {
            return nil
        }
        return metadata
    }

    private static func makePublicMetadata(
        payload: LyricSharePayload,
        artwork: UIImage?
    ) -> LPLinkMetadata {
        // Always allocate this fallback afresh. A partially configured private
        // metadata object must never escape into UIKit as ordinary song share.
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

    private static func setOptionalAlbum(
        _ album: String?,
        on songMetadata: NSObject
    ) -> Bool {
        guard let album = album?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !album.isEmpty else {
            return true
        }
        return setObject(
            album as NSString,
            selector: "setAlbum:",
            on: songMetadata
        )
    }

    private static func setOptionalPrivateArtwork(
        _ artwork: UIImage?,
        on songMetadata: NSObject
    ) -> Bool {
        guard let artwork,
              let privateImage = MXTryCreatePrivatePlatformImage(
                artwork
              ) as? NSObject else {
            // LPImage is optional. Public LPLinkMetadata still carries the
            // image provider when this private class or initializer is gone.
            return true
        }
        return setObject(
            privateImage,
            selector: "setArtwork:",
            on: songMetadata
        )
    }

    private static func setObject(
        _ value: NSObject,
        selector: String,
        on object: NSObject
    ) -> Bool {
        MXTrySetPrivateObject(object, selector, value)
    }
}
