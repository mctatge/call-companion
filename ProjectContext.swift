import Foundation
import PDFKit

struct ProjectDocument {
    let path: String
    let text: String
}

struct RetrievedReference: Identifiable {
    var id: String { path }
    let path: String
    let excerpt: String
}

struct ProjectIndex {
    let root: URL
    let documents: [ProjectDocument]
    let notices: [String]
    private let preparedDocuments: [ContextRanking.PreparedDocument]

    init(root: URL, documents: [ProjectDocument], notices: [String]) {
        self.root = root
        self.documents = documents
        self.notices = notices
        var prepared: [ContextRanking.PreparedDocument] = []
        for document in documents {
            if Task<Never, Never>.isCancelled { break }
            prepared.append(ContextRanking.prepare(document))
        }
        preparedDocuments = prepared
    }

    /// Ranks local content only. Text from a folder is reference material, never instructions.
    /// The budget includes both excerpt text and paths; at most seven files are returned.
    func retrieve(query: String, excluding: Set<String> = [], maxCharacters: Int = 22_000) -> [RetrievedReference] {
        guard maxCharacters > 0, !Task<Never, Never>.isCancelled else { return [] }
        let available = preparedDocuments.filter { !excluding.contains($0.document.path) }
        let queryWords = ContextRanking.words(query).filter { !ContextRanking.stopWords.contains($0) }
        let terms = Set(queryWords)
        let phrase = ContextRanking.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let phraseUseful = queryWords.count >= 2 && phrase.count >= 8

        var frequency: [String: Int] = [:]
        for document in available {
            if Task<Never, Never>.isCancelled { return [] }
            for term in terms where document.words.contains(term) { frequency[term, default: 0] += 1 }
        }
        var ranked: [(document: ProjectDocument, chunks: [(ContextRanking.Chunk, Double)], score: Double)] = []
        for prepared in available {
            if Task<Never, Never>.isCancelled { return [] }
            let document = prepared.document
            let chunks = prepared.chunks
            guard !chunks.isEmpty else { continue }
            let pathScore = terms.reduce(0.0) { result, term in
                result + (prepared.pathWords.contains(term) ? 5.0 * ContextRanking.weight(term, frequency, available.count) : 0)
            }
            var scored: [(ContextRanking.Chunk, Double)] = []
            for chunk in chunks {
                if Task<Never, Never>.isCancelled { return [] }
                var score = pathScore
                for term in terms {
                    if let count = chunk.counts[term] {
                        score += (1 + log(Double(min(count, 8)))) * ContextRanking.weight(term, frequency, available.count)
                    }
                    if chunk.headingWords.contains(term) { score += 2 * ContextRanking.weight(term, frequency, available.count) }
                }
                if phraseUseful && chunk.normalizedText.range(of: phrase, options: .literal) != nil { score += 10 }
                scored.append((chunk, score))
            }
            scored.sort { $0.1 == $1.1 ? $0.0.order < $1.0.order : $0.1 > $1.1 }
            let best = scored.first?.1 ?? 0
            ranked.append((document, scored, best))
        }

        let hasMatches = !terms.isEmpty && ranked.contains { $0.score > 0 }
        ranked.sort {
            if hasMatches && $0.score != $1.score { return $0.score > $1.score }
            let first = ContextRanking.defaultPriority($0.document.path)
            let second = ContextRanking.defaultPriority($1.document.path)
            if first != second { return first > second }
            return $0.document.path.localizedStandardCompare($1.document.path) == .orderedAscending
        }

        var remaining = maxCharacters
        var references: [RetrievedReference] = []
        for item in ranked {
            guard references.count < 7, remaining > 40 else { break }
            if hasMatches && item.score <= 0 { continue }
            let chunks: [(ContextRanking.Chunk, Double)]
            if hasMatches {
                // Spread the budget across files, while allowing a second relevant passage.
                chunks = Array(item.chunks.filter { $0.1 > 0 }.prefix(2))
            } else {
                chunks = Array(item.chunks.sorted { $0.0.order < $1.0.order }.prefix(2))
            }
            var body = ""
            let allowance = min(5_400, remaining - item.document.path.count)
            guard allowance > 30 else { continue }
            for (chunk, _) in chunks.sorted(by: { $0.0.order < $1.0.order }) {
                let separator = body.isEmpty ? "" : "\n\n[…]\n\n"
                let passage = separator + chunk.locator + "\n" + chunk.text
                let room = allowance - body.count
                guard room > separator.count + chunk.locator.count + 16 else { break }
                if passage.count > room {
                    body += String(passage.prefix(room - 14)) + "\n[truncated]"
                } else {
                    body += passage
                }
            }
            guard !body.isEmpty else { continue }
            references.append(RetrievedReference(path: item.document.path, excerpt: body))
            remaining -= item.document.path.count + body.count
        }
        return references
    }
}

