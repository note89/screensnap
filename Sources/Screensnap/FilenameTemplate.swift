import Foundation

/// How a new recording is named: literal text mixed with date fields, written the
/// way the settings field shows them (`%Y-%m-%dT%H-%M-%S`). A template can only be
/// made by parsing, and parsing rejects anything that would not render to a usable,
/// visible file name — so saving never depends on what was typed.
struct FilenameTemplate: Equatable {
    enum DateField: Character, CaseIterable {
        case year = "Y"
        case month = "m"
        case day = "d"
        case hour = "H"
        case minute = "M"
        case second = "S"

        fileprivate func render(_ parts: DateComponents) -> String {
            switch self {
            case .year: return String(format: "%04d", parts.year ?? 0)
            case .month: return String(format: "%02d", parts.month ?? 0)
            case .day: return String(format: "%02d", parts.day ?? 0)
            case .hour: return String(format: "%02d", parts.hour ?? 0)
            case .minute: return String(format: "%02d", parts.minute ?? 0)
            case .second: return String(format: "%02d", parts.second ?? 0)
            }
        }
    }

    enum Piece: Equatable {
        case literal(String)
        case field(DateField)
    }

    enum ParseError: Error, Equatable {
        case blank
        case startsWithDot
        case forbidden(Character)
        case unknownField(Character)
        case trailingPercent

        var message: String {
            switch self {
            case .blank: return "A file name needs at least one character."
            case .startsWithDot: return "A name starting with “.” would be hidden in Finder."
            case .forbidden(let character): return "File names cannot contain “\(character)”."
            case .unknownField(let character): return "%\(character) is not a date field. Use %Y %m %d %H %M %S, or %% for “%”."
            case .trailingPercent: return "A “%” at the end needs a field letter after it."
            }
        }
    }

    /// Exactly what the user typed, so the settings field shows it back unchanged.
    let text: String
    let pieces: [Piece]

    static let standardText = "%Y-%m-%dT%H-%M-%S"
    static let forbiddenCharacters: Set<Character> = ["/", ":"]

    private init(text: String, pieces: [Piece]) {
        self.text = text
        self.pieces = pieces
    }

    static func parse(_ text: String) -> Result<FilenameTemplate, ParseError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.blank) }
        guard !text.hasPrefix(".") else { return .failure(.startsWithDot) }
        var pieces: [Piece] = []
        var literal = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            if Self.forbiddenCharacters.contains(character) { return .failure(.forbidden(character)) }
            guard character == "%" else {
                literal.append(character)
                continue
            }
            guard let code = characters.next() else { return .failure(.trailingPercent) }
            if code == "%" {
                literal.append("%")
                continue
            }
            guard let field = DateField(rawValue: code) else { return .failure(.unknownField(code)) }
            if !literal.isEmpty { pieces.append(.literal(literal)) }
            literal = ""
            pieces.append(.field(field))
        }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return .success(FilenameTemplate(text: text, pieces: pieces))
    }

    /// Falls back to the standard template when the stored text no longer parses.
    static func parseOrStandard(_ text: String?) -> FilenameTemplate {
        if let text, case .success(let template) = parse(text) { return template }
        return standard
    }

    static let standard: FilenameTemplate = {
        guard case .success(let template) = parse(standardText) else {
            preconditionFailure("FilenameTemplate.standard: \(standardText) must parse")
        }
        return template
    }()

    /// The file name, without extension, for a recording started at `date`.
    func stem(at date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return pieces.map { piece in
            switch piece {
            case .literal(let text): return text
            case .field(let field): return field.render(parts)
            }
        }.joined()
    }
}

extension FileManager {
    /// `folder/stem.ext`, or `stem-2.ext`, `stem-3.ext`… — the first that names no
    /// existing file, so writing to it never replaces anything.
    func unusedURL(in folder: URL, stem: String, pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var counter = 2
        while fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return candidate
    }
}
