//
//  ContentView.swift
//  iMessageAI
//
//  Created by Caden Roberts on 11/28/25.
//

import SwiftUI
import UserNotifications

#if os(macOS)
import AppKit
#endif

#if os(macOS)
private func resolvePythonPath() -> String? {
    let user = NSUserName()
    let candidates = [
        "/Users/\(user)/iMessageAI/.venv/bin/python3",
        "/Users/\(user)/iMessageAI/.venv/bin/python",
        "/Users/\(user)/miniconda3/bin/python",
        "/Users/\(user)/miniconda3/bin/python3",
        "/opt/homebrew/bin/python",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python",
        "/usr/local/bin/python3",
        "/usr/bin/python",
        "/usr/bin/python3",
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}
#endif

private let basePath: String = "/Users/\(NSUserName())/iMessageAI"

private func ensureBaseDirectoryExists() {
    let url = URL(fileURLWithPath: basePath, isDirectory: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private func fixedConfigFileURL() -> URL { URL(fileURLWithPath: basePath + "/config.json") }
private func fixedRepliesFileURL() -> URL { URL(fileURLWithPath: basePath + "/replies.json") }
private func fixedModelScriptURL() -> URL { URL(fileURLWithPath: basePath + "/model.py") }

private func withFileLock<T>(for fileURL: URL, _ body: () throws -> T) rethrows -> T {
    let lockPath = fileURL.path + ".lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return try body() }
    defer {
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
    }
    _ = flock(fd, LOCK_EX)
    return try body()
}

struct Mood: Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String

    init(id: UUID = UUID(), name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

private let reservedMoodNames: Set<String> = ["Reply", "reply", "sender", "message", "time", "replies"]

struct ContentView: View {
    // MARK: - App Config State
    @State private var name: String = "Caden Roberts"
    @State private var personalDescription: String = "I am a 22 year old UCSC CSE MS student. I grew up in San Jose. I'm pretty casual about grammar but I send longer, more thought out messages and sound a bit gen z. I love hanging out with friends and my girlfriend, coding, and working out! I love coding! I love working out but also enjoy my alone time."

    // Editing states for Name and Description
    @State private var isEditingName: Bool = false
    @State private var draftName: String = ""

    @State private var isEditingDescription: Bool = false
    @State private var draftDescription: String = ""

    // Moods (1-5 max)
    @State private var moods: [Mood] = [
        Mood(name: "Happy", description: "Happy and carefree. Go on and on about whatever you can."),
        Mood(name: "Professional", description: "Polite. No slang, no casual phrasing. Sounds like a business email or a customer service agent. Gives clear acknowledgment of the message and responds with structured, direct sentences. Avoids emotional expression."),
        Mood(name: "Sad", description: "Avoid everything and rant a lot about how pointless it is.")
    ]
    
    // Phone number filter state
    enum PhoneListMode: String, CaseIterable, Identifiable {
        case include = "Include"
        case exclude = "Exclude"
        var id: String { rawValue }
    }
    @State private var phoneListMode: PhoneListMode = .exclude
    @State private var phoneNumbers: [String] = []
    @State private var newPhoneNumber: String = ""
    @State private var showAddPhoneForm: Bool = false

    // Add Mood form state
    @State private var showAddMoodForm: Bool = false
    @State private var newMoodName: String = ""
    @State private var newMoodDescription: String = ""

    // Edit Mood inline state
    @State private var editingMoodID: UUID? = nil
    @State private var draftMoodName: String = ""
    @State private var draftMoodDescription: String = ""

    // Delete mode toggle
    @State private var isDeleteMode: Bool = false
    @State private var repliesPollTimer: Timer? = nil

#if os(macOS)
    @State private var modelProcess: Process? = nil
    @State private var shouldKeepModelRunning: Bool = true
#endif

    // Generated replies from Python (mood -> reply)
    @State private var generatedReplies: [String: String] = [:]
    // Selected reply mood from Generated Replies
    @State private var selectedReplyMood: String? = nil

    // Edit state for a single generated reply
    @State private var editingReplyMood: String? = nil
    @State private var draftReplyText: String = ""
    
    // Sender/message and last chosen reply from replies.json
    @State private var lastSender: String = ""
    @State private var lastMessage: String = ""
    @State private var lastReply: String = ""
    @State private var generationTimeSeconds: String = ""

    @State private var notificationsEnabled: Bool = false
    @State private var lastNotifiedEmptyReplyID: String? = nil

    private func requestNotificationAuthorizationIfNeeded() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    private func postEmptyReplyNotificationIfNeeded(sender: String, message: String) {
        guard notificationsEnabled else { return }
        // Build a simple ID from sender+message to avoid duplicate notifications for the same event
        let eventID = "\(sender)|\(message)"
        if lastNotifiedEmptyReplyID == eventID { return }

        let content = UNMutableNotificationContent()
        content.title = "Reply Needed"
        if sender.isEmpty && message.isEmpty {
            content.body = "A conversation has no selected reply yet."
        } else if sender.isEmpty {
            content.body = "No selected reply for: \(message)"
        } else {
            content.body = "No selected reply for \(sender): \(message)"
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { print("Notification delivery failed: \(error)") }
        }
        // Remember we notified for this specific event
        DispatchQueue.main.async { self.lastNotifiedEmptyReplyID = eventID }
    }

    // Added helper method per instructions
    private func performRepliesWrite(_ write: () -> Void) {
        stopRepliesPolling()
        withFileLock(for: fixedRepliesFileURL()) {
            write()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startRepliesPolling()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    descriptionSection
                    moodsSection
                    phoneNumbersSection
                    generatedRepliesSection
                }
                .padding()
            }
            .navigationTitle("iMessageAI")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $notificationsEnabled) {
                        Text("Notifications")
                    }
                    .toggleStyle(.switch)
                    .onChange(of: notificationsEnabled) { _, _ in
                        requestNotificationAuthorizationIfNeeded()
                    }
                }
            }
            .onChange(of: phoneListMode) { _, _ in
                persistConfig()
            }
            .onAppear {
                loadConfigIfExists()
                startRepliesPolling()
                if notificationsEnabled { requestNotificationAuthorizationIfNeeded() }
#if os(macOS)
                shouldKeepModelRunning = true
                startModelIfNeeded()
#endif
            }
            .onDisappear {
#if os(macOS)
                stopModel()
#endif
                stopRepliesPolling()
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Name")
                    .font(.headline)
                Spacer()
                if isEditingName {
                    // While editing, show Save / Cancel
                    HStack(spacing: 8) {
                        Button("Cancel") { cancelNameEdit() }
                            .buttonStyle(.plain)
                        Button("Save") {
                            saveNameEdit()
                        }
                        .buttonStyle(.plain)
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button("Edit") { startNameEdit() }
                        .buttonStyle(.plain)
                }
            }

            if isEditingName {
                TextField("Enter name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(name)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Personal Description")
                    .font(.headline)
                Spacer()
                if isEditingDescription {
                    HStack(spacing: 8) {
                        Button("Cancel") { cancelDescriptionEdit() }
                            .buttonStyle(.plain)
                        Button("Save") {
                            saveDescriptionEdit()
                        }
                        .buttonStyle(.plain)
                        .disabled(draftDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button("Edit") { startDescriptionEdit() }
                        .buttonStyle(.plain)
                }
            }

            if isEditingDescription {
                TextEditor(text: $draftDescription)
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Text(personalDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var moodsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Moods")
                    .font(.headline)
                Spacer()
            }

            // List of moods
            VStack(spacing: 8) {
                ForEach(moods) { mood in
                    moodRow(mood)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                }
            }

            // Controls row: Delete and Add Mood side-by-side
            HStack {
                // Delete toggle button — show only if more than 1 mood and not currently showing Add form
                if moods.count > 1 && !showAddMoodForm {
                    Button(isDeleteMode ? "Cancel" : "Delete") {
                        withAnimation { isDeleteMode.toggle() }
                        if isDeleteMode { editingMoodID = nil }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Add Mood button — show only if fewer than 5 moods and not in delete mode and not currently showing the Add form
                if moods.count < 5 && !isDeleteMode && !showAddMoodForm {
                    Button("Add Mood") { showAddMoodForm = true }
                        .buttonStyle(.plain)
                }
            }

            // Add/Create form — only if showAddMoodForm is true
            if showAddMoodForm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Mood")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $newMoodName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Description", text: $newMoodDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Cancel") {
                            cancelAddMood()
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button("Create") {
                            createMood()
                        }
                        .buttonStyle(.plain)
                        .disabled(newMoodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newMoodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            }
        }
    }

    private var phoneNumbersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Phone Numbers")
                    .font(.headline)
                Spacer()
                // Include / Exclude selector
                Picker("Mode", selection: $phoneListMode) {
                    ForEach(PhoneListMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            // List of numbers
            VStack(spacing: 8) {
                if phoneNumbers.isEmpty {
                    Text("No phone numbers yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                } else {
                    ForEach(Array(phoneNumbers.enumerated()), id: \.offset) { index, number in
                        HStack(alignment: .center, spacing: 12) {
                            Text(number)
                                .font(.body)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Delete") {
                                deletePhoneNumber(at: index)
                            }
                            .buttonStyle(.plain)
                            .tint(.red)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
                    }
                }
            }

            // Add form (no limit)
            if showAddPhoneForm {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Phone Number")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("e.g. +1 (555) 123-4567", text: $newPhoneNumber)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Cancel") { cancelAddPhone() }
                            .buttonStyle(.plain)
                        Spacer()
                        Button("Create") { createPhoneNumber() }
                            .buttonStyle(.plain)
                            .disabled(newPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            } else {
                Button("Add Phone Number") { showAddPhoneForm = true }
                    .buttonStyle(.plain)
            }
        }
    }

    private var generatedRepliesSection: some View {
        // Break up complex expressions to help the type-checker
        let hasReplies = !generatedReplies.isEmpty
        let sortedKeys = Array(generatedReplies.keys).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        return VStack(alignment: .leading, spacing: 12) {
            // Header with sender/message
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation")
                    .font(.headline)
                if !lastSender.isEmpty || !lastMessage.isEmpty {
                    Text("\"\(lastSender)\" said: \"\(lastMessage)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No conversation yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Replies area
            if !lastReply.isEmpty && lastReply != "Refresh" && lastReply != "Ignore" {
                // When a reply has been chosen already, show summary instead of list
                VStack(alignment: .leading, spacing: 8) {
                    let repliedText = generatedReplies[lastReply] ?? lastReply
                    Text("You replied: \"\(repliedText)\"")
                        .font(.headline)
                    // Keep button disabled since reply already chosen
                    HStack { Spacer() }
                }
            } else {
                // If ignoring, show only Conversation
                if lastReply == "Ignore" {
                    EmptyView()
                } else {
                    // No reply yet: show generated replies list
                    HStack {
                        Text(
                            lastReply == "Refresh" ? "Generating Replies…" : (
                                lastReply.isEmpty && !generationTimeSeconds.isEmpty ? "Generated Replies in \(generationTimeSeconds)s" : "Generated Replies"
                            )
                        )
                        .font(.headline)
                        Spacer()
                        if !hasReplies && lastReply != "Refresh" {
                            Text("No replies yet")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if hasReplies {
                        VStack(spacing: 8) {
                            ForEach(sortedKeys, id: \.self) { mood in
                                let replyText = generatedReplies[mood] ?? ""
                                let isSelected = (selectedReplyMood == mood)
                                GeneratedReplyRow(
                                    mood: mood,
                                    reply: replyText,
                                    isSelected: isSelected,
                                    isEditing: editingReplyMood == mood,
                                    draftText: editingReplyMood == mood ? draftReplyText : replyText,
                                    onTap: {
                                        if selectedReplyMood == mood {
                                            selectedReplyMood = nil
                                        } else {
                                            selectedReplyMood = mood
                                        }
                                    },
                                    onEdit: {
                                        editingReplyMood = mood
                                        draftReplyText = replyText
                                    },
                                    onCancelEdit: {
                                        if editingReplyMood == mood {
                                            editingReplyMood = nil
                                            draftReplyText = ""
                                        }
                                    },
                                    onSaveEdit: { newText in
                                        generatedReplies[mood] = newText
                                        persistEditedReply(mood: mood, text: newText)
                                        editingReplyMood = nil
                                        draftReplyText = ""
                                    },
                                    onDraftChange: { newText in
                                        draftReplyText = newText
                                    }
                                )
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Ignore") {
                                saveIgnoreRequest()
                            }
                            .buttonStyle(.bordered)

                            Button("Refresh") {
                                saveRefreshRequest()
                            }
                            .buttonStyle(.bordered)

                            Button("Reply") {
                                saveSelectedReply()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedReplyMood == nil)
                        }
                    }
                }
            }
        }
    }

    private struct GeneratedReplyRow: View {
        let mood: String
        let reply: String
        let isSelected: Bool
        let isEditing: Bool
        let draftText: String
        let onTap: () -> Void
        let onEdit: () -> Void
        let onCancelEdit: () -> Void
        let onSaveEdit: (String) -> Void
        let onDraftChange: (String) -> Void

        @State private var internalDraft: String = ""

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mood)
                            .font(.subheadline)
                            .bold()
                        if isEditing {
                            TextEditor(text: $internalDraft)
                                .frame(minHeight: 80)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                                .onChange(of: internalDraft) { _, newValue in
                                    onDraftChange(newValue)
                                }
                                .onAppear { internalDraft = draftText }
                        } else {
                            Text(reply)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isEditing {
                        VStack(alignment: .trailing, spacing: 8) {
                            Button("Cancel") { onCancelEdit() }
                                .buttonStyle(.plain)
                            Button("Save") {
                                onSaveEdit(internalDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            .buttonStyle(.plain)
                            .disabled(internalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Button("Edit") { onEdit() }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                    )
            )
            .onTapGesture { if !isEditing { onTap() } }
        }
    }

    // MARK: - Mood Row
    @ViewBuilder
    private func moodRow(_ mood: Mood) -> some View {
        let isEditingThis = editingMoodID == mood.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if isEditingThis {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Mood name", text: $draftMoodName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Mood description", text: $draftMoodDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mood.name).font(.headline)
                        Text(mood.description).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isDeleteMode {
                    Button("Delete") { deleteMood(mood) }
                        .tint(.red)
                        .buttonStyle(.plain)
                } else if isEditingThis {
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Cancel") { cancelMoodEdit() }
                            .buttonStyle(.plain)
                        Button("Save") {
                            saveMoodEdit(mood)
                        }
                        .buttonStyle(.plain)
                        .disabled(draftMoodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftMoodDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button("Edit") { startMoodEdit(mood) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions: Name
    private func startNameEdit() {
        draftName = name
        isEditingName = true
    }

    private func saveNameEdit() {
        name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        persistConfig()
        isEditingName = false
    }

    private func cancelNameEdit() {
        isEditingName = false
    }

    // MARK: - Actions: Description
    private func startDescriptionEdit() {
        draftDescription = personalDescription
        isEditingDescription = true
    }

    private func saveDescriptionEdit() {
        personalDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        persistConfig()
        isEditingDescription = false
    }

    private func cancelDescriptionEdit() {
        isEditingDescription = false
    }

    // MARK: - Actions: Add Mood
    private func cancelAddMood() {
        showAddMoodForm = false
        newMoodName = ""
        newMoodDescription = ""
    }

    private func createMood() {
        let trimmedName = newMoodName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = newMoodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDesc.isEmpty, moods.count < 5 else { return }
        guard !reservedMoodNames.contains(trimmedName) else { return }
        guard !moods.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else { return }
        moods.append(Mood(name: trimmedName, description: trimmedDesc))
        persistConfig()
        cancelAddMood()
    }

    // MARK: - Actions: Edit Mood
    private func startMoodEdit(_ mood: Mood) {
        editingMoodID = mood.id
        draftMoodName = mood.name
        draftMoodDescription = mood.description
    }

    private func saveMoodEdit(_ mood: Mood) {
        guard let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        let newName = draftMoodName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newDesc = draftMoodDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newDesc.isEmpty else { return }
        guard !reservedMoodNames.contains(newName) else { return }
        guard !moods.contains(where: { $0.name.caseInsensitiveCompare(newName) == .orderedSame && $0.id != mood.id }) else { return }
        moods[idx].name = newName
        moods[idx].description = newDesc
        persistConfig()
        editingMoodID = nil
    }

    private func cancelMoodEdit() {
        editingMoodID = nil
    }

    // MARK: - Actions: Delete Mood
    private func deleteMood(_ mood: Mood) {
        moods.removeAll { $0.id == mood.id }
        persistConfig()
        // If only one mood remains, exit delete mode automatically
        if moods.count <= 1 {
            isDeleteMode = false
        }
    }

    // MARK: - Actions: Phone Numbers
    private func deletePhoneNumber(at index: Int) {
        guard phoneNumbers.indices.contains(index) else { return }
        phoneNumbers.remove(at: index)
        persistConfig()
    }

    private func cancelAddPhone() {
        showAddPhoneForm = false
        newPhoneNumber = ""
    }

    private func createPhoneNumber() {
        let trimmed = newPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !phoneNumbers.contains(trimmed) else { return }
        phoneNumbers.append(trimmed)
        persistConfig()
        cancelAddPhone()
    }

    private func persistConfig() {
        struct ConfigFile: Codable {
            let name: String
            let personalDescription: String
            let moods: [String: String]
            let phoneListMode: String
            let phoneNumbers: [String]
        }

        let moodsDict: [String: String] = Dictionary(moods.map { ($0.name, $0.description) }, uniquingKeysWith: { _, last in last })

        let config = ConfigFile(
            name: name,
            personalDescription: personalDescription,
            moods: moodsDict,
            phoneListMode: phoneListMode.rawValue,
            phoneNumbers: phoneNumbers
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(config)

            ensureBaseDirectoryExists()
            let fileURL = fixedConfigFileURL()
            try jsonData.write(to: fileURL, options: .atomic)
#if DEBUG
            print("Wrote config.json to: \(fileURL.path)\n")
#endif
        } catch {
            print("Failed to write config.json: \(error)\n")
        }
    }

    private func configFileURL() -> URL? {
        ensureBaseDirectoryExists()
        return fixedConfigFileURL()
    }

    private func repliesFileURL() -> URL? {
        ensureBaseDirectoryExists()
        return fixedRepliesFileURL()
    }

    private func loadConfigIfExists() {
        guard let url = configFileURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = json["name"] as? String { self.name = name }
                if let personalDescription = json["personalDescription"] as? String { self.personalDescription = personalDescription }
                if let moodsDict = json["moods"] as? [String: String] {
                    let valid = moodsDict.filter { !reservedMoodNames.contains($0.key) }
                    if !valid.isEmpty {
                        self.moods = valid.sorted(by: { $0.key < $1.key }).map { Mood(name: $0.key, description: $0.value) }
                    }
                }
                if let phoneListMode = json["phoneListMode"] as? String, let mode = PhoneListMode(rawValue: phoneListMode) {
                    self.phoneListMode = mode
                }
                if let phoneNumbers = json["phoneNumbers"] as? [String] {
                    var seen = Set<String>()
                    self.phoneNumbers = phoneNumbers.filter { seen.insert($0).inserted }
                }
            }
        } catch {
            print("Failed to load existing config.json: \(error)")
        }
    }

    struct ParsedReplies {
        let sender: String
        let message: String
        let replyValue: String
        let timeValue: String
        let repliesDict: [String: String]
    }

    static func readRepliesFile(at url: URL) -> ParsedReplies? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let anyJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let sender = anyJSON["sender"] as? String ?? ""
            let message = anyJSON["message"] as? String ?? ""
            let replyValue: String = {
                if let s = anyJSON["Reply"] as? String { return s }
                if let s = anyJSON["reply"] as? String { return s }
                return ""
            }()
            let timeValue: String = {
                if let t = anyJSON["time"] as? String { return t }
                if let n = anyJSON["time"] as? NSNumber { return n.stringValue }
                if let i = anyJSON["time"] as? Int { return String(i) }
                if let d = anyJSON["time"] as? Double { return String(d) }
                return ""
            }()
            var repliesDict: [String: String] = [:]
            for (k, v) in anyJSON {
                if let text = v as? String, k != "sender", k != "message", k != "Reply", k != "reply", k != "time", k != "replies" {
                    repliesDict[k] = text
                }
            }
            if let nested = anyJSON["replies"] as? [String: String] {
                for (k, v) in nested where repliesDict[k] == nil {
                    repliesDict[k] = v
                }
            }
            return ParsedReplies(sender: sender, message: message, replyValue: replyValue, timeValue: timeValue, repliesDict: repliesDict)
        } catch {
            print("Failed to load replies.json: \(error)")
            return nil
        }
    }

    private func applyParsedReplies(_ parsed: ParsedReplies) {
        self.lastSender = parsed.sender
        self.lastMessage = parsed.message
        self.lastReply = parsed.replyValue
        self.generatedReplies = parsed.repliesDict
        self.generationTimeSeconds = parsed.timeValue

        if self.lastReply.isEmpty {
            self.selectedReplyMood = nil
            self.editingReplyMood = nil
            self.draftReplyText = ""
            self.postEmptyReplyNotificationIfNeeded(sender: self.lastSender, message: self.lastMessage)
        } else {
            self.lastNotifiedEmptyReplyID = nil
        }
    }

    private func saveSelectedReply() {
        guard let mood = selectedReplyMood else { return }
        let replyText = generatedReplies[mood] ?? mood
        guard let url = repliesFileURL() else { return }
        performRepliesWrite {
            do {
                var dict: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: url.path) {
                    let data = try Data(contentsOf: url)
                    if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        dict = existing
                    }
                }
                // Overwrite the top-level mood key instead of nested replies dictionary
                dict[mood] = replyText
                // Write the selected mood under Reply key (as before)
                dict["Reply"] = mood
                dict["reply"] = replyText

                let newData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                try writeAtomicallyReplacing(url: url, data: newData)
                self.lastReply = mood
            } catch {
                print("Failed to save selected reply to replies.json: \(error)")
            }
        }
    }
    
    private func saveRefreshRequest() {
        selectedReplyMood = nil
        editingReplyMood = nil
        draftReplyText = ""
        guard let url = repliesFileURL() else { return }
        performRepliesWrite {
            do {
                var dict: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: url.path) {
                    let data = try Data(contentsOf: url)
                    if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        dict = existing
                    }
                }
                dict["Reply"] = "Refresh"
                self.lastReply = "Refresh"
                let newData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                try writeAtomicallyReplacing(url: url, data: newData)
            } catch {
                print("Failed to save refresh request to replies.json: \(error)")
            }
        }
    }
    
    private func saveIgnoreRequest() {
        selectedReplyMood = nil
        editingReplyMood = nil
        draftReplyText = ""
        guard let url = repliesFileURL() else { return }
        performRepliesWrite {
            do {
                var dict: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: url.path) {
                    let data = try Data(contentsOf: url)
                    if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        dict = existing
                    }
                }
                dict["Reply"] = "Ignore"
                self.lastReply = "Ignore"
                let newData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                try writeAtomicallyReplacing(url: url, data: newData)
            } catch {
                print("Failed to save ignore request to replies.json: \(error)")
            }
        }
    }

    private func persistEditedReply(mood: String, text: String) {
        guard let url = repliesFileURL() else { return }
        performRepliesWrite {
            do {
                var dict: [String: Any] = [:]
                if FileManager.default.fileExists(atPath: url.path) {
                    let data = try Data(contentsOf: url)
                    if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        dict = existing
                    }
                }
                // Overwrite the top-level mood key instead of nested replies dictionary
                dict[mood] = text
                if let selected = dict["Reply"] as? String, selected == mood {
                    dict["reply"] = text
                }
                // Preserve other keys like sender/message/Reply/time
                let newData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                try writeAtomicallyReplacing(url: url, data: newData)
            } catch {
                print("Failed to persist edited reply for \(mood): \(error)")
            }
        }
    }

    private func writeAtomicallyReplacing(url: URL, data: Data) throws {
        let dir = url.deletingLastPathComponent()
        let tmpURL = dir.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: tmpURL)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }

    private static let repliesIOQueue = DispatchQueue(label: "com.imessageai.repliesIO", qos: .utility)

    private func startRepliesPolling() {
        repliesPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Self.repliesIOQueue.async {
                ensureBaseDirectoryExists()
                let url = fixedRepliesFileURL()
                let maybeParsed = withFileLock(for: url, { Self.readRepliesFile(at: url) })
                guard let parsed = maybeParsed else { return }
                DispatchQueue.main.async {
                    self.applyParsedReplies(parsed)
                }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        repliesPollTimer = timer
    }

    private func stopRepliesPolling() {
        repliesPollTimer?.invalidate()
        repliesPollTimer = nil
    }

#if os(macOS)
    private func modelScriptURL() -> URL? {
        return fixedModelScriptURL()
    }

    private func startModelIfNeeded() {
        guard shouldKeepModelRunning else { return }
        // If already running, do nothing
        if let proc = modelProcess, proc.isRunning { return }
        guard let scriptURL = modelScriptURL() else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: scriptURL.path) else {
            print("model.py not found at: \(scriptURL.path)")
            return
        }
        do {
            let process = Process()
            let pythonPath = resolvePythonPath() ?? "/usr/bin/python3"
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-u", scriptURL.path]
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            let user = NSUserName()
            let condaBin = "/Users/\(user)/miniconda3/bin"
            let homebrewBin = "/opt/homebrew/bin"
            let defaultPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            var pathParts = defaultPath.split(separator: ":").map(String.init)
            func prepend(_ p: String) { if !pathParts.contains(p) { pathParts.insert(p, at: 0) } }
            prepend(homebrewBin)
            prepend(condaBin)
            env["PATH"] = pathParts.joined(separator: ":")
            process.environment = env
            process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    print(str, terminator: "")
                }
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    fputs(str, stderr)
                }
            }

            process.terminationHandler = { proc in
                DispatchQueue.main.async {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    self.modelProcess = nil
                    // Auto-restart if allowed
                    if self.shouldKeepModelRunning {
                        // Add a small delay to avoid tight loops
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.startModelIfNeeded()
                        }
                    }
                }
            }

            try process.run()
            self.modelProcess = process
#if DEBUG
            print("Started model.py at: \(scriptURL.path)\n")
#endif
        } catch {
            print("Failed to start model.py: \(error)\n")
        }
    }

    private func stopModel() {
        shouldKeepModelRunning = false
        if let proc = modelProcess, proc.isRunning {
            proc.terminate()
        }
        modelProcess = nil
    }
#endif
}

#Preview {
    ContentView()
}

