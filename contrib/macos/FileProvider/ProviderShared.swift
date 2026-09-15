import Foundation
import Security

enum ProviderConstants {
    static var appGroup: String {
        let configured = Bundle.main.object(forInfoDictionaryKey: "OneDriveAppGroupIdentifier") as? String
        if let configured, !configured.isEmpty, !configured.contains("$(") { return configured }
        return "group.org.onedrive.cli.macos"
    }
    static let keychainService = "org.onedrive.cli.macos.oauth.v6"
    static let credentialAccount = "microsoft"
    static let domainIdentifier = "org.onedrive.cli.macos.default"
    static let configurationFilename = "provider-configuration.json"
    static let stateFilename = "provider-state.json"
    static let defaultClientID = "d50ca740-c83f-4d1b-b616-12c519384f0c"
}

struct ProviderDrive: Codable, Hashable, Sendable {
    let driveID: String
    let remoteRootItemID: String
    let displayName: String
    let siteName: String?
    let keepDownloaded: Bool
    let rootFilesOnly: Bool

    init(
        driveID: String,
        remoteRootItemID: String,
        displayName: String,
        siteName: String?,
        keepDownloaded: Bool,
        rootFilesOnly: Bool = false
    ) {
        self.driveID = driveID
        self.remoteRootItemID = remoteRootItemID
        self.displayName = displayName
        self.siteName = siteName
        self.keepDownloaded = keepDownloaded
        self.rootFilesOnly = rootFilesOnly
    }

    private enum CodingKeys: String, CodingKey {
        case driveID, remoteRootItemID, displayName, siteName, keepDownloaded, rootFilesOnly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        driveID = try values.decode(String.self, forKey: .driveID)
        remoteRootItemID = try values.decode(String.self, forKey: .remoteRootItemID)
        displayName = try values.decode(String.self, forKey: .displayName)
        siteName = try values.decodeIfPresent(String.self, forKey: .siteName)
        keepDownloaded = try values.decode(Bool.self, forKey: .keepDownloaded)
        rootFilesOnly = try values.decodeIfPresent(Bool.self, forKey: .rootFilesOnly) ?? false
    }
}

struct ProviderOfflineItem: Codable, Hashable, Sendable {
    let driveID: String
    let itemID: String
}

enum ProviderCachePolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case spaceSaver
    case smart
    case alwaysAvailable
}

struct ProviderCacheOverride: Codable, Hashable, Sendable {
    let driveID: String
    let itemID: String
    let policy: ProviderCachePolicy
}

// Keep the shared configuration model independent from GraphClient.swift.
// The main app target compiles this file without the Graph client, while the
// extension and harness provide the concrete GraphDriveItem conformance.
protocol ProviderVisibilityItem {
    var providerItemIsDeleted: Bool { get }
    var providerItemIsFolder: Bool { get }
    var providerItemParentID: String? { get }
}

struct ProviderConfiguration: Codable, Sendable {
    let accountName: String
    let accountEmail: String
    let drives: [ProviderDrive]
    let offlineItems: Set<ProviderOfflineItem>
    let globalCachePolicy: ProviderCachePolicy
    let cacheOverrides: Set<ProviderCacheOverride>

    init(
        accountName: String,
        accountEmail: String,
        drives: [ProviderDrive],
        offlineItems: Set<ProviderOfflineItem> = [],
        globalCachePolicy: ProviderCachePolicy = .smart,
        cacheOverrides: Set<ProviderCacheOverride> = []
    ) {
        self.accountName = accountName
        self.accountEmail = accountEmail
        self.drives = drives
        self.offlineItems = offlineItems
        self.globalCachePolicy = globalCachePolicy
        self.cacheOverrides = cacheOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case accountName, accountEmail, drives, offlineItems, globalCachePolicy, cacheOverrides
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountName = try values.decode(String.self, forKey: .accountName)
        accountEmail = try values.decode(String.self, forKey: .accountEmail)
        drives = try values.decode([ProviderDrive].self, forKey: .drives)
        offlineItems = try values.decodeIfPresent(Set<ProviderOfflineItem>.self, forKey: .offlineItems) ?? []
        globalCachePolicy = try values.decodeIfPresent(ProviderCachePolicy.self, forKey: .globalCachePolicy) ?? .smart
        if let decoded = try values.decodeIfPresent(Set<ProviderCacheOverride>.self, forKey: .cacheOverrides) {
            cacheOverrides = decoded
        } else {
            cacheOverrides = Set(offlineItems.map {
                ProviderCacheOverride(driveID: $0.driveID, itemID: $0.itemID, policy: .alwaysAvailable)
            })
        }
    }
}

extension ProviderConfiguration {
    func drive(for reference: ProviderItemReference) -> ProviderDrive? {
        drives.first { $0.driveID == reference.driveID && $0.remoteRootItemID == reference.rootItemID }
    }

    func cachePolicyOverride(driveID: String, itemID: String, rootItemID: String? = nil) -> ProviderCachePolicy? {
        if let exact = cacheOverrides.first(where: { $0.driveID == driveID && $0.itemID == itemID }) {
            return exact.policy
        }

        // An override on a drive root is a drive-wide preference.  This is
        // especially important for the synthetic root-files projection: its
        // descendants have the same drive ID but are not descendants of a
        // separately mounted provider item.
        let rootIDs = rootItemID.map { Set([$0]) } ?? Set(drives.filter { $0.driveID == driveID }.map(\.remoteRootItemID))
        return cacheOverrides.first { $0.driveID == driveID && rootIDs.contains($0.itemID) }?.policy
    }

    var personalRootDrive: ProviderDrive? { drives.first(where: \.rootFilesOnly) }

