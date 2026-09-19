import SwiftUI

/// A GroupMe share link, drawn as the invitation it is.
///
/// Left alone it is a link to a web page whose entire purpose is to talk the
/// reader into installing the official client, and the group it points at is
/// one they can already join from here. So the transcript answers the link
/// itself: join, or open the group if this is one they are already in.
///
/// Deliberately not a link preview. The URL preview endpoint would describe the
/// landing page rather than the group, and "GroupMe — Group Messaging" over a
/// stock photograph tells the reader nothing they did not know. The group's own
/// preview endpoint is the one worth asking, and it answers with the name,
/// the picture, the size, and whether joining waits on an admin.
struct InviteCard: View {
    let link: GroupMeLink
    /// Matched to the bubble it sits in, like the link card next to it.
    let isOwn: Bool
    /// Called with the conversation to open, once there is one.
    var onOpen: (ConversationRow) -> Void = { _ in }

    @Environment(AppModel.self) private var model

    /// Where the card is in the one journey it can make.
    private enum Phase {
        case waiting
        case joining
        /// Asked, and now waiting on an admin. A terminal state: there is
        /// nothing further to tap until somebody else acts.
        case pending
        case failed
    }

    @State private var phase: Phase = .waiting
    /// What the link points at, once the server has said. Nil until then, and
    /// for a link that has expired.
    @State private var preview: Group?
    /// The group's question, while it is being put to the reader.
    @State private var asking: Group.JoinQuestion??
    @State private var answer = ""

    /// Same width as a link preview, so a bubble carrying either has one edge.
    private static let width: CGFloat = 232
    private static let corner: CGFloat = 18

    /// Set when this is a group we are already in, which turns the whole card
    /// from an invitation into a door.
    private var joined: ConversationRow? {
        model.conversations.first { $0.id == link.conversation }
    }

    /// What to call the group. The list wins over the preview: a nickname this
    /// account gave it is the name it is known by here.
    private var name: String {
        joined?.name ?? preview?.name ?? "Group Invite"
    }

    var body: some View {
        Button(action: act) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.75))
                                               : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                if phase == .joining {
                    ProgressView()
                } else if phase != .pending {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.6))
                                               : AnyShapeStyle(.tertiary))
                }
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: Self.width)
            .background(tint)
            .clipShape(.rect(cornerRadius: Self.corner, style: .continuous))
            .contentShape(.rect(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(phase == .joining || phase == .pending || (joined == nil && model.hasAsked(toJoin: link)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(joined.map { "Open \($0.name)" } ?? "Join \(name)")
        .accessibilityAddTraits(.isButton)
        // Once per link per session; the model caches the answer, misses
        // included, so a recycled row costs nothing.
        .task { preview = await model.invitePreview(link) }
        // A group may ask one question before it lets anybody in, and refuses
        // the join outright until it is answered. One line of text, so one
        // alert: a sheet for a single field would be a room built for a chair.
        .alert(asking.flatMap { $0?.text } ?? "Answer to join", isPresented: .init(
            get: { asking != nil },
            set: { if !$0 { asking = nil } }
        )) {
            TextField("Answer", text: $answer)
            Button("Cancel", role: .cancel) { phase = .waiting }
            Button("Join") { submit(answer) }
        } message: {
            Text("\(name) asks this of everybody joining.")
        }
    }

    /// The group's own picture once the preview has arrived, and a glyph before
    /// that. Same circle either way, so the card does not resize under itself
    /// when the image lands.
    @ViewBuilder private var icon: some View {
        if let image = joined?.avatarURL ?? preview?.imageUrl, !image.isEmpty {
            Avatar(url: image, name: name, size: 34, isGroup: true)
        } else {
            Image(systemName: joined == nil ? "person.badge.plus" : "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(
                    isOwn ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.quaternary),
                    in: .circle)
        }
    }

    private var subtitle: String {
        switch phase {
        case .failed: return "That link did not work. It may have expired."
        case .joining: return "Joining…"
        case .pending: return "Asked to join. An admin has to say yes."
        case .waiting: break
        }
        if joined != nil { return "You are already in this group" }
        // Survives the view, and the launch. A request already filed is a fact
        // about the account rather than about this card, so a rebuilt row says
        // "waiting" instead of offering a knock that has already been made.
        if model.hasAsked(toJoin: link) { return "Asked to join. An admin has to say yes." }
        // Deliberately not a prediction. A group carrying `requires_approval`,
        // and a join question besides, let an account straight in with no
        // answer sent, so a card promising "needs approval" would have been
        // wrong about the one thing it claimed to know. It says what the group
        // is; what the join came to is said afterwards.
        guard let members else { return "Tap to join" }
        return "\(members) members · tap to join"
    }

    /// Only worth printing when it is a real count. A group of one is a group
    /// nobody has joined yet, and "1 members" reads as a bug either way.
    private var members: String? {
        guard let count = preview?.membersCount, count > 1 else { return nil }
        return count.formatted(.number)
    }

    /// The bubble's own fill, a shade quieter, so the card belongs to the
    /// message rather than sitting on the transcript.
    private var tint: AnyShapeStyle {
        isOwn ? AnyShapeStyle(Color.accentColor.opacity(0.85))
              : AnyShapeStyle(Color(.tertiarySystemFill))
    }

    private func act() {
        if let joined {
            onOpen(joined)
            return
        }
        submit(nil)
    }

    /// Knock, with the group's question answered when it asked one.
    private func submit(_ answer: String?) {
        phase = .joining
        Task {
            switch await model.join(link, answer: answer) {
            case .joined(let conversation):
                guard let row = model.conversations.first(where: { $0.id == conversation })
                else {
                    phase = .failed
                    return
                }
                phase = .waiting
                onOpen(row)
            case .pending:
                phase = .pending
            case .needsAnswer(let question):
                // Double-wrapped on purpose: the outer layer is "are we
                // asking", the inner one is "did the server say what to ask".
                // A group can want an answer without saying to what.
                phase = .waiting
                asking = .some(question)
            case .failed:
                phase = .failed
            }
        }
    }
}
