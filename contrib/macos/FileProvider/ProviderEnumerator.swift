import FileProvider
import Foundation

final class OneDriveEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let configuration: ProviderConfiguration
    private let graph: GraphClient
    private let state: ProviderStateStore
    private var invalidated = false

    init(containerIdentifier: NSFileProviderItemIdentifier, configuration: ProviderConfiguration, graph: GraphClient, state: ProviderStateStore) {
        self.containerIdentifier = containerIdentifier
        self.configuration = configuration
        self.graph = graph
        self.state = state
    }

    func invalidate() { invalidated = true }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard !invalidated else { observer.finishEnumeratingWithError(CocoaError(.userCancelled)); return }
        if containerIdentifier == .rootContainer {
            enumerateRoot(for: observer, startingAt: page)
            return
        }
        if containerIdentifier == .workingSet {
            let items = state.materializedItems().compactMap { identifier, item -> OneDriveProviderItem? in
                guard let reference = ProviderItemReference.decode(identifier), let drive = configuration.drive(for: reference) else { return nil }
                guard configuration.isVisible(item, on: drive) else { return nil }
                return .remote(
                    item,
                    drive: drive,
                    cachePolicy: configuration.cachePolicyOverride(driveID: drive.driveID, itemID: item.id, rootItemID: drive.remoteRootItemID),
                    personalDocumentsItemID: configuration.personalDocumentsItemID,
                    editable: !drive.rootFilesOnly || configuration.allowsDomainRootWrites
                )
            }
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
            return
        }
        guard let reference = ProviderItemReference.decode(containerIdentifier.rawValue), let drive = configuration.drive(for: reference) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }
        let isProjectionContainer = drive.rootFilesOnly && reference.itemID != drive.remoteRootItemID
        if isProjectionContainer && !configuration.personalFolderIDs.contains(reference.itemID) {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }
        let pageURL = decodeURL(from: page)
        let itemID = reference.kind == .mount ? drive.remoteRootItemID : reference.itemID
        graph.children(driveID: drive.driveID, itemID: itemID, pageURL: pageURL) { [weak self] result in
            guard let self, !self.invalidated else { return }
            switch result {
            case let .failure(error): observer.finishEnumeratingWithError(self.providerError(error))
            case let .success(resultPage):
                var cached: [(String, GraphDriveItem)] = []
                let mapped = resultPage.value.filter { item in
                    if isProjectionContainer { return item.deleted == nil }
                    return self.configuration.isVisible(item, on: drive)
                }.map { item -> OneDriveProviderItem in
                    let providerItem = OneDriveProviderItem.remote(
                        item,
                        drive: drive,
                        cachePolicy: self.configuration.cachePolicyOverride(driveID: drive.driveID, itemID: item.id, rootItemID: drive.remoteRootItemID),
                        personalDocumentsItemID: self.configuration.personalDocumentsItemID,
                        parentOverride: self.containerIdentifier,
                        editable: !drive.rootFilesOnly || self.configuration.allowsDomainRootWrites
                    )
                    cached.append((providerItem.itemIdentifier.rawValue, item))
                    return providerItem
                }
                self.state.cache(cached)
                observer.didEnumerate(mapped)
                observer.finishEnumerating(upTo: resultPage.nextLink.map { NSFileProviderPage(Data($0.absoluteString.utf8)) })
            }
        }
    }

    private func enumerateRoot(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let mounts = configuration.visibleMountDrives.map {
            OneDriveProviderItem.mount($0, cachePolicy: configuration.cachePolicyOverride(driveID: $0.driveID, itemID: $0.remoteRootItemID, rootItemID: $0.remoteRootItemID))
        }
        guard let rootDrive = configuration.personalRootDrive else {
            observer.didEnumerate(mounts)
            observer.finishEnumerating(upTo: nil)
            return
        }
        let pageURL = decodeURL(from: page)
        graph.children(driveID: rootDrive.driveID, itemID: rootDrive.remoteRootItemID, pageURL: pageURL) { [weak self] result in
            guard let self, !self.invalidated else { return }
            switch result {
            case let .failure(error):
                observer.finishEnumeratingWithError(self.providerError(error))
            case let .success(resultPage):
                var cached: [(String, GraphDriveItem)] = []
                let rootItems = resultPage.value.filter { item in
                    self.configuration.isVisibleRootItem(item, on: rootDrive)
                }.map { item -> OneDriveProviderItem in
                    let providerItem = OneDriveProviderItem.remote(
                        item,
                        drive: rootDrive,
                        cachePolicy: self.configuration.cachePolicyOverride(driveID: rootDrive.driveID, itemID: item.id, rootItemID: rootDrive.remoteRootItemID),
                        personalDocumentsItemID: self.configuration.personalDocumentsItemID,
                        parentOverride: .rootContainer,
                        editable: self.configuration.allowsDomainRootWrites
                    )
                    cached.append((providerItem.itemIdentifier.rawValue, item))
                    return providerItem
                }
                self.state.cache(cached)
                observer.didEnumerate((pageURL == nil ? mounts : []) + rootItems)
                observer.finishEnumerating(upTo: resultPage.nextLink.map { NSFileProviderPage(Data($0.absoluteString.utf8)) })
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
        guard !invalidated else { observer.finishEnumeratingWithError(CocoaError(.userCancelled)); return }
        guard state.anchorIsCurrent(syncAnchor.rawValue, for: scopeIDs) else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        fetchChanges(at: 0, updated: [], deleted: [], commits: [], observer: observer)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(state.anchor(for: scopeIDs)))
    }

    private func fetchChanges(
        at index: Int,
        updated: [OneDriveProviderItem],
        deleted: [NSFileProviderItemIdentifier],
        commits: [ProviderDeltaCommit],
        observer: NSFileProviderChangeObserver,
        rescannedScopes: Set<String> = []
    ) {
        let drives = deltaDrives
        guard index < drives.count else {
            state.applyDeltas(commits)
            let finalUpdated: [OneDriveProviderItem]
            let finalDeleted: [NSFileProviderItemIdentifier]
            if containerIdentifier == .workingSet {
                finalUpdated = updated.filter { state.isMaterialized(identifier: $0.itemIdentifier.rawValue) }
                finalDeleted = deleted
            } else {
                finalUpdated = updated
                finalDeleted = deleted
            }
            observer.didUpdate(finalUpdated)
            observer.didDeleteItems(withIdentifiers: finalDeleted)
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(state.anchor(for: scopeIDs)), moreComing: false)
            return
        }
        let drive = drives[index]
        let scopeID = "\(drive.driveID)|\(drive.remoteRootItemID)"
        fetchDeltaPages(drive: drive, pageURL: state.deltaLink(for: scopeID), updated: [], deleted: [], cached: []) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                if let graphError = error as? GraphError, case let .http(code, _) = graphError, code == 400 || code == 410 {
                    self.state.resetDelta(for: scopeID)
                    guard !rescannedScopes.contains(scopeID) else {
                        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                        return
                    }
                    // A delta token is a cursor for this drive only.  Retry
                    // the same scope from its root before touching any other
                    // drive; silently skipping it leaves stale Finder items.
                    self.fetchChanges(
                        at: index,
                        updated: updated,
                        deleted: deleted,
                        commits: commits,
                        observer: observer,
                        rescannedScopes: rescannedScopes.union([scopeID])
                    )
                    return
                }
                observer.finishEnumeratingWithError(self.providerError(error))
            case let .success(changes):
                let commit = ProviderDeltaCommit(
                    cached: changes.cached,
                    deletedIdentifiers: changes.deleted.map(\.rawValue),
                    deltaLink: changes.deltaLink,
                    scopeID: scopeID
                )
                self.fetchChanges(at: index + 1, updated: updated + changes.updated, deleted: deleted + changes.deleted, commits: commits + [commit], observer: observer, rescannedScopes: rescannedScopes)
            }
        }
    }

    private typealias DeltaResult = (updated: [OneDriveProviderItem], deleted: [NSFileProviderItemIdentifier], cached: [(String, GraphDriveItem)], deltaLink: URL?)

    private func fetchDeltaPages(drive: ProviderDrive, pageURL: URL?, updated: [OneDriveProviderItem], deleted: [NSFileProviderItemIdentifier], cached: [(String, GraphDriveItem)], completion: @escaping (Result<DeltaResult, Error>) -> Void) {
        graph.delta(driveID: drive.driveID, rootItemID: drive.remoteRootItemID, deltaURL: pageURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(page):
                var nextUpdated = updated
                var nextDeleted = deleted
                var nextCached = cached
                for item in page.value {
                    let reference = ProviderItemReference(kind: .remote, driveID: drive.driveID, rootItemID: drive.remoteRootItemID, itemID: item.id)
                    let identifier = NSFileProviderItemIdentifier(reference.identifier)
                    let previous = self.state.item(identifier: identifier.rawValue)
                    let wasVisible = self.containerIdentifier == .workingSet
                        ? self.state.isMaterialized(identifier: identifier.rawValue)
                        : previous.map { self.isVisibleDeltaItem($0, on: drive) && self.isDirectDeltaItem($0, previous: nil, on: drive) } ?? false
                    let visible = item.deleted == nil && self.isVisibleDeltaItem(item, on: drive) && (
                        self.containerIdentifier == .workingSet || self.isDirectDeltaItem(item, previous: previous, on: drive)
                    )
                    nextUpdated.removeAll { $0.itemIdentifier == identifier }
                    nextDeleted.removeAll { $0 == identifier }
                    nextCached.removeAll { $0.0 == identifier.rawValue }
                    if item.deleted != nil || !visible {
                        // This also handles a root file moving into a hidden
                        // nested folder: it was visible before, but is not a
                        // visible update now, so Finder must remove it.
                        if wasVisible { nextDeleted.append(identifier) }
                    } else if self.containerIdentifier != .workingSet || wasVisible {
                        let providerItem = OneDriveProviderItem.remote(
                            item,
                            drive: drive,
                            cachePolicy: self.configuration.cachePolicyOverride(driveID: drive.driveID, itemID: item.id, rootItemID: drive.remoteRootItemID),
                            personalDocumentsItemID: self.configuration.personalDocumentsItemID,
                            parentOverride: self.containerIdentifier == .rootContainer ? .rootContainer : nil,
                            editable: !drive.rootFilesOnly || self.configuration.allowsDomainRootWrites
                        )
                        nextUpdated.append(providerItem)
                        nextCached.append((identifier.rawValue, item))
                    }
                }
                if let nextLink = page.nextLink {
                    self.fetchDeltaPages(drive: drive, pageURL: nextLink, updated: nextUpdated, deleted: nextDeleted, cached: nextCached, completion: completion)
                } else {
                    completion(.success((nextUpdated, nextDeleted, nextCached, page.deltaLink)))
                }
            }
        }
    }

    private func decodeURL(from page: NSFileProviderPage) -> URL? {
        let data = page.rawValue
        guard let value = String(data: data, encoding: .utf8), value.hasPrefix("http") else { return nil }
        return URL(string: value)
    }

    private var scopeIDs: [String] {
        deltaDrives.map { "\($0.driveID)|\($0.remoteRootItemID)" }
    }

    private var deltaDrives: [ProviderDrive] {
        if containerIdentifier == .workingSet { return configuration.enumeratedDrives }
        if containerIdentifier == .rootContainer {
            return configuration.personalRootDrive.map { [$0] } ?? []
        }
        guard let reference = ProviderItemReference.decode(containerIdentifier.rawValue),
              let drive = configuration.drive(for: reference) else { return [] }
        return [drive]
    }

    private func isVisibleDeltaItem(_ item: GraphDriveItem, on drive: ProviderDrive) -> Bool {
        if containerIdentifier == .rootContainer {
            return configuration.isVisibleRootItem(item, on: drive)
        }
        if containerIdentifier == .workingSet {
            return configuration.isVisible(item, on: drive)
        }
        guard let reference = ProviderItemReference.decode(containerIdentifier.rawValue) else { return false }
        if drive.rootFilesOnly && reference.itemID != drive.remoteRootItemID {
            return item.deleted == nil
        }
        return configuration.isVisible(item, on: drive)
    }

    private func isDirectDeltaItem(_ item: GraphDriveItem, previous: GraphDriveItem?, on drive: ProviderDrive) -> Bool {
        if containerIdentifier == .workingSet { return true }
        if containerIdentifier == .rootContainer {
            return configuration.isVisibleRootItem(item, on: drive) ||
                (item.deleted != nil && previous.map { configuration.isVisibleRootItem($0, on: drive) } == true)
        }
        guard let container = ProviderItemReference.decode(containerIdentifier.rawValue) else { return false }
        let expectedParent = container.kind == .mount ? drive.remoteRootItemID : container.itemID
        return (item.parentReference?.id ?? previous?.parentReference?.id) == expectedParent
    }

    private func providerError(_ error: Error) -> Error {
        if let graphError = error as? GraphError, case let .http(code, _) = graphError {
            switch code {
            case 401, 403: return NSFileProviderError(.notAuthenticated)
            case 400, 404: return NSFileProviderError(.noSuchItem)
            case 410: return NSFileProviderError(.syncAnchorExpired)
            case 429, 500...599: return NSFileProviderError(.serverUnreachable)
            default: return NSFileProviderError(.serverUnreachable)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return NSFileProviderError(.serverUnreachable) }
        return CocoaError(.fileReadCorruptFile, userInfo: [NSUnderlyingErrorKey: error])
    }
}
