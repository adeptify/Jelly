import Foundation

enum CategoryColorFamilyID: String, CaseIterable, Identifiable, Sendable {
    case basic
    case macaron
    case morandi
    case nature
    case vivid

    var id: Self { self }
}

struct CategoryColorPreset: Identifiable, Equatable, Hashable, Sendable {
    let hex: String
    let accessibilityName: String

    var id: String { hex }
}

struct CategoryColorFamily: Identifiable, Equatable, Sendable {
    let id: CategoryColorFamilyID
    let name: String
    let presets: [CategoryColorPreset]

    var colors: [String] { presets.map(\.hex) }

    func minimumRenderedAccentDeltaE(
        appearance: CalendarAppearance,
        simulation: ColorVisionSimulation
    ) throws -> Double {
        let accents = try colors.map {
            try CategoryColorResolver.roles(for: $0, appearance: appearance).accent.simulated(simulation)
        }
        guard accents.count > 1 else { return .infinity }
        var minimum = Double.infinity
        for firstIndex in accents.indices {
            for secondIndex in accents.indices where secondIndex > firstIndex {
                minimum = min(minimum, accents[firstIndex].cie76DeltaE(to: accents[secondIndex]))
            }
        }
        return minimum
    }
}

enum CategoryPalette {
    static let families: [CategoryColorFamily] = [
        family(.basic, "基础", [
            ("#4F7FFF", "晴空蓝"), ("#735DD0", "鸢尾紫"),
            ("#D65772", "莓果红"), ("#E58B39", "琥珀橙"),
            ("#4EAC73", "叶绿"), ("#2E9EB0", "湖水青"),
            ("#9A7650", "胡桃棕"), ("#8C8F96", "中性灰")
        ]),
        family(.macaron, "马卡龙", [
            ("#8FB8F4", "云朵蓝"), ("#A9A2E8", "丁香紫"),
            ("#D7A0C5", "樱花粉"), ("#F0A59A", "蜜桃粉"),
            ("#F4C58C", "奶油杏"), ("#E4D87D", "柠檬黄"),
            ("#9ED8C0", "薄荷绿"), ("#B9D69B", "青苹果")
        ]),
        family(.morandi, "莫兰迪", [
            ("#8296A8", "烟灰蓝"), ("#B28F9B", "灰豆沙"),
            ("#B6816D", "陶土棕"), ("#B6A184", "亚麻褐"),
            ("#8F9878", "苔藓灰绿"), ("#7F9B8B", "灰鼠尾草"),
            ("#5F889F", "雾霭蓝"), ("#8B7867", "暖岩棕")
        ]),
        family(.nature, "自然", [
            ("#4D83A6", "远山蓝"), ("#3E705A", "森林绿"),
            ("#6F8652", "橄榄绿"), ("#4D8D89", "松石青"),
            ("#C18A3D", "麦穗金"), ("#B86549", "红陶"),
            ("#81566F", "梅子紫"), ("#73716B", "岩石灰")
        ]),
        family(.vivid, "鲜亮", [
            ("#3D63E9", "电光蓝"), ("#7548D8", "亮紫"),
            ("#D43282", "玫红"), ("#EF5E55", "珊瑚红"),
            ("#F28A24", "活力橙"), ("#83B928", "青柠绿"),
            ("#19A86B", "翡翠绿"), ("#149DB4", "海洋蓝")
        ])
    ]

    static func family(id: CategoryColorFamilyID) -> CategoryColorFamily {
        families.first(where: { $0.id == id }) ?? families[0]
    }

    static func preset(hex: String) -> CategoryColorPreset? {
        let normalized = try? CategoryColorValidator.normalizedHex(hex)
        return families.lazy.flatMap(\.presets).first { $0.hex == normalized }
    }

    private static func family(
        _ id: CategoryColorFamilyID,
        _ name: String,
        _ values: [(String, String)]
    ) -> CategoryColorFamily {
        CategoryColorFamily(
            id: id,
            name: name,
            presets: values.map(CategoryColorPreset.init(hex:accessibilityName:))
        )
    }
}

enum ColorVisionSimulation: Sendable {
    case protanopia
    case deuteranopia
}

struct CategoryColorRoles: Equatable, Sendable {
    let accent: SRGBColor
    let softBackground: SRGBColor
    let outline: SRGBColor
    let text: SRGBColor
    let canvas: SRGBColor
    let completed: CategoryRenderedColorRoles

    var accentContrast: Double { accent.contrastRatio(with: softBackground) }
    var textContrast: Double { text.contrastRatio(with: softBackground) }

    var normal: CategoryRenderedColorRoles {
        CategoryRenderedColorRoles(
            accent: accent,
            background: softBackground,
            outline: outline,
            text: text
        )
    }

