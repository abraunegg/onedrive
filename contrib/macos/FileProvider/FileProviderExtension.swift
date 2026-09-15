import FileProvider
import Foundation
import UniformTypeIdentifiers

private final class ProviderCompletionGate {
    private let lock = NSLock()
    private var completed = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        body()
    }
}

private final class ProviderProgressBridge {
    let progress: Progress
    private let lock = NSLock()
    private var child: Progress?
    private var cancelled = false
    var onCancel: (() -> Void)?

    init() {
        progress = Progress(totalUnitCount: 100)
        // Keep the bridge alive for the lifetime of the returned Progress.
        // finish() releases this handler, breaking the temporary cycle.
        progress.cancellationHandler = { [self] in self.cancel() }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ operation: Progress) {
        lock.lock()
        if cancelled {
            lock.unlock()
            operation.cancel()
            return
        }
        child = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = child
        lock.unlock()
        operation?.cancel()
        onCancel?()
    }

    func finish() {
        progress.cancellationHandler = nil
        progress.completedUnitCount = progress.totalUnitCount
    }
}

@objc(OneDriveFileProviderExtension)
final class OneDriveFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let configurationStore = ProviderConfigurationStore()
    private let graph: GraphClient
    private let state: ProviderStateStore

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        guard let manager = NSFileProviderManager(for: domain) else {
            fatalError("OneDrive File Provider cannot create its domain manager.")
        }
        graph = GraphClient(downloadDirectory: { try manager.temporaryDirectoryURL() })
        guard let loadedState = try? ProviderStateStore() else {
            fatalError("OneDrive File Provider cannot access its signed App Group state.")
        }
        state = loadedState
        super.init()
    }

    private var configuration: ProviderConfiguration {
        (try? configurationStore.load()) ?? ProviderConfiguration(accountName: "OneDrive", accountEmail: "", drives: [])
    }

    func invalidate() {}

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        OneDriveEnumerator(containerIdentifier: containerItemIdentifier, configuration: configuration, graph: graph, state: state)
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(OneDriveProviderItem.domainRoot(
                accountName: configuration.accountName,
                cachePolicy: configuration.globalCachePolicy,
                allowsAddingSubItems: configuration.allowsDomainRootWrites
            ), nil)
            return completedProgress()
        }
        guard let reference = ProviderItemReference.decode(identifier.rawValue), let drive = configuration.drive(for: reference) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        if reference.kind == .mount {
            guard !drive.rootFilesOnly else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return completedProgress()
            }
            completionHandler(OneDriveProviderItem.mount(drive, cachePolicy: configuration.cachePolicyOverride(driveID: drive.driveID, itemID: drive.remoteRootItemID, rootItemID: drive.remoteRootItemID)), nil)
            return completedProgress()
        }
        if let cached = state.item(identifier: identifier.rawValue) {
            guard isVisible(cached, reference: reference, drive: drive) else {
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                return completedProgress()
            }
            completionHandler(OneDriveProviderItem.remote(
                cached,
                drive: drive,
                cachePolicy: configuration.cachePolicyOverride(driveID: drive.driveID, itemID: cached.id, rootItemID: drive.remoteRootItemID),
                personalDocumentsItemID: configuration.personalDocumentsItemID,
                editable: !drive.rootFilesOnly || configuration.allowsDomainRootWrites
            ), nil)
            return completedProgress()
        }
        return graph.item(driveID: drive.driveID, itemID: reference.itemID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completionHandler(nil, self.providerError(error))
            case let .success(remote):
                guard self.isVisible(remote, reference: reference, drive: drive) else {
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                    return
                }
                self.state.cache(remote, identifier: identifier.rawValue)
                completionHandler(OneDriveProviderItem.remote(
                    remote,
                    drive: drive,
                    cachePolicy: self.configuration.cachePolicyOverride(driveID: drive.driveID, itemID: remote.id, rootItemID: drive.remoteRootItemID),
                    personalDocumentsItemID: self.configuration.personalDocumentsItemID,
                    editable: !drive.rootFilesOnly || self.configuration.allowsDomainRootWrites
                ), nil)
            }
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let reference = ProviderItemReference.decode(itemIdentifier.rawValue), reference.kind == .remote,
              let drive = configuration.drive(for: reference) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        let progress = Progress(totalUnitCount: 100)
        var child: Progress?
        progress.cancellationHandler = { child?.cancel() }
        child = graph.item(driveID: drive.driveID, itemID: reference.itemID) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completionHandler(nil, nil, self.providerError(error))
            case let .success(remote):
                guard self.isVisible(remote, reference: reference, drive: drive) else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    return
                }
                if let requestedVersion,
                   requestedVersion.contentVersion != Data(remote.versionToken.utf8) {
                    completionHandler(nil, nil, NSFileProviderError(.versionNoLongerAvailable))
                    return
                }
                child = self.graph.download(remote, driveID: drive.driveID) { downloadResult in
                    switch downloadResult {
                    case let .failure(error): completionHandler(nil, nil, self.providerError(error))
                    case let .success(url):
                        self.state.cache(remote, identifier: itemIdentifier.rawValue, materialized: true)
                        progress.completedUnitCount = 100
                        completionHandler(url, OneDriveProviderItem.remote(
                            remote,
                            drive: drive,
                            cachePolicy: self.configuration.cachePolicyOverride(driveID: drive.driveID, itemID: remote.id, rootItemID: drive.remoteRootItemID),
                            personalDocumentsItemID: self.configuration.personalDocumentsItemID,
                            editable: !drive.rootFilesOnly || self.configuration.allowsDomainRootWrites
                        ), nil)
                    }
                }
            }
        }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let parent = remoteParent(for: itemTemplate.parentItemIdentifier) else {
            completionHandler(nil, fields, false, NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        let complete: (Result<GraphDriveItem, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completionHandler(nil, fields, false, self.providerError(error))
            case let .success(remote):
                let providerItem = OneDriveProviderItem.remote(remote, drive: parent.drive, cachePolicy: self.configuration.cachePolicyOverride(driveID: parent.drive.driveID, itemID: remote.id, rootItemID: parent.drive.remoteRootItemID), personalDocumentsItemID: self.configuration.personalDocumentsItemID)
                self.state.cache(remote, identifier: providerItem.itemIdentifier.rawValue, materialized: url != nil)
                completionHandler(providerItem, [], false, nil)
            }
        }
        if itemTemplate.contentType?.conforms(to: .folder) == true {
            return graph.createFolder(driveID: parent.drive.driveID, parentID: parent.itemID, name: itemTemplate.filename, completion: complete)
        }
        guard let url else {
            completionHandler(nil, fields, false, CocoaError(.fileReadNoSuchFile))
            return completedProgress()
        }
        return graph.upload(driveID: parent.drive.driveID, parentID: parent.itemID, name: itemTemplate.filename, contents: url, replacing: nil, eTag: nil, completion: complete)
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let reference = ProviderItemReference.decode(item.itemIdentifier.rawValue), reference.kind == .remote,
              let drive = configuration.drive(for: reference) else {
            completionHandler(nil, changedFields, false, NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        guard configuration.allowsMutation(of: reference) else {
            completionHandler(nil, changedFields, false, NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        let bridge = ProviderProgressBridge()
        let gate = ProviderCompletionGate()
        func finish(_ result: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?)) {
            gate.run {
                bridge.finish()
                bridge.onCancel = nil
                completionHandler(result.0, result.1, result.2, result.3)
            }
        }
        bridge.onCancel = {
            finish((nil, changedFields, false, CocoaError(.userCancelled)))
        }
        let baseETag = String(data: version.metadataVersion, encoding: .utf8)
        let destinationParent: (drive: ProviderDrive, itemID: String)?
        if changedFields.contains(.parentItemIdentifier) {
            guard let parent = remoteParent(for: item.parentItemIdentifier) else {
                finish((nil, changedFields, false, NSFileProviderError(.noSuchItem)))
                return bridge.progress
            }
            destinationParent = parent
        } else {
            destinationParent = nil
        }
        if changedFields.contains(.parentItemIdentifier), destinationParent?.drive.driveID != drive.driveID {
            finish((nil, changedFields, false, CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "Move items within the same OneDrive or company library. Cross-library moves are not supported."
            ])))
            return bridge.progress
        }

        let applyMetadata: (GraphDriveItem?) -> Void = { [weak self] uploaded in
            guard let self else { return }
            guard !bridge.isCancelled else { return }
            let rename = changedFields.contains(.filename) ? item.filename : nil
            let move = destinationParent?.itemID
            guard rename != nil || move != nil else {
                guard let remote = uploaded else {
                    finish((nil, changedFields, false, CocoaError(.fileWriteUnknown)))
                    return
                }
                self.finishMutation(remote, drive: destinationParent?.drive ?? drive, materialized: newContents != nil, completion: finish)
                return
            }
            let operation = self.graph.patch(
                driveID: drive.driveID,
                itemID: reference.itemID,
                name: rename,
                parentID: move,
                eTag: uploaded?.eTag ?? baseETag
            ) { result in
                switch result {
                case let .failure(error): finish((nil, changedFields, false, self.providerError(error)))
                case let .success(remote): self.finishMutation(remote, drive: destinationParent?.drive ?? drive, materialized: newContents != nil, completion: finish)
                }
            }
            bridge.attach(operation)
        }

        if changedFields.contains(.contents), let newContents {
            let operation = graph.upload(
                driveID: drive.driveID,
                parentID: destinationParent?.itemID ?? drive.remoteRootItemID,
                name: item.filename,
                contents: newContents,
                replacing: reference.itemID,
                eTag: baseETag
            ) { result in
                switch result {
                case let .failure(error): finish((nil, changedFields, false, self.providerError(error)))
                case let .success(remote): applyMetadata(remote)
                }
            }
            bridge.attach(operation)
        } else {
            applyMetadata(state.item(identifier: item.itemIdentifier.rawValue))
        }
        return bridge.progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard let reference = ProviderItemReference.decode(identifier.rawValue), reference.kind == .remote,
              let drive = configuration.drive(for: reference) else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        guard configuration.allowsMutation(of: reference) else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return completedProgress()
        }
        let eTag = String(data: version.metadataVersion, encoding: .utf8)
        return graph.delete(driveID: drive.driveID, itemID: reference.itemID, eTag: eTag) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completionHandler(self.providerError(error))
            case .success:
                self.state.remove(identifier: identifier.rawValue)
                completionHandler(nil)
            }
        }
    }

    private func finishMutation(
        _ remote: GraphDriveItem,
        drive: ProviderDrive,
        materialized: Bool,
        completion: @escaping ((NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?)) -> Void
    ) {
        let providerItem = OneDriveProviderItem.remote(remote, drive: drive, cachePolicy: configuration.cachePolicyOverride(driveID: drive.driveID, itemID: remote.id, rootItemID: drive.remoteRootItemID), personalDocumentsItemID: configuration.personalDocumentsItemID)
        state.cache(remote, identifier: providerItem.itemIdentifier.rawValue, materialized: materialized)
        completion((providerItem, [], false, nil))
    }

    private func remoteParent(for identifier: NSFileProviderItemIdentifier) -> (drive: ProviderDrive, itemID: String)? {
        if identifier == .rootContainer, configuration.allowsDomainRootWrites, let drive = configuration.personalRootDrive {
            return (drive, drive.remoteRootItemID)
        }
        guard let reference = ProviderItemReference.decode(identifier.rawValue), let drive = configuration.drive(for: reference) else { return nil }
        guard !drive.rootFilesOnly else { return nil }
        return (drive, reference.kind == .mount ? drive.remoteRootItemID : reference.itemID)
    }

    private func isVisible(_ item: GraphDriveItem, reference: ProviderItemReference, drive: ProviderDrive) -> Bool {
        if drive.rootFilesOnly && reference.itemID != drive.remoteRootItemID,
           configuration.personalFolderIDs.contains(reference.itemID) {
            // Compatibility for identifiers created by older versions that
            // projected a selected folder through the synthetic root drive.
            return item.deleted == nil
        }
        return configuration.isVisible(item, on: drive)
    }

    private func completedProgress() -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }

    private func providerError(_ error: Error) -> Error {
        if let graphError = error as? GraphError, case let .http(code, _) = graphError {
            switch code {
            case 401, 403: return NSFileProviderError(.notAuthenticated)
            case 400, 404: return NSFileProviderError(.noSuchItem)
            case 409, 412: return NSFileProviderError(.versionNoLongerAvailable)
            case 507: return NSFileProviderError(.insufficientQuota)
            case 429, 500...599: return NSFileProviderError(.serverUnreachable)
            default: return NSFileProviderError(.serverUnreachable)
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return NSFileProviderError(.serverUnreachable) }
        return CocoaError(.fileReadCorruptFile, userInfo: [NSUnderlyingErrorKey: error])
    }
}
