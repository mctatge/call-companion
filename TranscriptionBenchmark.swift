import AVFoundation
import CryptoKit
import Foundation
import Speech

enum BenchmarkPacing: String, Codable {
    case realtime
    case offline
}

struct BenchmarkEventRecord: Codable {
    let audioStartMs: Double
    let audioEndMs: Double
    let emittedMs: Double
    let isFinal: Bool
    let text: String
}

struct BenchmarkRunRecord: Codable {
    let mode: String
    let engine: String
    let reportingOptions: [String]
    let pacing: String
    let sequenceIndex: Int
    let status: String
    let error: String?
    let inputSha256: String?
    let selectedLocale: String?
    let analyzerFormat: String?
    let bufferFrames: Int
    let sourceFramesFed: Int64?
    let convertedFramesDelivered: Int64?
    let setupMs: Double?
    let firstEventMs: Double?
    let firstFinalMs: Double?
    let endOfInputMs: Double?
    let completedMs: Double?
    let tailFinalizationMs: Double?
    let offlineRealTimeFactor: Double?
    let partialEventCount: Int
    let finalEventCount: Int
    let events: [BenchmarkEventRecord]
    let rawTranscript: String
}

struct BenchmarkInputRecord: Codable {
    let fileName: String
    let sha256: String
    let byteCount: Int64
    let frameCount: Int64
    let sampleRateHz: Double
    let channels: Int
    let durationMs: Double
    let processingFormat: String
}

struct BenchmarkEnvironmentRecord: Codable {
    let macOSVersion: String
    let architecture: String
    let requestedLocale: String
    let appleModelVersion: String
    let harnessVersion: String
}

struct TranscriptionBenchmarkReport: Codable {
    let schemaVersion: Int
    let runId: String
    let createdAt: String
    let input: BenchmarkInputRecord
    let environment: BenchmarkEnvironmentRecord
    let contextTerms: [String]
    let runs: [BenchmarkRunRecord]
}

private final class BenchmarkFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ message: String) {
        lock.lock()
        if stored == nil { stored = message }
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@MainActor
enum TranscriptionBenchmark {
    static func run(audioURL: URL, localeIdentifier: String, pacing: BenchmarkPacing,
                    contextTerms: [String]) async throws -> TranscriptionBenchmarkReport {
        let input = try inputRecord(for: audioURL)
        var runs: [BenchmarkRunRecord] = []
        for (index, mode) in [AppleSpeechMode.currentFast, .accurate].enumerated() {
            do {
                runs.append(try await run(audioURL: audioURL, input: input, mode: mode,
                                          localeIdentifier: localeIdentifier, pacing: pacing,
                                          contextTerms: contextTerms, sequenceIndex: index))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                runs.append(failedRun(mode: mode, pacing: pacing, sequenceIndex: index, error: error))
            }
        }

        return TranscriptionBenchmarkReport(
            schemaVersion: 1,
            runId: UUID().uuidString,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            input: input,
            environment: BenchmarkEnvironmentRecord(
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture,
                requestedLocale: localeIdentifier,
                appleModelVersion: "not exposed by API",
                harnessVersion: "1"
            ),
            contextTerms: Array(contextTerms.prefix(60)),
            runs: runs
        )
    }

    private static func run(audioURL: URL, input: BenchmarkInputRecord, mode: AppleSpeechMode,
                            localeIdentifier: String, pacing: BenchmarkPacing,
                            contextTerms: [String], sequenceIndex: Int) async throws -> BenchmarkRunRecord {
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let runInputSha256 = try sha256(for: audioURL)
        guard runInputSha256 == input.sha256 else {
            throw CompanionError(message: "Benchmark audio changed after the run started.")
        }
        let capture = SpeechCapture()
        let transcriber = try await capture.prepare(mode: mode, localeIdentifier: localeIdentifier)
        let file = try AVAudioFile(forReading: audioURL)
        guard file.length > 0 else { throw CompanionError(message: "Benchmark audio file is empty.") }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: file.processingFormat
        ) else { throw CompanionError(message: "No compatible speech audio format.") }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(contextTerms.prefix(60))
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let failure = BenchmarkFailureBox()
        var resultTask: Task<[BenchmarkEventRecord], Error>?
        guard let bridge = AudioBridge(source: file.processingFormat, destination: format,
                                       continuation: continuation, onLevel: { _ in },
                                       onFailure: { failure.set($0) }) else {
            throw CompanionError(message: "Benchmark audio cannot be converted for transcription.")
        }