    func rendered(isCompleted: Bool) -> CategoryRenderedColorRoles {
        isCompleted ? completed : normal
    }
}

struct CategoryRenderedColorRoles: Equatable, Sendable {
    let accent: SRGBColor
    let background: SRGBColor
    let outline: SRGBColor
    let text: SRGBColor

    var accentContrast: Double { accent.contrastRatio(with: background) }
    var outlineContrast: Double { outline.contrastRatio(with: background) }
    var textContrast: Double { text.contrastRatio(with: background) }
}

struct CategoryColorCalibrationDrift: Equatable, Sendable {
    let hueDegrees: Double
    let lightness: Double
    let chroma: Double
}

enum CategoryColorResolver {
    static func roles(
        for colorHex: String,
        appearance: CalendarAppearance
    ) throws -> CategoryColorRoles {
        let normalized = try CategoryColorValidator.normalizedHex(colorHex)
        let base = try SRGBColor(hex: normalized)
        let canvas = try SRGBColor(hex: appearance == .light
            ? CalendarTheme.previewLightCanvasHex
            : CalendarTheme.previewDarkCanvasHex)
        let text = try SRGBColor(hex: appearance == .light
            ? CalendarTheme.previewLightTextHex
            : CalendarTheme.previewDarkTextHex)
        let softBackground = base.composited(
            over: canvas,
            alpha: CalendarTheme.categoryItemBackgroundOpacity
        )
        let accent = paletteAccents[appearance]?[normalized]
            ?? accentMeetingMinimumContrast(
                from: base,
                surface: softBackground,
                appearance: appearance
            )
        let outlineSeed = accent.mixed(toward: text, fraction: 0.18)
        let outline = accentMeetingMinimumContrast(
            from: outlineSeed,
            surface: softBackground,
            appearance: appearance
        )
        return CategoryColorRoles(
            accent: accent,
            softBackground: softBackground,
            outline: outline,
            text: text,
            canvas: canvas,
            completed: CategoryRenderedColorRoles(
                // Completion is expressed by the checkbox glyph and strikethrough in the row.
                // It deliberately keeps the contrast-safe colors instead of fading them.
                accent: accent,
                background: softBackground,
                outline: outline,
                text: text
            )
        )
    }

    static func calibrationDrift(
        for colorHex: String,
        appearance: CalendarAppearance
    ) throws -> CategoryColorCalibrationDrift {
        let baseline = try contrastOnlyAccent(for: colorHex, appearance: appearance)
        let rendered = try roles(for: colorHex, appearance: appearance).accent
        return baseline.calibrationDrift(to: rendered)
    }

    private static func contrastOnlyAccent(
        for colorHex: String,
        appearance: CalendarAppearance
    ) throws -> SRGBColor {
        let base = try SRGBColor(hex: colorHex)
        let canvas = try SRGBColor(hex: appearance == .light
            ? CalendarTheme.previewLightCanvasHex
            : CalendarTheme.previewDarkCanvasHex)
        let surface = base.composited(
            over: canvas,
            alpha: CalendarTheme.categoryItemBackgroundOpacity
        )
        return accentMeetingMinimumContrast(
            from: base,
            surface: surface,
            appearance: appearance
        )
    }

    private static func accentMeetingMinimumContrast(
        from color: SRGBColor,
        surface: SRGBColor,
        appearance: CalendarAppearance
    ) -> SRGBColor {
        // Keep a small margin so platform color conversion and rasterization cannot turn a
        // mathematically exact 3.00:1 result into a rendered near miss.
        let renderedMinimumContrast = CalendarTheme.categoryAccentMinimumContrast + 0.05
        let pole = appearance == .light ? SRGBColor.black : SRGBColor.white
        for step in 0...200 {
            let candidate = color.mixed(toward: pole, fraction: Double(step) / 200)
            if candidate.contrastRatio(with: surface) >= renderedMinimumContrast {
                return candidate
            }
        }
        return pole
    }

