import Foundation

/// Local repository implementation that supplied the inspection result.
public enum VCSRepositoryType: String, Equatable, Sendable { case git, svn }

/// Worktree state for the inspected file, independent of its preview content.
public enum VCSFileStatus: String, Equatable, Sendable {
    case clean, modified, added, deleted, replaced, untracked, conflicted, unavailable
}

/// Snapshot against which a file's line changes were calculated.
public enum VCSComparisonBase: String, Equatable, Sendable { case head, index, svnBase }

/// Line changes and their exact comparison base.
public struct VCSChangeSet: Equatable, Sendable {
    public let base: VCSComparisonBase
    public let lineDiff: VCSLineDiff
    /// Pairs a line diff with the exact repository snapshot used as its baseline.
    public init(base: VCSComparisonBase, lineDiff: VCSLineDiff) {
        self.base = base
        self.lineDiff = lineDiff
    }
}

/// Git's index-to-HEAD and working-tree-to-index comparisons remain distinct.
public struct VCSStagedInformation: Equatable, Sendable {
    public let stagedChanges: VCSChangeSet?
    public let unstagedChanges: VCSChangeSet?
    /// Keeps index-to-HEAD and working-tree-to-index changes separately addressable.
    public init(stagedChanges: VCSChangeSet?, unstagedChanges: VCSChangeSet?) {
        self.stagedChanges = stagedChanges
        self.unstagedChanges = unstagedChanges
    }
}

/// The commit that last changed a file along the history `git log -1 -- <path>` follows.
public struct VCSCommitSummary: Equatable, Sendable {
    public let id: String
    public let summary: String
    public let authorDate: Date
    /// Seven-character abbreviation shown in the status bar.
    public var shortID: String { String(id.prefix(7)) }
    /// Creates a summary from a full hexadecimal commit ID, its first message line and author time.
    public init(id: String, summary: String, authorDate: Date) {
        self.id = id
        self.summary = summary
        self.authorDate = authorDate
    }
}

/// Safe user-facing reasons that repository status or comparison information is unavailable.
public enum VCSDiagnostic: String, Equatable, Sendable {
    case repositoryNotReadable, repositoryMetadataMissing, comparisonUnavailable
    case unsupportedContent, resourceLimitReached, unsafePath

    public var message: String {
        switch self {
        case .repositoryNotReadable: "Repository metadata is not available to this preview."
        case .repositoryMetadataMissing: "Repository metadata is missing or incomplete."
        case .comparisonUnavailable: "A local comparison copy is not available."
        case .unsupportedContent: "Line changes are unavailable for this file content."
        case .resourceLimitReached: "Line comparison exceeded its local resource limit."
        case .unsafePath: "Repository lookup was stopped at a path safety boundary."
        }
    }
}

/// Local repository facts kept separate from type detection, parsing, and original file bytes.
public struct VCSInspectionResult: Equatable, Sendable {
    public let repositoryType: VCSRepositoryType
    public let fileStatus: VCSFileStatus
    public let comparison: VCSChangeSet?
    public let stagedInformation: VCSStagedInformation?
    public let lastCommit: VCSCommitSummary?
    public let diagnostics: [VCSDiagnostic]

    /// Creates a result with status, optional comparison snapshots, and non-sensitive diagnostics.
    public init(repositoryType: VCSRepositoryType, fileStatus: VCSFileStatus,
                comparison: VCSChangeSet?, stagedInformation: VCSStagedInformation? = nil,
                lastCommit: VCSCommitSummary? = nil, diagnostics: [VCSDiagnostic] = []) {
        self.repositoryType = repositoryType
        self.fileStatus = fileStatus
        self.comparison = comparison
        self.stagedInformation = stagedInformation
        self.lastCommit = lastCommit
        self.diagnostics = diagnostics
    }
}

/// Reads local repository state without changing files or executing repository content.
public protocol VCSProvider: Sendable {
    var repositoryType: VCSRepositoryType { get }
    /// Returns repository facts or `.notRepository`; providers must not turn unreadable matches into clean status.
    func inspect(fileURL: URL) async -> VCSProviderInspection
}

/// Provider outcome distinguishing no repository from a repository that could not be inspected.
public enum VCSProviderInspection: Sendable {
    case notRepository
    case inspected(VCSInspectionResult)
}

/// Ordered provider registry. A matched but unreadable repository is never presented as clean.
public struct VCSProviderRegistry: Sendable {
    private let providers: [any VCSProvider]
    /// Creates an ordered registry; the first provider that recognizes a repository owns the result.
    public init(providers: [any VCSProvider]) { self.providers = providers }

    /// Queries providers in order and checks cancellation before and after each repository lookup.
    public func inspect(fileURL: URL) async throws -> VCSInspectionResult? {
        for provider in providers {
            try Task.checkCancellation()
            let outcome = await provider.inspect(fileURL: fileURL)
            try Task.checkCancellation()
            if case .inspected(let result) = outcome { return result }
        }
        try Task.checkCancellation()
        return nil
    }
}
