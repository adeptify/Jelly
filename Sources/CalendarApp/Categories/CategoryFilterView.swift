import CalendarDomain
import SwiftUI

struct CategoryFilterView: View {
    let categories: [CalendarCategory]
    @Binding var hiddenCategoryIDs: Set<UUID>
    @AppStorage("calendar.hiddenCategoryIDs") private var storedHiddenCategoryIDs = ""

    var body: some View {
        Section("分类筛选") {
            Button("全部显示") {
                apply([])
            }
            ForEach(categories) { category in
                Toggle(isOn: visibilityBinding(for: category.id)) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(CalendarTheme.categoryColor(category.colorHex))
                            .frame(width: 9, height: 9)
                        Text(category.name)
                    }
                }
            }
        }
        .onAppear {
            hiddenCategoryIDs = Self.decode(storedHiddenCategoryIDs)
        }
    }

    private func visibilityBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !hiddenCategoryIDs.contains(id) },
            set: { visible in
                var next = hiddenCategoryIDs
                if visible {
                    next.remove(id)
                } else {
                    next.insert(id)
                }
                apply(next)
            }
        )
    }

    private func apply(_ ids: Set<UUID>) {
        hiddenCategoryIDs = ids
        storedHiddenCategoryIDs = Self.encode(ids)
    }

    static func encode(_ ids: Set<UUID>) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func decode(_ encoded: String) -> Set<UUID> {
        Set(encoded.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}
