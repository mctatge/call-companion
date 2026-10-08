import AppKit
import Combine
import Foundation

struct ProjectChoice: Identifiable {
    let path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var timeline = TranscriptTimeline()
    @Published var suggestions: [Suggestion] = []
    @Published var selectedSuggestion: UUID?
    @Published var listening = false
    @Published var preparing = false
    @Published var busy = false
    @Published var autoHelp = true
    @Published var keepOnTop = false {
        didSet { NSApp.windows.filter { $0.title == "Call Companion" }.forEach { $0.level = keepOnTop ? .floating : .normal } }
    }
    @Published var level = 0.0
    @Published var status = "Ready for your call"
    @Published var answerStatus = "Waiting for a question"
    @Published var error: String?
    @Published var showTranscriptionNotice = false
    @Published var typedQuestion = ""
    @Published var projects: [ProjectChoice] = []
    @Published private(set) var selectedProjectPath = ""
    @Published var callBrief = "" { didSet { if callBrief != oldValue { schedulePreview() } } }
    @Published private(set) var contextLoading = false
    @Published private(set) var contextStatus = "Choose a project, or use general assistance."
    @Published private(set) var references: [RetrievedReference] = []
    @Published private(set) var contextNotices: [String] = []
    @Published private(set) var excludedFiles: Set<String> = []
    private var index: ProjectIndex?
    private var indexTask: Task<ProjectIndex, Error>?
    private var previewTask: Task<Void, Never>?
    private var previewWorker: Task<[RetrievedReference], Never>?
    private var retrievalWorker: Task<[RetrievedReference], Never>?
    private var answerTask: Task<Void, Never>?
    private var contextGeneration = UUID()
    private let speech = SpeechCapture()
    private var answers: AnswerEngine?
    private var timer: Timer?
    private var session = UUID()
    private var offset = 0.0
    private var changedAt = Date.distantPast
    private var pendingSince: Date?
    private var lastRequestedAt = Date.distantPast
    private var lastRequestedText = ""
    private var answerGeneration = UUID()
    private var startTask: Task<Void, Never>?
    private var disclosureAcknowledgedForCall = false

    var currentSuggestion: Suggestion? { suggestions.first { $0.id == selectedSuggestion } ?? suggestions.last }
    var projectName: String { selectedProjectPath.isEmpty ? "General call" : URL(fileURLWithPath: selectedProjectPath).lastPathComponent }
    var canChangeProject: Bool { !listening && !preparing && !busy }
    var hasConversation: Bool { !timeline.lines.isEmpty || !suggestions.isEmpty }
    var canAnswer: Bool { answers != nil && !busy && !contextLoading && (selectedProjectPath.isEmpty || index != nil) }

