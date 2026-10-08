import SwiftUI
import AppKit

private enum Palette {
    static let background = Color(red: 0.965, green: 0.961, blue: 0.973)
    static let panel = Color(red: 0.937, green: 0.929, blue: 0.957)
    static let ink = Color(red: 0.129, green: 0.110, blue: 0.161)
    static let secondary = Color(red: 0.404, green: 0.373, blue: 0.451)
    static let plum = Color(red: 0.290, green: 0.129, blue: 0.408)
}

@main
struct CallCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var model = CompanionModel()
    init() { signal(SIGPIPE, SIG_IGN) }
    var body: some Scene {
        Window("Call Companion", id: "companion") {
            CompanionView(model: model)
                .preferredColorScheme(.light)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .defaultSize(width: 1120, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Help with the latest question") { model.requestAnswer() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canAnswer)
                Button(model.listening ? "Pause listening" : "Start listening") { model.listening ? model.pause() : model.start() }
                    .keyboardShortcut("l", modifiers: .command).disabled(model.preparing)
            }
        }
    }
}

final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @State private var showContext = false
    @State private var showClear = false
    @State private var showProjectChange = false
    @State private var pendingProject = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            callSetup
            if let error = model.error {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss", systemImage: "xmark") { model.error = nil }.labelStyle(.iconOnly).buttonStyle(.plain)
                }.font(.system(size: 14)).foregroundStyle(Palette.ink).padding(16).background(Color(red: 1, green: 0.94, blue: 0.81))
            }
            HSplitView {
                answerPanel.frame(minWidth: 450, idealWidth: 690, maxWidth: .infinity, maxHeight: .infinity)
                transcriptPanel.frame(minWidth: 280, idealWidth: 320, maxWidth: 340, maxHeight: .infinity)
            }
            questionBar
            footer
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.plum)
        .frame(minWidth: 900, minHeight: 740)
        .alert("Start a new call?", isPresented: $showClear) {
            Button("Start new call", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This clears the transcript, suggestions, and transcription acknowledgement. Save notes first if you want to keep them.") }
        .alert("Before listening", isPresented: $model.showTranscriptionNotice) {
            Button("Everyone has been told — Start listening") { model.acknowledgeDisclosureAndStart() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Call Companion transcribes audio heard by this Mac. Audio is processed on this Mac and is not uploaded. With Auto help on, transcript text and selected file excerpts are sent to Codex automatically when the app checks for a useful suggestion. Confirm that everyone on this call has been told transcription is on. You are responsible for obtaining any permission required. Call Companion cannot verify consent or determine whether its use is lawful.")
        }
    }

    private func chooseProject(_ path: String) {
        guard path != model.selectedProjectPath else { return }
        if model.hasConversation {
            pendingProject = path
            showProjectChange = true
        } else { model.selectProject(path) }
    }

    // Native setup controls leave the large, speakable answer as the focal point.
    private var callSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 8) {
                        Picker("Project", selection: Binding(get: { model.selectedProjectPath }, set: { chooseProject($0) })) {
                            Text("General call · no project").tag("")
                            ForEach(model.projects) { project in Text(project.name).tag(project.path) }
                        }.labelsHidden().help(model.selectedProjectPath.isEmpty ? "No project files will be used" : model.selectedProjectPath)
                        Button { if let path = model.browseProject() { chooseProject(path) } } label: {
                            Image(systemName: "folder.badge.plus")
                        }.help("Choose another folder").accessibilityLabel("Choose another project folder")
                    }.disabled(!model.canChangeProject)
                    Text(model.listening ? "Pause listening to change projects." : "Your project folders, or any folder you choose.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }.frame(width: 290, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("What is this call about?").font(.system(size: 12, weight: .semibold))
                    TextField("Who you're meeting, what you want to discuss, and what you hope to learn…", text: $model.callBrief, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.system(size: 14)).lineLimit(2...3)
                        .disabled(model.busy).accessibilityLabel("Call brief")
                    Text("Names and product terms in the brief are also prioritized for speech recognition.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            HStack(spacing: 8) {
                if model.contextLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: model.selectedProjectPath.isEmpty ? "bubble.left.and.bubble.right" : "doc.text.magnifyingglass") }
                Text(model.contextStatus).lineLimit(1)
                Spacer()
                if !model.selectedProjectPath.isEmpty {
                    Button("Refresh files", systemImage: "arrow.clockwise") { model.reloadContext() }
                        .disabled(model.busy || model.contextLoading)
                    Button("Review context (\(model.references.count))") { showContext.toggle() }
                }
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary).buttonStyle(.plain)
        }.padding(.horizontal, 28).padding(.vertical, 16).background(Palette.background)
        .alert("Start a new call with this project?", isPresented: $showProjectChange) {
            Button("Start new call") { model.selectProject(pendingProject) }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This clears the current transcript, suggestions, and call brief. Save notes first if you want to keep them.") }
    }

    private var header: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Call Companion").font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                Text("\(model.projectName) · Private text suggestions").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Toggle("Keep on top", isOn: $model.keepOnTop).toggleStyle(.checkbox).font(.system(size: 13))
            Button { model.listening ? model.pause() : model.start() } label: {
                Label(model.preparing ? "Preparing…" : model.listening ? "Pause listening" : "Start listening",
                      systemImage: model.listening ? "pause.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 10).frame(height: 32)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(model.preparing)
            .help("⌘L · The microphone starts only when you click this button.")
        }.padding(.horizontal, 28).padding(.vertical, 22).background(.white)
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Suggested answer", systemImage: "text.bubble").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Toggle("Auto help", isOn: $model.autoHelp).toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
            }.padding(.bottom, 8)
            Text(model.answerStatus).font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.bottom, 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let suggestion = model.currentSuggestion {
                        Text(suggestion.question).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                        Text(suggestion.answer).font(.system(size: 27, weight: .medium)).tracking(-0.35).lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if !suggestion.caveat.isEmpty { note("Keep in mind", text: suggestion.caveat, icon: "info.circle") }
                        if !suggestion.follow_up.isEmpty { note("A useful next question", text: suggestion.follow_up, icon: "arrow.turn.down.right") }
                        HStack(alignment: .top) {
                            Text(suggestion.source).font(.system(size: 11)).foregroundStyle(Palette.secondary).textSelection(.enabled)
                            Spacer()
                            Button("Copy answer", systemImage: "doc.on.doc") { model.copyAnswer() }.controlSize(.small)
                        }.padding(.top, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            Image(systemName: "ear.badge.waveform").font(.system(size: 35, weight: .light)).foregroundStyle(Palette.plum)
                            Text("Stay in the conversation.").font(.system(size: 36, weight: .semibold)).tracking(-1)
                            Text("Choose a project and describe your call. When a question comes up, a short, relevant answer will appear here.")
                                .font(.system(size: 19)).lineSpacing(5).foregroundStyle(Palette.secondary)
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Put your phone on speaker beside the Mac.", systemImage: "iphone")
                                Label("Let everyone on the call know you're using transcription.", systemImage: "person.wave.2")
                                Label("Click Start listening and allow the microphone.", systemImage: "mic")
                            }.font(.system(size: 14)).padding(.vertical, 6)
                            Button("Try an example question", systemImage: "arrow.right") { model.example() }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(!model.canAnswer)
                        }.padding(.vertical, 20)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.suggestions.count > 1 {
                HStack {
                    Text("Earlier answers").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    Picker("Earlier answers", selection: $model.selectedSuggestion) {
                        ForEach(model.suggestions.reversed()) { item in Text(item.question).tag(Optional(item.id)) }
                    }.labelsHidden().frame(maxWidth: 380)
                    Spacer()
                }.padding(.top, 20)
            }
        }.padding(28).background(.white)
    }

    private func note(_ title: String, text: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.plum)
            Text(text).font(.system(size: 15)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Live conversation").font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: model.listening ? "mic.fill" : "mic.slash").foregroundStyle(model.listening ? Palette.plum : Palette.secondary)
            }
            Text(model.status).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            ProgressView(value: model.level).progressViewStyle(.linear).tint(Palette.plum).accessibilityLabel("Microphone input level")
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.timeline.lines.isEmpty {
                            Text("Speech will appear here as you talk. The input meter above helps you check that the Mac can hear both people.")
                                .font(.system(size: 14)).lineSpacing(4).foregroundStyle(Palette.secondary).padding(.top, 24)
                        }
                        ForEach(model.timeline.lines) { line in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(String(format: "%02d:%02d", Int(line.start) / 60, Int(line.start) % 60))
                                    .font(.system(size: 10, design: .monospaced)).monospacedDigit().foregroundStyle(Palette.secondary)
                                Text(line.text).font(.system(size: 15)).lineSpacing(4).foregroundStyle(line.isFinal ? Palette.ink : Palette.secondary).textSelection(.enabled)
                            }.id(line.id)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: model.timeline.text) { _, _ in reader.scrollTo("latest", anchor: .bottom) }
            }
            Text("One microphone · speakers aren't identified\nCheck names and wording against what you hear.")
                .font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
            HStack {
                Button("Save notes", systemImage: "square.and.arrow.down") { model.exportNotes() }
                Spacer()
                Button("New call") { showClear = true }.disabled(model.listening || model.preparing || model.busy)
            }.controlSize(.small)
        }.padding(22).background(Palette.background)
    }

    private var questionBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.cursor").foregroundStyle(Palette.secondary)
            TextField("Type a question, or press Help now for the latest conversation", text: $model.typedQuestion)
                .textFieldStyle(.plain).font(.system(size: 15)).onSubmit { model.requestAnswer() }
            if model.busy {
                Button("Cancel") { model.cancelAnswer() }.buttonStyle(.bordered)
            } else {
                Button("Help now  ⌘↵") { model.requestAnswer() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).disabled(!model.canAnswer)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Palette.panel)
    }

    private var footer: some View {
        HStack {
            Text("Audio stays on this Mac. Auto help can send call text and selected file excerpts to Codex.")
            Spacer()
            Button("Context & sources", systemImage: "book.closed") { showContext.toggle() }
                .buttonStyle(.plain)
                .sheet(isPresented: $showContext) { contextReview }

        }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var contextReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Context for this call").font(.headline)
                Spacer()
                Button("Done") { showContext = false }
            }
            Text(model.contextStatus).font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Search runs locally. Only selected excerpts, your brief, and call text are sent when requesting a suggestion. Selection adapts as the conversation changes.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.references.isEmpty {
                        Text(model.contextLoading ? "Finding files…" : "No project excerpts selected. Add a call brief or choose another folder.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(model.references) { reference in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(reference.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("Exclude") { model.excludeReference(reference.path) }.controlSize(.small).disabled(model.busy)
                            }
                            Text(reference.excerpt).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    ForEach(model.contextNotices, id: \.self) { notice in
                        Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxHeight: 360)
            if !model.excludedFiles.isEmpty {
                Button("Restore \(model.excludedFiles.count) excluded files") { model.restoreExcludedFiles() }.disabled(model.busy)
            }
            Text("Refresh files after editing your project. Briefs and transcripts stay in memory until you save notes.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 560)
    }

}
