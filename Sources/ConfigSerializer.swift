import Foundation
import Yams

extension ConfigManager {
    /// Serializes an AppConfig to YAML and writes it to the config file.
    /// The previous file is used as a comment source (audit 2.7): Yams has no comment
    /// API, so comments are re-attached line-by-line to content lines whose text is
    /// unchanged; content lines themselves come from the encoder untouched.
    static func saveConfig(_ config: AppConfig, to path: String? = nil) throws {
        let configPath = path ?? shared.activePath ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)

        // Ensure the directory exists
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(config)

        let original = try? String(contentsOf: url, encoding: .utf8)
        let output = ConfigTextMerger.merge(body: yamlString, original: original)

        try output.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Line-level comment carry-over for `saveConfig`. Comment blocks stick to the next
/// content line in the original file and are re-emitted (re-indented to match) above
/// the same line in the new body; trailing `# …` comments are re-attached the same way.
/// Only comment text is ever inserted — no content line is modified — so the merged
/// document stays as valid as the encoded body.
enum ConfigTextMerger {
    static let defaultHeader = [
        "# ntfy-macos configuration",
        "# Edit manually or use Settings in the menu bar",
    ]

    struct CommentGroup: Equatable {
        var lines: [String]      // raw comment/blank lines, original order
        var contentIndent: Int   // indent of the content line they annotate
    }

    struct Parsed {
        var leading: [String] = []                                  // header before the first content line
        var preceding: [String: [CommentGroup]] = [:]               // trimmed content line → comment groups (FIFO)
        var trailingInline: [String: [String]] = [:]                // trimmed content line → " # …" texts (FIFO)
    }

    // MARK: - Parsing the original file

    static func parse(original: String) -> Parsed {
        var parsed = Parsed()
        var pending: [String] = []
        var sawContent = false

        for raw in original.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                pending.append(raw)
                continue
            }
            let (content, inline) = splitInlineComment(raw)
            let key = content.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            let group = trimBlankEdges(pending)
            pending.removeAll()
            if !sawContent {
                parsed.leading = group
            } else if !group.isEmpty {
                parsed.preceding[key, default: []].append(
                    CommentGroup(lines: group, contentIndent: indentOf(raw))
                )
            }
            if let inline {
                parsed.trailingInline[key, default: []].append(inline)
            }
            sawContent = true
        }
        // Trailing comments at EOF annotate nothing further — dropped with the old file.
        return parsed
    }

    /// Splits `key: value  # note` into content and comment at the first `#` that is
    /// outside quotes and preceded by whitespace — the same rule YAML itself applies.
    static func splitInlineComment(_ line: String) -> (content: String, comment: String?) {
        let chars = Array(line)
        var inSingle = false
        var inDouble = false
        var previous: Character?
        for (i, c) in chars.enumerated() {
            switch c {
            case "'": if !inDouble { inSingle.toggle() }
            case "\"": if !inSingle, previous != "\\" { inDouble.toggle() }
            case "#":
                if !inSingle, !inDouble, i > 0, chars[i - 1] == " " || chars[i - 1] == "\t" {
                    let content = String(chars[0..<i])
                    let comment = String(chars[i...]).trimmingCharacters(in: .whitespaces)
                    return (content, comment)
                }
            default: break
            }
            previous = c
        }
        return (line, nil)
    }

    // MARK: - Merging into the new body

    static func merge(body: String, original: String?) -> String {
        let parsed = original.map { parse(original: $0) } ?? Parsed()
        var remainingGroups = parsed.preceding
        var remainingInline = parsed.trailingInline

        var out: [String] = []
        var wroteContent = false
        for raw in body.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(raw)
                continue
            }
            if !wroteContent {
                wroteContent = true
                out.append(contentsOf: parsed.leading.isEmpty ? defaultHeader : parsed.leading)
                out.append("")
            }
            if let groups = remainingGroups[trimmed], let group = groups.first {
                popFirst(&remainingGroups, trimmed)
                out.append(contentsOf: reindent(group, to: indentOf(raw)))
            }
            var line = raw
            if let trailings = remainingInline[trimmed], let comment = trailings.first {
                popFirst(&remainingInline, trimmed)
                line = raw + "  " + comment
            }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func popFirst<Value>(_ dict: inout [String: [Value]], _ key: String) {
        var values = dict[key] ?? []
        if !values.isEmpty { values.removeFirst() }
        if values.isEmpty { dict[key] = nil } else { dict[key] = values }
    }

    /// Keeps each comment line's indentation *relative to its content line*, shifted to
    /// the new indent, so a block that sat over an indented `- name:` still reads right.
    private static func reindent(_ group: CommentGroup, to newIndent: Int) -> [String] {
        group.lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "" }
            let relative = max(indentOf(line) - group.contentIndent, 0)
            return String(repeating: " ", count: newIndent + relative) + trimmed
        }
    }

    private static func indentOf(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var lines = lines[...]
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines = lines.dropFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines = lines.dropLast() }
        return Array(lines)
    }
}
