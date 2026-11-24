import AppKit
import InspectorCore

// MARK: - Format Options (spec §11)

/// Contextual options for one format, opened from Formats & Views. Only formats with Markdown or
/// Structured options have this sheet; appearance is always General's.
@MainActor
final class FormatOptionsSheet: NSViewController {
    private let session: SettingsSession
    let format: FormatID
    private var synchronizers: [() -> Void] = []

    static func isAvailable(for format: FormatID) -> Bool {
        FormatSettingsCapabilities.hasMarkdownOptions(format) || FormatSettingsCapabilities.hasStructuredOptions(format)
    }

    /// Creates the options sheet for one format and its shared settings session.
    init(session: SettingsSession, format: FormatID) {
        self.session = session
        self.format = format
        super.init(nibName: nil, bundle: nil)
        session.observe { [weak self] _ in self?.synchronize() }
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    override func loadView() {
        let name = FormatCatalog.definition(for: format)?.displayName ?? format.rawValue
        let title = SettingsForm.heading("\(name) Options", subtitle: "Applies to \(name) documents in the app and Quick Look.")
        let grid = SettingsForm.grid(rows())
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        done.identifier = .init("FormatOptionsDone")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = SettingsForm.horizontal([spacer, done], spacing: 8)
        let root = NSStackView(views: [title, grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
        buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20).isActive = true
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        root.identifier = .init("FormatOptions")
        view = root
        synchronize()
    }

    override func cancelOperation(_ sender: Any?) { dismiss(self) }
    @objc private func done(_ sender: Any?) { dismiss(self) }

    private func synchronize() { synchronizers.forEach { $0() } }

    // MARK: Rows

    /// Markdown and Structured controls; each edit stores the whole option value so fields this
    /// sheet does not show are kept.
    private func rows() -> [[NSView]] {
        let id = format
        var rows: [[NSView]] = []
        if FormatSettingsCapabilities.hasMarkdownOptions(id) {
    /// Updates Markdown options for the sheet's format and persists through the session.
    func markdown(_ edit: @escaping (inout MarkdownFormatOptions) -> Void) {
                let current = EffectiveSettingsResolver.resolve(session.settings, for: id).markdown
                session.updateFormat(id) { stored in var value = current; edit(&value); stored.markdown = value }
            }
            let size = NumberStepperField(range: 10...28, suffix: "pt", accessibilityLabel: "Text size", identifier: "MarkdownFontSize")
            size.onChange = { value in markdown { $0.fontSize = Double(value) } }
            bind(size) { size.set(Int($0.markdown.fontSize)) }
            rows.append([SettingsForm.label("Text size:"), size])
            let profiles = MarkdownProfile.allCases
            let profile = ClosurePopUp(titles: profiles.map { $0 == .default ? "Standard" : $0.rawValue.capitalized })
            profile.setAccessibilityLabel("Layout")
            profile.onChange = { index in markdown { $0.profile = profiles[index] } }
            bind(profile) { profile.selectItem(at: profiles.firstIndex(of: $0.markdown.profile) ?? 0) }
            rows.append([SettingsForm.label("Layout:"), profile])
            let modes = MarkdownFrontMatterMode.allCases
            let front = ClosurePopUp(titles: modes.map(\.rawValue.capitalized))
            front.setAccessibilityLabel("Front matter")
            front.onChange = { index in markdown { $0.frontMatter = modes[index] } }
            bind(front) { front.selectItem(at: modes.firstIndex(of: $0.markdown.frontMatter) ?? 0) }
            rows.append([SettingsForm.label("Front matter:"), front])
            for (title, key) in [("Task lists", \MarkdownFormatOptions.taskLists), ("Strikethrough", \.strikethrough),
                                 ("Table of contents", \.tableOfContents)] {
                let box = ClosureCheckbox(title: title)
                box.onChange = { on in markdown { $0[keyPath: key] = on } }
                bind(box) { box.state = $0.markdown[keyPath: key] ? .on : .off }
                rows.append([NSView(), box])
            }
            let breaks = ClosureCheckbox(title: "Keep single line breaks")
            breaks.onChange = { on in markdown { $0.breakBehavior = on ? .preserveSoftLines : .standard } }
            bind(breaks) { breaks.state = $0.markdown.breakBehavior == .preserveSoftLines ? .on : .off }
            rows.append([NSView(), breaks])
        }
        if FormatSettingsCapabilities.hasStructuredOptions(id) {
    /// Updates structured-data options for the sheet's format and persists through the session.
    func structured(_ edit: @escaping (inout StructuredFormatOptions) -> Void) {
                let current = EffectiveSettingsResolver.resolve(session.settings, for: id).structured
                session.updateFormat(id) { stored in var value = current; edit(&value); stored.structured = value }
            }
            let depth = NumberStepperField(range: StructuredFormatOptions.expandDepthRange, suffix: "levels",
                                           accessibilityLabel: "Expand tree", identifier: "ExpandDepth")
            depth.onChange = { value in structured { $0.expandDepth = value } }
            bind(depth) { depth.set($0.structured.expandDepth) }
            rows.append([SettingsForm.label("Expand tree:"), depth])
            let sort = ClosureCheckbox(title: "Sort keys")
            sort.identifier = .init("SortKeys")
            sort.onChange = { on in structured { $0.sortKeys = on } }
            bind(sort) { sort.state = $0.structured.sortKeys ? .on : .off }
            rows.append([NSView(), sort])
        }
        return rows
    }

    /// Refreshes a control from the resolved format values and gates it on the session's edit state.
    private func bind(_ control: NSView, _ refresh: @escaping (ResolvedFormatSettings) -> Void) {
        synchronizers.append { [weak self, weak control] in
            guard let self, let control else { return }
            refresh(EffectiveSettingsResolver.resolve(self.session.settings, for: self.format))
            (control as? NSControl)?.isEnabled = self.session.canEdit
            (control as? NumberStepperField)?.isEnabled = self.session.canEdit
        }
    }
}
