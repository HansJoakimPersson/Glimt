import AppKit
import Foundation
import InspectorCore

/// The settings window's model: the v3 snapshot being edited and serialized persistence. Views
/// observe it and never touch `SettingsStore` directly.
@MainActor
final class SettingsSession {
    /// Distinguishes persisted setting changes from status-only updates for observers.
    enum Change { case settings, status }

    static let unconfiguredMessage = "Shared settings are not configured. Changes apply to this preview only and are not saved."
    static let saveFailedMessage = "Settings could not be saved. Changes apply to this preview only."
    static let mappingInvalidMessage = "Use a filename or one extension (foo or *.foo), without a path."

    private(set) var settings: GlimtSettingsV3
    private(set) var snapshot: SettingsSnapshot?
    private let store: SettingsStore?
    /// User-facing persistence state; empty when there is nothing to report.
    private(set) var statusMessage: String
    private(set) var saveFailed = false

    private var observers: [(Change) -> Void] = []
    private var saveTask: Task<Void, Never>?
    private var revision = 0

    // MARK: Lifecycle

    /// Creates a session from a loaded snapshot, or a read-only fallback when no store is available.
    init(store: SettingsStore?, snapshot: SettingsSnapshot?, status: String = "") {
        self.store = store
        self.snapshot = snapshot
        settings = (snapshot?.settings ?? .factoryDefaults).normalized()
        if store == nil { statusMessage = status.isEmpty ? Self.unconfiguredMessage : status }
        else if snapshot?.isWritable == false { statusMessage = SettingsStoreError.newerSchema.errorDescription ?? "" }
        else { statusMessage = status }
    }

    /// Loads off the main actor. Missing settings remain editable from factory values; unreadable
    /// or malformed files yield factory values that are never written over them.
    static func load(store: SettingsStore? = nil) async -> SettingsSession {
        // Keep home-directory I/O and JSON decoding off the main actor that owns the observable session.
        let result = await Task.detached { () -> (SettingsStore?, SettingsSnapshot?, String) in
            guard let store = store ?? (try? SettingsStore.shared()) else { return (nil, nil, "") }
            do { return (store, try store.loadV3(), "") }
            catch { return (nil, nil,
                            (error as? LocalizedError)?.errorDescription ?? SettingsStoreError.readFailed(error).errorDescription ?? "") }
        }.value
        return SettingsSession(store: result.0, snapshot: result.1, status: result.2)
    }

    /// `false` for a newer schema or unreadable file: controls are disabled so nothing can be lost.
    var canEdit: Bool { store == nil || (store?.readOnly == false && snapshot?.isWritable == true) }
    var isPersistent: Bool { store != nil && canEdit }

    /// Registers a view callback; notifications remain main-actor isolated with the session state.
    func observe(_ observer: @escaping (Change) -> Void) { observers.append(observer) }
    /// Delivers the change on the main actor to every view bound to this session.
    private func notify(_ change: Change) { observers.forEach { $0(change) } }

    var renderConfiguration: RenderConfiguration { .init(settings: settings) }

    // MARK: Editing and persistence

    /// Normalizes and publishes a settings edit, then schedules persistence if it changed.
    func update(_ edit: (inout GlimtSettingsV3) -> Void) {
        // Read-only/newer-schema sessions may preview factory values but must never accept edits.
        guard canEdit else { return }
        var value = settings
        edit(&value)
        value = value.normalized()
        guard value != settings else { return }
        settings = value
        notify(.settings)
        persist()
    }

    /// Applies one format-scoped edit through the same normalization and persistence path.
    func updateFormat(_ format: FormatID, _ edit: (inout FormatSettings) -> Void) {
        update { edit(&$0[format]) }
    }

    /// Global reset, confirmed by the caller: factory values, including custom themes and file
    /// mappings. Legacy files remain untouched during a reset.
    func resetAll() { update { $0 = .factoryDefaults } }

    /// Indicates whether every persisted setting currently matches the factory baseline.
    var isFactoryDefault: Bool { settings == .factoryDefaults }

    /// Waits for the latest coalesced settings write, primarily for orderly shutdown and tests.
    func waitForPersistence() async { await saveTask?.value }