enum ProjectContextLoader {
    // Limits are deliberate: folder indexing must remain responsive and finite.
    static let maximumTextBytes = 1_572_864
    static let maximumPDFBytes = 12_582_912
    static let maximumIndexedBytes = 16_777_216
    static let maximumFiles = 700
    static let maximumEntries = 16_000
    static let maximumDepth = 12
    static let maximumPDFPages = 180

    static func load(root selectedRoot: URL) throws -> ProjectIndex {
        try checkCancellation()
        let manager = FileManager.default
        let root = selectedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        guard rootValues.isDirectory == true, rootValues.isReadable != false else {
            throw NSError(domain: "CallCompanion.ProjectContext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a readable project folder."])
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var notices: [String] = []
        var skipped = 0
        func notice(_ message: String) {
            if notices.count < 30 { notices.append(message) } else { skipped += 1 }
        }
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                notice("Could not inspect \(relativePath(url, root: root)): \(error.localizedDescription)")
                return true
            }) else {
            throw NSError(domain: "CallCompanion.ProjectContext", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "This project folder could not be opened."])
        }
        var candidates: [(URL, String, Int)] = []
        var entryCount = 0
        var omittedByPolicy = 0
        for case let url as URL in enumerator {
            try checkCancellation()
            entryCount += 1
            if entryCount > maximumEntries {
                notice("Folder scan stopped after \(maximumEntries) entries; some files were not inspected.")
                break
            }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                let path = relativePath(url, root: root)
                let name = url.lastPathComponent.lowercased()
                if values.isSymbolicLink == true {
                    // FileManager's URL enumerator does not descend into symbolic links.
                    // skipDescendants on a non-directory can skip a later sibling directory.
                    omittedByPolicy += 1
                    continue
                }
                if values.isDirectory == true {
                    if excludedDirectories.contains(name) || isSensitiveName(name) {
                        enumerator.skipDescendants()
                        omittedByPolicy += 1
                    } else if path.split(separator: "/").count >= maximumDepth {
                        enumerator.skipDescendants()
                        notice("Depth limit reached at \(path); nested files were not inspected.")
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                guard !isSensitiveName(name), !isGeneratedName(name), isSupported(url) else {
                    omittedByPolicy += 1
                    continue
                }
                let size = values.fileSize ?? 0
                let limit = url.pathExtension.lowercased() == "pdf" ? maximumPDFBytes : maximumTextBytes
                guard size <= limit else {
                    notice("Skipped \(path): exceeds the \(limit / 1_024) KB per-file limit.")
                    continue
                }
                candidates.append((url, path, size))
            } catch {
                notice("Could not inspect \(relativePath(url, root: root)): \(error.localizedDescription)")
            }
        }
        // Load routing documents before ordinary files when a large folder reaches its limit.
        candidates.sort {
            let first = ContextRanking.defaultPriority($0.1), second = ContextRanking.defaultPriority($1.1)
            if first != second { return first > second }
            return $0.1.localizedStandardCompare($1.1) == .orderedAscending
        }
        var documents: [ProjectDocument] = []
        var indexedBytes = 0
        for (url, path, _) in candidates {
            try checkCancellation()
            if documents.count >= maximumFiles {
                notice("Index stopped at \(maximumFiles) files; \(candidates.count - documents.count) candidate files may be unindexed.")
                break
            }
            do {
                // Recheck immediately before opening in case the folder changed during the scan.
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                let canonicalPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let currentValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard resolved.path.hasPrefix(canonicalPrefix), resolved.path == url.standardizedFileURL.path,
                      currentValues.isSymbolicLink != true, currentValues.isRegularFile == true else {
                    notice("Skipped \(path): its location or file type changed during indexing.")
                    continue
                }
                let content: String
                if url.pathExtension.lowercased() == "pdf" {
                    guard (currentValues.fileSize ?? maximumPDFBytes + 1) <= maximumPDFBytes else {
                        notice("Skipped \(path): PDF grew beyond the per-file limit during indexing.")
                        continue
                    }
                    let result = try extractPDF(url)
                    content = result.text
                    for message in result.notices { notice("\(path): \(message)") }
                } else {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: maximumTextBytes + 1) ?? Data()
                    guard data.count <= maximumTextBytes else {
                        notice("Skipped \(path): file grew beyond the per-file limit during indexing.")
                        continue
                    }
                    guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else {
                        notice("Skipped \(path): unsupported encoding or binary content (UTF-8 text required).")
                        continue
                    }
                    guard !containsPrivateKey(decoded) else {
                        notice("Skipped \(path): private-key material was detected.")
                        continue
                    }
                    content = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let size = content.utf8.count
                guard indexedBytes + size <= maximumIndexedBytes else {
                    notice("Skipped \(path): the \(maximumIndexedBytes / 1_048_576) MB total text-index limit was reached.")
                    continue
                }
                documents.append(ProjectDocument(path: path, text: content))
                indexedBytes += size
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                notice("Could not read \(path): \(error.localizedDescription)")
            }
        }
        notices.insert("Indexed \(documents.count) readable text/PDF files. Hidden files, dependencies, build output, credential-like names, symlinks, and unsupported formats are excluded.", at: 0)
        if omittedByPolicy > 0 { notices.append("\(omittedByPolicy) visible entries were excluded by the indexing rules.") }
        if skipped > 0 { notices.append("\(skipped) additional indexing notices were omitted.") }
        if documents.isEmpty { notices.append("No supported readable content was found in this folder.") }
        let index = ProjectIndex(root: root, documents: documents, notices: notices)
        try checkCancellation()
        return index
    }

    private static func extractPDF(_ url: URL) throws -> (text: String, notices: [String]) {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked else {
            throw NSError(domain: "CallCompanion.ProjectContext", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PDF is locked or unreadable."])
        }
        var sections: [String] = []
        var notices: [String] = []
        var characterCount = 0
        if pdf.pageCount > maximumPDFPages {
            notices.append("only the first \(maximumPDFPages) of \(pdf.pageCount) PDF pages were indexed.")
        }
        for page in 0..<min(pdf.pageCount, maximumPDFPages) {
            try checkCancellation()
            let pageText = autoreleasepool { pdf.page(at: page)?.string ?? "" }
            if pageText.isEmpty { continue }
            guard characterCount + pageText.utf8.count <= maximumTextBytes else {
                notices.append("PDF text limit reached before page \(page + 1); later content was not indexed.")
                break
            }
            sections.append("[PDF page \(page + 1)]\n" + pageText)
            characterCount += pageText.utf8.count
        }
        if sections.isEmpty { notices.append("no extractable text; scanned/image-only PDFs require OCR and are not indexed.") }
        return (sections.joined(separator: "\n\n"), notices)
    }

    private static func checkCancellation() throws {
        if Task<Never, Never>.isCancelled { throw CancellationError() }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        // Foundation's enumerator can add /private to /var and /tmp URLs on macOS.
        // Normalize both sides before stripping the root, without following a link.
        let fullPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return fullPath.hasPrefix(prefix) ? String(fullPath.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private static let excludedDirectories: Set<String> = [
        "node_modules", "vendor", "vendors", "bower_components", "pods", "carthage",
        "build", "builds", "dist", "out", "target", "deriveddata", "coverage", "htmlcov",
        "__pycache__", "venv", "env", "site-packages", "cache", "caches", "tmp", "temp",
        "logs", "checkpoints", "weights", "artifacts", "generated", "third_party", "third-party"
    ]
    private static let supportedExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "rst", "adoc", "org", "csv", "tsv", "json", "jsonc",
        "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "sass", "less",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts",
        "js", "jsx", "ts", "tsx", "py", "pyi", "rb", "rs", "go", "php", "sql", "graphql",
        "gql", "sh", "bash", "zsh", "fish", "r", "jl", "lua", "vue", "svelte", "dart", "ex", "exs",
        "clj", "cljs", "scala", "proto", "ini", "cfg", "conf", "pdf"
    ]
    private static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) ||
        ["readme", "license", "makefile", "dockerfile", "gemfile", "procfile", "justfile"].contains(url.lastPathComponent.lowercased())
    }
    private static func isSensitiveName(_ name: String) -> Bool {
        if name == "env" || name.hasPrefix(".env") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") || name.hasPrefix("id_dsa") { return true }
        let ext = (name as NSString).pathExtension
        if ["key", "pem", "p12", "pfx", "keystore", "mobileprovision"].contains(ext) { return true }
        let parts = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let sensitive: Set<String> = ["secret", "secrets", "credential", "credentials", "password", "passwords", "token", "tokens", "apikey", "privatekey", "keychain", "auth", "env", "serviceaccount", "clientsecret"]
        return parts.contains { sensitive.contains($0) } || name.contains("private-key") || name.contains("private_key") || name.contains("service-account") || name.contains("service_account")
    }
    private static func isGeneratedName(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        // Content-addressed scrape/cache records are generated data, even when their
        // parent folder has a generic name that may also contain useful documents.
        let hashArtifact = ["json", "jsonc", "jsonl", "csv", "tsv"].contains(ext) &&
            stem.count >= 32 && stem.allSatisfy { "0123456789abcdef".contains($0) }
        return hashArtifact || name.hasSuffix(".lock") || name.hasSuffix("-lock.json") || name == "package-lock.json" || name == "yarn.lock" ||
        name.contains(".min.") || name.hasSuffix(".map") || name.contains(".generated.") ||
        name.hasSuffix(".pb.swift") || name.hasSuffix(".pb.go") || name.hasSuffix(".log")
    }
    private static func containsPrivateKey(_ text: String) -> Bool {
        ["-----BEGIN PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----",
         "-----BEGIN DSA PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----"]
            .contains { text.contains($0) }
    }
}

