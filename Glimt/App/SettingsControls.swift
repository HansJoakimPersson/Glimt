import AppKit
import InspectorCore

// Shared native controls for General and Format details. Each control shows one value, reports
// edits through `onChange`, and never writes settings itself.

// MARK: - Form layout

@MainActor
/// Shared layout helpers for native form labels and consistent settings control spacing.
enum SettingsForm {
    static let margin: CGFloat = 24
    static let subtitleToForm: CGFloat = 28
    static let rowSpacing: CGFloat = 12

    /// Creates the right-aligned label used in the shared settings grid.
    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    /// Builds secondary text with optional selection for values users may need to copy.
    static func secondary(_ text: String, selectable: Bool = false) -> NSTextField {
        let field = selectable ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.isSelectable = selectable
        return field
    }

    /// Groups a required title with an optional supporting line for a settings section.
    static func heading(_ title: String, subtitle: String?) -> NSStackView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 20, weight: .semibold)
        titleField.setAccessibilityRole(.staticText)
        var views: [NSView] = [titleField]
        if let subtitle {
            let field = NSTextField(labelWithString: subtitle)
            field.textColor = .secondaryLabelColor
            views.append(field)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// Right-aligned labels, one shared control start edge.
    /// Aligns control columns while fixing the label width to prevent short forms from drifting.
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // A stack hands a grid its spare width, which NSGridView gives the label column and so
        // pushes a short form's labels off the leading edge. Fix the label column to its widest label.
        // Grid widths are alignment widths, which a label's intrinsic size gives and its frame does not.
        grid.column(at: 0).width = rows.compactMap(\.first).map { view in
            view.intrinsicContentSize.width > 0 ? view.intrinsicContentSize.width : view.fittingSize.width
        }.max() ?? 0
        return grid
    }

    /// Arranges related controls along a common baseline.
    static func horizontal(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = spacing
        return stack
    }

    /// Centred, wrapping explanation for an empty list; `overlay(_:on:width:)` puts it inside the list.
    static func listEmptyState(_ text: String, identifier: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.alignment = .center
        label.identifier = .init(identifier)
        return label
    }

    /// Returns the list's scroll view with an empty-state label overlaid on it, inset from its edges.
    static func overlay(_ label: NSTextField, on scroll: NSScrollView, width: CGFloat) -> NSView {
        // NSScrollView tiles its own subviews, so the label sits in a container above the list.
        let container = NSView()
        label.preferredMaxLayoutWidth = width - 32
        for child in [scroll, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        return container
    }
}

/// Settings v8 rows (`16` §3.1, `09` §8.1): title and help on the leading side, one fixed
/// trailing control column, and a hairline separator between rows.
@MainActor
enum GeneralSettingsForm {
    static let sectionGap: CGFloat = 24
    static let headingGap: CGFloat = 8
    static let rowIndent: CGFloat = 24
    static let rowGap: CGFloat = 14
    static let controlColumn: CGFloat = 260
    static let controlGap: CGFloat = 16
    static let popupWidth: CGFloat = 200

    /// Adds a heading whose help text is available to both pointer and assistive users.
    static func sectionHeading(_ title: String, identifier: String, help: String) -> NSTextField {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .left
        heading.identifier = .init(identifier)
        heading.toolTip = help
        heading.setAccessibilityRole(.staticText)
        heading.setAccessibilityHelp(help)
        return heading
    }

    /// Creates wrapping explanatory text that yields width before controls do.
    static func wrappingHelp(_ text: String, identifier: String? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        // Below the fitting-size priority: help wraps instead of setting the window's minimum width.
        field.setContentCompressionResistancePriority(.init(49), for: .horizontal)
        if let identifier { field.identifier = .init(identifier) }
        return field
    }

    /// Builds one row: indented title over help, and the control right-aligned in the common column.
    static func row(label: String, help: String, control: NSView, identifier: String) -> NSView {
        let row = NSView()
        row.identifier = .init(identifier)
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: 13)
        title.identifier = .init("\(identifier)-Label")
        title.setAccessibilityRole(.staticText)
        title.lineBreakMode = .byWordWrapping
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = wrappingHelp(help, identifier: "\(identifier)-Help")
        let description = NSStackView(views: [title, detail])
        description.orientation = .vertical
        description.alignment = .leading
        description.spacing = 2
        description.translatesAutoresizingMaskIntoConstraints = false
        // Both lines span the column so short text stays left-aligned at the row indent.
        title.widthAnchor.constraint(equalTo: description.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: description.widthAnchor).isActive = true

