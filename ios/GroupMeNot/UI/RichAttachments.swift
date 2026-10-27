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
    @State private var isShowingVoters = false

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

    /// The question, a line saying what kind of poll it is, the options, and
    /// one button for the full breakdown. Everything else that used to sit in
    /// a dotted footnote either moved into those or was not earning its line.
    private func card(_ poll: Poll) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let subject = poll.subject, !subject.isEmpty {
                    Text(subject)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(kind(of: poll))
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.75))
            }

            VStack(spacing: 4) {
                ForEach(poll.options ?? [], id: \.identity) { option in
                    optionRow(option, in: poll)
                }
            }

            if showsVoters(poll) {
                Button { isShowingVoters = true } label: {
                    Text("Full Results")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(ink.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Text(status(of: poll))
                .font(.caption)
                .foregroundStyle(ink.opacity(0.75))
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $isShowingVoters) {
            PollVoters(poll: poll, members: model.members, meID: model.currentUser?.id)
        }
        .padding(14)
        .frame(minWidth: cardMinWidth, maxWidth: .infinity, alignment: .leading)
        .background(
            isOwn ? AnyShapeStyle(.white.opacity(0.15)) : AnyShapeStyle(.quaternary),
            in: .rect(cornerRadius: 18, style: .continuous))
        .foregroundStyle(ink)
    }

    /// One option: its title, who picked it (or how many, when the poll will
    /// not say who), and a thin bar for its share.
    ///
    /// Never `.disabled`, even once the poll has closed. Disabling a button
    /// dims everything inside it, so an ended poll turned grey and its results,
    /// the only thing left worth reading, became the hardest thing to read.
    /// `choose` declines a vote on a closed poll instead.
    private func optionRow(_ option: Poll.Option, in poll: Poll) -> some View {
        let mine = isMine(option)
        let votes = option.tally
        let share = poll.totalVotes > 0 ? Double(votes) / Double(poll.totalVotes) : 0
        let winner = isWinner(option, in: poll)
        return Button {
            choose(option, in: poll)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(option.title ?? "Option")
                        .font(.body)
                        .lineLimit(2)
                    if mine {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    if winner {
                        Image(systemName: "crown.fill")
                            .imageScale(.small)
                            .foregroundStyle(.yellow)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 4)
                    if !poll.isAnonymous, let voters = option.voterIds, !voters.isEmpty {
                        VoterFaces(ids: voters, members: model.members, ring: ring)
                    } else if votes > 0 {
                        Text("\(votes)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(ink.opacity(0.8))
                    }
                }
                // A bar rather than a percentage. The question a poll answers is
                // which one is winning, and a row of numbers makes the reader
                // work that out for themselves.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.opacity(0.18))
                        Capsule()
                            .fill(ink.opacity(mine || winner ? 0.95 : 0.6))
                            .frame(width: geo.size.width * share)
                    }
                }
                .frame(height: 5)
            }
            // Every option is a tap target, so every option gets the room a tap
            // target needs.
            .padding(.vertical, 6)
            .frame(minHeight: 44, alignment: .center)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title ?? "Option")
        .accessibilityValue("\(votes) vote\(votes == 1 ? "" : "s")\(winner ? ", winner" : "")")
        .accessibilityAddTraits(mine ? [.isButton, .isSelected] : .isButton)
    }

    /// The most-voted option once the poll has closed. A tie crowns everyone
    /// tied, because picking one of them would be a result nobody voted for.
    private func isWinner(_ option: Poll.Option, in poll: Poll) -> Bool {
        guard !poll.isOpen, option.tally > 0 else { return false }
        return option.tally == (poll.options ?? []).map(\.tally).max()
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

    /// What separates overlapping faces: the card's own ground, near enough.
    private var ring: Color { isOwn ? Color.accentColor : Color(.secondarySystemBackground) }

    /// Only a public poll names its voters, and only once somebody has voted.
    private func showsVoters(_ poll: Poll) -> Bool {
        !poll.isAnonymous && (poll.options ?? []).contains { !($0.voterIds ?? []).isEmpty }
    }

    /// What kind of poll this is, which changes what a vote means to the
    /// person casting it.
    private func kind(of poll: Poll) -> String {
        let choice = poll.allowsMultiple ? "Multiple choice" : "Single choice"
        return poll.isAnonymous ? "\(choice) · Anonymous" : choice
    }

    private func status(of poll: Poll) -> String {
        let total = poll.totalVotes
        var parts = [total == 1 ? "1 vote" : "\(total) votes"]
        if !poll.isOpen {
            parts.append("Poll ended")
        } else if let closes = poll.closesAt, closes > .now {
            parts.append("Ends \(closes.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var ink: Color { isOwn ? .white : .primary }

    /// A single-choice poll replaces the vote; a multiple-choice one toggles the
    /// option, and unticking the last leaves an empty list, which is how the
    /// route says "no vote at all".
    private func choose(_ option: Poll.Option, in poll: Poll) {
        guard poll.isOpen, let pollID = attachment.pollId, let optionID = option.id else { return }
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

/// The first few people who picked an option, overlapped the way the official
/// clients draw them. A face says more than a count at a glance, and three is
/// enough to recognise somebody without the row turning into a crowd.
private struct VoterFaces: View {
    let ids: [String]
    let members: [Member]
    let ring: Color

    private static let size: CGFloat = 26
    private static let shown = 3

    var body: some View {
        let byID = Dictionary(members.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let extra = ids.count - Self.shown
        HStack(spacing: -8) {
            ForEach(Array(ids.prefix(Self.shown).enumerated()), id: \.offset) { _, id in
                let member = byID[id]
                Avatar(url: member?.imageUrl, name: member?.nickname ?? member?.name ?? "?", size: Self.size)
                    .overlay(Circle().strokeBorder(ring, lineWidth: 1.5))
            }
            // The rest as a count in a face-sized chip, so the row keeps its
            // width however popular an option turns out to be.
            if extra > 0 {
                Text("+\(extra)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .frame(width: Self.size, height: Self.size)
                    .background(Color(.tertiarySystemFill), in: .circle)
                    .background(Color(.systemBackground), in: .circle)
                    .overlay(Circle().strokeBorder(ring, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Who voted for what, on a public poll.
///
/// A grouped list, one card per option in the poll's own order, so the sheet
/// reads the same way the bubble does. Rows are keyed by option *and* person:
/// on a pick-several poll the same person sits under more than one option, and
/// keying by person alone handed the list duplicate identities, which it
/// answered by drawing those rows blank until they were scrolled past.
private struct PollVoters: View {
    let poll: Poll
    let members: [Member]
    let meID: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(poll.options ?? [], id: \.identity) { option in
                    Section {
                        let voters = option.voterIds ?? []
                        if voters.isEmpty {
                            Text("No votes")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(voters, id: \.self) { id in row(id) }
                    } header: {
                        header(option)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(poll.subject ?? "Votes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func header(_ option: Poll.Option) -> some View {
        let isLeading = option.tally > 0 && option.tally == leadingTally
        return HStack(spacing: 6) {
            Text(option.title ?? "Option")
                .textCase(nil)
                .lineLimit(2)
            if isLeading {
                Image(systemName: poll.isOpen ? "chart.bar.fill" : "crown.fill")
                    .foregroundStyle(.yellow)
                    .imageScale(.small)
                    .accessibilityLabel(poll.isOpen ? "Leading" : "Winner")
            }
            Spacer(minLength: 8)
            Text(option.tally == 1 ? "1 vote" : "\(option.tally) votes")
                .textCase(nil)
                .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
    }

    private var leadingTally: Int { (poll.options ?? []).map(\.tally).max() ?? 0 }

    private func row(_ id: String) -> some View {
        let member = byID[id]
        // Somebody who has since left is still a vote; they are listed rather
        // than dropped, so the list agrees with the count above it.
        let name = member?.nickname ?? member?.name ?? "Former member"
        return HStack(spacing: 12) {
            Avatar(url: member?.imageUrl, name: name, size: 32)
            Text(name)
                .lineLimit(1)
                .foregroundStyle(member == nil ? .secondary : .primary)
            Spacer(minLength: 0)
            if id == meID {
                Text("You")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var byID: [String: Member] {
        Dictionary(members.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
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
