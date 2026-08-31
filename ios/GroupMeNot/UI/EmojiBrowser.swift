import SwiftUI

/// The whole emoji set, searchable, for when the quick row is not enough.
///
/// Raised from the reaction bar's More button. Everything here is local: the
/// catalog is derived from the Unicode tables in the OS (see ``EmojiCatalog``),
/// so the grid is the same with the radio off as with it on.
struct EmojiBrowser: View {
    /// Drawn selected, and the one already on the message.
    var selected: String?
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [EmojiEntry] = []

    @ScaledMetric(relativeTo: .title2) private var slot: CGFloat = 44

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: slot), spacing: 4)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(entries) { entry in
                        Button { onPick(entry.glyph) } label: {
                            Text(entry.glyph)
                                .font(.system(size: slot * 0.62))
                                .frame(width: slot, height: slot)
                                .background {
                                    if entry.glyph == selected {
                                        Circle().fill(Color.accentColor.opacity(0.22))
                                    }
                                }
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.name)
                        .accessibilityAddTraits(entry.glyph == selected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if entries.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .padding(.top, 40)
                }
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "Search emoji")
        }
        // Keyed on the query, so typing cancels the search it has moved past.
        // The first pass is also the one that builds the catalog, which is why
        // it happens here rather than in `body`: the grid draws empty for a
        // frame instead of the sheet hanging on the derivation.
        .task(id: query) {
            let found = await EmojiCatalog.shared.search(query)
            guard !Task.isCancelled else { return }
            entries = found
        }
    }
}
