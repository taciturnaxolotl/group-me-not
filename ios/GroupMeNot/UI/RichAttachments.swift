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

/// How narrow a card may get before it stops being usable.
///
/// A floor, not a width. Cards used to declare 272 points, which is wider than
/// the space left after an avatar, the padding and the bubble's gutter — so the
/// bubble grew past its row and pushed the sender's face off the screen. Asking
/// for all the available width and settling for whatever that is leaves the
/// layout to decide, which it is much better at.
private let cardMinWidth: CGFloat = 220

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

    private var box: PollBox? {
        attachment.pollId.flatMap { model.polls[$0] }
    }

    private var poll: Poll? { box?.data }

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
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(poll.options ?? [], id: \.identity) { option in
                optionRow(option, in: poll)
            }

            Text(footnote(for: poll))
                .font(.caption)
                .foregroundStyle(ink.opacity(0.8))
        }
        .padding(12)
        .frame(minWidth: cardMinWidth, maxWidth: .infinity, alignment: .leading)
        .background(
            isOwn ? AnyShapeStyle(.white.opacity(0.15)) : AnyShapeStyle(.quaternary),
            in: .rect(cornerRadius: 14, style: .continuous))
        .foregroundStyle(ink)
    }

    private func optionRow(_ option: Poll.Option, in poll: Poll) -> some View {
        let mine = isMine(option)
        let votes = option.tally
        let share = poll.totalVotes > 0 ? Double(votes) / Double(poll.totalVotes) : 0
        return Button {
            choose(option, in: poll)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: mine ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                    Text(option.title ?? "Option")
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(votes)")
                        .font(.subheadline.monospacedDigit())
                }
                // A bar rather than a percentage. The question a poll answers is
                // which one is winning, and a row of numbers makes the reader
                // work that out for themselves.
                GeometryReader { geo in
                    Capsule()
                        .fill(ink.opacity(mine ? 0.55 : 0.25))
                        .frame(width: max(3, geo.size.width * share))
                }
                .frame(height: 7)
            }
            // Every option is a tap target, so every option gets the room a tap
            // target needs. At caption size with four points of padding these
            // were half the height a finger expects.
            .padding(.vertical, 6)
            .frame(minHeight: 44, alignment: .center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!poll.isOpen)
        .accessibilityLabel(option.title ?? "Option")
        .accessibilityValue("\(votes) vote\(votes == 1 ? "" : "s")")
        .accessibilityAddTraits(mine ? [.isButton, .isSelected] : .isButton)
    }

    /// Whether this option is one of ours.
    ///
    /// An anonymous poll does not say, so a vote cast on this device is
    /// remembered by the model and answers for it. That is the whole truth
    /// available: nothing can show a vote cast from another device on a poll the
    /// server declines to attribute.
    /// Whether this option is one of ours.
    ///
    /// Straight from `user_votes`, which the server sends for every poll
    /// including the anonymous ones. An earlier version of this remembered votes
    /// locally because the poll body appeared not to say — it does say, one
    /// level up from where the poll itself lives.
    private func isMine(_ option: Poll.Option) -> Bool {
        guard let id = option.id else { return false }
        return box?.chosen.contains(id) ?? false
    }

    private func footnote(for poll: Poll) -> String {
        let total = poll.totalVotes
        var parts = [total == 1 ? "1 vote" : "\(total) votes"]
        // Worth saying, because it changes what a vote means to the person
        // casting it. It does not change what is shown: anonymous hides who
        // voted, never how many did.
        if poll.isAnonymous { parts.append("Anonymous") }
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
                .filter { isMine($0) }
                .compactMap(\.id)
            if let index = chosen.firstIndex(of: optionID) {
                chosen.remove(at: index)
            } else {
                chosen.append(optionID)
            }
        } else {
            chosen = isMine(option) ? [] : [optionID]
        }
        Task { await model.vote(chosen, in: pollID) }
    }
}