    // Palette rendering is calibrated as a family, not by color-specific exceptions. Starting
    // from each contrast-safe accent, a deterministic bounded HSL search chooses the nearest
    // rendered candidate that stays distinguishable from every earlier family member under
    // both simulations. Persisted base hex values never enter this cache as mutated values.
    private static let paletteAccents: [CalendarAppearance: [String: SRGBColor]] = {
        var result: [CalendarAppearance: [String: SRGBColor]] = [:]
        for appearance in [CalendarAppearance.light, .dark] {
            let canvasHex = appearance == .light
                ? CalendarTheme.previewLightCanvasHex
                : CalendarTheme.previewDarkCanvasHex
            guard let canvas = try? SRGBColor(hex: canvasHex) else { continue }
            var accentsByHex: [String: SRGBColor] = [:]
            for family in CategoryPalette.families {
                var resolvedFamily: [SRGBColor] = []
                for hex in family.colors {
                    guard let base = try? SRGBColor(hex: hex) else { continue }
                    let surface = base.composited(
                        over: canvas,
                        alpha: CalendarTheme.categoryItemBackgroundOpacity
                    )
                    let raw = accentMeetingMinimumContrast(
                        from: base,
                        surface: surface,
                        appearance: appearance
                    )
                    let accent = nearestDistinguishableAccent(
                        from: raw,
                        surface: surface,
                        appearance: appearance,
                        previous: resolvedFamily
                    )
                    resolvedFamily.append(accent)
                    accentsByHex[hex] = accent
                }
            }
            result[appearance] = accentsByHex
        }
        return result
    }()

    private static func nearestDistinguishableAccent(
        from raw: SRGBColor,
        surface: SRGBColor,
        appearance: CalendarAppearance,
        previous: [SRGBColor]
    ) -> SRGBColor {
        let minimumDeltaE = 3.25
        guard !meetsSimulationSeparation(raw, previous: previous, minimum: minimumDeltaE) else {
            return raw
        }

        for adjustment in calibrationCandidates {
            let adjusted = raw.adjustingHSL(
                hueDegrees: adjustment.hueDegrees,
                saturationMultiplier: adjustment.saturationMultiplier,
                lightnessOffset: adjustment.lightnessOffset
            )
            let candidate = accentMeetingMinimumContrast(
                from: adjusted,
                surface: surface,
                appearance: appearance
            )
            if meetsSimulationSeparation(
                candidate,
                previous: previous,
                minimum: minimumDeltaE
            ) {
                return candidate
            }
        }
        return raw
    }

    private static func meetsSimulationSeparation(
        _ candidate: SRGBColor,
        previous: [SRGBColor],
        minimum: Double
    ) -> Bool {
        previous.allSatisfy { other in
            [ColorVisionSimulation.protanopia, .deuteranopia].allSatisfy { simulation in
                candidate.simulated(simulation).cie76DeltaE(to: other.simulated(simulation)) >= minimum
            }
        }
    }

    private struct HSLAdjustment: Sendable {
        let hueDegrees: Double
        let saturationMultiplier: Double
        let lightnessOffset: Double

        var searchCost: Double {
            abs(hueDegrees) / 3
                + abs(saturationMultiplier - 1) / 0.1
                + abs(lightnessOffset) / 0.01
        }
    }

    private static let calibrationCandidates: [HSLAdjustment] = {
        var hueOffsets: [Double] = [0]
        for step in 1...10 {
            hueOffsets.append(Double(step) * 3)
            hueOffsets.append(-Double(step) * 3)
        }
        var lightnessOffsets: [Double] = [0]
        for step in 1...25 {
            lightnessOffsets.append(Double(step) / 100)
            lightnessOffsets.append(-Double(step) / 100)
        }
        let saturationMultipliers = [1.0, 0.9, 1.1, 0.75, 1.25, 0.6, 1.4]
        return hueOffsets.flatMap { hue in
            lightnessOffsets.flatMap { lightness in
                saturationMultipliers.map { saturation in
                    HSLAdjustment(
                        hueDegrees: hue,
                        saturationMultiplier: saturation,
                        lightnessOffset: lightness
                    )
                }
            }
        }.sorted {
            if $0.searchCost != $1.searchCost { return $0.searchCost < $1.searchCost }
            if abs($0.hueDegrees) != abs($1.hueDegrees) {
                return abs($0.hueDegrees) < abs($1.hueDegrees)
            }
            if abs($0.lightnessOffset) != abs($1.lightnessOffset) {
                return abs($0.lightnessOffset) < abs($1.lightnessOffset)
            }
            if $0.saturationMultiplier != $1.saturationMultiplier {
                return $0.saturationMultiplier < $1.saturationMultiplier
            }
            if $0.hueDegrees != $1.hueDegrees { return $0.hueDegrees < $1.hueDegrees }
            return $0.lightnessOffset < $1.lightnessOffset
        }
    }()
}

