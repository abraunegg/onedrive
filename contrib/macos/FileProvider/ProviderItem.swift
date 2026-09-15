import FileProvider
import Foundation
import UniformTypeIdentifiers

final class OneDriveProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    private let cachePolicy: ProviderCachePolicy?

    var contentPolicy: NSFileProviderContentPolicy {
        switch cachePolicy {
        case .spaceSaver: return .downloadLazilyAndEvictOnRemoteUpdate
        case .smart: return .downloadLazily
        case .alwaysAvailable: return .downloadEagerlyAndKeepDownloaded
        case nil: return .inherited
        }
    }

    init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        isFolder: Bool,
        size: Int64? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        version: String,
        cachePolicy: ProviderCachePolicy? = nil,
        editable: Bool = true,
        allowsAddingSubItems: Bool = false
    ) {
        itemIdentifier = identifier
        parentItemIdentifier = parentIdentifier
        self.filename = filename
        contentType = isFolder ? .folder : (UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data)
        var itemCapabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if isFolder { itemCapabilities.insert(.allowsContentEnumerating) }
        if editable {
            itemCapabilities.formUnion([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting])
        } else if isFolder && allowsAddingSubItems {
            itemCapabilities.insert(.allowsWriting)
        }
        capabilities = itemCapabilities
        documentSize = size.map(NSNumber.init(value:))
        self.creationDate = creationDate
        contentModificationDate = modificationDate
        let versionData = Data(version.utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
        self.cachePolicy = cachePolicy
        super.init()
    }

    static func domainRoot(accountName: String, cachePolicy: ProviderCachePolicy = .smart, allowsAddingSubItems: Bool = true) -> OneDriveProviderItem {
        OneDriveProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: accountName,
            isFolder: true,
            version: "root-v1",
            cachePolicy: cachePolicy,
            editable: false,
            allowsAddingSubItems: allowsAddingSubItems
        )
    }

    static func mount(_ drive: ProviderDrive, cachePolicy: ProviderCachePolicy? = nil) -> OneDriveProviderItem {
        let reference = ProviderItemReference(kind: .mount, driveID: drive.driveID, rootItemID: drive.remoteRootItemID, itemID: drive.remoteRootItemID)
        return OneDriveProviderItem(
            identifier: NSFileProviderItemIdentifier(reference.identifier),
            parentIdentifier: .rootContainer,
            filename: drive.displayName,
            isFolder: true,
            version: "mount:\(drive.driveID):\(drive.remoteRootItemID)",
            cachePolicy: cachePolicy,
            editable: false,
            allowsAddingSubItems: !drive.rootFilesOnly
        )
    }

    static func remote(
        _ item: GraphDriveItem,
        drive: ProviderDrive,
        cachePolicy: ProviderCachePolicy? = nil,
        personalDocumentsItemID: String? = nil,
        parentOverride: NSFileProviderItemIdentifier? = nil,
        editable: Bool = true
    ) -> OneDriveProviderItem {
        let reference = ProviderItemReference(kind: .remote, driveID: drive.driveID, rootItemID: drive.remoteRootItemID, itemID: item.id)
        let parent: NSFileProviderItemIdentifier
        if let parentOverride {
            parent = parentOverride
        } else if drive.rootFilesOnly && (item.parentReference?.id == drive.remoteRootItemID || item.parentReference?.id == nil) {
            parent = .rootContainer
        } else if item.parentReference?.id == drive.remoteRootItemID || item.parentReference?.id == nil {
            let mount = ProviderItemReference(kind: .mount, driveID: drive.driveID, rootItemID: drive.remoteRootItemID, itemID: drive.remoteRootItemID)
            parent = NSFileProviderItemIdentifier(mount.identifier)
        } else {
            let parentReference = ProviderItemReference(kind: .remote, driveID: drive.driveID, rootItemID: drive.remoteRootItemID, itemID: item.parentReference!.id!)
            parent = NSFileProviderItemIdentifier(parentReference.identifier)
        }
        return OneDriveProviderItem(
            identifier: NSFileProviderItemIdentifier(reference.identifier),
            parentIdentifier: parent,
            filename: item.name,
            isFolder: item.isFolder,
            size: item.size,
            creationDate: item.createdDateTime,
            modificationDate: item.lastModifiedDateTime,
            version: item.versionToken,
            cachePolicy: cachePolicy,
            editable: editable
        )
    }
}
