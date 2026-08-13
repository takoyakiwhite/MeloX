import SwiftUI
import UIKit

struct LyricsSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let store: LyricShareSelectionStore
    let isEmbeddedInActivityController: Bool

    @State private var replacementIndex: Int?
    @State private var sharePayload: LyricSharePayload?

    init(
        store: LyricShareSelectionStore,
        isEmbeddedInActivityController: Bool = false
    ) {
        self.store = store
        self.isEmbeddedInActivityController =
            isEmbeddedInActivityController
    }

    var body: some View {
        VStack(spacing: 0) {
            songHeader
            selectionSummary
            Divider()
            lyricsList
        }
        .background(.regularMaterial)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isEmbeddedInActivityController {
                shareControl
            }
        }
        .alert(
            "替换之前的选择？",
            isPresented: replacementAlertBinding
        ) {
            Button("替换", role: .destructive) {
                guard let replacementIndex else { return }
                store.replaceSelection(with: replacementIndex)
                self.replacementIndex = nil
            }
            Button("取消", role: .cancel) {
                replacementIndex = nil
            }
        } message: {
            Text(
                "这行歌词无法在 \(store.characterLimit) 个字符的限制内与当前选择一起分享。"
            )
        }
        .sheet(item: $sharePayload) { payload in
            LyricsShareSheet(
                payload: payload,
                artwork: store.artwork,
                onComplete: { completed in
                    sharePayload = nil
                    // The fallback is a two-stage flow. Match the embedded
                    // path's lifecycle by ending it after either completion
                    // or cancellation of the activity controller.
                    _ = completed
                    dismiss()
                }
            )
        }
    }

    private var songHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = store.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.presentation.song.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(store.presentation.song.artistText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(selectionTitle)
                .font(.title3.weight(.semibold))
            Text(selectionSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .animation(.smooth(duration: 0.22), value: store.selectedLineCount)
        .animation(
            .smooth(duration: 0.22),
            value: store.selectedCharacterCount
        )
    }

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.presentation.lyrics.indices, id: \.self) {
                        index in
                        let lyric = store.presentation.lyrics[index]
                        LyricsSelectionRow(
                            lyric: lyric,
                            state: store.rowState(at: index)
                        ) {
                            handleLyricTap(at: index)
                        }
                        .id(lyric.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 19)
            }
            .onAppear {
                proxy.scrollTo(
                    store.presentation.initialLyricID,
                    anchor: .center
                )
            }
        }
    }

    private var shareControl: some View {
        Button {
            sharePayload = store.payload
        } label: {
            Label(
                "分享歌词",
                systemImage: "square.and.arrow.up"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!store.canShare)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var selectionTitle: String {
        let count = store.selectedLineCount
        return count == 0 ? "未选择歌词" : "已选择 \(count) 行歌词"
    }

    private var selectionSubtitle: String {
        guard store.selectedLineCount > 0 else {
            return "轻点一行歌词以分享"
        }
        return "\(store.selectedCharacterCount) / \(store.characterLimit) 个字符"
    }

    private var replacementAlertBinding: Binding<Bool> {
        Binding(
            get: { replacementIndex != nil },
            set: { isPresented in
                if !isPresented {
                    replacementIndex = nil
                }
            }
        )
    }

    private func handleLyricTap(at index: Int) {
        switch store.tapLyric(at: index) {
        case .changed, .ignored:
            break
        case .requiresReplacement(let index):
            replacementIndex = index
        }
    }
}

private struct LyricsSelectionRow: View {
    let lyric: LyricLine
    let state: LyricsSelectionManager.RowState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(lyric.text)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .background {
                    if let position = selectionPosition {
                        selectionBackground(for: position)
                            .fill(Color.accentColor.opacity(0.2))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(state == .disabled)
        .opacity(state == .disabled ? 0.32 : 1)
        .accessibilityAddTraits(
            selectionPosition == nil ? [] : .isSelected
        )
    }

    private var selectionPosition:
        LyricsSelectionManager.SelectionPosition?
    {
        guard case .selected(let position) = state else { return nil }
        return position
    }

    private func selectionBackground(
        for position: LyricsSelectionManager.SelectionPosition
    ) -> UnevenRoundedRectangle {
        let radius: CGFloat = 16
        switch position {
        case .single:
            return UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: radius,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: radius
                ),
                style: .continuous
            )
        case .first:
            return UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: radius,
                    bottomLeading: 0,
                    bottomTrailing: 0,
                    topTrailing: radius
                ),
                style: .continuous
            )
        case .middle:
            return UnevenRoundedRectangle(
                cornerRadii: .init(),
                style: .continuous
            )
        case .last:
            return UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: 0,
                    bottomLeading: radius,
                    bottomTrailing: radius,
                    topTrailing: 0
                ),
                style: .continuous
            )
        }
    }
}