    /// Coalesces edits and serializes atomic writes against the snapshot they replace.
    private func persist() {
        // Serialize writes against their prior snapshot and coalesce edits to the newest revision.
        guard let store, isPersistent else { return }
        revision += 1
        let current = revision
        let previous = saveTask
        saveTask = Task { [weak self] in
            // Preserve write ordering so the next optimistic snapshot check sees the previous save.
            await previous?.value
            // A later edit carries the newest value; intermediate states need not be written.
            guard let self, current == self.revision, let base = self.snapshot else { return }
            let value = self.settings
            // Store I/O may block; return only the result to the main-actor session.
            let result = await Task.detached { Result { try store.saveV3(value, replacing: base) } }.value
            switch result {
            case .success(let saved):
                self.snapshot = saved
                if self.saveFailed || !self.statusMessage.isEmpty { self.saveFailed = false; self.setStatus("") }
            case .failure(SettingsStoreError.changedExternally):
                await self.reloadAfterExternalChange(store)
            case .failure:
                self.saveFailed = true
                self.setStatus(Self.saveFailedMessage)
            }
        }
    }

    /// Another process or editor replaced the file: adopt it instead of overwriting it.
    private func reloadAfterExternalChange(_ store: SettingsStore) async {
        // Adopt the external version after a failed compare-and-swap instead of retrying over it.
        guard let reloaded = try? await Task.detached(operation: { try store.loadV3() }).value else {
            saveFailed = true
            setStatus(Self.saveFailedMessage)
            return
        }
        snapshot = reloaded
        settings = reloaded.settings
        notify(.settings)
        setStatus(reloaded.isWritable ? SettingsStoreError.changedExternally.errorDescription ?? ""
                                      : SettingsStoreError.newerSchema.errorDescription ?? "")
    }

    /// Publishes a persistence status only when its user-visible value changes.
    private func setStatus(_ message: String) {
        // Avoid duplicate observer refreshes when persistence reports the same state again.
        guard message != statusMessage else { return }
        statusMessage = message
        notify(.status)
    }

    // MARK: Data limit (D07)

    /// Converts the entered amount to bytes and clamps it. Returns feedback when the stored value
    /// differs from what was entered.
    @discardableResult
    func setDataLimit(amount: Double, unit: DataLimitUnit) -> String? {
        // Convert and clamp before Int conversion so NaN, infinity, and excessive user input stay safe.
        let requested = amount.isFinite ? amount * Double(unit.bytes) : 0
        let bounded = min(max(requested, 0), Double(Int32.max))
        let clamped = GeneralSettingsV3.clampDataLimit(Int(bounded))
        update { $0.general.dataLimitBytes = clamped; $0.general.dataLimitDisplayUnit = unit }
        guard Double(clamped) != requested else { return nil }
        let range = GeneralSettingsV3.dataLimitRange
        if requested > Double(range.upperBound) { return "The maximum is 1 MiB (1024 KiB)." }
        if requested < Double(range.lowerBound) { return "The minimum is 64 KiB." }
        return "Rounded to \(Self.formatDataLimit(clamped, unit: .kb)) KiB."
    }

    /// Changes only the displayed unit; the persisted limit remains in bytes.
    func setDataLimitUnit(_ unit: DataLimitUnit) { update { $0.general.dataLimitDisplayUnit = unit } }