        let trailing = NSView()
        trailing.identifier = .init("\(identifier)-Controls")
        trailing.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        trailing.addSubview(control)
        NSLayoutConstraint.activate([
            control.trailingAnchor.constraint(equalTo: trailing.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: trailing.centerYAnchor),
            control.leadingAnchor.constraint(greaterThanOrEqualTo: trailing.leadingAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: trailing.topAnchor),
            control.bottomAnchor.constraint(lessThanOrEqualTo: trailing.bottomAnchor)
        ])
        if control is NSPopUpButton {
            control.widthAnchor.constraint(equalToConstant: popupWidth).isActive = true
        }
        if let dataLimit = control as? DataLimitControl {
            dataLimit.feedback.preferredMaxLayoutWidth = controlColumn
        }

        row.addSubview(description)
        row.addSubview(trailing)
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: rowIndent),
            description.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -controlGap),
            // Text takes the room up to the control column, and wraps only when that runs out.
            {
                let fill = description.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -controlGap)
                // Above text hugging, below required: the row width decides, never the text.
                fill.priority = .init(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)
                return fill
            }(),
            description.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            description.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            description.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            trailing.widthAnchor.constraint(equalToConstant: controlColumn),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            trailing.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        // Hug the taller of text and control instead of keeping a minimum row height.
        for view in [description, trailing] as [NSView] {
            let hug = view.heightAnchor.constraint(equalTo: row.heightAnchor)
            hug.priority = .defaultLow
            hug.isActive = true
        }
        return row
    }
}

// MARK: - Slider with value and reset

/// Standard `NSSlider` preceded by its value and a reset button (`16` §3.2). The reset is hidden
/// at the default value but keeps its space so the value and slider never move.
@MainActor
final class ValueSlider: NSStackView {
    let slider: NSSlider
    let valueLabel = NSTextField(labelWithString: "")
    let reset: NSButton
    private let resetSlot = NSView()
    private let defaultValue: Double
    private let step: Double
    private let format: (Double) -> String
    var onChange: ((Double) -> Void)?

    /// Creates a bounded numeric control with a stable accessibility identifier and default.
    init(range: ClosedRange<Double>, step: Double, defaultValue: Double, name: String, identifier: String,
         format: @escaping (Double) -> String) {
        self.defaultValue = defaultValue
        self.step = step
        self.format = format
        slider = NSSlider(value: defaultValue, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise",
                                        accessibilityDescription: "Reset to default") ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        slider.identifier = .init(identifier)
        slider.setAccessibilityLabel(name)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        setStepRange(maximum: range.upperBound)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.identifier = .init("\(identifier)Value")
        valueLabel.setAccessibilityElement(false)
        valueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        reset.isBordered = false
        reset.contentTintColor = .secondaryLabelColor
        reset.imageScaling = .scaleProportionallyDown
        reset.identifier = .init("Reset\(identifier)")
        reset.target = self
        reset.action = #selector(resetToDefault(_:))
        let resetTitle = "Reset to default (\(format(defaultValue)))"
        reset.toolTip = resetTitle
        reset.setAccessibilityLabel(resetTitle)
        reset.translatesAutoresizingMaskIntoConstraints = false
        resetSlot.addSubview(reset)
        NSLayoutConstraint.activate([
            resetSlot.widthAnchor.constraint(equalToConstant: 16),
            resetSlot.heightAnchor.constraint(equalToConstant: 16),
            reset.leadingAnchor.constraint(equalTo: resetSlot.leadingAnchor),
            reset.trailingAnchor.constraint(equalTo: resetSlot.trailingAnchor),
            reset.topAnchor.constraint(equalTo: resetSlot.topAnchor),
            reset.bottomAnchor.constraint(equalTo: resetSlot.bottomAnchor)
        ])
        addArrangedSubview(resetSlot)
        addArrangedSubview(valueLabel)
        addArrangedSubview(slider)
        set(defaultValue)
    }
    /// Rejects storyboard construction because the slider control is assembled programmatically.
    required init?(coder: NSCoder) { nil }

