import CoreImage.CIFilterBuiltins
import SwiftUI

/// What is behind the chevron under the chat title.
///
/// A group gets its roster; a DM gets the one person it is with. Everything
/// here comes from what the model already holds, so the sheet is drawn on the
/// frame it is presented and never waits for a request.
struct ConversationInfoView: View {
    let conversation: ConversationRow
    let members: [Member]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var isInvitePresented = false
    @State private var isLeaving = false
    @State private var isDeleting = false
    @State private var removing: Member?

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }
                if let summary = conversation.summary, !summary.isEmpty {
                    Section("About") {
                        Text(summary)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let invite { share(invite) }
                if let created = conversation.createdAt {
                    Section {
                        LabeledContent("Created", value: created.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                if conversation.isGroup { settingsSection }
                // Above the roster, not below it. A group of forty puts forty
                // rows between the reader and the way out, which is the same as
                // not having one.
                //
                // Not for a topic: there is nothing to leave. Membership is the
                // parent group's, and "Delete Group" pointed at a topic id is
                // either a 404 or, much worse, not one.
                if conversation.isGroup, !isTopic { leaving }
                if !people.isEmpty { roster }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isInvitePresented) {
                InvitePeopleView(conversation: conversation, alreadyIn: members)
            }
            .confirmationDialog(
                "Leave \(conversation.name)?", isPresented: $isLeaving, titleVisibility: .visible
            ) {
                Button("Leave", role: .destructive) {
                    Task {
                        if await model.leave(conversation.id) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You stop receiving messages and the conversation is removed from this phone.")
            }
            .confirmationDialog(
                "Delete \(conversation.name)?", isPresented: $isDeleting, titleVisibility: .visible
            ) {
                Button("Delete for Everyone", role: .destructive) {
                    Task {
                        if await model.destroy(conversation.id) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The group and its messages are gone for every member. This cannot be undone.")
            }
            .confirmationDialog(
                removing.map { "Remove \(displayName($0))?" } ?? "",
                isPresented: .init(
                    get: { removing != nil },
                    set: { if !$0 { removing = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let member = removing {
                    Button("Remove", role: .destructive) {
                        removing = nil
                        Task { await model.remove(member, from: conversation.id) }
                    }
                    Button("Cancel", role: .cancel) { removing = nil }
                }
            }
        }
    }

    // MARK: Settings

    /// What this account may change here.
    ///
    /// Everyone gets their own nickname; the group's own name, picture,
    /// description and join rule are admin and owner only. Absent rather than
    /// disabled for a member, because a greyed-out row invites a tap and then
    /// explains nothing.
    private var settingsTitle: String {
        guard canEditGroup else { return "Your Nickname" }
        return isTopic ? "Topic Settings" : "Group Settings"
    }

    private var settingsSection: some View {
        Section("Settings") {
            NavigationLink {
                GroupSettingsView(conversation: conversation, myNickname: myNickname)
            } label: {
                Label(
                    settingsTitle,
                    systemImage: "slider.horizontal.3")
            }

            // Topics are made and listed from the group, so the group is where
            // the row for them belongs.
            if !isTopic, canEditGroup {
                NavigationLink {
                    NewTopicView(conversation: conversation)
                } label: {
                    Label("Add Topic", systemImage: "square.stack.3d.up.badge.a")
                }
            }

            // Only where it can be acted on, and only where it applies. A group
            // that lets anyone in has no queue to show, and a topic never does:
            // joining happens at the group.
            if canEditGroup, !isTopic, conversation.requiresApproval == true {
                NavigationLink {
                    JoinRequestsView(conversation: conversation)
                } label: {
                    Label("Join Requests", systemImage: "person.badge.clock")
                }
            }
        }
    }

    private var canEditGroup: Bool { model.role(in: conversation.id).canEditGroup }

    /// A topic borrows almost everything from its parent, so most of what this
    /// sheet offers has to be asked of the parent instead — or not offered.
    private var isTopic: Bool { conversation.isTopic }

    private var myNickname: String {
        guard let me = model.currentUser?.id,
              let mine = members.first(where: { $0.identity == me })
        else { return "" }
        return mine.nickname ?? mine.name ?? ""
    }

    // MARK: Invitations

    /// The join link, if this is a group we hold one for.
    private var invite: URL? {
        guard conversation.isGroup, let raw = conversation.shareURL else { return nil }
        return URL(string: raw)
    }

    /// Three ways to hand this group to somebody, which is three because they
    /// suit three different situations: a person across the table, a person in a
    /// another app, and a person you are already writing to.
    @ViewBuilder private func share(_ url: URL) -> some View {
        Section {
            if let code = Self.qrCode(for: url) {
                Image(uiImage: code)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                    .accessibilityLabel("Join code")
            }

            Button {
                isInvitePresented = true
            } label: {
                Label("Invite People", systemImage: "person.badge.plus")
            }

            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
            if conversation.requiresApproval == true {
                Label("New members need approval", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let question = conversation.joinQuestion, !question.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Joining asks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(question)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Share")
        }
    }

    /// Drawn here rather than fetched.
    ///
    /// GroupMe serves a `share_qr_code_url` and it is the obvious thing to use,
    /// which is exactly why it is not used: a code is what you show somebody
    /// standing next to you, and the two of you are as likely as not to be
    /// somewhere with no signal. Generating it from the link needs nothing but
    /// the link.
    ///
    /// `.none` interpolation on the way out, because a QR code enlarged with
    /// smoothing is a QR code with soft edges, and scanners want hard ones.
    private static func qrCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        // Medium correction. The link is short, so the extra redundancy costs
        // little and survives a thumb over one corner.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(
                url: conversation.avatarURL,
                name: conversation.name,
                size: 88,
                isGroup: conversation.isGroup
            )
            Text(conversation.name)
                .lineLimit(2)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var roster: some View {
        Section(conversation.isGroup ? "Members" : "Conversation") {
            ForEach(orderedPeople, id: \.identity) { member in
                HStack(spacing: 12) {
                    Avatar(url: member.imageUrl, name: displayName(member), size: 34)
                    Text(displayName(member))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let badge = role(of: member) {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .accessibilityElement(children: .combine)
                .contextMenu { memberActions(member) }
            }
        }
    }

    /// What an admin may do to somebody, and nothing at all for anyone else.
    ///
    /// A context menu rather than buttons on the row: removing a person is a
    /// deliberate act and should take a deliberate gesture, and the roster is
    /// mostly read rather than administered.
    @ViewBuilder private func memberActions(_ member: Member) -> some View {
        let isMe = member.identity == model.currentUser?.id
        if canEditGroup, !isMe {
            if model.role(in: conversation.id) == .owner {
                let isAdmin = member.canPostInAnnouncements
                Button {
                    Task { await model.setAdmin(!isAdmin, for: member, in: conversation.id) }
                } label: {
                    Label(
                        isAdmin ? "Remove as Admin" : "Make Admin",
                        systemImage: isAdmin ? "person.badge.minus" : "person.badge.shield.checkmark")
                }
            }
            Button(role: .destructive) {
                removing = member
            } label: {
                Label("Remove from Group", systemImage: "person.fill.xmark")
            }
        }
    }

    /// The way out.
    ///
    /// Two different things wearing similar words: leaving takes you out, and
    /// deleting ends the group for everybody. Only the owner is offered the
    /// second, and both ask first.
    private var leaving: some View {
        Section {
            Button(role: .destructive) { isLeaving = true } label: {
                Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
            }
            if model.role(in: conversation.id) == .owner {
                Button(role: .destructive) { isDeleting = true } label: {
                    Label("Delete Group", systemImage: "trash")
                }
            }
        }
    }

    // MARK: Content

    /// A DM has no roster worth listing, so the other person stands in for one.
    private var people: [Member] {
        guard members.isEmpty else { return members }
        guard !conversation.isGroup else { return [] }
        return [Member(id: nil, userId: conversation.id.storageKey, nickname: conversation.name, name: nil, imageUrl: conversation.avatarURL, roles: nil)]
    }

    private var subtitle: String? {
        guard conversation.isGroup else { return "Direct message" }
        guard let count = memberCount else { return "Group" }
        // With a ceiling, the interesting number is how much room is left, and
        // a group at 4,998 of 5,000 is a group that needs to know.
        if let max = conversation.maxMembers, max > 0 {
            return "\(count.formatted()) of \(max.formatted()) members"
        }
        return count == 1 ? "1 member" : "\(count) members"
    }

    /// Owner and admin, and nothing for everybody else. A badge on every row is
    /// a badge on no row.
    ///
    /// Roles first, because they are what the server actually maintains;
    /// `creator_user_id` is the fallback for a roster that arrived without them.
    private func role(of member: Member) -> String? {
        if let roles = member.roles {
            if roles.contains("owner") { return "Owner" }
            if roles.contains("admin") { return "Admin" }
            return nil
        }
        return member.identity == conversation.creatorUserID ? "Owner" : nil
    }

    /// Sorted so the people running the group are at the top of it.
    private var orderedPeople: [Member] {
        people.sorted { a, b in
            let rank = { (m: Member) -> Int in
                switch self.role(of: m) {
                case "Owner": 0
                case "Admin": 1
                default: 2
                }
            }
            guard rank(a) == rank(b) else { return rank(a) < rank(b) }
            return displayName(a).localizedCaseInsensitiveCompare(displayName(b)) == .orderedAscending
        }
    }

    private var memberCount: Int? {
        members.isEmpty ? conversation.memberCount : members.count
    }

    private func displayName(_ member: Member) -> String {
        member.nickname ?? member.name ?? "Someone"
    }
}