    /// KB as whole numbers; MB with up to four decimals (64 KB = 0.0625 MB).
    static func formatDataLimit(_ bytes: Int, unit: DataLimitUnit) -> String {
        let value = Double(bytes) / Double(unit.bytes)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = unit == .kb ? 0 : 4
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: Themes

    var canAddTheme: Bool { settings.customThemes.count < 16 }

    /// The palette a choice renders with in the given appearance.
    func palette(for choice: ThemeChoice, appearance: NSAppearance) -> SourceThemePalette {
        settings.customThemes.first { $0.id == choice.customThemeID }?.palette
            ?? SourceSyntaxColors.palette(for: choice.preset, appearance: appearance)
    }

    /// Resolves a custom theme name, falling back to the selected preset's label.
    func themeName(for choice: ThemeChoice) -> String {
        settings.customThemes.first { $0.id == choice.customThemeID }?.name ?? choice.preset.displayName
    }

    /// Copies the palette `choice` shows in `appearance` into a new editable theme.
    @discardableResult
    func duplicateTheme(_ choice: ThemeChoice, appearance: PreviewAppearance, named name: String) -> CustomSourceTheme? {
        // A custom theme needs a concrete light/dark palette; System appearance has no stable copy source.
        guard canAddTheme, canEdit, appearance != .system,
              let native = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) else { return nil }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        let base = settings.customThemes.first { $0.id == choice.customThemeID }?.basePreset ?? choice.preset
        let theme = CustomSourceTheme(id: UUID().uuidString, name: clean.isEmpty ? "Custom Theme" : clean,
                                      appearance: appearance, basePreset: base, palette: palette(for: choice, appearance: native))
        update { $0.customThemes.append(theme) }
        return theme
    }

    /// Assignments that used the theme fall back to its built-in base preset.
    func deleteTheme(id: String) {
        // Remove dangling references in General and every format before the settings snapshot is persisted.
        update { settings in
            settings.customThemes.removeAll { $0.id == id }
            // Clear both appearance slots so deleting a theme cannot leave stale identifiers.
            /// Removes this theme reference from both appearance assignments.
            func clear(_ assignment: inout ThemeAssignment) {
                if assignment.light.customThemeID == id { assignment.light.customThemeID = nil }
                if assignment.dark.customThemeID == id { assignment.dark.customThemeID = nil }
            }
            clear(&settings.general.themeAssignment)
            for key in settings.formats.keys {
                guard var assignment = settings.formats[key]?.themeAssignment else { continue }
                clear(&assignment.value)
                settings.formats[key]?.themeAssignment = assignment
            }
        }
    }

    /// Trims and bounds a theme name; an empty result leaves the current name intact.
    func renameTheme(id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        update { settings in
            guard let index = settings.customThemes.firstIndex(where: { $0.id == id }) else { return }
            settings.customThemes[index].name = String(clean.prefix(48))
        }
    }

    // MARK: File mappings

    /// The most mappings the settings file keeps (`GlimtSettingsV3.normalized()`).
    static let mappingLimit = 64
    static let mappingLimitMessage = "Glimt keeps up to 64 file mappings. Remove one to add another."

    /// "This extension is already mapped to YAML." Shown instead of replacing another format's mapping.
    static func mappingConflictMessage(_ kind: FileAssociation.Kind, mappedTo target: FormatID) -> String {
        "This \(kind == .filename ? "filename" : "extension") is already mapped to \(target.displayName)."
    }

    /// The same pattern already maps to the requested format.
    static func mappingDuplicateMessage(_ kind: FileAssociation.Kind) -> String {
        "This \(kind == .filename ? "filename" : "extension") is already in the list."
    }

    /// The mappings that preview as `target`, in stored order. Storage stays one global list.
    func mappings(for target: FormatID) -> [FileAssociation] {
        settings.fileAssociations.filter { $0.target == target }
    }

    /// Validates, normalizes and appends a mapping; returns feedback instead of adding when the
    /// pattern is invalid, already listed, or mapped to another format. Never replaces a mapping.
    @discardableResult
    func addMapping(kind: FileAssociation.Kind, value: String, target: FormatID) -> String? {
        guard let mapping = FileAssociation(kind: kind, value: value, target: target).validated() else { return Self.mappingInvalidMessage }
        if let existing = settings.fileAssociations.first(where: { $0.kind == mapping.kind && $0.value == mapping.value }) {
            return existing.target == target ? Self.mappingDuplicateMessage(kind)
                : Self.mappingConflictMessage(kind, mappedTo: existing.target)
        }
        guard settings.fileAssociations.count < Self.mappingLimit else { return Self.mappingLimitMessage }
        update { $0.fileAssociations.append(mapping) }
        return nil
    }

    /// Removes the mapping with this kind, value and target; a stale key removes nothing.
    func removeMapping(_ mapping: FileAssociation) {
        update { $0.fileAssociations.removeAll { $0 == mapping } }
    }
}
