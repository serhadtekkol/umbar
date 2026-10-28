import SwiftUI
import AppKit
import Defaults

struct DragPreviewView: View {
    let thumbnail: NSImage?
    let displayName: String
    /// Whether a drop on Finder moves the file (Settings: remove items after
    /// dragging). Only then does "⌥: kopyala" say something true.
    var showsCopyRule: Bool = Defaults[.autoRemoveShelfItems]

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            Image(nsImage: thumbnail ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                .frame(alignment: .top)

            // The rule, not the outcome (design-language §5.3, card #101):
            // the image is drawn once when the drag starts, so it cannot know
            // where the drop will land; the system cursor shows the operation.
            if showsCopyRule {
                Text(String(localized: "shelf.drag.copyRule", defaultValue: "⌥: copy"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PageTokens.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(PageTokens.raisedStrong))
            }
        }
        .frame(width: 105)
    }
}
