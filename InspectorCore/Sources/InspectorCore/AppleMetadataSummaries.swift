import Foundation

/// Validates the known shape of Apple privacy keys and returns counts without exposing their values.
public enum ApplePrivacyManifestSummary {
    public static func make(from value: PlistValue) -> String? {
        guard case .dictionary(let root) = value, uniqueKeys(root),
              optional(root, "NSPrivacyTracking", is: { if case .boolean = $0 { true } else { false } }),
              let domains = stringArray(root, "NSPrivacyTrackingDomains"),
              let apiTypes = dictionaryArray(root, "NSPrivacyAccessedAPITypes"),
              let dataTypes = dictionaryArray(root, "NSPrivacyCollectedDataTypes") else { return nil }
        for entry in apiTypes {
            guard uniqueKeys(entry), string(entry, "NSPrivacyAccessedAPIType") != nil,
                  stringArray(entry, "NSPrivacyAccessedAPITypeReasons") != nil else { return nil }
        }
        for entry in dataTypes {
            guard uniqueKeys(entry), string(entry, "NSPrivacyCollectedDataType") != nil,
                  optional(entry, "NSPrivacyCollectedDataTypeLinked", is: isBoolean),
                  optional(entry, "NSPrivacyCollectedDataTypeTracking", is: isBoolean),
                  stringArray(entry, "NSPrivacyCollectedDataTypePurposes") != nil else { return nil }
        }
        return "Privacy manifest · \(countLabel(apiTypes.count, singular: "accessed API category")) · " +
            "\(countLabel(dataTypes.count, singular: "collected data category")) · " +
            countLabel(domains.count, singular: "tracking domain")
    }

    private static func optional(_ members: [PlistMember], _ key: String,
                                 is predicate: (PlistValue) -> Bool) -> Bool {
        guard let value = members.first(where: { $0.key == key })?.value else { return true }
        return predicate(value)
    }

    private static func isBoolean(_ value: PlistValue) -> Bool {
        if case .boolean = value { true } else { false }
    }

    private static func string(_ members: [PlistMember], _ key: String) -> String? {
        guard case .string(let value)? = members.first(where: { $0.key == key })?.value else { return nil }
        return value
    }

    private static func stringArray(_ members: [PlistMember], _ key: String) -> [String]? {
        guard let value = members.first(where: { $0.key == key })?.value else { return [] }
        guard case .array(let values) = value else { return nil }
        let strings = values.compactMap { element -> String? in
            guard case .string(let string) = element else { return nil }
            return string
        }
        return strings.count == values.count ? strings : nil
    }

    private static func dictionaryArray(_ members: [PlistMember], _ key: String) -> [[PlistMember]]? {
        guard let value = members.first(where: { $0.key == key })?.value else { return [] }
        guard case .array(let values) = value else { return nil }
        let dictionaries = values.compactMap { element -> [PlistMember]? in
            guard case .dictionary(let members) = element else { return nil }
            return members
        }
        return dictionaries.count == values.count ? dictionaries : nil
    }

    private static func uniqueKeys(_ members: [PlistMember]) -> Bool {
        Set(members.map(\.key)).count == members.count
    }

    private static func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

/// Validates the Xcode test plan's version and structural arrays; test names and options stay in Tree only.
public enum XcodeTestPlanSummary {
    public static func make(from value: StructuredValue) -> String? {
        guard case .object(let root) = value, uniqueKeys(root),
              case .number("1")? = member("version", in: root),
              case .array(let targets)? = member("testTargets", in: root),
              case .array(let configurations)? = member("configurations", in: root),
              targets.allSatisfy(isTestTarget),
              configurations.allSatisfy(isConfiguration) else { return nil }
        return "Xcode test plan · \(countLabel(targets.count, singular: "test target")) · " +
            countLabel(configurations.count, singular: "configuration")
    }

    private static func isTestTarget(_ value: StructuredValue) -> Bool {
        guard case .object(let members) = value, uniqueKeys(members),
              case .object(let target)? = member("target", in: members), uniqueKeys(target),
              case .string(let name)? = member("name", in: target), !name.isEmpty,
              case .string(let identifier)? = member("identifier", in: target), !identifier.isEmpty else { return false }
        return true
    }

    private static func isConfiguration(_ value: StructuredValue) -> Bool {
        guard case .object(let members) = value, uniqueKeys(members),
              case .string(let name)? = member("name", in: members), !name.isEmpty,
              case .object? = member("options", in: members) else { return false }
        return true
    }

    private static func member(_ key: String, in members: [StructuredMember]) -> StructuredValue? {
        members.first(where: { $0.key == key })?.value
    }

    private static func uniqueKeys(_ members: [StructuredMember]) -> Bool {
        Set(members.map(\.key)).count == members.count
    }

    private static func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}

/// Produces an identity-free thumbnail summary for an Apple code-signing resource manifest.
public enum AppleCodeResourcesSummary {
    public static func make(from value: PlistValue) -> String? {
        guard case .dictionary(let root) = value,
              Set(root.map(\.key)).count == root.count else { return nil }
        let files = root.compactMap { member -> PlistValue? in
            guard member.key == "files" || member.key == "files2" else { return nil }
            return member.value
        }
        guard files.allSatisfy({ if case .dictionary = $0 { true } else { false } }) else { return nil }
        let count = files.reduce(into: 0) { total, value in
            if case .dictionary(let entries) = value { total += entries.count }
        }
        let label = count == 1 ? "entry" : "entries"
        return "CodeResources · \(count) sealed resource \(label) · signature not checked"
    }
}
