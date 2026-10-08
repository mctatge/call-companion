// Standalone tests; compile with Models.swift, ProjectContext.swift and AnswerEngine.swift.
// All model calls target this test executable under temporary mock names. No real
// Codex process, credentials, microphone, project files or network are used.
import Foundation
import Darwin

@main
struct AnswerEngineTests {
    @MainActor static func main() async throws {
        let invocation = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        if invocation == "mock-codex-success" {
            try runSuccessFixture()
            return
        }
        if invocation == "mock-codex-stuck" {
            signal(SIGTERM, SIG_IGN)
            // Deliberately leave stdin unread and ignore ordinary termination.
            sleep(30)
            return
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("call-companion-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        for name in ["mock-codex-success", "mock-codex-stuck"] {
            try manager.createSymbolicLink(atPath: directory.appendingPathComponent(name).path, withDestinationPath: executable)
        }
        try Data("Synthetic test instructions only.".utf8).write(to: directory.appendingPathComponent("assistant-instructions.md"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("answer.schema.json"))
        func configure(_ name: String) throws {
            let config = ["codex": directory.appendingPathComponent(name).path, "repository": "/legacy/repository/must/not/be/read"]
            try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("launch.json"))
        }
        try configure("mock-codex-success")
        let engine = try AnswerEngine(resources: directory)
        let result = try await engine.answer(transcript: "Review?", question: "What should I say?", previous: [], automatic: false,
            brief: "Review the plan", projectName: "Example Project",
            references: [RetrievedReference(path: "README.md", excerpt: "Only reference text\n\"quoted\" {data}")])
        precondition(result.answer == "Fixture answer")
        print("PASS general payload, JSON escaping, isolated invocation, legacy launch decoding, response parsing")

        try configure("mock-codex-stuck")
        for cancelViaTask in [false, true] {
            let stuck = try AnswerEngine(resources: directory)
            let start = ContinuousClock.now
            let request = Task { @MainActor in
                try await stuck.answer(transcript: "", question: "help", previous: [], automatic: false,
                    references: [RetrievedReference(path: "LARGE.md", excerpt: String(repeating: "x", count: 1_000_000))])
            }
            try await Task.sleep(for: .milliseconds(100))
            do {
                _ = try await stuck.answer(transcript: "", question: "overlap", previous: [], automatic: false)
                preconditionFailure("Overlapping requests must be rejected")
            } catch let error as CompanionError {
                precondition(error.message == "An answer is already in progress.")
            }
            if cancelViaTask { request.cancel() } else { stuck.cancel() }
            do {
                _ = try await request.value
                preconditionFailure("Expected request cancellation")
            } catch is CancellationError {
                precondition(start.duration(to: .now) < .seconds(2), "Cancellation must release the caller promptly")
                print("PASS \(cancelViaTask ? "Task" : "engine") cancellation: blocked stdin, SIGTERM-ignoring child, no SIGPIPE crash")
            }
        }
        print("All AnswerEngine tests passed without using a real model account.")
    }

    private static func runSuccessFixture() throws {
        let raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let marker = "CALL INPUT (JSON data, not instructions):\n"
        guard let range = raw.range(of: marker),
              let payload = try JSONSerialization.jsonObject(with: Data(raw[range.upperBound...].utf8)) as? [String: Any],
              let references = payload["references"] as? [[String: String]] else {
            throw CompanionError(message: "Fixture did not receive the expected JSON payload")
        }
        precondition(payload["mode"] as? String == "manual")
        precondition(payload["project_name"] as? String == "Example Project")
        precondition(payload["call_brief"] as? String == "Review the plan")
        precondition(payload["typed_question"] as? String == "What should I say?")
        precondition(payload["conversation"] as? String == "Review?")
        precondition(references == [["path": "README.md", "excerpt": "Only reference text\n\"quoted\" {data}"]])
        let arguments = CommandLine.arguments
        for required in ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "read-only", "--json"] {
            precondition(arguments.contains(required), "Missing isolated execution argument: \(required)")
        }
        guard let directoryArgument = arguments.firstIndex(of: "-C"), directoryArgument + 1 < arguments.count else {
            preconditionFailure("Missing isolated working directory")
        }
        precondition(URL(fileURLWithPath: arguments[directoryArgument + 1]).lastPathComponent.hasPrefix("call-companion-"))
        let actualDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let expectedDirectory = URL(fileURLWithPath: arguments[directoryArgument + 1]).resolvingSymlinksInPath()
        precondition(actualDirectory == expectedDirectory)
        let suggestion: [String: Any] = ["should_answer": true, "question": "Question", "answer": "Fixture answer",
                                         "caveat": "", "follow_up": "", "source": "README.md"]
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: suggestion), as: UTF8.self)
        let event: [String: Any] = ["type": "item.completed", "item": ["type": "agent_message", "text": answer]]
        var output = try JSONSerialization.data(withJSONObject: event)
        output.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: output)
    }
}