private enum ContextRanking {
    struct Chunk {
        let order: Int
        let locator: String
        let text: String
        let normalizedText: String
        let counts: [String: Int]
        let headingWords: Set<String>

        init(order: Int, locator: String, text: String) {
            self.order = order
            self.locator = locator
            self.text = text
            normalizedText = ContextRanking.normalized(text)
            counts = Dictionary(ContextRanking.words(normalizedText).map { ($0, 1) }, uniquingKeysWith: +)
            let headings = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: " ")
            headingWords = Set(ContextRanking.words(headings))
        }
    }
    struct PreparedDocument {
        let document: ProjectDocument
        let chunks: [Chunk]
        let pathWords: Set<String>
        let words: Set<String>
    }
    static func prepare(_ document: ProjectDocument) -> PreparedDocument {
        let preparedChunks = chunks(document.text)
        let pathWords = Set(words(document.path))
        let allWords = preparedChunks.reduce(into: pathWords) { result, chunk in result.formUnion(chunk.counts.keys) }
        return PreparedDocument(document: document, chunks: preparedChunks, pathWords: pathWords, words: allWords)
    }
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "about", "into", "have", "has", "had",
        "was", "were", "will", "would", "could", "should", "can", "our", "your", "their", "they",
        "them", "what", "when", "where", "which", "who", "why", "how", "not", "are", "you", "but",
        "call", "meeting", "project", "discuss", "discussing", "talk", "talking", "want", "need", "please"
    ]
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func words(_ text: String) -> [String] {
        normalized(text).split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 2 }.map(String.init)
    }
    static func weight(_ term: String, _ frequency: [String: Int], _ count: Int) -> Double {
        1 + log(Double(count + 1) / Double((frequency[term] ?? 0) + 1))
    }
    static func defaultPriority(_ path: String) -> Int {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let isHumanDocument = ["md", "markdown", "mdx", "txt", "rst", "adoc", "org", "pdf"].contains(ext) || name == "license"
        let depth = path.split(separator: "/").count - 1
        let priority: Int
        if name == "readme.md" || name == "readme" || name == "readme.txt" { priority = 200 }
        else if name == "claude.md" || name == "agents.md" { priority = 190 }
        else if isHumanDocument && (name.contains("overview") || name.contains("brief") || name.contains("hub")) { priority = 180 }
        else if isHumanDocument && (name.contains("roadmap") || name.contains("status") || name.contains("plan")) { priority = 165 }
        else if isHumanDocument { priority = 140 }
        else if sourceExtensions.contains(ext) || ["makefile", "dockerfile", "gemfile", "procfile", "justfile"].contains(name) { priority = 70 }
        else { priority = 10 }
        return priority - min(depth * 5, 35)
    }
    private static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts",
        "js", "jsx", "ts", "tsx", "py", "pyi", "rb", "rs", "go", "php", "sql", "graphql",
        "gql", "sh", "bash", "zsh", "fish", "r", "jl", "lua", "vue", "svelte", "dart", "ex", "exs",
        "clj", "cljs", "scala", "proto", "html", "htm", "css", "scss", "sass", "less"
    ]
    static func chunks(_ text: String) -> [Chunk] {
        // Whole documents are indexed; chunks are built across every line, including their tails.
        let lines = text.components(separatedBy: "\n")
        var chunks: [Chunk] = []
        var current: [String] = []
        var size = 0
        var start = 1
        var page: Int?
        var currentPage: Int?
        func flush(end: Int) {
            guard !current.isEmpty else { return }
            let location = currentPage.map { "PDF page \($0), extracted lines \(start)–\(max(start, end))" } ?? "Lines \(start)–\(max(start, end))"
            chunks.append(Chunk(order: chunks.count, locator: location, text: current.joined(separator: "\n")))
            current.removeAll(keepingCapacity: true)
            size = 0
        }
        for (offset, line) in lines.enumerated() {
            if Task<Never, Never>.isCancelled { break }
            let lineNumber = offset + 1
            if line.hasPrefix("[PDF page "), let number = Int(line.dropFirst(10).dropLast()) {
                flush(end: lineNumber - 1)
                page = number
                continue
            }
            if size + line.count + 1 > 2_500 && !current.isEmpty { flush(end: lineNumber - 1) }
            if current.isEmpty { start = lineNumber; currentPage = page }
            // Long single lines are split too, so minified prose cannot consume an entire excerpt.
            if line.count > 2_500 {
                flush(end: lineNumber - 1)
                var slice = line[...]
                while !slice.isEmpty {
                    if Task<Never, Never>.isCancelled { break }
                    let end = slice.index(slice.startIndex, offsetBy: 2_500, limitedBy: slice.endIndex) ?? slice.endIndex
                    let location = page.map { "PDF page \($0), extracted line \(lineNumber) (segment)" } ?? "Line \(lineNumber) (segment)"
                    chunks.append(Chunk(order: chunks.count, locator: location, text: String(slice[..<end])))
                    slice = slice[end...]
                }
            } else {
                current.append(line)
                size += line.count + 1
            }
        }
        flush(end: lines.count)
        return chunks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
