import AppKit
import InspectorCore

/// The native Markdown navigation menu built from InspectorCore's heading model.
///
/// Exactly one heading item carries the `.on` state: the reading section reported by the preview.
/// Keyboard and mouse focus stay with `NSMenu`'s own highlight, and choosing an item only reports
/// its index; the preview decides what becomes active after navigating.
@MainActor
final class MarkdownTOCMenu: NSObject {
    /// Longest heading label before trailing truncation; the full title stays in tooltip and VoiceOver.
    static let maximumTitleWidth: CGFloat = 340
    private static let indentationWidth: CGFloat = 10

    let menu = NSMenu(title: "Table of contents")
    private let headingItems: [NSMenuItem]
    private(set) var activeIndex: Int?
    var onSelectHeading: ((Int) -> Void)?
    var headingCount: Int { headingItems.count }
    var checkedIndices: [Int] { headingItems.indices.filter { headingItems[$0].state == .on } }

    /// Creates the table-of-contents panel from document headings and the active heading index.
    init(headings: [MarkdownHeading], activeIndex: Int?) {
        let font = NSFont.menuFont(ofSize: 0)
        headingItems = headings.enumerated().map { index, heading in
            let level = min(max(heading.level, 1), 6) - 1
            let width = Self.maximumTitleWidth - CGFloat(level) * Self.indentationWidth
            let item = NSMenuItem(title: Self.truncatedTitle(heading.title, font: font, maximumWidth: width),
                                  action: #selector(chooseHeading(_:)), keyEquivalent: "")
            item.tag = index
            item.indentationLevel = level
            item.toolTip = heading.title
            item.setAccessibilityLabel(heading.title)
            return item
        }
        super.init()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Contents"))
        for item in headingItems {
            item.target = self
            menu.addItem(item)
        }
        setActiveIndex(activeIndex)
    }

    /// Returns the menu item associated with a heading index, if the panel contains one.
    func item(forHeading index: Int) -> NSMenuItem? {
        headingItems.indices.contains(index) ? headingItems[index] : nil
    }

    /// Moves the single checkmark; safe to call while the menu is tracking.
    func setActiveIndex(_ index: Int?) {
        let next = index.flatMap { headingItems.indices.contains($0) ? $0 : nil }
        if let activeIndex, next != activeIndex { headingItems[activeIndex].state = .off }
        activeIndex = next
        if let next { headingItems[next].state = .on }
    }

    @objc private func chooseHeading(_ sender: NSMenuItem) {
        guard headingItems.indices.contains(sender.tag) else { return }
        onSelectHeading?(sender.tag)
    }

    // MARK: - Layout policy

    /// Shortens `title` with a trailing ellipsis so it fits `maximumWidth` in `font`.
    static func truncatedTitle(_ title: String, font: NSFont, maximumWidth: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
    /// Measures one heading with the panel's configured font for stable popup sizing.
    func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: attributes).width }
        guard width(title) > maximumWidth else { return title }
        let characters = Array(title)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let candidate = String(characters[..<middle]).trimmingCharacters(in: .whitespaces) + "…"
            if width(candidate) <= maximumWidth { low = middle } else { high = middle - 1 }
        }
        return String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The heading to anchor the popup on, or nil to drop the menu below its button.
    ///
    /// The menu scrolls to the active heading only when a top-anchored menu of `menuHeight`
    /// would leave that heading outside `availableHeight`.
    static func positioningIndex(activeIndex: Int?, itemCount: Int, menuHeight: CGFloat,
                                 availableHeight: CGFloat) -> Int? {
        guard let activeIndex, itemCount > 0, menuHeight > availableHeight else { return nil }
        // One extra row covers the section header above the headings.
        let rowHeight = menuHeight / CGFloat(itemCount + 1)
        let activeBottom = CGFloat(activeIndex + 2) * rowHeight
        return activeBottom > availableHeight ? activeIndex : nil
    }
}

/// The small rounded system-material backing behind the TOC button and section label.
@MainActor
final class MarkdownTOCHUDSurface: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorder()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
