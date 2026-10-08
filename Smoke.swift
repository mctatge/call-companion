import Foundation
import Speech
import AVFoundation

@main
struct Smoke {
    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        if args.contains("--speech") {
            print("SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
            print("Installed locales: \(await SpeechTranscriber.installedLocales.map(\.identifier).joined(separator: ", "))")
            let capture = SpeechCapture()
            capture.onStatus = { print($0) }
            _ = try await capture.prepare()
            print("English speech model ready")
        } else if let index = args.firstIndex(of: "--benchmark-audio"), args.count > index + 1 {
            guard index == 1 else { throw CompanionError(message: "--benchmark-audio must be the first command.") }
            let allowedFlags = Set(["--locale", "--pace", "--context", "--output"])
            var options: [String: String] = [:]
            var cursor = index + 2
            while cursor < args.count {
                let flag = args[cursor]
                guard allowedFlags.contains(flag) else { throw CompanionError(message: "Unknown benchmark option: \(flag)") }
                guard options[flag] == nil else { throw CompanionError(message: "Duplicate benchmark option: \(flag)") }
                guard cursor + 1 < args.count, !args[cursor + 1].hasPrefix("--") else {
                    throw CompanionError(message: "Missing value for \(flag).")
                }
                options[flag] = args[cursor + 1]
                cursor += 2
            }
            let audioURL = URL(fileURLWithPath: args[index + 1])
            let locale = options["--locale"] ?? "en-US"
            let pacingRaw = options["--pace"] ?? BenchmarkPacing.realtime.rawValue
            guard let pacing = BenchmarkPacing(rawValue: pacingRaw) else {
                throw CompanionError(message: "--pace must be realtime or offline.")
            }
            let contextTerms = (options["--context"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let report = try await TranscriptionBenchmark.run(audioURL: audioURL, localeIdentifier: locale,
                                                               pacing: pacing, contextTerms: contextTerms)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            if let output = options["--output"] {
                let outputURL = URL(fileURLWithPath: output)
                try writePrivate(data, to: outputURL)
                print("BENCHMARK: \(output)")
            } else {
                FileHandle.standardError.write(Data("Warning: benchmark JSON contains raw transcript and glossary text.\n".utf8))
                print(String(decoding: data, as: UTF8.self))
            }
            if let failed = report.runs.first(where: { $0.status != "ok" }) {
                throw CompanionError(message: "\(failed.mode) benchmark failed: \(failed.error ?? "unknown error")")
            }
        } else if let index = args.firstIndex(of: "--audio"), args.count > index + 1 {
            let capture = SpeechCapture()
            let transcriber = try await capture.prepare()
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[index + 1]))
            guard file.length > 0 else { throw CompanionError(message: "Synthetic audio file is empty. Generate it outside the shell sandbox.") }
            let results = Task {
                var recognized = ""
                for try await result in transcriber.results {
                    if result.isFinal { recognized += String(result.text.characters) + " " }
                }
                return recognized
            }
            // Feed through the same conversion bridge as the live microphone.
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: file.processingFormat) else {
                throw CompanionError(message: "No compatible speech audio format")
            }
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let bridge = AudioBridge(source: file.processingFormat, destination: format, continuation: continuation,
                                     onLevel: { _ in }, onFailure: { print("CONVERSION ERROR: \($0)") })!
            try await analyzer.start(inputSequence: stream)
            let timeout = Task {
                try? await Task.sleep(for: .seconds(40))
                if !Task.isCancelled { await analyzer.cancelAndFinishNow() }
            }
            defer { timeout.cancel() }
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
                try file.read(into: buffer)
                bridge.append(buffer)
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let recognized = try await results.value
            print("TRANSCRIBED: \(recognized)")
            await analyzer.cancelAndFinishNow()
            guard recognized.lowercased().contains("spreadsheet") else { throw CompanionError(message: "Synthetic speech was not transcribed correctly.") }
        } else if let index = args.firstIndex(of: "--answer"), args.count > index + 1 {
            let engine = try AnswerEngine(resources: URL(fileURLWithPath: args[index + 1]))
            let date = Date()
            let question = args.count > index + 2 ? args[index + 2] : "What are three useful questions to clarify expectations on a project kickoff call?"
            let references: [RetrievedReference]
            if let projectArg = args.firstIndex(of: "--project"), args.count > projectArg + 1 {
                let context = try ProjectContextLoader.load(root: URL(fileURLWithPath: args[projectArg + 1]))
                references = context.retrieve(query: question)
                print("Retrieved \(references.count) references")
            } else { references = [] }
            let result = try await engine.answer(transcript: "", question: question, previous: [], automatic: false,
                brief: "A project kickoff call", projectName: "Smoke test", references: references)
            print("QUESTION: \(question)\nANSWER (\(Int(Date().timeIntervalSince(date))) seconds): \(result.answer)\nCAVEAT: \(result.caveat)\nFOLLOW UP: \(result.follow_up)\nSOURCE: \(result.source)")
            guard result.should_answer, !result.answer.isEmpty else { throw CompanionError(message: "No answer returned.") }
        } else {
            var timeline = TranscriptTimeline()
            let session = UUID()
            timeline.update(session: session, offset: 0, start: 0, end: 2, text: "Can it", isFinal: false)
            timeline.update(session: session, offset: 0, start: 0, end: 4, text: "Can it inspect spreadsheets?", isFinal: true)
            precondition(timeline.lines.count == 1 && timeline.text == "Can it inspect spreadsheets?")
            timeline.update(session: session, offset: 0, start: 4, end: 6, text: "What about", isFinal: false)
            timeline.update(session: session, offset: 0, start: 4.1, end: 8, text: "What about privacy?", isFinal: true)
            precondition(timeline.lines.count == 2)
            timeline.update(session: UUID(), offset: 8, start: 0, end: 2, text: "After resuming", isFinal: true)
            precondition(timeline.lines.count == 3 && timeline.end == 10)
            timeline.update(session: session, offset: 0, start: .nan, end: 4, text: "invalid", isFinal: true)
            precondition(timeline.lines.count == 3)
            let excerpt = conversationExcerpt(String(repeating: "a", count: 20000) + "new question")
            precondition(excerpt.count < 14000 && excerpt.hasSuffix("new question"))
            // The project, course, and person in this vocabulary fixture are fictional.
            let terms = speechContextTerms(
                projectName: "LumaQ",
                callBrief: "Discuss ZYX 6207, XR-17, Q4, C++, and SOC 2 with Dr. Tovin about LumaQ, then cover ordinary onboarding details."
            )
            precondition(terms.first == "LumaQ")
            precondition(terms.contains("ZYX 6207") && terms.contains("XR-17") && terms.contains("Q4"))
            precondition(terms.contains("C++") && terms.contains("SOC 2") && terms.contains("Tovin"))
            precondition(terms.filter { $0.caseInsensitiveCompare("LumaQ") == .orderedSame }.count == 1)
            precondition(Set(terms.map { $0.lowercased() }).count == terms.count)
            precondition(speechContextTerms(projectName: "General call", callBrief: "", limit: 0).isEmpty)
            print("PASS: partial replacement, segment revisions, pause/resume offsets, invalid timestamps, bounded context, focused speech vocabulary")
        }
    }

    private static func writePrivate(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CompanionError(message: "Could not create a private benchmark output file.")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }
}
