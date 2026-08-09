import Foundation
import WorkspaceDomain

public enum WorkspaceDocumentCodec {
    public static func encode(_ state: WorkspaceState) throws -> Data {
        do {
            try WorkspaceValidator.validate(state)
            let encoded = try JSONEncoder.workspaceDeterministic.encode(WorkspaceDocument(state: state))
            let object = try JSONSerialization.jsonObject(with: encoded)
            return try JSONSerialization.data(
                withJSONObject: canonicalized(object),
                options: [.sortedKeys]
            )
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
    }

    public static func decode(_ data: Data) throws -> WorkspaceLoadResult {
        let schema: Int
        do {
            schema = try JSONDecoder.workspaceDeterministic.decode(SchemaEnvelope.self, from: data).schemaVersion
        } catch {
            throw WorkspacePersistenceError.invalidDocument
        }
        let provenance = WorkspaceLoadProvenance(
            sourceSchema: schema,
            sourceBytesSHA256: persistenceSHA256(data),
            sourceByteCount: data.count
        )
        switch schema {
        case 1, CalendarDocument.currentSchemaVersion:
            do {
                let calendar = try CalendarDocumentCodec.decode(data)
                return .init(
                    state: .empty(calendar: calendar),
                    provenance: provenance,
                    consistencyIssues: []
                )
            } catch let error as BackupError {
                switch error {
                case let .unsupportedSchema(value): throw WorkspacePersistenceError.unsupportedSchema(value)
                default: throw WorkspacePersistenceError.invalidDocument
                }
            } catch {
                throw WorkspacePersistenceError.invalidDocument
            }
        case WorkspaceDocument.currentSchemaVersion:
            let document: WorkspaceDocument
            do {
                document = try JSONDecoder.workspaceDeterministic.decode(WorkspaceDocument.self, from: data)
            } catch {
                throw WorkspacePersistenceError.invalidDocument
            }
            let report = WorkspaceConsistencyInspector.inspect(document.state)
            guard !report.hasFatalIssues else { throw WorkspacePersistenceError.invalidDocument }
            return .init(state: document.state, provenance: provenance, consistencyIssues: report.issues)
        default:
            throw WorkspacePersistenceError.unsupportedSchema(schema)
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private static func canonicalized(_ value: Any, key: String? = nil) -> Any {
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { childKey, childValue in
                (childKey, canonicalized(childValue, key: childKey))
            })
        }
        guard let array = value as? [Any] else { return value }
        let values = array.map { canonicalized($0) }
        guard let key else { return values }
        if key == "weekdays"
            || [
                "taskBlockLinks", "inspirationNoteLinks", "referenceNoteIDs", "marks",
                "addedReferenceNoteIDs", "removedReferenceNoteIDs"
            ].contains(key) {
            return values.sorted { sortKey(for: $0) < sortKey(for: $1) }
        }
        guard [
            "categories", "items", "series", "exceptions", "completions", "notes",
            "inspirations", "baselines", "occurrenceOverrides"
        ].contains(key), values.count.isMultiple(of: 2)
        else { return values }
        return stride(from: 0, to: values.count, by: 2)
            .map { [values[$0], values[$0 + 1]] }
            .sorted { sortKey(for: $0[0]) < sortKey(for: $1[0]) }
            .flatMap { $0 }
    }

    private static func sortKey(for value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func canonicalPersistentData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder.workspaceDeterministic.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: canonicalized(object), options: [.sortedKeys])
    }
}
