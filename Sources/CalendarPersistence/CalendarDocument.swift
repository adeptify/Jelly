import CalendarDomain
import Foundation

public struct CalendarDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var state: CalendarState

    public init(
        schemaVersion: Int = currentSchemaVersion,
        state: CalendarState
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}

public enum BackupError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchema(Int)
    case atomicWriteFailed
    case rollbackWriteFailed
}

enum CalendarDocumentCodec {
    static func encode(_ state: CalendarState) throws -> Data {
        do {
            try CalendarStateValidator.validate(state)
        } catch {
            throw BackupError.invalidDocument
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            let encoded = try encoder.encode(CalendarDocument(state: state))
            let object = try JSONSerialization.jsonObject(with: encoded)
            return try JSONSerialization.data(
                withJSONObject: canonicalized(object),
                options: [.sortedKeys]
            )
        } catch {
            throw BackupError.invalidDocument
        }
    }

    static func decode(_ data: Data) throws -> CalendarState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let schemaVersion: Int
        do {
            schemaVersion = try decoder.decode(SchemaEnvelope.self, from: data).schemaVersion
        } catch {
            throw BackupError.invalidDocument
        }
        switch schemaVersion {
        case 1:
            return try decodeAndMigrateV1(data, using: decoder)
        case CalendarDocument.currentSchemaVersion:
            return try decodeAndValidateV2(data, using: decoder)
        default:
            throw BackupError.unsupportedSchema(schemaVersion)
        }
    }

    private static func decodeAndMigrateV1(_ data: Data, using decoder: JSONDecoder) throws -> CalendarState {
        let document: V1CalendarDocument
        do {
            document = try decoder.decode(V1CalendarDocument.self, from: data)
        } catch {
            throw BackupError.invalidDocument
        }
        do {
            let migrated = try document.migratedState()
            try CalendarStateValidator.validate(migrated)
            return migrated
        } catch {
            throw BackupError.invalidDocument
        }
    }

    private static func decodeAndValidateV2(_ data: Data, using decoder: JSONDecoder) throws -> CalendarState {
        let document: CalendarDocument
        do {
            document = try decoder.decode(CalendarDocument.self, from: data)
        } catch {
            throw BackupError.invalidDocument
        }
        do {
            try CalendarStateValidator.validate(document.state)
        } catch {
            throw BackupError.invalidDocument
        }
        return document.state
    }

    private static func canonicalized(_ value: Any, key: String? = nil) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                result[childKey] = canonicalized(childValue, key: childKey)
            }
            return result
        }
        guard let array = value as? [Any] else {
            return value
        }

        let values = array.map { canonicalized($0, key: nil) }
        if key == "weekdays" {
            return values.sorted { sortKey(for: $0) < sortKey(for: $1) }
        }
        guard let key,
              ["categories", "items", "series", "exceptions", "completions"].contains(key),
              values.count.isMultiple(of: 2)
        else {
            return values
        }

        return stride(from: 0, to: values.count, by: 2)
            .map { [values[$0], values[$0 + 1]] }
            .sorted { sortKey(for: $0[0]) < sortKey(for: $1[0]) }
            .flatMap { $0 }
    }

    private static func sortKey(for value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}
