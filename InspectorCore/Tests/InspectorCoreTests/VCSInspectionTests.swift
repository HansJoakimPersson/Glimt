import XCTest
@testable import InspectorCore

final class VCSInspectionTests: XCTestCase {
    func testProviderRegistryFallsThroughAndReturnsFirstMatch() async throws {
        let unavailable = VCSInspectionResult(repositoryType: .svn, fileStatus: .unavailable, comparison: nil,
                                              diagnostics: [.repositoryNotReadable])
        let registry = VCSProviderRegistry(providers: [
            StubProvider(repositoryType: .git, result: .notRepository),
            StubProvider(repositoryType: .svn, result: .inspected(unavailable)),
            StubProvider(repositoryType: .git, result: .inspected(.init(repositoryType: .git, fileStatus: .clean, comparison: nil)))
        ])
        let result = try await registry.inspect(fileURL: URL(fileURLWithPath: "/tmp/file"))
        XCTAssertEqual(result, unavailable)
        XCTAssertEqual(result?.fileStatus, .unavailable)
    }

    func testGitComparisonBaseLabelsPreventStagedAndUnstagedAmbiguity() {
        let diff = VCSLineDiff(changes: [], baselineLineCount: 0, workingLineCount: 0)
        let result = VCSInspectionResult(repositoryType: .git, fileStatus: .modified, comparison: .init(base: .index, lineDiff: diff),
            stagedInformation: .init(stagedChanges: .init(base: .head, lineDiff: diff), unstagedChanges: .init(base: .index, lineDiff: diff)))
        XCTAssertEqual(result.stagedInformation?.stagedChanges?.base, .head)
        XCTAssertEqual(result.stagedInformation?.unstagedChanges?.base, .index)
    }
}

private struct StubProvider: VCSProvider {
    let repositoryType: VCSRepositoryType
    let result: VCSProviderInspection
    func inspect(fileURL: URL) async -> VCSProviderInspection { result }
}
