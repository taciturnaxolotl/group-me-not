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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }
                if let invite { share(invite) }
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
        }
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
                VStack(spacing: 10) {
                    Image(uiImage: code)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("Join code")
                    Text("Point a camera at this to join")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
            }

            ShareLink(item: url) {
                Label("Invite People", systemImage: "person.badge.plus")
            }

            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("Copy Link", systemImage: "link")
            }
        } header: {
            Text("Share")
        } footer: {
            Text("Anyone with this link can join.")
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
            ForEach(people, id: \.identity) { member in
                HStack(spacing: 12) {
                    Avatar(url: member.imageUrl, name: displayName(member), size: 34)
                    Text(displayName(member))
                        .lineLimit(1)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
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
        return count == 1 ? "1 member" : "\(count) members"
    }

    private var memberCount: Int? {
        members.isEmpty ? conversation.memberCount : members.count
    }

    private func displayName(_ member: Member) -> String {
        member.nickname ?? member.name ?? "Someone"
    }
}