        do {
            try await analyzer.start(inputSequence: stream)
            let setupMs = milliseconds(since: setupStarted)
            let runStarted = ProcessInfo.processInfo.systemUptime
            let results = Task { () throws -> [BenchmarkEventRecord] in
                var events: [BenchmarkEventRecord] = []
                for try await result in transcriber.results {
                    events.append(BenchmarkEventRecord(
                        audioStartMs: result.range.start.seconds * 1000,
                        audioEndMs: result.range.end.seconds * 1000,
                        emittedMs: milliseconds(since: runStarted),
                        isFinal: result.isFinal,
                        text: String(result.text.characters)
                    ))
                }
                return events
            }
            resultTask = results
            var framesFed: AVAudioFramePosition = 0
            var convertedFramesDelivered: Int64 = 0
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                    throw CompanionError(message: "Could not allocate a benchmark audio buffer.")
                }
                try file.read(into: buffer)
                framesFed += AVAudioFramePosition(buffer.frameLength)
                if pacing == .realtime {
                    let target = Double(framesFed) / file.processingFormat.sampleRate
                    let remaining = target - (ProcessInfo.processInfo.systemUptime - runStarted)
                    if remaining > 0 {
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                }
                convertedFramesDelivered += Int64(bridge.append(buffer))
                if let message = failure.get() { throw CompanionError(message: message) }
            }
            continuation.finish()
            let endOfInputMs = milliseconds(since: runStarted)
            let tailTimeoutSeconds = max(30, min(120, input.durationMs / 4000 + 15))
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(tailTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                failure.set("Transcription did not finish within \(Int(tailTimeoutSeconds)) seconds after end of input.")
                results.cancel()
                await analyzer.cancelAndFinishNow()
            }
            defer { timeout.cancel() }
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                if let message = failure.get() { throw CompanionError(message: message) }
                throw error
            }
            let events: [BenchmarkEventRecord]
            do { events = try await results.value }
            catch {
                if let message = failure.get() { throw CompanionError(message: message) }
                throw error
            }
            timeout.cancel()
            let completedMs = milliseconds(since: runStarted)
            await analyzer.cancelAndFinishNow()
            let partialCount = events.filter { !$0.isFinal }.count
            let finals = events.filter(\.isFinal)
            guard !finals.isEmpty, finals.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CompanionError(message: "The recognizer produced no final speech transcript.")
            }
            return BenchmarkRunRecord(
                mode: mode.rawValue,
                engine: "Apple SpeechTranscriber",
                reportingOptions: mode == .currentFast ? ["volatileResults", "fastResults"] : ["volatileResults"],
                pacing: pacing.rawValue,
                sequenceIndex: sequenceIndex,
                status: "ok",
                error: nil,
                inputSha256: runInputSha256,
                selectedLocale: transcriber.selectedLocales.first?.identifier,
                analyzerFormat: format.description,
                bufferFrames: 4096,
                sourceFramesFed: Int64(framesFed),
                convertedFramesDelivered: convertedFramesDelivered,
                setupMs: rounded(setupMs),
                firstEventMs: events.first.map { rounded($0.emittedMs) },
                firstFinalMs: finals.first.map { rounded($0.emittedMs) },
                endOfInputMs: rounded(endOfInputMs),
                completedMs: rounded(completedMs),
                tailFinalizationMs: rounded(max(0, completedMs - endOfInputMs)),
                offlineRealTimeFactor: pacing == .offline && input.durationMs > 0 ? rounded(completedMs / input.durationMs) : nil,
                partialEventCount: partialCount,
                finalEventCount: finals.count,
                events: events,
                rawTranscript: finals.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            continuation.finish()
            resultTask?.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private static func failedRun(mode: AppleSpeechMode, pacing: BenchmarkPacing,
                                  sequenceIndex: Int, error: Error) -> BenchmarkRunRecord {
        BenchmarkRunRecord(
            mode: mode.rawValue,
            engine: "Apple SpeechTranscriber",
            reportingOptions: mode == .currentFast ? ["volatileResults", "fastResults"] : ["volatileResults"],
            pacing: pacing.rawValue,
            sequenceIndex: sequenceIndex,
            status: "failed",
            error: error.localizedDescription,
            inputSha256: nil,
            selectedLocale: nil,
            analyzerFormat: nil,
            bufferFrames: 4096,
            sourceFramesFed: nil,
            convertedFramesDelivered: nil,
            setupMs: nil,
            firstEventMs: nil,
            firstFinalMs: nil,
            endOfInputMs: nil,
            completedMs: nil,
            tailFinalizationMs: nil,
            offlineRealTimeFactor: nil,
            partialEventCount: 0,
            finalEventCount: 0,
            events: [],
            rawTranscript: ""
        )
    }

    private static func inputRecord(for url: URL) throws -> BenchmarkInputRecord {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = try sha256(for: url)
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let durationMs = sampleRate > 0 ? Double(file.length) / sampleRate * 1000 : 0
        return BenchmarkInputRecord(
            fileName: url.lastPathComponent,
            sha256: digest,
            byteCount: Int64(data.count),
            frameCount: file.length,
            sampleRateHz: sampleRate,
            channels: Int(file.processingFormat.channelCount),
            durationMs: rounded(durationMs),
            processingFormat: file.processingFormat.description
        )
    }

    private static func sha256(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
