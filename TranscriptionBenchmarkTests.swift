import Foundation

private struct Manifest: Decodable {
    let schemaVersion: Int
    let clips: [Clip]
}

private struct Clip: Decodable {
    let id: String
    let category: String
    let pairId: String?
    let locale: String
    let speakerCount: Int
    let capturePlan: String
    let script: String
    let criticalTerms: [String]
    let status: String
    let audio: String?
    let sha256: String?
    let verbatimReference: String?
    let consentStatus: String
}

@main
struct TranscriptionBenchmarkTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass the transcription fixture manifest path.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        precondition(manifest.schemaVersion == 1)
        precondition(manifest.clips.count == 12)
        precondition(Set(manifest.clips.map(\.id)).count == manifest.clips.count)

        let expectedCounts = [
            "clean-near-field": 3,
            "phone-speaker-replay": 3,
            "names-acronyms": 2,
            "critical-content": 2,
            "moderate-noise": 1,
            "controlled-overlap": 1
        ]
        let counts = Dictionary(grouping: manifest.clips, by: \.category).mapValues(\.count)
        precondition(counts == expectedCounts)

        for clip in manifest.clips {
            precondition(!clip.id.isEmpty && clip.locale == "en-US" && clip.speakerCount > 0)
            precondition(!clip.capturePlan.isEmpty && !clip.script.isEmpty && !clip.criticalTerms.isEmpty)
            switch clip.status {
            case "planned":
                precondition(clip.audio == nil && clip.sha256 == nil && clip.verbatimReference == nil)
                precondition(clip.consentStatus == "not-recorded")
            case "recorded":
                precondition(clip.audio != nil && clip.sha256 != nil && clip.verbatimReference == nil)
                precondition(clip.consentStatus == "informed-participants")
            case "reference-ready":
                precondition(clip.audio != nil && clip.sha256 != nil && clip.verbatimReference != nil)
                precondition(clip.consentStatus == "informed-participants")
            default:
                preconditionFailure("Unknown fixture state: \(clip.status)")
            }
        }

        for pairId in ["voice-a", "voice-b", "voice-c"] {
            let pair = manifest.clips.filter { $0.pairId == pairId }
            precondition(pair.count == 2)
            precondition(Set(pair.map(\.category)) == Set(["clean-near-field", "phone-speaker-replay"]))
            precondition(Set(pair.map(\.script)).count == 1)
        }
        precondition(manifest.clips.filter { $0.pairId != nil }.count == 6)
        print("PASS: 12 transcription fixtures, paired capture controls, valid evidence lifecycle states")
    }
}