struct SRGBColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let black = SRGBColor(red: 0, green: 0, blue: 0)
    static let white = SRGBColor(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    init(hex: String) throws {
        let normalized = try CategoryColorValidator.normalizedHex(hex)
        let value = UInt64(normalized.dropFirst(), radix: 16)!
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    func composited(over canvas: SRGBColor, alpha: Double) -> SRGBColor {
        mixed(toward: canvas, fraction: 1 - Self.clamp(alpha))
    }

    func mixed(toward other: SRGBColor, fraction: Double) -> SRGBColor {
        let amount = Self.clamp(fraction)
        return SRGBColor(
            red: red * (1 - amount) + other.red * amount,
            green: green * (1 - amount) + other.green * amount,
            blue: blue * (1 - amount) + other.blue * amount
        )
    }

    func contrastRatio(with other: SRGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func simulated(_ simulation: ColorVisionSimulation) -> SRGBColor {
        // Machado, Oliveira & Fernandes (2009), severity 1.0 precomputed matrices
        // published in the 2010 supplemental table and exposed by Colour Science as
        // CVD_MATRICES_MACHADO2010. Domain: linear RGB. Pipeline: sRGB decode ->
        // 3x3 matrix -> gamut clamp -> sRGB encode.
        // https://doi.org/10.1109/TVCG.2009.113
        // https://colour.readthedocs.io/en/develop/generated/colour.CVD_MATRICES_MACHADO2010.html
        let matrix: [[Double]] = switch simulation {
        case .protanopia:
            [
                [0.152286, 1.052583, -0.204868],
                [0.114503, 0.786281, 0.099216],
                [-0.003882, -0.048116, 1.051998]
            ]
        case .deuteranopia:
            [
                [0.367322, 0.860646, -0.227968],
                [0.280085, 0.672501, 0.047413],
                [-0.011820, 0.042940, 0.968881]
            ]
        }
        let linearComponents = [Self.linear(red), Self.linear(green), Self.linear(blue)]
        let transformed = matrix.map { row in
            zip(row, linearComponents).reduce(0) { $0 + $1.0 * $1.1 }
        }
        return SRGBColor(
            red: Self.encoded(Self.clamp(transformed[0])),
            green: Self.encoded(Self.clamp(transformed[1])),
            blue: Self.encoded(Self.clamp(transformed[2]))
        )
    }

    func cie76DeltaE(to other: SRGBColor) -> Double {
        let first = lab
        let second = other.lab
        return sqrt(
            pow(first.l - second.l, 2)
                + pow(first.a - second.a, 2)
                + pow(first.b - second.b, 2)
        )
    }

    func adjustingHSL(
        hueDegrees: Double,
        saturationMultiplier: Double,
        lightnessOffset: Double
    ) -> SRGBColor {
        let hsl = hslComponents
        var hue = hsl.hueDegrees
        hue = (hue + hueDegrees).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let adjustedSaturation = Self.clamp(hsl.saturation * saturationMultiplier)
        let adjustedLightness = Self.clamp(hsl.lightness + lightnessOffset)
        let chroma = (1 - abs(2 * adjustedLightness - 1)) * adjustedSaturation
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let offset = adjustedLightness - chroma / 2
        let components: (Double, Double, Double) = switch hue {
        case 0..<60: (chroma, x, 0)
        case 60..<120: (x, chroma, 0)
        case 120..<180: (0, chroma, x)
        case 180..<240: (0, x, chroma)
        case 240..<300: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return SRGBColor(
            red: components.0 + offset,
            green: components.1 + offset,
            blue: components.2 + offset
        )
    }

    func calibrationDrift(to other: SRGBColor) -> CategoryColorCalibrationDrift {
        let first = hslComponents
        let second = other.hslComponents
        let directHueDistance = abs(first.hueDegrees - second.hueDegrees)
        return CategoryColorCalibrationDrift(
            hueDegrees: min(directHueDistance, 360 - directHueDistance),
            lightness: abs(first.lightness - second.lightness),
            chroma: abs(chroma - other.chroma)
        )
    }

    private var relativeLuminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    private var chroma: Double {
        max(red, green, blue) - min(red, green, blue)
    }

    private var hslComponents: (hueDegrees: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        let hue: Double
        if maximum == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        return (hue < 0 ? hue + 360 : hue, saturation, lightness)
    }

    private var lab: (l: Double, a: Double, b: Double) {
        let red = Self.linear(red)
        let green = Self.linear(green)
        let blue = Self.linear(blue)
        let x = (0.4124564 * red + 0.3575761 * green + 0.1804375 * blue) / 0.95047
        let y = 0.2126729 * red + 0.7151522 * green + 0.0721750 * blue
        let z = (0.0193339 * red + 0.1191920 * green + 0.9503041 * blue) / 1.08883
        let fx = Self.labPivot(x)
        let fy = Self.labPivot(y)
        let fz = Self.labPivot(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ component: Double) -> Double {
        component <= 0.0031308
            ? 12.92 * component
            : 1.055 * pow(component, 1 / 2.4) - 0.055
    }

    private static func labPivot(_ value: Double) -> Double {
        let threshold = pow(6.0 / 29.0, 3)
        return value > threshold
            ? pow(value, 1.0 / 3.0)
            : value / (3 * pow(6.0 / 29.0, 2)) + 4.0 / 29.0
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
