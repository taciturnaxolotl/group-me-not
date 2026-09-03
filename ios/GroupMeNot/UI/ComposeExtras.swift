import SwiftUI

// MARK: - New poll

/// Ask a group something.
///
/// Two options to start, because a poll with one is not a poll, and a cap of
/// ten because past that a poll is a form.
struct NewPollView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var subject = ""
    @State private var options = ["", ""]
    @State private var endsAt = Date().addingTimeInterval(86_400)
    @State private var allowsMultiple = false
    @State private var anonymous = true
    @State private var isSending = false
    @State private var failure: String?

    private static let maxOptions = 10
    /// An hour is the shortest the server accepts; ten minutes is refused.
    private static let shortest: TimeInterval = 3_600

    var body: some View {
        NavigationStack {
            Form {
                Section("Question") {
                    TextField("What are you asking?", text: $subject, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section("Options") {
                    ForEach(options.indices, id: \.self) { index in
                        TextField("Option \(index + 1)", text: $options[index])
                    }
                    .onDelete { offsets in
                        guard options.count > 2 else { return }
                        options.remove(atOffsets: offsets)
                    }
                    if options.count < Self.maxOptions {
                        Button("Add Option", systemImage: "plus") { options.append("") }
                    }
                }

                Section {
                    DatePicker("Ends", selection: $endsAt, in: Date().addingTimeInterval(Self.shortest)...)
                    Toggle("Pick Several", isOn: $allowsMultiple)
                    Toggle("Hide Who Voted", isOn: $anonymous)
                } footer: {
                    Text("Vote counts are always visible. Hiding who voted keeps the names private.")
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("New Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if isSending { ProgressView() } else { Text("Create") }
                    }
                    .disabled(!isReady || isSending)
                }
            }
        }
    }

    private var filledOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var isReady: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && filledOptions.count >= 2
    }

    private func create() {
        isSending = true
        failure = nil
        Task {
            let ok = await model.createPoll(
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                options: filledOptions,
                expiresAt: endsAt,
                allowsMultiple: allowsMultiple,
                anonymous: anonymous)
            isSending = false
            if ok { dismiss() } else { failure = "Could not create that poll." }
        }
    }
}

// MARK: - New event

/// Put something in the group's calendar.
struct NewEventView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var detail = ""
    @State private var place = ""
    @State private var startsAt = Date().addingTimeInterval(3_600)
    @State private var endsAt = Date().addingTimeInterval(7_200)
    @State private var isAllDay = false
    @State private var isSending = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is it?", text: $name)
                    TextField("Where?", text: $place)
                }
                Section {
                    Toggle("All Day", isOn: $isAllDay)
                    DatePicker(
                        "Starts", selection: $startsAt,
                        displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                    DatePicker(
                        "Ends", selection: $endsAt, in: startsAt...,
                        displayedComponents: isAllDay ? .date : [.date, .hourAndMinute])
                }
                Section("Details") {
                    TextField("Anything else", text: $detail, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: create) {
                        if isSending { ProgressView() } else { Text("Create") }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
            // The server wants start and end together and refuses a backwards
            // pair, so the end follows the start rather than being validated
            // after the fact.
            .onChange(of: startsAt) { _, new in
                if endsAt <= new { endsAt = new.addingTimeInterval(3_600) }
            }
        }
    }

    private func create() {
        isSending = true
        failure = nil
        Task {
            let ok = await model.createEvent(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: detail.isEmpty ? nil : detail,
                location: place.isEmpty ? nil : place,
                startAt: startsAt, endAt: endsAt, isAllDay: isAllDay)
            isSending = false
            if ok { dismiss() } else { failure = "Could not create that event." }
        }
    }
}