    var isEnabled = true { didSet { slider.isEnabled = isEnabled; updateReset() } }
    var value: Double { slider.doubleValue }

    /// One tick per step so arrow keys and dragging land on whole steps.
    func setStepRange(maximum: Double) {
        slider.maxValue = maximum
        slider.numberOfTickMarks = Int(((maximum - slider.minValue) / step).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
    }

    /// Shows a stored value without reporting an edit.
    func set(_ number: Double) {
        slider.doubleValue = number
        updateValueText()
    }

    /// Updates the visible and accessible slider value without notifying the settings owner.
    private func updateValueText() {
        let text = format(slider.doubleValue)
        valueLabel.stringValue = text
        slider.setAccessibilityValueDescription(text)
        updateReset()
    }

    /// Hides reset when the slider is already at its default or the control is disabled.
    private func updateReset() {
        reset.isHidden = abs(slider.doubleValue - defaultValue) < step / 2 || !isEnabled
    }

    @objc private func changed(_ sender: NSSlider) {
        updateValueText()
        onChange?(sender.doubleValue)
    }

    @objc private func resetToDefault(_ sender: Any?) {
        set(defaultValue)
        onChange?(defaultValue)
        window?.makeFirstResponder(slider)
    }
}

// MARK: - Color scheme

/// `Light` / `Dark` / `Adapt to system` (D51); the choice applies to the whole app.
@MainActor
final class ColorSchemePopup: NSPopUpButton {
    static let schemes: [PreviewAppearance] = [.light, .dark, .system]
    var onChange: ((PreviewAppearance) -> Void)?

    /// Creates the General settings form and binds it to the shared session.
    init() {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: ["Light", "Dark", "Adapt to system"])
        setAccessibilityLabel("Color scheme")
        identifier = .init("ColorScheme")
        target = self
        action = #selector(changed(_:))
    }
    /// Rejects storyboard construction because the popup configures its own fixed choices.
    required init?(coder: NSCoder) { nil }

    var value: PreviewAppearance { Self.schemes[max(0, indexOfSelectedItem)] }
    /// Synchronizes the popup selection with the stored appearance without emitting a change.
    func set(_ scheme: PreviewAppearance) { selectItem(at: Self.schemes.firstIndex(of: scheme) ?? 2) }
    @objc private func changed(_ sender: Any?) { onChange?(value) }
}

// MARK: - Text font

/// Prose family for rendered Markdown (`16` §3.2); each item previews its own family.
@MainActor
final class TextFontPopup: NSPopUpButton {
    var onChange: ((String) -> Void)?

    /// Creates the text and code settings form from the current General settings.
    init() {
        super.init(frame: .zero, pullsDown: false)
        for family in GeneralSettingsV3.textFontFamilies {
            addItem(withTitle: family)
            lastItem?.attributedTitle = NSAttributedString(string: family, attributes: [
                .font: MarkdownRenderer.textFont(family, size: NSFont.systemFontSize)
            ])
        }
        setAccessibilityLabel("Text font")
        identifier = .init("TextFont")
        target = self
        action = #selector(changed(_:))
    }
    /// Rejects storyboard construction because font choices are populated from settings metadata.
    required init?(coder: NSCoder) { nil }

    var value: String { titleOfSelectedItem ?? "System" }
    /// Selects the saved font family, falling back to the first supported choice if unavailable.
    func set(_ family: String) { selectItem(withTitle: family); if indexOfSelectedItem < 0 { selectItem(at: 0) } }
    @objc private func changed(_ sender: Any?) { onChange?(value) }
}

// MARK: - Theme swatches

/// One theme, drawn in its own palette regardless of the window's appearance.
@MainActor
final class ThemeSwatchButton: NSButton {
    var palette: SourceThemePalette? { didSet { needsDisplay = true } }
    var themeName = "" { didSet { needsDisplay = true; updateAccessibility() } }
    var isInherited = false { didSet { updateAccessibility() } }
    let slot: PreviewAppearance

