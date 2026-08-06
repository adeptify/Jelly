import AppKit
import CalendarDomain
import SwiftUI

/// Category manager — same visual language as the item editor (compact, warm, non-system).
struct CategoryManagerView: View {
    let store: CalendarStore
    @StateObject private var model: CategoryManagerViewModel
    @State private var editingCategoryID: UUID?
    @State private var localError: String?
    @State private var attemptedSave = false
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    init(store: CalendarStore) {
        self.store = store
        _model = StateObject(wrappedValue: CategoryManagerViewModel(store: store))
    }

    var body: some View {
        HStack(spacing: 0) {
            categoryList
                .frame(width: 200)
            Rectangle()
                .fill(theme.separator.opacity(0.45))
                .frame(width: 1)
            editor
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Single elevated surface like the item editor — avoids muddy nested grays.
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .tint(theme.controlAccent)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .onAppear {
            if editingCategoryID == nil, model.draftName.isEmpty {
                startCreating()
            }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    // MARK: - Sidebar

    private var categoryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("分类")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                toolbarIconButton(
                    systemName: "plus",
                    help: "新建分类",
                    emphasized: editingCategoryID == nil
                ) {
                    startCreating()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            thinRule

            ScrollView {
                LazyVStack(spacing: 6) {
                    if editingCategoryID == nil {
                        creatingRow
                    }
                    ForEach(orderedCategories) { category in
                        categoryRow(category)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
        // Slightly quieter than the editor column.
        .background(theme.canvas.opacity(colorScheme == .dark ? 0.55 : 0.35))
    }

    private var creatingRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(CalendarTheme.categoryTagColor(model.draftColorHex, appearance: appearance))
                .frame(width: 10, height: 10)
            Text(model.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "新分类…"
                : model.draftName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("编辑中")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.controlAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(theme.controlAccent.opacity(0.16), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.selectionFill,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.controlAccent.opacity(0.35), lineWidth: 1)
        }
    }

    private func categoryRow(_ category: CalendarCategory) -> some View {
        let selected = category.id == editingCategoryID
        return Button {
            select(category)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(CalendarTheme.categoryTagColor(category.colorHex, appearance: appearance))
                    .frame(width: 10, height: 10)
                Text(category.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                if category.id == store.state.uncategorizedID {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText.opacity(0.55))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? theme.selectionFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toolbarIconButton(
        systemName: String,
        help: String,
        disabled: Bool = false,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    disabled
                        ? theme.secondaryText.opacity(0.3)
                        : (emphasized ? theme.controlAccent : theme.secondaryText)
                )
                .frame(width: 28, height: 28)
                .background(
                    (emphasized ? theme.controlAccent.opacity(0.18) : theme.subtleBorder.opacity(disabled ? 0.08 : 0.22)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            editorHeader
            thinRule
            VStack(alignment: .leading, spacing: 16) {
                if isProtectedCategory {
                    protectedBanner
                }

                livePreviewHero
                nameBlock
                colorBlock

                if let message = userFacingMessage {
                    Text(message.text)
                        .font(.system(size: 12))
                        .foregroundStyle(message.isError ? theme.error : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)

            thinRule
            editorFooter
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Text(editingCategory == nil ? "新建分类" : "编辑分类")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.subtleBorder.opacity(0.3), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Matches item editor: destructive left, primary actions right.
    private var editorFooter: some View {
        HStack(spacing: 8) {
            if editingCategory != nil {
                Button("删除", role: .destructive, action: beginDelete)
                    .controlSize(.small)
                    .disabled(isProtectedCategory || store.phase != .ready)
            }
            Spacer(minLength: 0)
            Button("取消") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
            Button(editingCategory == nil ? "创建" : "保存", action: save)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(isSaveDisabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var protectedBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            Text("「未分类」是系统分类，名称与颜色受保护。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    /// Primary feedback: how the category will look on the calendar.
    private var livePreviewHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("月历预览")
            HStack(spacing: 12) {
                previewChip(appearance: .light, caption: "浅色")
                previewChip(appearance: .dark, caption: "深色")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private func previewChip(appearance: CalendarAppearance, caption: String) -> some View {
        let previewTheme = appearance == .light ? CalendarTheme.light : CalendarTheme.dark
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
        let label = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(previewTheme.secondaryText)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accentColor)
                    .frame(width: 3, height: 15)
                Text(label.isEmpty ? "分类事项" : label)
                    .lineLimit(1)
                    .foregroundStyle(CalendarTheme.categoryColor(textHex))
                Spacer(minLength: 0)
            }
            .font(CalendarTheme.itemFont)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CalendarTheme.categoryColor(canvasHex),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(previewTheme.subtleBorder.opacity(0.55), lineWidth: 1)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("名称")
            TextField("例如：学习、运动、副业", text: $model.draftName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($nameFocused)
                .disabled(isProtectedCategory)
                .onChange(of: model.draftName) { _, _ in
                    if attemptedSave { attemptedSave = false }
                    localError = nil
                }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    private var colorBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("颜色")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CategoryPalette.families) { family in
                        let selected = model.selectedFamilyID == family.id
                        Button {
                            model.selectFamily(family.id)
                        } label: {
                            Text(family.name)
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    selected
                                        ? theme.controlAccent.opacity(0.24)
                                        : theme.subtleBorder.opacity(0.14),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(
                                            selected ? theme.controlAccent.opacity(0.45) : Color.clear,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isProtectedCategory)
                    }
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 30), spacing: 10), count: 8),
                spacing: 10
            ) {
                ForEach(selectedFamily.presets) { preset in
                    let selected = model.draftColorHex.uppercased() == preset.hex
                    Button {
                        model.selectPreset(preset.hex)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(CalendarTheme.categoryColor(preset.hex))
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(swatchCheckColor(for: preset.hex))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .overlay {
                            Circle().stroke(
                                selected ? theme.primaryText.opacity(0.9) : theme.subtleBorder.opacity(0.4),
                                lineWidth: selected ? 2 : 1
                            )
                        }
                        .shadow(
                            color: selected ? CalendarTheme.categoryColor(preset.hex).opacity(0.4) : .clear,
                            radius: 5,
                            y: 1
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isProtectedCategory)
                    .accessibilityLabel("选择\(selectedFamily.name)色系的\(preset.accessibilityName)")
                    .accessibilityValue(selected ? "已选中" : "未选中")
                }
            }

            HStack(spacing: 10) {
                Text("色值")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 32, alignment: .leading)
                TextField("#RRGGBB", text: $model.draftColorHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(isProtectedCategory)
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(isProtectedCategory)
                    .frame(width: 28, height: 22)
                    .help("打开取色器")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fieldBlockBackground)
    }

    // MARK: - Shared chrome

    private var thinRule: some View {
        Rectangle()
            .fill(theme.separator.opacity(0.45))
            .frame(height: 1)
    }

    /// Soft fill only — matches item editor blocks (no heavy double borders).
    private var fieldBlockBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.subtleBorder.opacity(colorScheme == .dark ? 0.16 : 0.14))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
    }

    // MARK: - Validation display

    /// Only show hard errors after the user tries to save (or real save failures).
    private var userFacingMessage: (text: String, isError: Bool)? {
        if let localError {
            return (localError, true)
        }
        if isProtectedCategory {
            return ("系统分类受保护，仅可调整顺序。", false)
        }
        guard attemptedSave, let validationError else { return nil }
        switch validationError {
        case .emptyName:
            return ("请填写分类名称。", true)
        case .duplicateName:
            return ("已有同名分类，请换一个名称。", true)
        case .invalidColor:
            return ("颜色必须是 #RRGGBB 格式。", true)
        case .insufficientContrast:
            return ("这个颜色在浅色或深色下不够清晰，请换一个。", true)
        default:
            return ("当前分类不能保存。", true)
        }
    }

    // MARK: - Model helpers

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

    private var selectedFamily: CategoryColorFamily {
        CategoryPalette.family(id: model.selectedFamilyID)
    }

    private func swatchCheckColor(for hex: String) -> Color {
        guard let base = try? SRGBColor(hex: hex),
              let warmLight = try? SRGBColor(hex: CalendarTheme.dark.primaryTextHex),
              let warmDark = try? SRGBColor(hex: CalendarTheme.light.primaryTextHex)
        else {
            return theme.primaryText
        }
        return base.contrastRatio(with: warmLight) >= base.contrastRatio(with: warmDark)
            ? CalendarTheme.dark.primaryText
            : CalendarTheme.light.primaryText
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

    private var isSaveDisabled: Bool {
        isProtectedCategory || store.phase != .ready
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
        attemptedSave = false
        nameFocused = true
    }

    private func startCreating() {
        editingCategoryID = nil
        model.beginCreating()
        localError = nil
        attemptedSave = false
        nameFocused = true
    }

    private func save() {
        attemptedSave = true
        localError = nil
        if validationError != nil { return }
        Task {
            do {
                if let category = editingCategory {
                    try await model.update(category)
                } else {
                    try await model.create()
                }
                attemptedSave = false
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

    private func migrationTargets(for category: CalendarCategory) -> [CalendarCategory] {
        orderedCategories.filter { $0.id != category.id }
    }

    private func migrationLabel(for target: CalendarCategory) -> String {
        target.id == store.state.uncategorizedID ? "转入未分类" : "转入“\(target.name)”"
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
