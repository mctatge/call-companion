import AVFoundation
import Speech
import Foundation

enum AppleSpeechMode: String, CaseIterable, Sendable {
    case currentFast = "speech-fast"
    case accurate = "speech-accurate"

    var reportingOptions: Set<SpeechTranscriber.ReportingOption> {
        switch self {
        case .currentFast: [.volatileResults, .fastResults]
        case .accurate: [.volatileResults]
        }
    }
}

// Audio buffers belong to the audio callback. Convert/copy before handing them
// to the asynchronous analyzer; never retain AVAudioEngine's borrowed buffer.
final class AudioBridge: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let onLevel: @Sendable (Double) -> Void
    let onFailure: @Sendable (String) -> Void
    private var lastMeter = Date.distantPast

    init?(source: AVAudioFormat, destination: AVAudioFormat,
          continuation: AsyncStream<AnalyzerInput>.Continuation,
          onLevel: @escaping @Sendable (Double) -> Void,
          onFailure: @escaping @Sendable (String) -> Void) {
        guard let converter = AVAudioConverter(from: source, to: destination) else { return nil }
        self.converter = converter
        self.format = destination
        self.continuation = continuation
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> AVAudioFrameCount {
        if Date().timeIntervalSince(lastMeter) > 0.1 {
            lastMeter = Date()
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                let rms = sqrt(Double(sum) / Double(buffer.frameLength))
                onLevel(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60)))
            }
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return 0 }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        if status == .error {
            onFailure(error?.localizedDescription ?? "Microphone audio conversion failed.")
            return 0
        } else if output.frameLength > 0 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                onFailure("Transcription could not keep up with the microphone. Pause and start again.")
                return 0
            }
        }
        return output.frameLength
    }
}

@MainActor
final class SpeechCapture {
    var onText: ((Double, Double, String, Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var running = false

    func prepare(mode: AppleSpeechMode = .accurate, localeIdentifier: String = "en-US") async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw CompanionError(message: "On-device transcription for \(localeIdentifier) is unavailable on this Mac. You can still type questions below.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: mode.reportingOptions, attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?("Downloading Apple's \(localeIdentifier) speech model…")
            try await install.downloadAndInstall()
        }
        return transcriber
    }

    func start(contextualStrings: [String] = []) async throws {
        let token = UUID()
        generation = token
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == token else { throw CancellationError() }
        guard allowed else {
            throw CompanionError(message: "Allow Call Companion in System Settings → Privacy & Security → Microphone, then start again.")
        }
        let transcriber = try await prepare()
        guard generation == token else { throw CancellationError() }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let naturalFormat = input.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else {
            throw CompanionError(message: "No usable microphone input. Select the Mac microphone in System Settings → Sound → Input.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(contextualStrings.prefix(60))
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        guard generation == token else { await analyzer.cancelAndFinishNow(); throw CancellationError() }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(100))
        guard let bridge = AudioBridge(source: naturalFormat, destination: format, continuation: continuation,
            onLevel: { [weak self] level in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.onLevel?(level)
            } },
            onFailure: { [weak self] message in Task { @MainActor in
                guard let self, self.generation == token, self.running else { return }
                self.onError?(message)
            } }) else {
            throw CompanionError(message: "The selected microphone format cannot be converted for transcription.")
        }
        self.engine = engine
        self.analyzer = analyzer
        self.continuation = continuation
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == token else { return }
                    self.onText?(result.range.start.seconds, result.range.end.seconds,
                                 String(result.text.characters), result.isFinal)
                }
            } catch {
                guard let self, self.generation == token, self.running else { return }
                self.onError?("Transcription stopped: \(error.localizedDescription)")
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
            input.installTap(onBus: 0, bufferSize: 4096, format: naturalFormat) { buffer, _ in bridge.append(buffer) }
            engine.prepare()
            try engine.start()
            running = true
            onStatus?("Listening through this Mac's microphone")
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        running = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        continuation?.finish()
        continuation = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        resultTask?.cancel()
        resultTask = nil
        generation = UUID()
        onLevel?(0)
    }
}
