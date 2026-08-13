import LinkPresentation
import MXPrivateRuntime
import SwiftUI
import UIKit

/// Routes a fixed lyric selection to the runtime-verified Messages rich-link
/// path. If the complete private metadata graph or activity override is not
/// available, this renders the ordinary system share sheet unchanged.
struct LyricsShareSheet: View {
    let payload: LyricSharePayload
    let artwork: UIImage?
    let onComplete: (Bool) -> Void

    @State private var privateMetadata: LPLinkMetadata?
    @State private var canPreparePrivateActivity: Bool

    init(
        payload: LyricSharePayload,
        artwork: UIImage?,
        onComplete: @escaping (Bool) -> Void
    ) {
        self.payload = payload
        self.artwork = artwork
        self.onComplete = onComplete

        let metadata = AppleMusicLyricsShareMetadataFactory
            .makePrivateMetadata(payload: payload, artwork: artwork)
        _privateMetadata = State(initialValue: metadata)
        _canPreparePrivateActivity = State(
            initialValue: metadata != nil
                && MXCanUsePrivateLyricsActivityViewController()
        )
    }

    var body: some View {
        if let privateMetadata, canPreparePrivateActivity {
            PrivateLyricsActivitySheet(
                activityItems: activityItems,
                metadata: privateMetadata,
                onComplete: onComplete
            )
        } else {
            SystemShareSheet(
                activityItems: activityItems,
                onComplete: onComplete
            )
        }
    }

    private var activityItems: [Any] {
        [
            LyricShareURLActivityItemSource(
                payload: payload,
                artwork: artwork
            ),
            LyricShareTextActivityItemSource(payload: payload),
        ]
    }
}

private struct PrivateLyricsActivitySheet:
    UIViewControllerRepresentable
{
    let activityItems: [Any]
    let metadata: LPLinkMetadata
    let onComplete: (Bool) -> Void

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        let viewController =
            MXCreatePrivateLyricsActivityViewController(
                activityItems,
                metadata
            ) ?? UIActivityViewController(
                activityItems: activityItems,
                applicationActivities: nil
            )
        viewController.completionWithItemsHandler = {
            _, completed, _, _ in
            onComplete(completed)
        }
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
