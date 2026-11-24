import Foundation
import InspectorCore

// MARK: - Scope and results

/// What a Formats & Views edit applies to: a category profile or one format's override.
enum ViewScope: Hashable, Sendable {
    case category(ViewCategoryID)
    case format(FormatID)
}

/// Whether a view order comes from its category profile or a format-specific override.
enum ViewOrigin: String, Sendable { case inherited, customized }

/// Matrix cell state. Inherited/Customized is a property of the row, reported by `ViewOrigin`.
enum ViewState: Sendable { case enabled, disabled, unsupported }

/// The views a document of one format gets before runtime availability is known.
struct ResolvedViews: Equatable, Sendable {
    let format: FormatID
    let category: ViewCategoryID
    /// Capability: catalog-declared views, in catalog order.
    let supported: [FormatDefinition.RepresentationID]
    /// Active views in the user's order, limited to supported ones. The first is the default.
    let configured: [FormatDefinition.RepresentationID]
    let origin: ViewOrigin

    var defaultView: FormatDefinition.RepresentationID? { configured.first }

    /// Configured ∩ available, in configured order.
    func effective(available: Set<FormatDefinition.RepresentationID>) -> [FormatDefinition.RepresentationID] {
        configured.filter(available.contains)
    }

    /// Tabs a preview shows. When nothing configured is available, a recovery view keeps the
    /// document inspectable; it is presentation-only and never written to settings.
    func presented(available: Set<FormatDefinition.RepresentationID>, isBinary: Bool) -> PresentedViews {
        ViewResolver.presented(configured: configured, available: available, isBinary: isBinary)
    }
}

/// Views actually shown in the preview, including whether recovery selected the fallback.
struct PresentedViews: Equatable, Sendable {
    let views: [FormatDefinition.RepresentationID]
    let isRecovery: Bool
}

// MARK: - Resolver

/// Pure, deterministic and independent of persistence (ADR-022). One source of truth for the
/// Settings Live Preview, the app preview and Quick Look.
enum ViewResolver {
    typealias View = FormatDefinition.RepresentationID

    /// Matrix column order; extensible as `RepresentationID` grows.
    static let matrixColumns: [View] = [.tree, .pretty, .table, .rendered, .source, .diff, .raw, .hex]

    /// Supported views for a format: the catalog declaration of a supported format, in catalog
    /// order. Every `RepresentationID` has a renderer in the preview's `RepresentationRegistry`.
    /// Plain text declares none; its decoded-text renderer is always available, so it has Raw.
    static func supported(for format: FormatID) -> [View] {
        guard let definition = FormatCatalog.definition(for: format), definition.status == .supported else { return [] }
        let declared = definition.availableRepresentations
        return declared.isEmpty && definition.inspectionKind == .text ? [.raw] : declared
    }

    /// Category profile as configured: stored when customized, otherwise the factory profile.
    static func profile(of category: ViewCategoryID, in settings: GlimtSettingsV3) -> [View] {
        guard category != .binaryAndUnknown else { return category.factoryProfile }
        return settings.categoryProfiles[category.rawValue].map(views(from:)) ?? category.factoryProfile
    }

    static func resolve(_ settings: GlimtSettingsV3, for format: FormatID) -> ResolvedViews {
        let category = ViewCategoryID.category(for: format)
        let supported = supported(for: format)
        let stored = settings.formatOverrides[format.rawValue]
        let categoryOverride = settings.categoryProfiles[category.rawValue]
        let catalogDefault = FormatCatalog.definition(for: format)?.defaultViews
        let order = stored.map(views(from:))
            ?? categoryOverride.map(views(from:))
            ?? catalogDefault
            ?? category.factoryProfile
        return .init(format: format, category: category, supported: supported,
                     configured: order.filter(supported.contains),
                     origin: stored == nil ? .inherited : .customized)
    }

    static func presented(configured: [View], available: Set<View>, isBinary: Bool) -> PresentedViews {
        let effective = configured.filter(available.contains)
        if !effective.isEmpty { return .init(views: effective, isRecovery: false) }
        return .init(views: [isBinary ? .hex : .raw], isRecovery: true)
    }

    // MARK: Matrix queries

    static func supported(in scope: ViewScope) -> [View] {
        switch scope {
        case .category(let category): category.supported
        case .format(let format): supported(for: format)
        }
    }

