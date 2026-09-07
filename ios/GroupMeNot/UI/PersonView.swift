import SwiftUI

/// Somebody a sheet is about to be opened for.
///
/// The id is the whole identity; the name and the face are what the caller
/// already had on screen, carried across so the sheet opens with something on it
/// rather than filling in a moment later.
nonisolated struct PersonRef: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var avatarURL: String?
}

/// Who somebody is, in one sheet.
///
/// Reached from a face: an avatar in the transcript, or a row in a roster. That
/// is the whole point of it — a name and a picture are what a group gives you,
/// and everything else about the person is a tap away and nowhere else.
///
/// Opens with whatever the caller already knew, and fills the rest in. Nothing
/// here is load-bearing: a person with no interests, no anthem, no shared groups
/// and no presence is a face, a name and two buttons, which is a perfectly good
/// sheet.
struct PersonView: View {
    let userID: String
    /// What the roster or the transcript already knows, so the sheet has a name
    /// on it from the first frame.
    var name: String
    var avatarURL: String?
    /// Open a DM with them. Nil where there is nowhere to open one from.
    var onOpenDirect: ((ConversationRow) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var person: Person?
    @State private var isAddingToGroup = false

    private var isMe: Bool { userID == model.currentUser?.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if !charms.isEmpty { chips }
                if let anthem = person?.anthem { self.anthem(anthem) }
                if !(person?.sharedGroups.isEmpty ?? true) { shared }
                if let since = person?.since { self.since(since) }
                actions
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .task {
            person = await model.person(userID, named: name, avatarURL: avatarURL)
        }
        .sheet(isPresented: $isAddingToGroup) {
            AddToGroupView(userID: userID, name: displayName)
        }
    }

    private var displayName: String { person?.name ?? name }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(url: person?.avatarURL ?? avatarURL, name: displayName, size: 104)
                // The status rides on the face rather than standing beside it,
                // which is what makes it read as a fact about the person and not
                // as another line of the sheet.
                .overlay(alignment: .bottomTrailing) { presenceBadge }
            Text(displayName)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let summary = person?.presence?.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let bio = person?.bio {
                Text(bio)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .animation(.snappy(duration: 0.2), value: person)
        .accessibilityElement(children: .combine)
    }

    /// A dot for here, a moon for idle, and nothing at all for away: an
    /// indicator that is always lit says nothing, and "offline" is mostly "has
    /// not opened GroupMe lately" rather than news about a person.
    @ViewBuilder private var presenceBadge: some View {
        switch person?.presence?.status {
        case .online:
            Circle()
                .fill(.green)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
        case .away:
            Image(systemName: "moon.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .padding(4)
                .background(Color(.systemBackground), in: .circle)
        case .offline, nil:
            EmptyView()
        }
    }

    /// The school first, then whatever they picked. The school is the one chip
    /// nobody chose and everybody in a campus group reads first.
    private var charms: [InterestCharm] {
        let school = person?.school.map { InterestCharm(id: -1, glyph: "🎓", name: $0) }
        return (school.map { [$0] } ?? []) + (person?.charms ?? [])
    }

    private var chips: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(charms) { charm in
                HStack(spacing: 6) {
                    Text(charm.glyph)
                    Text(charm.name)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary, in: .capsule)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func anthem(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anthem")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            AnthemRow(url: url, previews: model.previews)
        }
    }

    private var shared: some View {
        VStack(spacing: 8) {
            Text(sharedSummary)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach((person?.sharedGroups ?? []).prefix(Self.facesShown)) { group in
                    Avatar(url: group.avatarURL, name: group.name, size: 44, isGroup: true)
                }
                if let extra = overflow {
                    Text("+\(extra)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: .circle)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sharedSummary)
    }

    private static let facesShown = 5

    private var overflow: Int? {
        let count = person?.sharedGroups.count ?? 0
        return count > Self.facesShown ? count - Self.facesShown : nil
    }

    /// Named rather than counted, because the name is the useful half: "you are
    /// both in Residents of Rivendell" places somebody, where "6 groups" does
    /// not.
    private var sharedSummary: String {
        let groups = person?.sharedGroups ?? []
        guard let first = groups.first else { return "" }
        let others = groups.count - 1
        switch others {
        case 0: return "You're both in \(first.name)"
        case 1: return "You're both in \(first.name) and 1 other group"
        default: return "You're both in \(first.name) and \(others) other groups"
        }
    }

    private func since(_ date: Date) -> some View {
        Label(
            "Since \(date.formatted(.dateTime.month(.wide).year()))",
            systemImage: "calendar")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if !isMe {
                Button {
                    isAddingToGroup = true
                } label: {
                    // `lineLimit` on the label, not the button. Left to itself
                    // "Add to Group" wraps onto two lines inside a capsule sized
                    // for one, and a button half a line taller than the one
                    // beside it is the first thing the eye finds on the sheet.
                    Label("Add to Group", systemImage: "person.badge.plus")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let onOpenDirect {
                    Button {
                        let id = ConversationID.direct(otherUserID: userID)
                        let row = model.conversations.first { $0.id == id }
                            ?? .direct(
                                with: userID, name: displayName,
                                avatarURL: person?.avatarURL ?? avatarURL)
                        dismiss()
                        onOpenDirect(row)
                    } label: {
                        Label("Send DM", systemImage: "bubble.left")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Anthem

/// The song somebody pinned to their profile.
///
/// Not the card a link in a message gets. That one is 232 points wide with the
/// picture on top, which is right for a bubble it has to sit inside and wrong
/// for a sheet, where it reads as a screenshot somebody pasted. A song is a row:
/// art, title, who by, full width, and the whole of it is the tap target.
///
/// Everything is drawn from the same preview service the transcript uses, so a
/// song already seen in a message costs nothing here.
private struct AnthemRow: View {
    let url: URL
    let previews: LinkPreviewService?

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview: LinkPreview?

    private static let art: CGFloat = 62

    var body: some View {
        Button {
            openURL(preview?.canonicalURL ?? url)
        } label: {
            HStack(spacing: 12) {
                RemoteImage(url: preview?.imageURL, maxPixelSize: Self.art * 3) {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: Self.art, height: Self.art)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? url.host() ?? "Anthem")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let detail = preview?.summary ?? preview?.siteName {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: colorScheme) {
            preview = await previews?.preview(for: url, dark: colorScheme == .dark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preview?.title.map { "Anthem, \($0)" } ?? "Anthem")
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - Add to group

/// Put somebody in one of your groups.
///
/// Only groups, and only ones this account is actually in: a topic takes its
/// membership from its parent and has nothing to add anybody to.
private struct AddToGroupView: View {
    let userID: String
    let name: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List(groups) { group in
                Button {
                    add(to: group)
                } label: {
                    HStack(spacing: 12) {
                        Avatar(url: group.avatarURL, name: group.name, size: 34, isGroup: true)
                        Text(group.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if working == group.id.storageKey { ProgressView() }
                    }
                }
                .buttonStyle(.plain)
                .disabled(working != nil)
            }
            .navigationTitle("Add \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No Groups", systemImage: "person.3",
                        description: Text("Groups you are in appear here."))
                }
            }
            .alert("Could not add them", isPresented: .init(
                get: { failure != nil }, set: { if !$0 { failure = nil } })
            ) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                if let failure { Text(failure) }
            }
        }
    }

    private var groups: [ConversationRow] {
        model.conversations.filter { $0.isGroup && !$0.isTopic }
    }

    private func add(to group: ConversationRow) {
        guard case .group(let groupID) = group.id else { return }
        working = group.id.storageKey
        Task {
            let ok = await model.invite(
                [.init(userId: userID, nickname: name)], to: groupID)
            working = nil
            if ok {
                dismiss()
            } else {
                failure = "GroupMe would not take that. You may not be able to add "
                    + "people to \(group.name)."
            }
        }
    }
}

// MARK: - Chips

/// Rows of things that wrap, sized to what they are rather than to a grid.
///
/// A `LazyVGrid` was the alternative and it is the wrong shape: every column
/// there is the same width, so "Bass" gets as much room as "Cedarville 2030"
/// and the row reads as a table of oddly padded pills. Chips want to be their
/// own width and to wrap when they run out of line, which is a paragraph, and
/// this is the smallest layout that does one.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = wrap(subviews, within: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in wrap(subviews, within: bounds.width) {
            // Centred, which is what the chips want: a last row of two left
            // against the edge under a full row above reads as a mistake.
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrap(_ subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(index)
                row.width = next
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
