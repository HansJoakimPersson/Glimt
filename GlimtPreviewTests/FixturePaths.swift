import Foundation

/// Read the canonical repository file directly; test bundles contain no duplicate input.
func fixtureURL(_ relativePath: String) throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let root = directory.appendingPathComponent("Fixtures", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path) {
            let file = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw NSError(domain: "GlimtFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing shared fixture: \(relativePath)"])
            }
            return file
        }
        directory.deleteLastPathComponent()
    }
    throw NSError(domain: "GlimtFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "Repository Fixtures directory not found; run tests from a complete checkout."])
}
