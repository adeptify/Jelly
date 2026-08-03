import AppKit
import CalendarDomain
import SwiftUI

struct CategoryManagerView: View {
    let store: CalendarStore
    @StateObject private var model: CategoryManagerViewModel
    @State private var editingCategoryID: UUID?
    @State private var localError: String?
    @Environment(\.colorScheme) private var colorScheme

    init(store: CalendarStore) {
        self.store = store
        _model = StateObject(wrappedValue: CategoryManagerViewModel(store: store))
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(minWidth: 176, idealWidth: 190, maxWidth: 230)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        }
        .confirmationDialog(
            "删除分类并迁移事项",
            isPresented: deleteDialogPresented,
            presenting: model.categoryToDelete
        ) { category in
            ForEach(migrationTargets(for: category)) { target in
                Button(migrationLabel(for: target)) {
                    confirmDelete(category, migrateTo: target.id)
                }
            }
            Button("取消", role: .cancel) {
                model.categoryToDelete = nil
                model.migrationTargetID = nil
            }
        } message: { category in
            Text("“\(category.name)”中的事项和重复事项会被一并迁移。请选择迁移目标。")
        }
        .onChange(of: store.state) { _, state in
            if let editingCategoryID {
                if let category = state.categories[editingCategoryID] {
                    model.synchronizeDraftFromStore(category)
                } else {
                    startCreating()
                }
            }
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("分类")
                    .font(.headline)
                Spacer()
                Button {
                    moveSelectedCategory(.up)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("上移当前分类")
                .accessibilityLabel("上移当前分类")
                .disabled(reorderedIDs(for: .up) == nil || store.phase != .ready)
                Button {
                    moveSelectedCategory(.down)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("下移当前分类")
                .accessibilityLabel("下移当前分类")
                .disabled(reorderedIDs(for: .down) == nil || store.phase != .ready)
                Button(action: startCreating) {
                    Image(systemName: "plus")
                }
                .help("新建分类")
            }
            .padding(12)

            List {
                ForEach(orderedCategories) { category in
                    Button {
                        select(category)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Circle()
                                .fill(CalendarTheme.categoryAccent(
                                    category.colorHex,
                                    appearance: colorScheme == .dark ? .dark : .light
                                ))
                                .frame(width: 10, height: 10)
                            Text(category.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .listRowBackground(
                        category.id == editingCategoryID
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                }
                .onMove(perform: moveCategories)
            }
            .listStyle(.sidebar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editingCategory == nil ? "新建分类" : "编辑分类")
                    .font(.title3.weight(.semibold))
                Spacer()
                if editingCategory != nil {
                    Button("删除", role: .destructive, action: beginDelete)
                        .disabled(isProtectedCategory)
                }
            }

            if isProtectedCategory {
                Label("“未分类”是系统分类，名称、颜色和删除受到保护；你仍可在左侧拖动它调整顺序。", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            TextField("分类名称", text: $model.draftName)
                .textFieldStyle(.roundedBorder)
                .disabled(isProtectedCategory)

            VStack(alignment: .leading, spacing: 8) {
                Text("颜色")
                    .font(.subheadline.weight(.medium))
                Picker("色系", selection: familySelection) {
                    ForEach(CategoryPalette.families) { family in
                        Text(family.name).tag(family.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isProtectedCategory)
                .accessibilityLabel("分类色系")

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 8),
                    spacing: 8
                ) {
                    ForEach(selectedFamily.presets) { preset in
                        Button {
                            model.selectPreset(preset.hex)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(CalendarTheme.categoryColor(preset.hex))
                                if model.draftColorHex.uppercased() == preset.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(swatchCheckColor(for: preset.hex))
                                }
                            }
                                .frame(width: 26, height: 26)
                                .overlay {
                                    Circle().stroke(
                                        model.draftColorHex.uppercased() == preset.hex
                                            ? Color.primary.opacity(0.85)
                                            : Color.primary.opacity(0.12),
                                        lineWidth: model.draftColorHex.uppercased() == preset.hex ? 2 : 1
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isProtectedCategory)
                        .accessibilityLabel("选择\(selectedFamily.name)色系的\(preset.accessibilityName)")
                        .accessibilityValue(
                            model.draftColorHex.uppercased() == preset.hex ? "已选中" : "未选中"
                        )
                    }
                }
                ColorPicker("自定义颜色", selection: colorBinding, supportsOpacity: false)
                    .disabled(isProtectedCategory)
                TextField("#RRGGBB", text: $model.draftColorHex)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isProtectedCategory)
            }

            contrastPreviews

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(validationError == nil ? Color.secondary : Color.red)
            }
            if let localError {
                Text(localError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(editingCategory == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(isSaveDisabled)
            }
        }
    }

    private var contrastPreviews: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可读性预览")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                preview(appearance: .light, title: "浅色")
                preview(appearance: .dark, title: "深色")
            }
        }
    }

    private func preview(appearance: CalendarAppearance, title: String) -> some View {
        let roles = try? CategoryColorResolver.roles(for: model.draftColorHex, appearance: appearance)
        let canvasHex = roles?.canvas.hex ?? (appearance == .light
            ? CalendarTheme.previewLightCanvasHex
            : CalendarTheme.previewDarkCanvasHex)
        let textHex = roles?.text.hex ?? (appearance == .light
            ? CalendarTheme.previewLightTextHex
            : CalendarTheme.previewDarkTextHex)
        let accentColor = roles.map { CalendarTheme.categoryColor($0.accent) }
            ?? CalendarTheme.categoryColor(model.draftColorHex)
        let backgroundColor = roles.map { CalendarTheme.categoryColor($0.softBackground) }
            ?? CalendarTheme.categoryColor(canvasHex)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(contrastText(for: appearance))
                    .monospacedDigit()
            }
            .font(.caption)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(width: 3, height: 22)
                Text(model.draftName.isEmpty ? "分类事项" : model.draftName)
                    .lineLimit(1)
                    .foregroundStyle(CalendarTheme.categoryColor(textHex))
                Spacer(minLength: 0)
            }
            .font(CalendarTheme.itemFont)
            .padding(.horizontal, 6)
            .frame(height: CalendarTheme.itemRowHeight)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius)
            )
        }
        .padding(8)
        .background(CalendarTheme.categoryColor(canvasHex), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.12)))
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { CalendarTheme.categoryColor(model.draftColorHex) },
            set: { color in
                if let hex = Self.hexString(from: color) {
                    model.draftColorHex = hex
                }
            }
        )
    }

    private var familySelection: Binding<CategoryColorFamilyID> {
        Binding(
            get: { model.selectedFamilyID },
            set: { model.selectFamily($0) }
        )
    }

    private var selectedFamily: CategoryColorFamily {
        CategoryPalette.family(id: model.selectedFamilyID)
    }

    private func swatchCheckColor(for hex: String) -> Color {
        guard let base = try? SRGBColor(hex: hex),
              let white = try? SRGBColor(hex: "#FFFFFF"),
              let black = try? SRGBColor(hex: "#231F1C")
        else {
            return .primary
        }
        return base.contrastRatio(with: white) >= base.contrastRatio(with: black)
            ? .white
            : CalendarTheme.categoryColor("#231F1C")
    }

    private var editingCategory: CalendarCategory? {
        editingCategoryID.flatMap { store.state.categories[$0] }
    }

    private var isProtectedCategory: Bool {
        editingCategoryID == store.state.uncategorizedID
    }

    private var orderedCategories: [CalendarCategory] {
        store.state.categories.values.sorted {
            $0.sortIndex == $1.sortIndex ? $0.name < $1.name : $0.sortIndex < $1.sortIndex
        }
    }

    private var validationError: CategoryManagerError? {
        guard !isProtectedCategory else { return nil }
        let name = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .emptyName }
        let nameKey = name.lowercased()
        guard !store.state.categories.values.contains(where: {
            $0.id != editingCategoryID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == nameKey
        }) else {
            return .duplicateName
        }
        do {
            try CategoryColorValidator.validateReadableInBothAppearances(model.draftColorHex)
            return nil
        } catch let error as CategoryManagerError {
            return error
        } catch {
            return .invalidColor
        }
    }

    private var validationMessage: String? {
        if isProtectedCategory {
            return "系统分类受到保护。"
        }
        switch validationError {
        case nil:
            return "浅色 \(contrastText(for: .light))，深色 \(contrastText(for: .dark))；两种外观均满足文字 4.5:1、强调 3:1。"
        case .emptyName:
            return "请填写分类名称。"
        case .duplicateName:
            return "已有同名分类，请换一个名称。"
        case .invalidColor:
            return "颜色必须是 #RRGGBB 格式。"
        case .insufficientContrast:
            return "这个颜色在浅色或深色下文字不够清晰，请换一个颜色。"
        default:
            return "当前分类不能保存。"
        }
    }

    private var isSaveDisabled: Bool {
        isProtectedCategory || validationError != nil || store.phase != .ready
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { model.categoryToDelete != nil },
            set: {
                if !$0 {
                    model.categoryToDelete = nil
                    model.migrationTargetID = nil
                }
            }
        )
    }

    private func select(_ category: CalendarCategory) {
        editingCategoryID = category.id
        model.beginEditing(category)
        localError = nil
    }

    private func startCreating() {
        editingCategoryID = nil
        model.beginCreating()
        localError = nil
    }

    private func save() {
        localError = nil
        Task {
            do {
                if let category = editingCategory {
                    try await model.update(category)
                } else {
                    try await model.create()
                }
            } catch {
                localError = message(for: error)
            }
        }
    }

    private func beginDelete() {
        guard let category = editingCategory, category.id != store.state.uncategorizedID else { return }
        model.categoryToDelete = category
        model.migrationTargetID = nil
    }

    private func confirmDelete(_ category: CalendarCategory, migrateTo targetID: UUID) {
        model.categoryToDelete = nil
        model.migrationTargetID = nil
        localError = nil
        Task {
            do {
                try await model.deleteConfirmed(category: category, migrationTargetID: targetID)
                startCreating()
            } catch {
                localError = message(for: error)
            }
        }
    }

    private func moveCategories(from source: IndexSet, to destination: Int) {
        var categories = orderedCategories
        categories.move(fromOffsets: source, toOffset: destination)
        submitReorder(categories.map(\.id))
    }

    private func moveSelectedCategory(_ direction: CategoryReorderMove.Direction) {
        guard let ids = reorderedIDs(for: direction) else { return }
        submitReorder(ids)
    }

    private func reorderedIDs(for direction: CategoryReorderMove.Direction) -> [UUID]? {
        CategoryReorderMove.reorderedIDs(
            orderedCategories.map(\.id),
            selected: editingCategoryID,
            direction: direction
        )
    }

    private func submitReorder(_ ids: [UUID]) {
        localError = nil
        Task {
            do {
                try await model.reorder(ids)
            } catch {
                localError = message(for: error)
            }
        }
    }

    private func migrationTargets(for category: CalendarCategory) -> [CalendarCategory] {
        orderedCategories.filter { $0.id != category.id }
    }

    private func migrationLabel(for target: CalendarCategory) -> String {
        target.id == store.state.uncategorizedID ? "转入未分类" : "转入“\(target.name)”"
    }

    private func contrastText(for appearance: CalendarAppearance) -> String {
        guard let roles = try? CategoryColorResolver.roles(
            for: model.draftColorHex,
            appearance: appearance
        ) else {
            return "—"
        }
        return String(format: "文字 %.2f:1 · 强调 %.2f:1", roles.textContrast, roles.accentContrast)
    }

    private func message(for error: Error) -> String {
        switch error as? CategoryManagerError {
        case .emptyName:
            return "请填写分类名称。"
        case .duplicateName:
            return "已有同名分类，请换一个名称。"
        case .invalidColor:
            return "颜色必须是 #RRGGBB 格式。"
        case .insufficientContrast:
            return "这个颜色在浅色或深色下文字不够清晰，请换一个颜色。"
        case .protectedCategory:
            return "“未分类”是系统分类，不能修改或删除。"
        case .migrationRequired:
            return "删除前请选择迁移目标。"
        case .invalidMigrationTarget:
            return "请选择其他有效分类作为迁移目标。"
        case nil:
            return store.mutationError ?? "保存分类失败，请重试。"
        }
    }

    private static func hexString(from color: Color) -> String? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }
}
