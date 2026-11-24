import AppKit
import InspectorCore

extension SourceRenderConfiguration {
    @MainActor
    /// Chooses the configured palette from the preview's effective appearance, including simulated themes.
    func activePalette(for appearance: NSAppearance) -> SourceThemePalette? {
        // Resolve by the preview's explicit effective appearance rather than the process-wide setting.
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkPalette : lightPalette
    }

    @MainActor
    /// Resolves the corresponding built-in preset for the same explicit appearance used by the palette.
    func activeTheme(for appearance: NSAppearance) -> SourceThemePreset {
        // Keep preset selection aligned with palette selection for simulated light/dark previews.
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkTheme : lightTheme
    }

    /// Resolve only the explicit render input; native renderers never consult a settings store.
    @MainActor
    func resolvedFont(weight: NSFont.Weight = .regular) -> NSFont {
        let size = CGFloat(fontSize)
        let font: NSFont
        switch fontFamily {
        case "Menlo", "Monaco": font = NSFont(name: fontFamily, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        default: return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return weight == .bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }
}

/// System-derived token colors, blended toward text when needed for readable contrast.
enum SourceSyntaxColors {
    @MainActor
    /// Captures system-resolved built-in colors as stable sRGB values for settings swatches.
    static func palette(for preset: SourceThemePreset, appearance: NSAppearance) -> SourceThemePalette {
        /// Resolves one system color in the requested appearance and converts it to persisted sRGB channels.
        func value(_ color: NSColor) -> SourceThemeColor {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            guard let resolved else { return .init(red: 0, green: 0, blue: 0) }
            return .init(red: Double(resolved.redComponent), green: Double(resolved.greenComponent),
                         blue: Double(resolved.blueComponent), alpha: Double(resolved.alphaComponent))
        }
        return .init(background: value(background(for: preset)), foreground: value(foreground(for: preset)),
                     comment: value(color(for: .comment, preset: preset)), keyword: value(color(for: .keyword, preset: preset)),
                     string: value(color(for: .string, preset: preset)), number: value(color(for: .number, preset: preset)),
                     type: value(color(for: .type, preset: preset)), directive: value(color(for: .directive, preset: preset)))
    }

    /// Constructs an AppKit color only after persisted channels have been normalized.
    private static func native(_ color: SourceThemeColor) -> NSColor {
        // Normalize persisted components before constructing an AppKit color.
        let value = color.normalized()
        return .init(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    /// A small, inert settings sample resolved in the preset's own light/dark appearance.
    @MainActor
    static func swatch(for preset: SourceThemePreset, appearance: NSAppearance) -> NSAttributedString {
        /// Resolves a dynamic color in the swatch's simulated appearance before storing it as an attribute.
        func resolved(_ color: NSColor) -> NSColor {
            var value = color
            appearance.performAsCurrentDrawingAppearance { value = color.usingColorSpace(.sRGB) ?? color }
            return value
        }
        let sample = NSMutableAttributedString(string: "")
        let parts: [(String, SyntaxTokenKind?)] = [("let", .keyword), (" value = ", nil), ("\"Glimt\"", .string), (" // comment", .comment)]
        for (text, kind) in parts {
            sample.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: resolved(kind.map { color(for: $0, preset: preset) } ?? foreground(for: preset)),
                .backgroundColor: resolved(background(for: preset))
            ]))
        }
        return sample
    }

    /// Uses a custom persisted background when present and the system text background otherwise.
    static func background(for preset: SourceThemePreset, palette: SourceThemePalette? = nil) -> NSColor {
        palette.map { native($0.background) } ?? .textBackgroundColor
    }

    /// Resolves the custom foreground or the preset's system foreground fallback.
    static func foreground(for preset: SourceThemePreset, palette: SourceThemePalette? = nil) -> NSColor {
        palette.map { native($0.foreground) } ?? (preset == .highContrast ? .labelColor : .textColor)
    }

    /// Returns custom token colors unchanged; built-in candidates are blended to their contrast target.
    static func color(for kind: SyntaxTokenKind, preset: SourceThemePreset = .glimtDefault, palette: SourceThemePalette? = nil) -> NSColor {
        // A custom palette is already user-authored; built-in palettes instead enforce their contrast target.
        if let palette {
            let value: SourceThemeColor = switch kind {
            case .comment: palette.comment
            case .string: palette.string
            case .keyword: palette.keyword
            case .number: palette.number
            case .type: palette.type
            case .variable: palette.type
            case .directive: palette.directive
            }
            return native(value)
        }
        return NSColor(name: nil) { appearance in
            var result = foreground(for: preset)
            appearance.performAsCurrentDrawingAppearance {
                let candidate: NSColor
                switch preset {
                case .glimtDefault:
                    candidate = switch kind {
                    case .comment: .secondaryLabelColor
                    case .string: .systemGreen
                    case .keyword: .systemPurple
                    case .number: .systemBlue
                    case .type: .systemTeal
                    case .variable: .systemTeal
                    case .directive: .systemOrange
                    }
                case .neutral:
                    candidate = kind == .comment ? .secondaryLabelColor : .textColor
                case .highContrast:
                    candidate = switch kind {
                    case .comment: .labelColor
                    case .string: .systemBlue
                    case .keyword: .systemPink
                    case .number: .systemPurple
                    case .type: .systemIndigo
                    case .variable: .systemIndigo
                    case .directive: .systemRed
                    }
                }
                let backgroundColor = background(for: preset)
                let foregroundColor = foreground(for: preset)
                let minimumContrast = preset == .highContrast ? 7.0 : 4.5
                result = candidate
                for _ in 0..<20 {
                    if contrast(result, backgroundColor) >= minimumContrast { break }
                    result = result.blended(withFraction: 0.25, of: foregroundColor) ?? foregroundColor
                }
                if contrast(result, backgroundColor) < minimumContrast { result = foregroundColor }
            }
            return result
        }
    }

    /// Computes WCAG contrast after compositing the first color over the second in sRGB.
    static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        // Compute WCAG relative luminance after alpha-compositing the foreground over the background.
        /// Converts an sRGB channel from gamma-encoded space to linear light.
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        guard let foreground = first.usingColorSpace(.sRGB), let background = second.usingColorSpace(.sRGB) else { return 1 }
        let alpha = Double(foreground.alphaComponent)
        let fg = [foreground.redComponent, foreground.greenComponent, foreground.blueComponent].map(Double.init)
        let bg = [background.redComponent, background.greenComponent, background.blueComponent].map(Double.init)
        let weights = [0.2126, 0.7152, 0.0722]
        let a = zip(zip(fg, bg), weights).reduce(0.0) { $0 + linear($1.0.0 * alpha + $1.0.1 * (1 - alpha)) * $1.1 }
        let b = zip(bg, weights).reduce(0.0) { $0 + linear($1.0) * $1.1 }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

