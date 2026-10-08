import Foundation
import PDFKit
import AppKit
import CoreText

@main
struct ProjectContextTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("call-companion-context-tests-\(UUID().uuidString)")
        let project = fixture.appendingPathComponent("project")
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        func write(_ path: String, _ contents: String) throws {
            let target = project.appendingPathComponent(path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "ProjectContextTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("PASS: \(message)")
        }

        try write("README.md", "# Acorn Studio\nA desktop audio product.\nSee docs for customer plans.\n")
        try write("CLAUDE.md", "# Project map\nPricing is documented in docs/pricing.md.\n")
        try write("docs/pricing.md", "# Enterprise pricing\nAnnual commitment is $8,000.\nPilot discounts require approval.\n")
        try write("src/audio.swift", "// Audio input code\nlet recording = true\n")
        try write("packages/product/README.md", "First-party monorepo package documentation.")
        try write("docs/long-history.md", String(repeating: "Old gardening notes and unrelated records.\n", count: 8_000) + "\n# Zephyr launch\nThe zephyr integration deadline is October 14.\n")
        try write("node_modules/dependency/README.md", "forbidden dependency zephyr")
        try write(".git/config", "forbidden git metadata")
        try write(".env", "API_KEY=forbidden")
        try write("credentials.json", "{\"password\":\"forbidden\"}")
        try write("private_key.txt", "forbidden private key")
        try write("service-account.json", "forbidden service account")
        try write("backup.txt", "-----BEGIN RSA PRIVATE KEY-----\nforbidden private key\n-----END RSA PRIVATE KEY-----")
        try write("dist/bundle.js", "forbidden generated bundle")
        try write("src/bundle.min.js", "forbidden minified bundle")
        try write("package-lock.json", "forbidden lockfile")
        try write("oversized.txt", String(repeating: "a", count: ProjectContextLoader.maximumTextBytes + 1))
        try write("nulls.txt", "binary\u{0000}content")
        let outside = fixture.appendingPathComponent("outside.md")
        try "forbidden external symlink secret".write(to: outside, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: project.appendingPathComponent("linked.md"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: project.appendingPathComponent("external-folder"), withDestinationURL: fixture)
        let deep = Array(repeating: "nested", count: ProjectContextLoader.maximumDepth + 1).joined(separator: "/")
        try write(deep + "/deep.md", "forbidden beyond depth")

        let index = try ProjectContextLoader.load(root: project)
        try require(index.documents.count == 6, "Only six supported, safe fixture documents are indexed (found \(index.documents.map(\.path)))")
        try require(index.documents.contains { $0.path == "packages/product/README.md" }, "First-party monorepo packages are retained")
        try require(index.documents.allSatisfy { !$0.text.contains("forbidden") }, "Dependencies, hidden files, secrets, build output, symlinks and depth overflow are excluded")
        try require(index.notices.contains { $0.contains("oversized.txt") }, "Oversized files produce a notice")
        try require(index.notices.contains { $0.contains("nulls.txt") }, "Binary text produces a notice")
        try require(index.notices.contains { $0.contains("private-key material") }, "Private keys under innocuous filenames are skipped with a notice")
        try require(index.notices.contains { $0.contains("Depth limit") }, "Depth limits produce a notice")
        let pricing = index.retrieve(query: "Discuss enterprise pricing and annual commitment")
        try require(pricing.first?.path == "docs/pricing.md", "The call brief ranks its relevant pricing document first")
        try require(pricing.first?.excerpt.contains("$8,000") == true, "The retrieved excerpt contains supporting facts")
        try require(pricing.first?.excerpt.contains("Lines ") == true, "Text excerpts include line locators")
        let late = index.retrieve(query: "zephyr integration deadline")
        try require(late.first?.path == "docs/long-history.md" && late.first?.excerpt.contains("October 14") == true, "Relevant content near the end of a long document is retrieved")
        let defaults = index.retrieve(query: "")
        try require(defaults.first?.path == "README.md", "An empty brief starts with project README context")
        try require(defaults.contains { $0.path == "CLAUDE.md" }, "An empty brief includes the project router")
        try require(index.retrieve(query: "enterprise pricing", excluding: ["docs/pricing.md"]).allSatisfy { $0.path != "docs/pricing.md" }, "Explicit reference exclusions are respected")
        for budget in [0, 1, 40, 100, 500, 2_000, 22_000] {
            let result = index.retrieve(query: "zephyr deadline", maxCharacters: budget)
            try require(result.reduce(0) { $0 + $1.path.count + $1.excerpt.count } <= budget, "Retrieval stays within its \(budget)-character budget")
        }
        let many = ProjectIndex(root: project, documents: (0..<12).map { ProjectDocument(path: "doc\($0).md", text: "# Onboarding\nOnboarding requirements differ by customer.") }, notices: [])
        try require(many.retrieve(query: "onboarding").count == 7, "Retrieval diversifies over at most seven files")
        let longLine = ProjectIndex(root: project, documents: [ProjectDocument(path: "one-line.md", text: String(repeating: "a", count: 8_000) + " targetphrase contractual deadline")], notices: [])
        try require(longLine.retrieve(query: "targetphrase").first?.excerpt.contains("contractual deadline") == true, "Long single-line tails can be retrieved")

        // Draw actual PDF text, so this verifies PDFKit extraction as well as locators.
        let pdfURL = project.appendingPathComponent("contract.pdf")
        let consumer = CGDataConsumer(url: pdfURL as CFURL)!
        var pageBounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: consumer, mediaBox: &pageBounds, nil)!
        for message in ["First page is background.", "Quasar renewal deadline is November 3."] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 30, y: 650)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let scanURL = project.appendingPathComponent("scan.pdf")
        let scanContext = CGContext(consumer: CGDataConsumer(url: scanURL as CFURL)!, mediaBox: &pageBounds, nil)!
        scanContext.beginPDFPage(nil)
        scanContext.setFillColor(CGColor(gray: 0.8, alpha: 1))
        scanContext.fill(CGRect(x: 40, y: 40, width: 500, height: 700))
        scanContext.endPDFPage()
        scanContext.closePDF()
        let pdfIndex = try ProjectContextLoader.load(root: project)
        try require(pdfIndex.notices.contains { $0.contains("scan.pdf") && $0.contains("no extractable text") }, "Image-only PDFs report that OCR is required")
        let pdfMatch = pdfIndex.retrieve(query: "Quasar renewal deadline")
        try require(pdfMatch.first?.excerpt.contains("PDF page 2") == true && pdfMatch.first?.excerpt.contains("November 3") == true, "PDF passages retain the matching page locator")

        let empty = fixture.appendingPathComponent("empty")
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyIndex = try ProjectContextLoader.load(root: empty)
        try require(emptyIndex.documents.isEmpty && emptyIndex.retrieve(query: "anything").isEmpty, "Empty folders return no invented context")
        try require(emptyIndex.notices.contains { $0.contains("No supported") }, "Empty folders explain the lack of indexed content")
        do {
            _ = try ProjectContextLoader.load(root: project.appendingPathComponent("README.md"))
            throw NSError(domain: "ProjectContextTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "A file was incorrectly accepted as the project folder"])
        } catch let error as NSError {
            try require(error.domain == "CallCompanion.ProjectContext", "Non-folder selections are rejected")
        }
        let cancellation = Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try ProjectContextLoader.load(root: project); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await cancellation.value
        try require(cancelled, "Folder indexing cooperatively honors task cancellation")

        let hashFolder = fixture.appendingPathComponent("hash-artifacts/snapshots")
        try manager.createDirectory(at: hashFolder, withIntermediateDirectories: true)
        for (name, text) in [
            (String(repeating: "a1", count: 32) + ".json", "generated JSON record"),
            (String(repeating: "B2", count: 16) + ".csv", "generated CSV record"),
            ("manual-review.md", "Human-written snapshot review."),
            (String(repeating: "a", count: 31) + ".json", "Short identifiers are retained.")
        ] {
            try text.write(to: hashFolder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let hashIndex = try ProjectContextLoader.load(root: hashFolder.deletingLastPathComponent())
        try require(hashIndex.documents.count == 2 && hashIndex.documents.allSatisfy { !$0.text.contains("generated") }, "Hash-only generated data filenames are excluded")
        try require(hashIndex.documents.contains { $0.path == "snapshots/manual-review.md" }, "Human documents inside snapshots directories remain indexable")

        let manyFolder = fixture.appendingPathComponent("many")
        try manager.createDirectory(at: manyFolder, withIntermediateDirectories: true)
        for number in 0...ProjectContextLoader.maximumFiles {
            try "File count fixture.".write(to: manyFolder.appendingPathComponent("doc-\(number).md"), atomically: true, encoding: .utf8)
        }
        let fileLimited = try ProjectContextLoader.load(root: manyFolder)
        try require(fileLimited.documents.count == ProjectContextLoader.maximumFiles && fileLimited.notices.contains { $0.contains("Index stopped at") }, "The file-count cap is enforced and reported")
        let byteFolder = fixture.appendingPathComponent("byte-limit")
        try manager.createDirectory(at: byteFolder, withIntermediateDirectories: true)
        let megabyte = String(repeating: "Bounded content.\n", count: 65_536)
        for number in 0..<18 {
            try megabyte.write(to: byteFolder.appendingPathComponent("data-\(number).json"), atomically: true, encoding: .utf8)
        }
        let sourceURL = byteFolder.appendingPathComponent("zsrc/modules/feature/main.swift")
        try manager.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let importantFeature = true".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "# Project overview\nImportant human context.".write(to: byteFolder.appendingPathComponent("overview.md"), atomically: true, encoding: .utf8)
        let byteLimited = try ProjectContextLoader.load(root: byteFolder)
        try require(byteLimited.documents.prefix(2).map(\.path) == ["overview.md", "zsrc/modules/feature/main.swift"], "Human docs and nested source code load before structured data can consume the index budget")
        try require(byteLimited.documents.reduce(0) { $0 + $1.text.utf8.count } <= ProjectContextLoader.maximumIndexedBytes, "The total indexed-text byte cap is enforced")
        try require(byteLimited.notices.contains { $0.contains("total text-index limit") }, "The total indexed-text byte cap is reported")

        let corpus = (0..<500).map { number in
            ProjectDocument(path: "docs/operations-\(number).md", text:
                String(repeating: "Operations records contain general business context.\n", count: 400) +
                (number == 357 ? "Lunar onboarding deadline is December 9.\n" : ""))
        }
        let preparedAt = Date()
        let largeIndex = ProjectIndex(root: project, documents: corpus, notices: [])
        let preparationTime = Date().timeIntervalSince(preparedAt)
        let queriedAt = Date()
        let largeResult = largeIndex.retrieve(query: "lunar onboarding deadline")
        let retrievalTime = Date().timeIntervalSince(queriedAt)
        let bytes = corpus.reduce(0) { $0 + $1.text.utf8.count }
        print(String(format: "TIMING: %d documents, %.1f MB, %.3f s initial preparation, %.3f s retrieval", corpus.count, Double(bytes) / 1_000_000, preparationTime, retrievalTime))
        try require(largeResult.first?.path == "docs/operations-357.md", "A 500-document corpus finds the relevant file")
        try require(retrievalTime < 2, "Cached retrieval stays responsive for a 10 MB corpus")
        print("All project-context tests passed.")
    }
}