// MARK: - Events

/// An event, with the day it is on and a way to answer it.
///
/// The message carries only `event_id` and a `view` hint, so this fetches once
/// and follows the model. Times come off the wire as ISO 8601 strings rather
/// than the epoch seconds the rest of this API uses, which is handled in
/// `GroupEvent` so nothing here has to know.
struct EventCard: View {
    let attachment: Message.Attachment
    let isOwn: Bool

    @Environment(AppModel.self) private var model

    private var event: GroupEvent? {
        attachment.eventId.flatMap { model.events[$0] }
    }

    var body: some View {
        SwiftUI.Group {
            if let event {
                card(event)
            } else {
                AttachmentChip(
                    symbol: "calendar",
                    title: attachment.name ?? "Event",
                    isOwn: isOwn
                )
            }
        }
        .task(id: attachment.eventId) {
            guard let id = attachment.eventId else { return }
            await model.loadEvent(id)
        }
    }

    private func card(_ event: GroupEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let starts = event.starts { datePlaque(starts) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name ?? "Event")
                        .font(.headline)
                        .lineLimit(2)
                    if let when = timeLine(event) {
                        Text(when)
                            .font(.subheadline)
                            .foregroundStyle(ink.opacity(0.75))
                    }
                    if let place = event.location?.name, !place.isEmpty {
                        Label(place, systemImage: "mappin")
                            .font(.subheadline)
                            .foregroundStyle(ink.opacity(0.75))
                            .lineLimit(1)
                    }
                }
            }

            if let detail = event.description, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.8))
                    .lineLimit(3)
            }

            replies(event)
        }
        .padding(12)
        .frame(minWidth: cardMinWidth, maxWidth: .infinity, alignment: .leading)
        .background(
            isOwn ? AnyShapeStyle(.white.opacity(0.15)) : AnyShapeStyle(.quaternary),
            in: .rect(cornerRadius: 14, style: .continuous))
        .foregroundStyle(ink)
    }

    /// A calendar tear-off. It is the one part of an event a reader takes in
    /// without reading, which is worth more here than a fourth line of text.
    private func datePlaque(_ date: Date) -> some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.caption.weight(.bold))
            Text(date.formatted(.dateTime.day()))
                .font(.title2.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(isOwn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white))
        .frame(width: 54, height: 54)
        .background(
            isOwn ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor),
            in: .rect(cornerRadius: 11, style: .continuous))
    }

    private func timeLine(_ event: GroupEvent) -> String? {
        guard let starts = event.starts else { return nil }
        if event.isAllDay == true {
            return starts.formatted(.dateTime.weekday(.wide).month().day())
        }
        return starts.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute())
    }

    private func replies(_ event: GroupEvent) -> some View {
        let mine = event.reply(from: model.currentUser?.id)
        return HStack(spacing: 8) {
            button("Going", isOn: mine == .going) { answer(true, to: event) }
            button("Can't", isOn: mine == .notGoing) { answer(false, to: event) }
            Spacer(minLength: 0)
            if let count = event.goingCount, count > 0 {
                Text("\(count) going")
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.7))
            }
        }
    }

    private func button(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(
                    isOn ? AnyShapeStyle(ink.opacity(0.28)) : AnyShapeStyle(ink.opacity(0.10)),
                    in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// Answering the same way twice is not a toggle: there is no "un-RSVP" on
    /// this route, and the way out is a separate delete this app does not offer
    /// yet. So a second tap on the same answer does nothing rather than
    /// pretending to withdraw it.
    private func answer(_ going: Bool, to event: GroupEvent) {
        guard let id = attachment.eventId else { return }
        let mine = event.reply(from: model.currentUser?.id)
        guard mine != (going ? .going : .notGoing) else { return }
        Task { await model.rsvp(going, to: id) }
    }

    private var ink: Color { isOwn ? .white : .primary }
}
