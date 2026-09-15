import Foundation

private struct PersistedProviderState: Codable {
    var revision: Int64 = 0
    var scopeRevisions: [String: Int64] = [:]
    var items: [String: GraphDriveItem] = [:]
    var materializedIdentifiers: Set<String> = []
    var deltaLinks: [String: URL] = [:]

    private enum CodingKeys: String, CodingKey {
        case revision, scopeRevisions, items, materializedIdentifiers, deltaLinks
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        scopeRevisions = try values.decodeIfPresent([String: Int64].self, forKey: .scopeRevisions) ?? [:]
        items = try values.decodeIfPresent([String: GraphDriveItem].self, forKey: .items) ?? [:]
        materializedIdentifiers = try values.decodeIfPresent(Set<String>.self, forKey: .materializedIdentifiers) ?? []
        deltaLinks = try values.decodeIfPresent([String: URL].self, forKey: .deltaLinks) ?? [:]
    }
}

struct ProviderDeltaCommit {
    let cached: [(String, GraphDriveItem)]
    let deletedIdentifiers: [String]
    let deltaLink: URL?
    let scopeID: String
}

final class ProviderStateStore {
    private let lock = NSLock()
    private var state: PersistedProviderState
    private let stateURL: URL

    init() throws {
        stateURL = try ProviderFiles.stateURL()
        if let data = try? Data(contentsOf: stateURL), let decoded = try? JSONDecoder.provider.decode(PersistedProviderState.self, from: data) {
            state = decoded
        } else {
            state = PersistedProviderState()
        }
    }

    var revision: Int64 { withLock { state.revision } }

    func item(identifier: String) -> GraphDriveItem? { withLock { state.items[identifier] } }

    func materializedItems() -> [(String, GraphDriveItem)] {
        withLock {
            state.materializedIdentifiers.compactMap { identifier in
                state.items[identifier].map { (identifier, $0) }
            }
        }
    }

    func isMaterialized(identifier: String) -> Bool {
        withLock { state.materializedIdentifiers.contains(identifier) }
    }

    func deltaLink(for scopeID: String) -> URL? { withLock { state.deltaLinks[scopeID] } }

    func cache(_ item: GraphDriveItem, identifier: String, materialized: Bool = false) {
        withLock {
            state.items[identifier] = item
            if materialized { state.materializedIdentifiers.insert(identifier) }
            persistLocked()
        }
    }

    func cache(_ items: [(String, GraphDriveItem)]) {
        guard !items.isEmpty else { return }
        withLock {
            for (identifier, item) in items { state.items[identifier] = item }
            persistLocked()
        }
    }

    func cache(_ items: [(String, GraphDriveItem)], deltaLink: URL?, scopeID: String) {
        withLock {
            for (identifier, item) in items { state.items[identifier] = item }
            if let deltaLink { state.deltaLinks[scopeID] = deltaLink }
            state.revision += 1
            state.scopeRevisions[scopeID, default: 0] += 1
            persistLocked()
        }
    }

    func applyDelta(
        cached: [(String, GraphDriveItem)],
        deletedIdentifiers: [String],
        deltaLink: URL?,
        scopeID: String
    ) {
        withLock {
            for (identifier, item) in cached { state.items[identifier] = item }
            for identifier in deletedIdentifiers {
                state.items.removeValue(forKey: identifier)
                state.materializedIdentifiers.remove(identifier)
            }
            if let deltaLink { state.deltaLinks[scopeID] = deltaLink }
            state.revision += 1
            if !cached.isEmpty || !deletedIdentifiers.isEmpty {
                state.scopeRevisions[scopeID, default: 0] += 1
            }
            persistLocked()
        }
    }

    func applyDeltas(_ commits: [ProviderDeltaCommit]) {
        guard !commits.isEmpty else { return }
        withLock {
            for commit in commits {
                for (identifier, item) in commit.cached { state.items[identifier] = item }
                for identifier in commit.deletedIdentifiers {
                    state.items.removeValue(forKey: identifier)
                    state.materializedIdentifiers.remove(identifier)
                }
                if let deltaLink = commit.deltaLink { state.deltaLinks[commit.scopeID] = deltaLink }
                if !commit.cached.isEmpty || !commit.deletedIdentifiers.isEmpty {
                    state.scopeRevisions[commit.scopeID, default: 0] += 1
                }
            }
            state.revision += 1
            persistLocked()
        }
    }

    func remove(identifier: String) {
        withLock {
            state.items.removeValue(forKey: identifier)
            state.materializedIdentifiers.remove(identifier)
            state.revision += 1
            if let reference = ProviderItemReference.decode(identifier) {
                let scopeID = "\(reference.driveID)|\(reference.rootItemID)"
                state.scopeRevisions[scopeID, default: 0] += 1
            }
            persistLocked()
        }
    }

    func resetDelta(for scopeID: String) {
        withLock {
            state.deltaLinks.removeValue(forKey: scopeID)
            persistLocked()
        }
    }

    func anchor() -> Data { Data(String(revision).utf8) }

    func anchor(for scopeIDs: [String]) -> Data {
        let revisions = withLock {
            scopeIDs.reduce(into: [String: Int64]()) { result, scopeID in
                result[scopeID] = state.scopeRevisions[scopeID, default: 0]
            }
        }
        return (try? JSONEncoder.provider.encode(revisions)) ?? Data()
    }

    func scopeRevisions(from anchor: Data) -> [String: Int64]? {
        try? JSONDecoder.provider.decode([String: Int64].self, from: anchor)
    }

    func anchorIsCurrent(_ anchor: Data, for scopeIDs: [String]) -> Bool {
        guard let revisions = scopeRevisions(from: anchor) else { return false }
        let expected = withLock {
            scopeIDs.reduce(into: [String: Int64]()) { result, scopeID in
                result[scopeID] = state.scopeRevisions[scopeID, default: 0]
            }
        }
        return revisions == expected
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder.provider.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
