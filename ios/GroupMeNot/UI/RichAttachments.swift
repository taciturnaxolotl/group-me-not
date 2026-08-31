import AVFoundation
import MapKit
import SwiftUI

// MARK: - Location

/// A shared place, drawn as the map it is.
///
/// Everything here comes off the attachment — `name`, `lat`, `lng` — so it needs
/// no request and works with the radio off; MapKit draws its tiles when it can
/// and its grid when it cannot. Tapping opens Maps, which is the only thing
/// anybody wants from a pin in a chat.
struct LocationCard: View {
    let attachment: Message.Attachment
    let isOwn: Bool

    private static let side = CGSize(width: 232, height: 132)

    var body: some View {
        if let coordinate {
            Button {
                open(coordinate)
            } label: {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                ))) {
                    Marker(attachment.name ?? "Location", coordinate: coordinate)
                }
                .disabled(true)
                .frame(width: Self.side.width, height: Self.side.height)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) { caption }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Location: \(attachment.name ?? "shared place")")
            .accessibilityHint("Opens in Maps")
        } else {
            AttachmentChip(
                symbol: "mappin.and.ellipse",
                title: attachment.name ?? "Location",
                isOwn: isOwn
            )
        }
    }

    @ViewBuilder private var caption: some View {
        if let name = attachment.name, !name.isEmpty {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: Self.side.width, alignment: .leading)
                .background(.black.opacity(0.45))
        }
    }

    /// The wire sends these as strings, which is why they are parsed rather than
    /// read, and why a malformed pair falls back to a chip instead of drawing a
    /// map of the Atlantic.
    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = attachment.lat.flatMap(Double.init),
              let lng = attachment.lng.flatMap(Double.init),
              (-90...90).contains(lat), (-180...180).contains(lng),
              !(lat == 0 && lng == 0)
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private func open(_ coordinate: CLLocationCoordinate2D) {
        let item = MKMapItem(location: CLLocation(
            latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        item.name = attachment.name ?? "Shared Location"
        item.openInMaps()
    }
}

// MARK: - Voice

/// A voice message, with a play button and a length.
///
/// Deliberately not a waveform. GroupMe sends no sample data, so a waveform here
/// would be a drawing of nothing, and the honest version of "how long is this"
/// is the number.
struct VoiceNote: View {
    let attachment: Message.Attachment
    let isOwn: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var observer: Any?

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isOwn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
                    .frame(width: 30, height: 30)
                    .background(isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor), in: .circle)

                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))

                Text(length)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOwn ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isOwn ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.quaternary),
                in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice message, \(length)")
        .onDisappear(perform: stop)
    }

    private var length: String {
        // `duration` is milliseconds on this attachment, unlike the seconds
        // every other timestamp in this API uses.
        guard let ms = attachment.duration, ms > 0 else { return "Voice" }
        let seconds = ms / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func toggle() {
        if isPlaying {
            stop()
            return
        }
        guard let raw = attachment.url, let url = URL(string: raw) else { return }
        let player = AVPlayer(url: url)
        // Playback should be heard even with the ring switch off, which is what
        // somebody tapping a play button is asking for.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
        self.player = player
        player.play()
        isPlaying = true
    }

    private func stop() {
        player?.pause()
        player = nil
        isPlaying = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

// MARK: - Polls

/// A poll, with its options and where the votes have gone.
///
/// The message carries only `poll_id`, so this fetches once and then follows the
/// model's copy. While it has nothing it draws the chip it replaced, which means
/// a poll whose shape this app has guessed wrong degrades to exactly what was
/// there before rather than to a hole.
struct PollCard: View {
    let attachment: Message.Attachment
    let isOwn: Bool

    @Environment(AppModel.self) private var model

    private var poll: Poll? {
        attachment.pollId.flatMap { model.polls[$0] }
    }

    var body: some View {
        SwiftUI.Group {
            if let poll {
                card(poll)
            } else {
                AttachmentChip(symbol: "chart.bar.fill", title: "Poll", isOwn: isOwn)
            }
        }
        .task(id: attachment.pollId) {
            guard let id = attachment.pollId else { return }
            await model.loadPoll(id)
        }
    }

    private func card(_ poll: Poll) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subject = poll.subject, !subject.isEmpty {
                Text(subject)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(poll.options ?? [], id: \.identity) { option in
                optionRow(option, in: poll)
            }

            Text(footnote(for: poll))
                .font(.caption2)
                .foregroundStyle(ink.opacity(0.8))
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(
            isOwn ? AnyShapeStyle(.white.opacity(0.15)) : AnyShapeStyle(.quaternary),
            in: .rect(cornerRadius: 12, style: .continuous))
        .foregroundStyle(ink)
    }

    private func optionRow(_ option: Poll.Option, in poll: Poll) -> some View {
        let mine = isMine(option, in: poll)
        let votes = option.votes
        let share = poll.totalVotes > 0 ? Double(votes ?? 0) / Double(poll.totalVotes) : 0
        return Button {
            choose(option, in: poll)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: mine ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                    Text(option.title ?? "Option")
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    // Only where there is a number. An anonymous poll sends no
                    // counts, and drawing "0" against every option would be
                    // reporting a result rather than withholding one.
                    if let votes {
                        Text("\(votes)")
                            .font(.caption.monospacedDigit())
                    }
                }
                if poll.showsResults {
                    // A bar rather than a percentage. The question a poll answers
                    // is which one is winning, and a row of numbers makes the
                    // reader work that out for themselves.
                    GeometryReader { geo in
                        Capsule()
                            .fill(ink.opacity(mine ? 0.55 : 0.25))
                            .frame(width: max(2, geo.size.width * share))
                    }
                    .frame(height: 4)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!poll.isOpen)
        .accessibilityLabel(option.title ?? "Option")
        .accessibilityValue(votes.map { "\($0) vote\($0 == 1 ? "" : "s")" } ?? "")
        .accessibilityAddTraits(mine ? [.isButton, .isSelected] : .isButton)
    }

    /// Whether this option is one of ours.
    ///
    /// An anonymous poll does not say, so a vote cast on this device is
    /// remembered by the model and answers for it. That is the whole truth
    /// available: nothing can show a vote cast from another device on a poll the
    /// server declines to attribute.
    private func isMine(_ option: Poll.Option, in poll: Poll) -> Bool {
        if poll.chose(option, as: model.currentUser?.id) { return true }
        guard let pollID = attachment.pollId, let id = option.id else { return false }
        return model.myVotes[pollID]?.contains(id) ?? false
    }

    private func footnote(for poll: Poll) -> String {
        var parts: [String] = []
        if poll.showsResults {
            let total = poll.totalVotes
            parts.append(total == 1 ? "1 vote" : "\(total) votes")
        } else {
            parts.append(poll.isOpen ? "Results hidden" : "Anonymous")
        }
        if !poll.isOpen {
            parts.append("Closed")
        } else if let closes = poll.closesAt, closes > .now {
            parts.append("Ends \(closes.formatted(.relative(presentation: .named)))")
        }
        if poll.allowsMultiple { parts.append("Pick several") }
        return parts.joined(separator: " · ")
    }

    private var ink: Color { isOwn ? .white : .primary }

    /// A single-choice poll replaces the vote; a multiple-choice one toggles the
    /// option, and unticking the last leaves an empty list, which is how the
    /// route says "no vote at all".
    private func choose(_ option: Poll.Option, in poll: Poll) {
        guard let pollID = attachment.pollId, let optionID = option.id else { return }
        var chosen: [String]
        if poll.allowsMultiple {
            chosen = (poll.options ?? [])
                .filter { isMine($0, in: poll) }
                .compactMap(\.id)
            if let index = chosen.firstIndex(of: optionID) {
                chosen.remove(at: index)
            } else {
                chosen.append(optionID)
            }
        } else {
            chosen = isMine(option, in: poll) ? [] : [optionID]
        }
        Task { await model.vote(chosen, in: pollID) }
    }
}
