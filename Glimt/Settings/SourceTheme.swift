/// Original native presets. Colors are resolved in the renderer, never loaded from code or URLs.
enum SourceThemePreset: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case glimtDefault, neutral, highContrast

    var displayName: String {
        switch self {
        case .glimtDefault: "Glimt Default"
        case .neutral: "Neutral"
        case .highContrast: "High Contrast"
        }
    }
}

/// Codable sRGB components, independent of AppKit's archived color representations.
struct SourceThemeColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// Creates an sRGB color after replacing non-finite components and clamping them to 0...1.
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        // Sanitize at the value boundary so decoded and editor-created colors share the same range.
        self.red = Self.component(red)
        self.green = Self.component(green)
        self.blue = Self.component(blue)
        self.alpha = alpha.isFinite ? min(max(alpha, 0), 1) : 1
    }

    /// Reapplies component bounds to values decoded without going through the validated initializer.
    func normalized() -> SourceThemeColor { .init(red: red, green: green, blue: blue, alpha: alpha) }
    /// Replaces non-finite channels and clamps every color component to the sRGB unit interval.
    private static func component(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
}

/// A complete custom palette: no token falls through to an unrelated preset color.
struct SourceThemePalette: Codable, Equatable, Sendable {
    var background: SourceThemeColor
    var foreground: SourceThemeColor
    var comment: SourceThemeColor
    var keyword: SourceThemeColor
    var string: SourceThemeColor
    var number: SourceThemeColor
    var type: SourceThemeColor
    var directive: SourceThemeColor

    /// Normalizes every palette color before it reaches AppKit drawing APIs.
    func normalized() -> SourceThemePalette {
        // Normalize every token color; partial fallback to preset colors would change user-authored palettes.
        .init(background: background.normalized(), foreground: foreground.normalized(),
              comment: comment.normalized(), keyword: keyword.normalized(), string: string.normalized(),
              number: number.normalized(), type: type.normalized(), directive: directive.normalized())
    }
}