    /// Active views of a row, in order.
    static func configured(in scope: ViewScope, settings: GlimtSettingsV3) -> [View] {
        switch scope {
        case .category(let category): profile(of: category, in: settings).filter(category.supported.contains)
        case .format(let format): resolve(settings, for: format).configured
        }
    }

    static func isCustomized(_ scope: ViewScope, in settings: GlimtSettingsV3) -> Bool {
        switch scope {
        case .category(let category): settings.categoryProfiles[category.rawValue] != nil
        case .format(let format): settings.formatOverrides[format.rawValue] != nil
        }
    }

    /// Binary & Unknown has one fixed recovery view and no editable profile.
    static func isEditable(_ scope: ViewScope) -> Bool { scope != .category(.binaryAndUnknown) }

    static func state(of view: View, in settings: GlimtSettingsV3, for scope: ViewScope) -> ViewState {
        guard supported(in: scope).contains(view) else { return .unsupported }
        return configured(in: scope, settings: settings).contains(view) ? .enabled : .disabled
    }

    /// A row keeps at least one active view; a category edit may not leave an inheriting member
    /// format without one.
    static func canDisable(_ view: View, in settings: GlimtSettingsV3, for scope: ViewScope) -> Bool {
        guard isEditable(scope), state(of: view, in: settings, for: scope) == .enabled else { return false }
        var edited = settings
        edited.applyViewEdit(for: scope) { visible in visible.removeAll { $0 == view } }
        switch scope {
        case .format(let format):
            return !resolve(edited, for: format).configured.isEmpty
        case .category(let category):
            guard !configured(in: scope, settings: edited).isEmpty else { return false }
            return category.formats.allSatisfy { !resolve(edited, for: $0.id).configured.isEmpty }
        }
    }

    /// Known view IDs in stored order; unknown or removed IDs are skipped, duplicates collapsed.
    static func views(from raw: [String]) -> [View] {
        var seen = Set<View>()
        return raw.compactMap(View.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}

// MARK: - Edits

extension GlimtSettingsV3 {
    /// Toggles activation only. Enabling appends at the end; disabling removes from the order.
    /// Unsupported views and removing the last active view are ignored.
    mutating func setView(_ view: FormatDefinition.RepresentationID, enabled: Bool, for scope: ViewScope) {
        let state = ViewResolver.state(of: view, in: self, for: scope)
        guard ViewResolver.isEditable(scope), state != .unsupported, (state == .enabled) != enabled else { return }
        if !enabled, !ViewResolver.canDisable(view, in: self, for: scope) { return }
        applyViewEdit(for: scope) { visible in
            if enabled { visible.append(view) } else { visible.removeAll { $0 == view } }
        }
    }

    /// Moves an active view within the row's visible order; out-of-range indices are ignored.
    mutating func moveView(from source: Int, to destination: Int, for scope: ViewScope) {
        let visible = ViewResolver.configured(in: scope, settings: self)
        guard ViewResolver.isEditable(scope), visible.indices.contains(source), visible.indices.contains(destination),
              source != destination else { return }
        applyViewEdit(for: scope) { visible in
            let view = visible.remove(at: source)
            visible.insert(view, at: destination)
        }
    }

    /// Reset to Category (format) or Restore Category Defaults (category).
    mutating func resetViews(for scope: ViewScope) {
        switch scope {
        case .category(let category): categoryProfiles[category.rawValue] = nil
        case .format(let format): formatOverrides[format.rawValue] = nil
        }
    }

    /// Edits the visible (known, supported) part of a row's list. An inherited row is first
    /// materialized from its effective configuration. Hidden stored IDs are kept after the
    /// visible ones as compatibility data.
    fileprivate mutating func applyViewEdit(for scope: ViewScope, _ edit: (inout [FormatDefinition.RepresentationID]) -> Void) {
        let supported = ViewResolver.supported(in: scope)
        var visible = ViewResolver.configured(in: scope, settings: self)
        let stored: [String]
        switch scope {
        case .category(let category): stored = categoryProfiles[category.rawValue] ?? []
        case .format(let format): stored = formatOverrides[format.rawValue] ?? []
        }
        let hidden = stored.filter { raw in FormatDefinition.RepresentationID(rawValue: raw).map { !supported.contains($0) } ?? true }
        edit(&visible)
        let result = visible.map(\.rawValue) + hidden
        switch scope {
        case .category(let category): categoryProfiles[category.rawValue] = result
        case .format(let format): formatOverrides[format.rawValue] = result
        }
    }
}