    init() {
        do { answers = try AnswerEngine() }
        catch { self.error = "Could not start the answer service: \(error.localizedDescription)" }
        reloadProjects()
        // Start with no project: restoring folder history never silently loads its contents.
        speech.onStatus = { [weak self] in self?.status = $0 }
        speech.onLevel = { [weak self] in self?.level = $0 }
        speech.onText = { [weak self] start, end, text, final in
            guard let self else { return }
            let before = self.timeline.text
            self.timeline.update(session: self.session, offset: self.offset, start: start, end: end, text: text, isFinal: final)
            if before != self.timeline.text {
                self.changedAt = Date()
                if self.pendingSince == nil { self.pendingSince = Date() }
            }
        }
        speech.onError = { [weak self] message in self?.error = message; self?.pause() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.considerAutomaticAnswer() }
        }
    }

    func reloadProjects() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let discovered = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.path)
        let recent = UserDefaults.standard.stringArray(forKey: "recentProjectFolders") ?? []
        let paths = Set(discovered + recent + (selectedProjectPath.isEmpty ? [] : [selectedProjectPath]))
        projects = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { ProjectChoice(path: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func browseProject() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.prompt = "Use project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    func selectProject(_ path: String) {
        guard canChangeProject, path != selectedProjectPath else { return }
        let hadConversation = hasConversation
        let draftQuestion = typedQuestion
        clear()
        if hadConversation { callBrief = "" } else { typedQuestion = draftQuestion }
        selectedProjectPath = path
        excludedFiles = []
        if !path.isEmpty {
            let previous = UserDefaults.standard.stringArray(forKey: "recentProjectFolders") ?? []
            UserDefaults.standard.set(Array(([path] + previous.filter { $0 != path }).prefix(12)), forKey: "recentProjectFolders")
        }
        reloadProjects()
        reloadContext()
    }

    func reloadContext() {
        guard !busy else { return }
        indexTask?.cancel()
        previewTask?.cancel()
        previewWorker?.cancel()
        let token = UUID()
        contextGeneration = token
        index = nil
        references = []
        contextNotices = []
        guard !selectedProjectPath.isEmpty else {
            contextLoading = false
            contextStatus = "General assistance · no project files"
            return
        }
        contextLoading = true
        contextStatus = "Finding readable project files…"
        let root = URL(fileURLWithPath: selectedProjectPath, isDirectory: true)
        let worker = Task.detached(priority: .userInitiated) { try ProjectContextLoader.load(root: root) }
        indexTask = worker
        Task {
            do {
                let loaded = try await worker.value
                guard contextGeneration == token else { return }
                index = loaded
                contextNotices = loaded.notices
                contextLoading = false
                let partial = loaded.notices.contains { $0.contains("limit") || $0.contains("stopped") }
                contextStatus = "\(loaded.documents.count) files indexed" + (partial ? " · partial coverage (see context)" : " locally")
                schedulePreview()
            } catch {
                guard contextGeneration == token else { return }
                contextLoading = false
                contextStatus = "Project context unavailable"
                contextNotices = [error.localizedDescription]
                self.error = "Could not read this project: \(error.localizedDescription). Choose another folder or use a general call."
            }
        }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        previewWorker?.cancel()
        guard let index else { return }
        let token = contextGeneration
        let query = callBrief
        let excluded = excludedFiles
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { index.retrieve(query: query, excluding: excluded) }
            previewWorker = worker
            let found = await worker.value
            guard !Task.isCancelled, contextGeneration == token else { return }
            references = found
        }
    }

    func excludeReference(_ path: String) {
        guard !busy else { return }
        excludedFiles.insert(path)
        references.removeAll { $0.path == path }
        schedulePreview()
    }

    func restoreExcludedFiles() { guard !busy else { return }; excludedFiles = []; schedulePreview() }

    func start() {
        guard !listening, !preparing else { return }
        guard disclosureAcknowledgedForCall else {
            showTranscriptionNotice = true
            return
        }
        beginListening()
    }

    func acknowledgeDisclosureAndStart() {
        disclosureAcknowledgedForCall = true
        showTranscriptionNotice = false
        start()
    }

    private func beginListening() {
        preparing = true
        error = nil
        status = "Preparing microphone and on-device transcription…"
        session = UUID()
        offset = timeline.end + 0.1
        startTask = Task {
            do {
                let vocabulary = speechContextTerms(projectName: projectName, callBrief: callBrief)
                try await speech.start(contextualStrings: vocabulary)
                guard !Task.isCancelled else { await speech.stop(); return }
                listening = true
            } catch is CancellationError { status = "Paused" }
            catch { self.error = error.localizedDescription; status = "Microphone is off" }
            preparing = false
        }
    }

    func pause() {
        listening = false
        preparing = true
        startTask?.cancel()
        answerGeneration = UUID()
        answers?.cancel()
        answerTask?.cancel()
        retrievalWorker?.cancel()
        status = "Stopping microphone…"
        Task {
            await speech.stop()
            preparing = false
            status = "Paused · microphone off"
            answerStatus = "Paused"
        }
    }

    func shutdown() {
        timer?.invalidate()
        answers?.cancel()
        answerTask?.cancel()
        retrievalWorker?.cancel()
        startTask?.cancel()
        indexTask?.cancel()
        previewTask?.cancel()
        previewWorker?.cancel()
    }

    private func considerAutomaticAnswer() {
        guard listening, autoHelp, canAnswer else { return }
        let text = timeline.text
        guard text.count >= 25, text != lastRequestedText else { return }
        let sinceRequest = Date().timeIntervalSince(lastRequestedAt)
        let quietFor = Date().timeIntervalSince(changedAt)
        let pendingFor = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        guard sinceRequest >= 10, quietFor >= 1.8 || pendingFor >= 20 else { return }
        requestAnswer(automatic: true)
    }

    func requestAnswer(automatic: Bool = false) {
        guard canAnswer, let answers else { return }
        let question = automatic ? "" : typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = timeline.text
        guard !question.isEmpty || !transcript.isEmpty else {
            error = "Start listening or type a question first."
            return
        }
        previewTask?.cancel()
        previewWorker?.cancel()
        let token = UUID()
        answerGeneration = token
        busy = true
        error = nil
        lastRequestedAt = Date()
        lastRequestedText = transcript
        pendingSince = nil
        answerStatus = "Finding context for the latest question…"
        let brief = String(callBrief.prefix(6000))
        let name = projectName
        let snapshot = index
        let excluded = excludedFiles
        let query = brief + "\n" + question + "\n" + String(transcript.suffix(2500))
        let history = suggestions
        if !automatic { typedQuestion = "" }
        answerTask = Task {
            defer { busy = false }
            do {
                let worker = Task.detached(priority: .userInitiated) { snapshot?.retrieve(query: query, excluding: excluded) ?? [] }
                retrievalWorker = worker
                let found = await worker.value
                guard answerGeneration == token else { return }
                references = found
                answerStatus = "Thinking about the latest question…"
                let suggestion = try await answers.answer(transcript: transcript, question: question, previous: history,
                    automatic: automatic, brief: brief, projectName: name, references: found)
                guard answerGeneration == token else { return }
                if suggestion.should_answer, !suggestion.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    suggestions.append(suggestion)
                    selectedSuggestion = suggestion.id
                    answerStatus = "Suggestion ready · \(Date().formatted(date: .omitted, time: .shortened))"
                } else { answerStatus = "Following along · no new question" }
            } catch {
                guard answerGeneration == token else { return }
                self.error = error.localizedDescription
                answerStatus = "Answer unavailable"
                if automatic { autoHelp = false }
                if !automatic, typedQuestion.isEmpty { typedQuestion = question }
            }
        }
    }

    func cancelAnswer() {
        answerGeneration = UUID()
        answers?.cancel()
        answerTask?.cancel()
        retrievalWorker?.cancel()
        answerStatus = "Answer cancelled"
    }

    func example() {
        typedQuestion = selectedProjectPath.isEmpty ? "What are three useful questions to understand what someone needs from this call?" :
            "Based on the call brief and project files, what should I clarify or ask on this call?"
        requestAnswer()
    }

    func copyAnswer() {
        guard let suggestion = currentSuggestion else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(suggestion.copyText, forType: .string)
    }

    func exportNotes() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Call notes \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let notes = "CALL NOTES\nProject: \(projectName)\nCall brief: \(callBrief)\nMachine transcript; speakers are not identified and wording may be wrong.\n\nCONVERSATION\n\(timeline.text)\n\nSUGGESTIONS\n" + suggestions.map { "\($0.question)\n\($0.copyText)\nSource: \($0.source)" }.joined(separator: "\n\n")
        do { try notes.write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "Could not save notes: \(error.localizedDescription)" }
    }

    func clear() {
        guard canChangeProject else { return }
        disclosureAcknowledgedForCall = false
        showTranscriptionNotice = false
        timeline = TranscriptTimeline()
        suggestions = []
        selectedSuggestion = nil
        lastRequestedText = ""
        pendingSince = nil
        typedQuestion = ""
        error = nil
        answerStatus = "Waiting for a question"
        schedulePreview()
    }
}