    /// Creates a theme selector for the requested light or dark appearance slot.
    init(slot: PreviewAppearance) {
        self.slot = slot
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        identifier = .init(slot == .dark ? "DarkThemeSwatch" : "LightThemeSwatch")
        // Preferred 156 pt; narrows in the 40 % Format details column instead of widening the window.
        let preferred = widthAnchor.constraint(equalToConstant: 156)
        preferred.priority = .defaultLow
        NSLayoutConstraint.activate([preferred, widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
                                     heightAnchor.constraint(equalToConstant: 52)])
        setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
    }
    /// Rejects storyboard construction because the swatch requires a runtime theme palette.
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: 52) }

    /// Keeps VoiceOver and the tooltip synchronized with theme and inheritance state.
    private func updateAccessibility() {
        let label = "\(slot == .dark ? "Dark" : "Light") theme: \(themeName)"
        setAccessibilityLabel(isInherited ? label + ", inherited from General" : label)
        toolTip = label
    }

    // Keyword, name, operator, string and comment: the sample shows whole tokens only (D36).
    static let sample = ["let ", "x", " = ", "\"Glimt\"", " // 1"]
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// How many leading sample tokens fit whole in a swatch of this width.
    static func sampleTokenCount(fitting width: CGFloat) -> Int {
        var x: CGFloat = 10
        for (index, token) in sample.enumerated() {
            x += ceil((token as NSString).size(withAttributes: [.font: codeFont]).width)
            if x > width - 8 { return index }
        }
        return sample.count
    }

    /// Converts the persisted sRGB components to AppKit's color type.
    static func color(_ value: SourceThemeColor) -> NSColor {
        NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
    }

    /// Draws the appearance-specific palette and only whole syntax tokens that fit.
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        guard let palette else { return }
        Self.color(palette.background).setFill()
        shape.fill()
        (isEnabled ? NSColor.separatorColor : NSColor.quaternaryLabelColor).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // A compressed swatch clips its sample instead of drawing over its neighbour.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds.insetBy(dx: 6, dy: 0)).addClip()
        let sample = NSMutableAttributedString()
        let colors = [palette.keyword, palette.foreground, palette.foreground, palette.string, palette.comment]
        for (text, color) in zip(Self.sample.prefix(Self.sampleTokenCount(fitting: bounds.width)), colors) {
            sample.append(.init(string: text, attributes: [.font: Self.codeFont, .foregroundColor: Self.color(color)]))
        }
        sample.draw(at: .init(x: 10, y: isFlipped ? 9 : bounds.height - 24))
        let name = NSAttributedString(string: themeName, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Self.color(palette.foreground)])
        name.draw(at: .init(x: 10, y: isFlipped ? bounds.height - 22 : 8))
        NSGraphicsContext.restoreGraphicsState()
        // A disabled swatch keeps the theme's real colours and contrast (E5-05); the pair's caption
        // says when it is inherited, and only interaction is disabled.
    }
}

/// Light and Dark swatches edited as one atomic pair (D05). Clicking a swatch lists the themes for
/// that appearance; there is no theme editor (D51).
@MainActor
final class ThemePairControl: NSStackView {
    static let inheritedCaption = "Inherited from General"

    private let session: SettingsSession
    private let light = ThemeSwatchButton(slot: .light)
    private let dark = ThemeSwatchButton(slot: .dark)
    private let inheritedLabel = SettingsForm.secondary(inheritedCaption)
    var onChange: ((ThemeAssignment) -> Void)?
    private(set) var value = ThemeAssignment()
    var isEnabled = true { didSet { light.isEnabled = isEnabled; dark.isEnabled = isEnabled } }
    /// Marks the pair as showing General's value in text rather than by dimming it (E5-05).
    var isInherited = false {
        didSet { inheritedLabel.isHidden = !isInherited; light.isInherited = isInherited; dark.isInherited = isInherited }
    }

    /// Creates the custom theme editor backed by the active settings session.
    init(session: SettingsSession) {
        self.session = session
        super.init(frame: .zero)
        orientation = .vertical
        spacing = 4
        alignment = .leading
        let swatches = NSStackView()
        swatches.orientation = .horizontal
        swatches.spacing = 12
        swatches.alignment = .top
        for button in [light, dark] {
            button.target = self
            button.action = #selector(showMenu(_:))
            let caption = SettingsForm.secondary(button.slot == .dark ? "Dark" : "Light")
            let column = NSStackView(views: [button, caption])
            column.orientation = .vertical
            column.spacing = 4
            swatches.addArrangedSubview(column)
        }
        addArrangedSubview(swatches)
        inheritedLabel.identifier = .init("ThemeInherited")
        inheritedLabel.isHidden = true
        addArrangedSubview(inheritedLabel)
        // Both swatches compress together so the pair stays visually balanced.
        light.widthAnchor.constraint(equalTo: dark.widthAnchor).isActive = true
    }
    /// Rejects storyboard construction because both appearance swatches are created at runtime.
    required init?(coder: NSCoder) { nil }

