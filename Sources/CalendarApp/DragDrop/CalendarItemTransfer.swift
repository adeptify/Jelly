import CalendarDomain
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let personalCalendarItem = UTType(
        exportedAs: "com.oreal.personalcalendar.item"
    )
}

enum CalendarTransferPayload: Codable, Transferable {
    case item(UUID)
    case occurrence(OccurrenceKey)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .personalCalendarItem)
    }
}
