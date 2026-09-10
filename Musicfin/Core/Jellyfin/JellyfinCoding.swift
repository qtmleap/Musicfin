import Foundation

/// Jellyfin は既定で PascalCase の JSON を返すが、リバースプロキシや将来のバージョンで
/// camelCase になる可能性があるため、先頭 1 文字を小文字化する変換で両方を受け入れる。
nonisolated enum JellyfinCoding {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            guard let last = path.last else { return AnyKey(stringValue: "") }
            let key = last.stringValue
            guard let first = key.first, first.isUppercase else { return last }
            return AnyKey(stringValue: first.lowercased() + key.dropFirst())
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.jellyfinFractional.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.jellyfinPlain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "日付として解釈できません: \(raw)"
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            guard let last = path.last else { return AnyKey(stringValue: "") }
            let key = last.stringValue
            guard let first = key.first, first.isLowercase else { return last }
            return AnyKey(stringValue: first.uppercased() + key.dropFirst())
        }
        return encoder
    }()
}

private nonisolated extension ISO8601DateFormatter {
    nonisolated(unsafe) static let jellyfinFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let jellyfinPlain = ISO8601DateFormatter()
}
