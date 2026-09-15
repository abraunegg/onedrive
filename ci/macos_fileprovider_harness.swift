import FileProvider
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var holdRequests = false
    static var started: (() -> Void)?
    static var stopped: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.started?()
        if Self.holdRequests { return }
        do {
            guard let handler = Self.handler else { throw GraphError.invalidResponse }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.stopped?() }
}

private func wait<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Progress) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error>?
    _ = operation { result in outcome = result; semaphore.signal() }
    require(semaphore.wait(timeout: .now() + 5) == .success, "operation timed out")
    return try outcome!.get()
}

@main
private enum FileProviderHarness {
static func main() throws {
let stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("onedrive-provider-harness-\(UUID().uuidString)", isDirectory: true)
setenv("ONEDRIVE_PROVIDER_STATE_DIR", stateDirectory.path, 1)

let drive = ProviderDrive(driveID: "drive:/with unsafe", remoteRootItemID: "root-item", displayName: "Contoso — Operations", siteName: "Contoso", keepDownloaded: false)
let configuration = ProviderConfiguration(accountName: "Test Account", accountEmail: "test@example.com", drives: [drive])
try ProviderConfigurationStore().save(configuration)
let loadedConfiguration = try ProviderConfigurationStore().load()
require(loadedConfiguration.drives == [drive], "configuration round trip")
require(loadedConfiguration.globalCachePolicy == .smart, "smart cache is the default")
let legacyConfigurationData = Data("""
{"accountName":"Legacy","accountEmail":"legacy@example.com","drives":[],"offlineItems":[{"driveID":"drive","itemID":"folder"}]}
""".utf8)
let migratedConfiguration = try JSONDecoder.provider.decode(ProviderConfiguration.self, from: legacyConfigurationData)
require(migratedConfiguration.cachePolicyOverride(driveID: "drive", itemID: "folder") == .alwaysAvailable, "legacy offline choices migrate to always available")
let policyConfiguration = ProviderConfiguration(
    accountName: "Test",
    accountEmail: "test@example.com",
    drives: [drive],
    globalCachePolicy: .spaceSaver,
    cacheOverrides: [ProviderCacheOverride(driveID: drive.driveID, itemID: "folder", policy: .alwaysAvailable)]
)
require(policyConfiguration.globalCachePolicy == .spaceSaver, "global cache policy round trip")
require(policyConfiguration.cachePolicyOverride(driveID: drive.driveID, itemID: "folder") == .alwaysAvailable, "folder cache override lookup")
require(OneDriveProviderItem.domainRoot(accountName: "Test", cachePolicy: .spaceSaver).contentPolicy == .downloadLazilyAndEvictOnRemoteUpdate, "space saver maps to aggressive native eviction")
require(OneDriveProviderItem.domainRoot(accountName: "Test", cachePolicy: .smart).contentPolicy == .downloadLazily, "smart cache maps to native lazy download")
require(OneDriveProviderItem.domainRoot(accountName: "Test", cachePolicy: .alwaysAvailable).contentPolicy == .downloadEagerlyAndKeepDownloaded, "always available maps to native keep downloaded")
let legacyDriveData = Data("""
{"driveID":"legacy","remoteRootItemID":"root","displayName":"Legacy","keepDownloaded":false}
""".utf8)
let legacyDrive = try JSONDecoder.provider.decode(ProviderDrive.self, from: legacyDriveData)
require(!legacyDrive.rootFilesOnly, "legacy configuration defaults to showing folders and files")
let rootFilesDrive = ProviderDrive(driveID: "drive", remoteRootItemID: "root", displayName: "Root files", siteName: nil, keepDownloaded: false, rootFilesOnly: true)
require(rootFilesDrive.rootFilesOnly, "root files mount preserves its filter")
let writableMount = OneDriveProviderItem.mount(drive)
require(writableMount.capabilities.contains(.allowsWriting), "real folder mounts accept files and folders")
let personalFolder = ProviderDrive(driveID: "drive", remoteRootItemID: "documents", displayName: "Documents", siteName: nil, keepDownloaded: false)
let companyDrive = ProviderDrive(driveID: "company", remoteRootItemID: "library", displayName: "Company — Documents", siteName: "Company", keepDownloaded: false)
let projectedConfiguration = ProviderConfiguration(accountName: "Test", accountEmail: "test@example.com", drives: [rootFilesDrive, personalFolder, companyDrive])
require(projectedConfiguration.personalRootDrive == rootFilesDrive, "personal root projection is discoverable")
require(projectedConfiguration.personalDocumentsItemID == personalFolder.remoteRootItemID, "Documents is the personal projection container")
require(projectedConfiguration.personalFolderIDs == [personalFolder.remoteRootItemID], "selected personal folders remain direct root items")
require(projectedConfiguration.visibleMountDrives == [personalFolder, companyDrive], "selected personal projections and company libraries appear as root mounts")
require(projectedConfiguration.enumeratedDrives == [rootFilesDrive, personalFolder, companyDrive], "personal projections are enumerated for delta reconciliation")
require(!projectedConfiguration.allowsDomainRootWrites, "a folder-only personal selection cannot write at the domain root")
require(!OneDriveProviderItem.domainRoot(accountName: "Test", allowsAddingSubItems: projectedConfiguration.allowsDomainRootWrites).capabilities.contains(.allowsWriting), "domain root hides writes without a personal projection")
let everythingConfiguration = ProviderConfiguration(
    accountName: "Test",
    accountEmail: "test@example.com",
    drives: [rootFilesDrive, ProviderDrive(driveID: "drive", remoteRootItemID: "root", displayName: "Everything", siteName: nil, keepDownloaded: false)],
    cacheOverrides: [ProviderCacheOverride(driveID: "drive", itemID: "root", policy: .alwaysAvailable)]
)
require(everythingConfiguration.allowsDomainRootWrites, "Everything in OneDrive enables domain-root writes")
require(OneDriveProviderItem.domainRoot(accountName: "Test", allowsAddingSubItems: everythingConfiguration.allowsDomainRootWrites).capabilities.contains(.allowsWriting), "domain root advertises writes with an allowed projection")
require(everythingConfiguration.cachePolicyOverride(driveID: "drive", itemID: "nested-file", rootItemID: "root") == .alwaysAvailable, "whole-drive cache override applies to descendants")
require(OneDriveProviderItem.domainRoot(accountName: "Test").capabilities.contains(.allowsWriting), "personal OneDrive root accepts files and folders")

let reference = ProviderItemReference(kind: .remote, driveID: drive.driveID, rootItemID: drive.remoteRootItemID, itemID: "item+with/slash")
require(ProviderItemReference.decode(reference.identifier) == reference, "stable identifier round trip")

let graphJSON = """
{
  "id": "child-1",
  "name": "Budget.xlsx",
  "size": 128,
  "eTag": "etag-1",
  "createdDateTime": "2026-09-11T10:00:00Z",
  "lastModifiedDateTime": "2026-09-11T11:00:00.123Z",
  "parentReference": {"driveId": "drive:/with unsafe", "id": "root-item"},
  "file": {"mimeType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}
}
""".data(using: .utf8)!
let decoded = try JSONDecoder.provider.decode(GraphDriveItem.self, from: graphJSON)
require(decoded.name == "Budget.xlsx" && decoded.versionToken == "etag-1", "Graph item decoding")
let movedJSON = Data("""
{"id":"moved","name":"Moved.txt","parentReference":{"driveId":"drive","id":"documents"},"file":{}}
""".utf8)
let movedItem = try JSONDecoder.provider.decode(GraphDriveItem.self, from: movedJSON)
let movedProviderItem = OneDriveProviderItem.remote(movedItem, drive: rootFilesDrive)
let expectedMovedParent = ProviderItemReference(kind: .remote, driveID: "drive", rootItemID: "root", itemID: "documents")
require(movedProviderItem.parentItemIdentifier.rawValue == expectedMovedParent.identifier, "root moves retain their real destination parent")
let rootSiblingJSON = Data("""
{"id":"apps","name":"Apps","parentReference":{"driveId":"drive","id":"root"},"folder":{"childCount":2}}
""".utf8)
let rootSibling = try JSONDecoder.provider.decode(GraphDriveItem.self, from: rootSiblingJSON)
let projectedRootSibling = OneDriveProviderItem.remote(rootSibling, drive: rootFilesDrive, personalDocumentsItemID: "documents")
require(projectedRootSibling.parentItemIdentifier == .rootContainer, "root-only folders do not create an unselected Documents projection")
let deletion = try JSONDecoder.provider.decode(GraphDriveItem.self, from: Data("{\"id\":\"child-1\",\"deleted\":{}}".utf8))
require(deletion.deleted != nil && deletion.name.isEmpty, "business deletion decoding without a name")
let rootFile = try JSONDecoder.provider.decode(GraphDriveItem.self, from: Data("{\"id\":\"root-file\",\"name\":\"root.txt\",\"parentReference\":{\"id\":\"root\"},\"file\":{}}".utf8))
let rootFolder = try JSONDecoder.provider.decode(GraphDriveItem.self, from: Data("{\"id\":\"hidden-folder\",\"name\":\"Hidden\",\"parentReference\":{\"id\":\"root\"},\"folder\":{}}".utf8))
require(projectedConfiguration.isVisibleRootItem(rootFile, on: rootFilesDrive), "root files remain visible in the personal projection")
require(!projectedConfiguration.isVisibleRootItem(rootFolder, on: rootFilesDrive), "unselected personal folders stay hidden")

let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.protocolClasses = [MockURLProtocol.self]
let graph = GraphClient(session: URLSession(configuration: sessionConfiguration), testingAccessToken: "test-token")

MockURLProtocol.handler = { request in
    require(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "authorization header")
    require(request.url?.absoluteString.contains("/drives/drive%3A%2Fwith%20unsafe/items/root-item/children") == true, "escaped children URL")
    let body = Data("{\"value\":[\(String(data: graphJSON, encoding: .utf8)!)],\"@odata.nextLink\":\"https://graph.microsoft.com/next\"}".utf8)
    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
}
let page: GraphPage = try wait { graph.children(driveID: drive.driveID, itemID: drive.remoteRootItemID, pageURL: nil, completion: $0) }
require(page.value.count == 1 && page.nextLink?.absoluteString == "https://graph.microsoft.com/next", "paged enumeration decoding")

let cancellation = DispatchSemaphore(value: 0)
let requestStarted = DispatchSemaphore(value: 0)
MockURLProtocol.holdRequests = true
MockURLProtocol.started = { requestStarted.signal() }
MockURLProtocol.stopped = { cancellation.signal() }
let cancellable = graph.children(driveID: drive.driveID, itemID: drive.remoteRootItemID, pageURL: nil) { _ in }
require(requestStarted.wait(timeout: .now() + 2) == .success, "cancellable request starts")
cancellable.cancel()
require(cancellation.wait(timeout: .now() + 2) == .success, "request cancellation reaches URLSession")
MockURLProtocol.holdRequests = false
MockURLProtocol.started = nil
MockURLProtocol.stopped = nil

MockURLProtocol.handler = { request in
    require(request.httpMethod == "PATCH", "rename uses PATCH")
    require(request.value(forHTTPHeaderField: "If-Match") == "etag-1", "mutation uses optimistic concurrency")
    require(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "rename uses JSON")
    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, graphJSON)
}
let _: GraphDriveItem = try wait { graph.patch(driveID: drive.driveID, itemID: decoded.id, name: "Budget 2027.xlsx", parentID: nil, eTag: decoded.eTag, completion: $0) }

MockURLProtocol.handler = { request in
    require(request.httpMethod == "DELETE", "delete uses DELETE")
    return (HTTPURLResponse(url: request.url!, statusCode: 412, httpVersion: nil, headerFields: nil)!, Data("{\"error\":\"conflict\"}".utf8))
}
do {
    let _: Void = try wait { graph.delete(driveID: drive.driveID, itemID: decoded.id, eTag: decoded.eTag, completion: $0) }
    require(false, "delete conflict must fail")
} catch let GraphError.http(code, _) {
    require(code == 412, "delete preserves Graph conflict status")
}

let state = try ProviderStateStore()
state.cache(decoded, identifier: reference.identifier, materialized: true)
require(state.materializedItems().count == 1, "materialized working set")
let scopeID = "\(drive.driveID)|\(drive.remoteRootItemID)"
state.cache([(reference.identifier, decoded)], deltaLink: URL(string: "https://graph.microsoft.com/delta-token"), scopeID: scopeID)
require(state.revision == 1 && state.deltaLink(for: scopeID) != nil, "durable delta state")
let scopeAnchor = state.anchor(for: [scopeID])
let secondScope = "second-drive|second-root"
state.applyDeltas([
    ProviderDeltaCommit(cached: [(reference.identifier, decoded)], deletedIdentifiers: [], deltaLink: URL(string: "https://graph.microsoft.com/delta-one"), scopeID: scopeID),
    ProviderDeltaCommit(cached: [], deletedIdentifiers: [], deltaLink: URL(string: "https://graph.microsoft.com/delta-two"), scopeID: secondScope)
])
require(state.revision == 2 && state.deltaLink(for: secondScope) != nil, "multi-drive delta commit is atomic")
require(!state.anchorIsCurrent(scopeAnchor, for: [scopeID]), "changed drive invalidates its scoped anchor")
require(state.anchorIsCurrent(state.anchor(for: [secondScope]), for: [secondScope]), "unrelated drive keeps its own scoped anchor current")
state.remove(identifier: reference.identifier)
require(state.materializedItems().isEmpty, "delete clears working set")

print("File Provider contract harness passed")
}
}