    var personalProjectionDrives: [ProviderDrive] {
        guard let root = personalRootDrive else { return [] }
        return drives.filter {
            !$0.rootFilesOnly && $0.driveID == root.driveID && $0.siteName == nil
        }
    }

    var personalDocumentsItemID: String? {
        guard let root = personalRootDrive else { return nil }
        return drives.first {
            !$0.rootFilesOnly &&
                $0.driveID == root.driveID &&
                $0.siteName == nil &&
                ["documents", "dokumente"].contains($0.displayName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).lowercased())
        }?.remoteRootItemID
    }

    var personalFolderIDs: Set<String> {
        guard let root = personalRootDrive else { return [] }
        return Set(drives.filter {
            !$0.rootFilesOnly && $0.driveID == root.driveID && $0.siteName == nil && $0.remoteRootItemID != root.remoteRootItemID
        }.map(\.remoteRootItemID))
    }

    var showsWholePersonalDrive: Bool {
        guard let root = personalRootDrive else { return false }
        return drives.contains {
            !$0.rootFilesOnly && $0.driveID == root.driveID && $0.siteName == nil && $0.remoteRootItemID == root.remoteRootItemID
        }
    }

    var visibleMountDrives: [ProviderDrive] {
        // Every configured non-root drive is a real projection.  Keeping
        // personal projections as mounts makes a selected nested folder
        // reachable even when none of its ancestors was selected.
        drives.filter { !$0.rootFilesOnly }
    }

    var enumeratedDrives: [ProviderDrive] {
        guard let root = personalRootDrive else { return visibleMountDrives }
        return [root] + visibleMountDrives
    }

    var allowsDomainRootWrites: Bool {
        showsWholePersonalDrive
    }

    func isVisibleRootItem(_ item: ProviderVisibilityItem, on drive: ProviderDrive) -> Bool {
        guard !item.providerItemIsDeleted else { return false }
        guard drive.rootFilesOnly else { return true }
        // The root-files projection intentionally contains files only.  All
        // selected folders are represented by their own projection/mount.
        return !item.providerItemIsFolder && item.providerItemParentID == drive.remoteRootItemID
    }

    func isVisible(_ item: ProviderVisibilityItem, on drive: ProviderDrive) -> Bool {
        if drive.rootFilesOnly { return isVisibleRootItem(item, on: drive) }
        return !item.providerItemIsDeleted
    }

    func allowsMutation(of reference: ProviderItemReference) -> Bool {
        guard let providerDrive = self.drive(for: reference) else { return false }
        return !providerDrive.rootFilesOnly || allowsDomainRootWrites
    }
}

struct ProviderCredential: Codable, Sendable {
    var refreshToken: String
    let clientID: String
    let tenantID: String
    let authEndpoint: String
    let graphEndpoint: String

    init(
        refreshToken: String,
        clientID: String = ProviderConstants.defaultClientID,
        tenantID: String = "common",
        authEndpoint: String = "https://login.microsoftonline.com",
        graphEndpoint: String = "https://graph.microsoft.com"
    ) {
        self.refreshToken = refreshToken
        self.clientID = clientID
        self.tenantID = tenantID
        self.authEndpoint = authEndpoint
        self.graphEndpoint = graphEndpoint
    }
}

enum ProviderFiles {
    static func containerURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["ONEDRIVE_PROVIDER_STATE_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ProviderConstants.appGroup
        ) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The OneDrive App Group is unavailable. Check the app signature and entitlements."
            ])
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func configurationURL() throws -> URL {
        try containerURL().appendingPathComponent(ProviderConstants.configurationFilename)
    }

    static func stateURL() throws -> URL {
        try containerURL().appendingPathComponent(ProviderConstants.stateFilename)
    }
}

final class ProviderConfigurationStore {
    func load() throws -> ProviderConfiguration {
        let data = try Data(contentsOf: ProviderFiles.configurationURL())
        return try JSONDecoder.provider.decode(ProviderConfiguration.self, from: data)
    }

    func save(_ configuration: ProviderConfiguration) throws {
        let data = try JSONEncoder.provider.encode(configuration)
        try data.write(to: ProviderFiles.configurationURL(), options: .atomic)
    }
}

final class SharedCredentialStore {
    private var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "OneDriveKeychainAccessGroup") as? String
    }

    func load() throws -> ProviderCredential {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status, fallback: "OneDrive credentials are unavailable. Sign in again.")
        }
        return try JSONDecoder.provider.decode(ProviderCredential.self, from: data)
    }

    func save(_ credential: ProviderCredential) throws {
        let data = try JSONEncoder.provider.encode(credential)
        let query = baseQuery
        let values = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw keychainError(status, fallback: "Couldn’t save OneDrive credentials.") }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus, fallback: "Couldn’t update OneDrive credentials.")
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ProviderConstants.keychainService,
            kSecAttrAccount as String: ProviderConstants.credentialAccount,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup, !accessGroup.isEmpty, !accessGroup.contains("$(") {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func keychainError(_ status: OSStatus, fallback: String) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? fallback
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct ProviderItemReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case mount, remote }
    let kind: Kind
    let driveID: String
    let rootItemID: String
    let itemID: String

    var identifier: String {
        let payload = try? JSONEncoder.provider.encode(self)
        return "od:\((payload ?? Data()).base64URLEncodedString())"
    }

    static func decode(_ rawValue: String) -> ProviderItemReference? {
        guard rawValue.hasPrefix("od:"), let data = Data(base64URLString: String(rawValue.dropFirst(3))) else { return nil }
        return try? JSONDecoder.provider.decode(Self.self, from: data)
    }
}

extension JSONEncoder {
    static var provider: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var provider: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(raw)")
        }
        return decoder
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
