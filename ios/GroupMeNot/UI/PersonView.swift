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
    /// Open a conversation: the DM with them, or one of the groups you share.
    /// Nil where there is nowhere to open one from.
    var onOpenDirect: ((ConversationRow) -> Void)?
    /// The conversation this profile was opened from, which is the one the
    /// shared-groups line names first. You are looking at somebody *here*, so
    /// here is the group worth naming.
    var openedFrom: ConversationID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var person: Person?
    @State private var isAddingToGroup = false
    @State private var isShowingShared = false
    @State private var viewing: PhotoTap?

    private var isMe: Bool { userID == model.currentUser?.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if !charms.isEmpty { chips }
                if !(person?.photos.isEmpty ?? true) { photos }
                if let anthem = person?.anthem { self.anthem(anthem) }
                if !(person?.sharedGroups.isEmpty ?? true) { shared }
                actions
                // Under the buttons, not above them. It is the least of what
                // this sheet says: a footnote about how long they have been
                // here, which belongs after the two things you might act on.
                if let joined = person?.since { self.joined(joined) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Stated, rather than left to the system.
        //
        // A sheet with no background of its own is drawn on the presentation's
        // material, and that material is not one thing: it is translucent while
        // the sheet is on its way up and opaque once it has settled, and the
        // swap happens a beat after the dimming behind it has finished. On a
        // `Form` or a `List` nobody sees it, because those paint their own
        // ground on the first frame. This sheet is a plain stack, so the swap
        // is the whole background of the thing changing colour in front of you.
        //
        // One colour from the first frame has nothing to swap to.
        .presentationBackground(Color(.systemBackground))
        .scrollBounceBehavior(.basedOnSize)
        .task {
            person = await model.person(userID, named: name, avatarURL: avatarURL)
        }
        .sheet(isPresented: $isAddingToGroup) {
            AddToGroupView(userID: userID, name: displayName)
        }
        .sheet(isPresented: $isShowingShared) {
            SharedGroupsView(groups: sharedGroups, name: displayName) { row in
                dismiss()
                onOpenDirect?(row)
            }
        }
    }

    private var displayName: String { person?.name ?? name }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(url: person?.avatarURL ?? avatarURL, name: displayName, size: 104)
            Text(displayName)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
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

    /// The pictures somebody has put on their profile.
    ///
    /// A grid rather than a strip: three across is how the official client draws
    /// them and it is the right call, because a row that scrolls sideways hides
    /// most of itself, and the whole point of these is that they are a set. Two
    /// rows of three, and no more — past six the sheet is a gallery with a name
    /// at the top rather than a profile.
    ///
    /// GroupMe shows the block only when there are more than two. That rule is
    /// not copied: one photo somebody chose to put up is still something they
    /// chose to put up.
    private var photos: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(Array(shownPhotos.enumerated()), id: \.element) { index, url in
                Button {
                    viewing = PhotoTap(index: index)
                } label: {
                    RemoteImage(url: URL(string: url), maxPixelSize: 360) {
                        Rectangle().fill(.quaternary)
                    }
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .contentShape(.rect(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo \(index + 1)")
            }
        }
        .fullScreenCover(item: $viewing) { tap in
            MediaViewer(
                attachments: shownPhotos.map { Message.Attachment(type: "image", url: $0) },
                initialIndex: tap.index)
        }
    }

    private static let photosShown = 6

    private var shownPhotos: [String] {
        Array((person?.photos ?? []).prefix(Self.photosShown))
    }

    /// Which photo is open. A box rather than an index because `fullScreenCover`
    /// wants something `Identifiable`, and index zero is a perfectly good answer.
    private struct PhotoTap: Identifiable {
        var index: Int
        var id: Int { index }
    }

    private func anthem(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anthem")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            AnthemRow(url: url, previews: model.previews)
        }
    }

    /// The groups you share, the one you are in first.
    ///
    /// Ordering rather than filtering: every group is still there, and still
    /// counted. A topic answers with its parent, which is the group you are
    /// actually both in.
    private var sharedGroups: [SharedGroup] {
        let all = person?.sharedGroups ?? []
        guard case .group(let here)? = openedFrom else { return all }
        let parent = model.conversations.first { $0.id == openedFrom }?.parentID ?? here
        guard let index = all.firstIndex(where: { $0.id == parent }) else { return all }
        var reordered = all
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    private var shared: some View {
        Button {
            isShowingShared = true
        } label: {
            sharedContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sharedSummary)
        .accessibilityHint("Shows every group you share")
    }

    private var sharedContent: some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(sharedLine)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                if let rest = otherShared {
                    Text(rest)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // Overlapped, and capped at five plus a count. A row of faces
            // shoulder to shoulder reads as a set — these belong together —
            // where evenly spaced circles read as a list that ran out of room.
            // The ring is the background colour cut into each face, which is
            // what stops the pile from becoming a smear.
            HStack(spacing: -Self.faceOverlap) {
                ForEach(Array(shownFaces.enumerated()), id: \.element.id) { index, group in
                    Avatar(url: group.avatarURL, name: group.name, size: Self.faceSize, isGroup: true)
                        .overlay {
                            Circle().strokeBorder(Color(.systemBackground), lineWidth: 2)
                        }
                        // First on top, so the pile reads left to right the way
                        // the sentence above it does.
                        .zIndex(Double(shownFaces.count - index))
                }
                if let extra = overflow {
                    Text("+\(extra)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.faceSize, height: Self.faceSize)
                        .background(.quaternary, in: .circle)
                        .overlay {
                            Circle().strokeBorder(Color(.systemBackground), lineWidth: 2)
                        }
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Five faces and then a number. Past that they are too small to be
    /// pictures of anything, and the count says the rest.
    private static let facesShown = 5
    private static let faceSize: CGFloat = 48
    /// How far each face sits over the one before it. A third of a face: enough
    /// to read as a pile, not so much that they stop being recognisable.
    private static let faceOverlap: CGFloat = 16

    private var shownFaces: [SharedGroup] {
        Array(sharedGroups.prefix(Self.facesShown))
    }

    private var overflow: Int? {
        let count = person?.sharedGroups.count ?? 0
        return count > Self.facesShown ? count - Self.facesShown : nil
    }

    /// Named rather than counted, because the name is the useful half: "you are
    /// both in Residents of Rivendell" places somebody, where "6 groups" does
    /// not.
    private var firstShared: String {
        sharedGroups.first?.name ?? ""
    }

    /// The name in the sentence, weighted. "You're both in" is the grammar; the
    /// group is the fact, and a line of even weight makes the reader find it for
    /// themselves.
    ///
    /// Built as an `AttributedString` rather than as markdown in a
    /// `LocalizedStringKey`, because the emphasised half is a group's name and
    /// names are not ours to parse: a group called `**hi**` would come out
    /// wearing somebody else's bold.
    private var sharedLine: AttributedString {
        var line = AttributedString("You're both in ")
        var name = AttributedString(firstShared)
        name.font = .title3.weight(.semibold)
        line.append(name)
        return line
    }

    private var otherShared: String? {
        let others = (person?.sharedGroups.count ?? 0) - 1
        guard others > 0 else { return nil }
        return others == 1 ? "and 1 other group" : "and \(others) other groups"
    }

    /// The whole sentence, for anybody listening rather than looking.
    private var sharedSummary: String {
        guard !firstShared.isEmpty else { return "" }
        return ["You're both in \(firstShared)", otherShared].compactMap { $0 }.joined(separator: " ")
    }

    private func joined(_ date: Date) -> some View {
        Label(
            "Joined \(date.formatted(.dateTime.month(.wide).year()))",
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

// MARK: - Shared groups

/// Every group two people are both in, as a list you can walk into.
///
/// The row on the profile shows five faces and a count, which answers "how
/// much do we overlap" and nothing else. This answers "which ones" — and since
/// each one is a conversation, each one opens.
private struct SharedGroupsView: View {
    let groups: [SharedGroup]
    /// Whose profile this came from, so the title says what the list is.
    let name: String
    let onOpen: (ConversationRow) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(groups) { group in
                let row = model.conversations.first { $0.id == .group(group.id) }
                Button {
                    guard let row else { return }
                    dismiss()
                    onOpen(row)
                } label: {
                    HStack(spacing: 12) {
                        Avatar(url: group.avatarURL, name: group.name, size: 38, isGroup: true)
                        Text(group.name)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if row != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // A group the server counts and this device has never listed
                // is a row with nowhere to go. Shown, because it is still an
                // answer to "which ones", and not offered as a tap.
                .disabled(row == nil)
            }
            .navigationTitle("You and \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemBackground))
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