    /// Resolves light and dark palettes independently so each swatch previews its own appearance.
    func set(_ assignment: ThemeAssignment) {
        value = assignment
        for (button, choice, name) in [(light, assignment.light, NSAppearance.Name.aqua), (dark, assignment.dark, .darkAqua)] {
            guard let native = NSAppearance(named: name) else { continue }
            button.palette = session.palette(for: choice, appearance: native)
            button.themeName = session.themeName(for: choice)
        }
    }

    /// Lists built-in choices and custom themes matching the requested appearance slot.
    func choices(for slot: PreviewAppearance) -> [(title: String, choice: ThemeChoice)] {
        SourceThemePreset.allCases.map { ($0.displayName, ThemeChoice(preset: $0)) }
            + session.settings.customThemes.filter { $0.appearance == slot }
                .map { ($0.name, ThemeChoice(preset: $0.basePreset, customThemeID: $0.id)) }
    }

    /// Updates only the chosen light/dark slot, then reports the complete assignment.
    func select(_ choice: ThemeChoice, for slot: PreviewAppearance) {
        var assignment = value
        if slot == .dark { assignment.dark = choice } else { assignment.light = choice }
        set(assignment)
        onChange?(assignment)
    }

    /// Anchors each appearance-specific menu to its swatch and keeps the current choice checked.
    @objc private func showMenu(_ sender: ThemeSwatchButton) {
        let menu = NSMenu()
        let current = sender.slot == .dark ? value.dark : value.light
        for (index, entry) in choices(for: sender.slot).enumerated() {
            if index == SourceThemePreset.allCases.count { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ThemeMenuChoice(slot: sender.slot, choice: entry.choice)
            item.state = entry.choice == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: .init(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ThemeMenuChoice else { return }
        select(entry.choice, for: entry.slot)
    }
}

/// Carries a theme choice and appearance slot through the swatch menu action.
private final class ThemeMenuChoice: NSObject {
    let slot: PreviewAppearance
    let choice: ThemeChoice
    /// Creates the action payload used to restore the selected appearance and theme.
    init(slot: PreviewAppearance, choice: ThemeChoice) { self.slot = slot; self.choice = choice }
}

// MARK: - Font

/// One combined chooser for family and size (D05), titled e.g. "System Monospaced, 12 pt".
@MainActor
final class FontChooser: NSPopUpButton {
    static let sizes = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32]
    var onChange: ((FontSetting) -> Void)?
    var showsSizeOptions = true
    private(set) var value = FontSetting()

    /// Creates the Formats and Views controls with their supported category rows.
    init() {
        super.init(frame: .zero, pullsDown: true)
        setAccessibilityLabel("Font")
        identifier = .init("FontChooser")
    }
    /// Rejects storyboard construction because the menu is rebuilt from normalized settings.
    required init?(coder: NSCoder) { nil }

    /// Rebuilds menu state from normalized settings without emitting a user edit.
    func set(_ font: FontSetting) {
        value = font.normalized()
        removeAllItems()
        addItem(withTitle: showsSizeOptions ? value.displayName : value.family)
        for family in FontSetting.families {
            let item = NSMenuItem(title: family, action: #selector(pickFamily(_:)), keyEquivalent: "")
            item.target = self
            item.state = family == value.family ? .on : .off
            menu?.addItem(item)
        }
        if showsSizeOptions {
            menu?.addItem(.separator())
            for size in Self.sizes {
                let item = NSMenuItem(title: "\(size) pt", action: #selector(pickSize(_:)), keyEquivalent: "")
                item.target = self
                item.tag = size
                item.state = Double(size) == Double(value.size) ? .on : .off
                menu?.addItem(item)
            }
        }
    }

    @objc private func pickFamily(_ sender: NSMenuItem) { commit { $0.family = sender.title } }
    @objc private func pickSize(_ sender: NSMenuItem) { commit { $0.size = .init(sender.tag) } }

    /// Applies one family or size edit and reports the normalized value through the callback.
    func commit(_ edit: (inout FontSetting) -> Void) {
        var font = value
        edit(&font)
        set(font)
        onChange?(value)
    }
}

// MARK: - Word wrap

@MainActor
/// Popup control for the three supported line-wrapping behaviors.
final class WordWrapPopup: NSPopUpButton {
    static let modes: [WordWrapMode] = [.off, .soft, .hard]
    var onChange: ((WordWrapMode) -> Void)?

    /// Creates the format mapping controls for literal filenames and extensions.
    init() {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: Self.modes.map(\.displayName))
        setAccessibilityLabel("Word wrap")
        identifier = .init("WordWrap")
        target = self
        action = #selector(changed(_:))
    }
    /// Rejects storyboard construction because the popup derives its choices from the wrap model.
    required init?(coder: NSCoder) { nil }

    var value: WordWrapMode { Self.modes[max(0, indexOfSelectedItem)] }
    /// Synchronizes the selected menu item with the stored wrap mode.
    func set(_ mode: WordWrapMode) { selectItem(at: Self.modes.firstIndex(of: mode) ?? 0) }
    @objc private func changed(_ sender: Any?) { onChange?(value) }
}

// MARK: - Numbers

/// Integer field with stepper. Out-of-range input is clamped on commit; there is no slider.
@MainActor
final class NumberStepperField: NSStackView, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    private var suffixLabel: NSTextField?
    private let range: ClosedRange<Int>
    var onChange: ((Int) -> Void)?
    private(set) var value: Int

    /// Creates an integer stepper with the supplied bounds and accessibility metadata.
    init(range: ClosedRange<Int>, suffix: String?, accessibilityLabel: String, identifier: String) {
        self.range = range
        value = range.lowerBound
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 4
        field.alignment = .right
        field.setAccessibilityLabel(accessibilityLabel)
        field.identifier = .init(identifier)
        field.delegate = self
        field.target = self
        field.action = #selector(commitField(_:))
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.setAccessibilityLabel(accessibilityLabel)
        stepper.target = self
        stepper.action = #selector(step(_:))
        addArrangedSubview(field)
        addArrangedSubview(stepper)
        if let suffix {
            let label = NSTextField(labelWithString: suffix)
            addArrangedSubview(label)
            suffixLabel = label
        }
    }
    /// Rejects storyboard construction because the field owns a runtime-configured stepper pair.
    required init?(coder: NSCoder) { nil }

    /// The unit dims with the field so a disabled value never looks available (D35).
    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            stepper.isEnabled = isEnabled
            suffixLabel?.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        }
    }

    /// Synchronizes text and stepper without firing an edit callback.
    func set(_ number: Int) {
        value = number
        field.stringValue = String(number)
        stepper.integerValue = number
    }

    @objc private func step(_ sender: NSStepper) { commit(sender.integerValue) }
    @objc private func commitField(_ sender: NSTextField) { commitText() }
    /// Commits text when the field loses focus, applying the same range policy as the stepper.
    func controlTextDidEndEditing(_ notification: Notification) { commitText() }

    /// Restores the last valid value when text is not an integer; valid values clamp on commit.
    private func commitText() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let number = Int(text) else { set(value); return }
        commit(number)
    }

    /// Keeps the displayed field and stepper synchronized with the permitted range.
    func commit(_ number: Int) {
        let clamped = min(max(number, range.lowerBound), range.upperBound)
        set(clamped)
        onChange?(clamped)
    }
}

/// Bytes shown in KiB or MiB (D07, D54): field, stepper, unit popup and explicit clamp feedback.
@MainActor
final class DataLimitControl: NSStackView, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    let unitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let feedback = SettingsForm.secondary("")
    private let units: [DataLimitUnit] = [.kb, .mb]
    private var bytes = GeneralSettingsV3().dataLimitBytes
    private var unit: DataLimitUnit = .mb
    /// Returns clamp feedback for the entered amount.
    var onCommit: ((Double, DataLimitUnit) -> String?)?
    var onUnitChange: ((DataLimitUnit) -> Void)?

    /// Creates the debug logging preference control and its status text.
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .trailing
        spacing = 4
        field.alignment = .right
        field.setAccessibilityLabel("Data limit")
        field.identifier = .init("DataLimit")
        field.delegate = self
        field.target = self
        field.action = #selector(commitField(_:))
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        stepper.valueWraps = false
        stepper.setAccessibilityLabel("Data limit")
        stepper.target = self
        stepper.action = #selector(step(_:))
        unitPopup.addItems(withTitles: units.map(\.displayName))
        unitPopup.setAccessibilityLabel("Data limit unit")
        unitPopup.widthAnchor.constraint(equalToConstant: 72).isActive = true
        unitPopup.target = self
        unitPopup.action = #selector(changeUnit(_:))
        feedback.identifier = .init("DataLimitFeedback")
        feedback.isHidden = true
        addArrangedSubview(SettingsForm.horizontal([field, stepper, unitPopup], spacing: 4))
        addArrangedSubview(feedback)
    }
    /// Rejects storyboard construction because the control is bound to runtime data-limit settings.
    required init?(coder: NSCoder) { nil }

    var isEnabled = true { didSet { [field, stepper, unitPopup].forEach { ($0 as NSControl).isEnabled = isEnabled } } }

    private var stepSize: Double { unit == .kb ? 64 : 0.25 }

    /// Changes display units while preserving the canonical byte value used by settings.
    func set(bytes: Int, unit: DataLimitUnit) {
        self.bytes = bytes
        self.unit = unit
        unitPopup.selectItem(at: units.firstIndex(of: unit) ?? 1)
        field.stringValue = SettingsSession.formatDataLimit(bytes, unit: unit)
        let range = GeneralSettingsV3.dataLimitRange
        stepper.minValue = Double(range.lowerBound) / Double(unit.bytes)
        stepper.maxValue = Double(range.upperBound) / Double(unit.bytes)
        stepper.increment = stepSize
        stepper.doubleValue = Double(bytes) / Double(unit.bytes)
    }

    /// Displays optional clamp feedback and hides the label when there is no message.
    func showFeedback(_ message: String?) {
        feedback.stringValue = message ?? ""
        feedback.isHidden = message == nil
    }

    @objc private func step(_ sender: NSStepper) { commit(sender.doubleValue) }
    @objc private func commitField(_ sender: NSTextField) { commitText() }
    /// Commits text on focus loss through the same validation path as Return and the stepper.
    func controlTextDidEndEditing(_ notification: Notification) { commitText() }

    /// Accepts locale comma or dot decimals, but restores the prior value on malformed input.
    private func commitText() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(text), amount.isFinite else {
            set(bytes: bytes, unit: unit)
            showFeedback("Enter a number.")
            return
        }
        commit(amount)
    }

    /// Sends the typed amount and current unit to the session, then displays its feedback.
    func commit(_ amount: Double) { showFeedback(onCommit?(amount, unit)) }

    @objc private func changeUnit(_ sender: NSPopUpButton) {
        let selected = units[max(0, sender.indexOfSelectedItem)]
        guard selected != unit else { return }
        set(bytes: bytes, unit: selected)
        showFeedback(nil)
        onUnitChange?(selected)
    }
}

// MARK: - Closure controls

@MainActor
/// Checkbox adapter that reports state changes through a closure instead of writing settings.
final class ClosureCheckbox: NSButton {
    var onChange: ((Bool) -> Void)?
    /// Creates a native checkbox with a callback for user changes.
    convenience init(title: String) {
        self.init(checkboxWithTitle: title, target: nil, action: nil)
        target = self
        action = #selector(changed(_:))
    }
    @objc private func changed(_ sender: NSButton) { onChange?(state == .on) }
}

@MainActor
/// Popup adapter that reports selected indices through a closure instead of persisting them.
final class ClosurePopUp: NSPopUpButton {
    var onChange: ((Int) -> Void)?
    /// Creates a popup containing the supplied choices and a selection callback.
    convenience init(titles: [String]) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        target = self
        action = #selector(changed(_:))
    }
    @objc private func changed(_ sender: NSPopUpButton) { onChange?(max(0, indexOfSelectedItem)) }
}
