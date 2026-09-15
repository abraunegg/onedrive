/*
 THESIS: OneDrive setup is a short guided promise—sign in, choose folders, done—not a control panel of engine switches.
 OWN-WORLD: Native macOS typography and controls sit on quiet cloud-white surfaces with decisive OneDrive blue and a compact Finder-like folder list.
 STORY: The user connects a Microsoft account, chooses personal or work folders, then sees every synced location in one editable grid.
 FIRST VIEWPORT: A centered cloud mark, one sentence, and one Microsoft sign-in button; no paths, logs, or secondary actions compete with it.
 FORM: A calm cloud shelf with a three-step onboarding flow and an expandable selective-sync list, seed 6901841d.
*/

import AppKit
import FileProvider
import Foundation
import ServiceManagement

private let oneDriveBlue = NSColor(calibratedRed: 0.0, green: 0.47, blue: 0.88, alpha: 1)

private struct RemoteFolder: Codable, Hashable {
    let id: String
    let name: String
    let path: String
    let childCount: Int?
    let driveId: String?
    let siteName: String?
    let libraryName: String?
    let isLibraryRoot: Bool

    init(id: String, name: String, path: String, childCount: Int?, driveId: String? = nil, siteName: String? = nil, libraryName: String? = nil, isLibraryRoot: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.childCount = childCount
        self.driveId = driveId
        self.siteName = siteName
        self.libraryName = libraryName
        self.isLibraryRoot = isLibraryRoot
    }

    private enum CodingKeys: String, CodingKey { case id, name, path, childCount, driveId, siteName, libraryName, isLibraryRoot }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        childCount = try values.decodeIfPresent(Int.self, forKey: .childCount)
        driveId = try values.decodeIfPresent(String.self, forKey: .driveId)
        siteName = try values.decodeIfPresent(String.self, forKey: .siteName)
        libraryName = try values.decodeIfPresent(String.self, forKey: .libraryName)
        isLibraryRoot = try values.decodeIfPresent(Bool.self, forKey: .isLibraryRoot) ?? false
    }
}

private struct DiscoveryPayload: Codable {
    let accountType: String?
    let accountName: String?
    let accountEmail: String?
    let driveId: String?
    let rootId: String?
    let folders: [RemoteFolder]
}

private struct DeviceAuthPayload: Codable {
    let url: String
    let code: String
    let expiresIn: Int
}

private struct RemoteLibrary: Codable {
    let id: String
    let name: String
    let siteName: String
    let driveId: String
    let childCount: Int?
}

private struct LibraryPayload: Codable {
    let libraries: [RemoteLibrary]
    let shortcuts: [RemoteShortcut]?
}

private struct RemoteShortcut: Codable {
    let id: String
    let name: String
    let driveId: String
    let path: String
    let childCount: Int?
}

private struct SyncLocation: Codable, Hashable {
    let id: String
    let name: String
    let path: String
    let driveId: String?
    let siteName: String?
    let libraryName: String?

    init(id: String, name: String, path: String, driveId: String? = nil, siteName: String? = nil, libraryName: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.driveId = driveId
        self.siteName = siteName
        self.libraryName = libraryName
    }
}

private final class OutputCollector {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class SurfaceView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class FolderListStack: NSStackView {
    override var isFlipped: Bool { true }
}

private final class FolderNode {
    let folder: RemoteFolder
    private let selectionIDOverride: String?
    weak var parent: FolderNode?
    var children: [FolderNode]?
    var isExpanded = false
    var isLoading = false
    var providerError: String?

    init(folder: RemoteFolder, parent: FolderNode? = nil, selectionIDOverride: String? = nil) {
        self.folder = folder
        self.parent = parent
        self.selectionIDOverride = selectionIDOverride
    }

    var depth: Int { (parent?.depth ?? -1) + 1 }
    var selectionID: String { selectionIDOverride ?? folder.driveId.map { "\($0):\(folder.id)" } ?? folder.id }
}

private final class FolderActionButton: NSButton {
    let folderID: String
    init(folderID: String, title: String = "", target: AnyObject?, action: Selector) {
        self.folderID = folderID
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { nil }
}

private final class FolderCachePopUpButton: NSPopUpButton {
    let folderID: String?
    init(folderID: String?, target: AnyObject?, action: Selector) {
        self.folderID = folderID
        super.init(frame: .zero, pullsDown: false)
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { nil }
}

private final class SiteActionButton: NSButton {
    let siteName: String
    init(siteName: String, target: AnyObject?, action: Selector) {
        self.siteName = siteName
        super.init(frame: .zero)
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { nil }
}

private final class DashboardSectionButton: NSButton {
    let sectionID: String
    init(sectionID: String, target: AnyObject?, action: Selector) {
        self.sectionID = sectionID
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
    }
    required init?(coder: NSCoder) { nil }
}

final class OneDriveAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let locationsKey = "syncLocations"
    private let syncDirectoryKey = "syncDirectory"
    private let accountNameKey = "accountName"
    private let accountEmailKey = "accountEmail"
    private let accountTypeKey = "accountType"
    private let syncReadyKey = "syncReady"
    private let primaryDriveIDKey = "primaryDriveID"
    private let primaryRootIDKey = "primaryRootID"
    private let offlineLocationsKey = "offlineLocations"
    private let globalCachePolicyKey = "globalCachePolicy"
    private let cacheOverridesKey = "cacheOverrides"
    private let folderMetadataCacheFilename = "folder-metadata-cache.json"
    private let providerReadyKey = "providerReady"
    private let providerStorageVersionKey = "providerStorageVersion"
    private let currentProviderStorageVersion = 11

    private var window: NSWindow!
    private var diagnosticsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var statusMenuLabel: NSMenuItem!
    private var currentProcess: Process?
    private var monitorProcesses: [String: Process] = [:]
    private var diagnostics = ""
    private var availableFolders: [RemoteFolder] = []
    private var previewLocations: [SyncLocation]?
    private var previewAccountName: String?
    private var previewAccountEmail: String?
    private var previewAccountType: String?
    private var selectedFolderIDs = Set<String>()
    private var selectedGlobalCachePolicy: ProviderCachePolicy = .smart
    private var selectedCacheOverrides: [String: ProviderCachePolicy] = [:]
    private var selectionWasAutoInferred = false
    private var folderRoots: [FolderNode] = []
    private var libraryRoots: [FolderNode] = []
    private var expandedLibrarySites = Set<String>()
    private var expandedDashboardSections = Set<String>()
    private var dashboardRoots: [String: FolderNode] = [:]
    private var dashboardListStack: NSStackView?
    private var providerMutationInFlight = false
    private var folderMetadataCache: [String: [RemoteFolder]] = [:]
    private var folderListStack: NSStackView?
    private var syncEverythingButton: NSButton?
    private var selectionSummaryLabel: NSTextField?
    private var folderSearchField: NSSearchField?
    private var statusText = "Ready"
    private var deviceAuthCode = ""
    private var deviceAuthURL: URL?
    private let providerCoordinator = ProviderCoordinator()

    private var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OneDrive Native", isDirectory: true)
    }

    private var engineDirectory: URL {
        configDirectory.appendingPathComponent("Engine", isDirectory: true)
    }

    private var syncDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: syncDirectoryKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OneDrive", isDirectory: true)
    }

    private var savedLocations: [SyncLocation] {
        if let previewLocations { return previewLocations }
        guard let data = UserDefaults.standard.data(forKey: locationsKey) else { return [] }
        return (try? JSONDecoder().decode([SyncLocation].self, from: data)) ?? []
    }

    private var isAuthenticated: Bool {
        let token = configDirectory.appendingPathComponent("refresh_token")
        return (try? token.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        loadFolderMetadataCache()
        recoverSavedLocationsFromProviderIfNeeded()
        setupWindow()
        setupMenuBar()

        if CommandLine.arguments.contains("--repair-finder-layout") {
            repairFinderLayout()
            showMainWindow()
            return
        }

        let preview = ProcessInfo.processInfo.environment["ONEDRIVE_UI_PREVIEW"]
        if preview == "welcome" {
            showWelcome()
        } else if preview == "device" {
            showDeviceCode(DeviceAuthPayload(url: "https://microsoft.com/devicelogin", code: "F7K9-WQ2M", expiresIn: 900), openBrowser: false)
        } else if preview == "dashboard" {
            seedPreviewData()
            showDashboard()
        } else if preview == "entitlement" {
            seedPreviewData()
            showDashboard(error: "Couldn’t start Files On-Demand: A required entitlement isn’t present.")
        } else if preview == "picker" {
            seedPreviewData()
            showFolderPicker(editing: false)
        } else if preview == "fileprovider" {
            seedPreviewData()
            showFolderPicker(editing: false)
        } else if isAuthenticated {
            if savedLocations.isEmpty {
                discoverFolders(editing: false)
            } else {
                let defaults = UserDefaults.standard
                let needsStorageMigration = defaults.integer(forKey: providerStorageVersionKey) < currentProviderStorageVersion
                let ready = defaults.bool(forKey: providerReadyKey) && providerCoordinator.hasConfiguration() && !needsStorageMigration
                if ready {
                    showDashboard()
                } else {
                    activateProvider(
                        locations: savedLocations,
                        title: needsStorageMigration ? "Repairing OneDrive in Finder…" : "Adding OneDrive to Finder…"
                    )
                }
            }
        } else {
            showWelcome()
        }

        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        currentProcess?.terminate()
        for process in monitorProcesses.values { process.terminate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            window.orderOut(nil)
            return false
        }
        return true
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OneDrive"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 680, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let icon = Bundle.main.image(forResource: "MenuBarIcon") {
                icon.isTemplate = true
                icon.size = NSSize(width: 22, height: 22)
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "OneDrive")
            }
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "OneDrive"
        }

        let menu = NSMenu()
        statusMenuLabel = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuLabel.isEnabled = false
        menu.addItem(statusMenuLabel)
        menu.addItem(.separator())
        menu.addItem(menuItem("Open OneDrive", #selector(showMainWindow)))
        menu.addItem(menuItem("Refresh Finder", #selector(syncNow)))
        menu.addItem(menuItem("Choose folders…", #selector(manageFolders)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Diagnostics…", #selector(showDiagnostics)))
        menu.addItem(menuItem("Repair Finder layout", #selector(repairFinderLayout)))
        menu.addItem(menuItem("Quit OneDrive", #selector(quitApp), key: "q"))
        statusItem.menu = menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func showWelcome(message: String? = nil) {
        setStatus("Not connected")
        let outer = pageStack(alignment: .centerX, spacing: 18)
        outer.edgeInsets = NSEdgeInsets(top: 78, left: 82, bottom: 70, right: 82)
        outer.addArrangedSubview(brandIcon(size: 86))

        let title = label("Your files, right where you work", size: 31, weight: .bold, color: .labelColor)
        title.alignment = .center
        outer.addArrangedSubview(title)

        let subtitle = label("Connect Microsoft once. Then choose exactly what belongs on this Mac.", size: 16, weight: .regular, color: .secondaryLabelColor)
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 510
        outer.addArrangedSubview(subtitle)

        if let message {
            let notice = label(message, size: 13, weight: .regular, color: .systemRed)
            notice.alignment = .center
            notice.maximumNumberOfLines = 3
            notice.preferredMaxLayoutWidth = 500
            outer.addArrangedSubview(notice)
        }

        let signIn = primaryButton("Continue with Microsoft", action: #selector(signIn))
        signIn.widthAnchor.constraint(equalToConstant: 250).isActive = true
        signIn.heightAnchor.constraint(equalToConstant: 42).isActive = true
        outer.addArrangedSubview(signIn)

        let privacy = label("Use your personal, work, or school Microsoft account. Your password is never stored by this app.", size: 12, weight: .regular, color: .tertiaryLabelColor)
        privacy.alignment = .center
        outer.addArrangedSubview(privacy)
        setContent(outer)
    }

    @objc private func signIn() {
        setStatus("Waiting for sign-in")
        showProgress(
            title: "Finish signing in in your browser",
            detail: "OneDrive will continue here automatically when Microsoft confirms your account."
        )
        executeCLI(arguments: ["--gui-browser-auth"]) { [weak self] code, output in
            guard let self else { return }
            self.addDiagnostic("SIGN IN", output)
            if self.isAuthenticated {
                self.discoverFolders(editing: false)
            } else {
                let detail = output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .last { !$0.isEmpty && !$0.hasPrefix("ONEDRIVE_DEVICE_AUTH=") }
                let message: String
                if output.localizedCaseInsensitiveContains("expired") {
                    message = "That sign-in code expired. Please request a new one."
                } else if let detail {
                    message = "We couldn’t finish signing in. \(detail)"
                } else {
                    message = "We couldn’t start Microsoft sign-in. Please try again."
                }
                self.showWelcome(message: message)
            }
        }
    }

    private func parseDeviceAuth(_ output: String) -> DeviceAuthPayload? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("ONEDRIVE_DEVICE_AUTH=") }) else { return nil }
        let json = line.dropFirst("ONEDRIVE_DEVICE_AUTH=".count)
        return try? JSONDecoder().decode(DeviceAuthPayload.self, from: Data(json.utf8))
    }

    private func showDeviceCode(_ payload: DeviceAuthPayload, openBrowser: Bool) {
        deviceAuthCode = payload.code
        deviceAuthURL = URL(string: payload.url)
        setStatus("Waiting for sign-in")

        let stack = pageStack(alignment: .centerX, spacing: 16)
        stack.edgeInsets = NSEdgeInsets(top: 112, left: 78, bottom: 38, right: 78)
        stack.addArrangedSubview(brandIcon(size: 62))
        let title = label("Sign in to Microsoft", size: 28, weight: .bold, color: .labelColor)
        title.alignment = .center
        stack.addArrangedSubview(title)
        let copy = label("Enter this code, then sign in with your work or school account:", size: 14, weight: .regular, color: .secondaryLabelColor)
        copy.alignment = .center
        stack.addArrangedSubview(copy)

        let code = label(payload.code, size: 30, weight: .bold, color: .labelColor)
        code.font = .monospacedSystemFont(ofSize: 30, weight: .bold)
        code.alignment = .center
        code.drawsBackground = true
        code.backgroundColor = .controlBackgroundColor
        code.wantsLayer = true
        code.layer?.cornerRadius = 12
        code.translatesAutoresizingMaskIntoConstraints = false
        code.widthAnchor.constraint(equalToConstant: 280).isActive = true
        code.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(code)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.addArrangedSubview(linkButton("Copy code", action: #selector(copyDeviceCode)))
        actions.addArrangedSubview(primaryButton("Open Microsoft sign-in", action: #selector(openDeviceAuthPage)))
        stack.addArrangedSubview(actions)

        let waiting = NSStackView()
        waiting.orientation = .horizontal
        waiting.spacing = 8
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        waiting.addArrangedSubview(spinner)
        waiting.addArrangedSubview(label("Waiting for you to finish…", size: 13, weight: .regular, color: .secondaryLabelColor))
        stack.addArrangedSubview(waiting)
        stack.addArrangedSubview(linkButton("Cancel", action: #selector(cancelSignIn)))
        setContent(stack)

        if openBrowser, let deviceAuthURL { NSWorkspace.shared.open(deviceAuthURL) }
    }

    @objc private func copyDeviceCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceAuthCode, forType: .string)
    }

    @objc private func openDeviceAuthPage() {
        if let deviceAuthURL { NSWorkspace.shared.open(deviceAuthURL) }
    }

    @objc private func cancelSignIn() {
        currentProcess?.terminate()
        currentProcess = nil
        showWelcome()
    }

    private func showProgress(title: String, detail: String) {
        let stack = pageStack(alignment: .centerX, spacing: 18)
        stack.edgeInsets = NSEdgeInsets(top: 150, left: 70, bottom: 100, right: 70)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)
        let heading = label(title, size: 24, weight: .semibold, color: .labelColor)
        heading.alignment = .center
        stack.addArrangedSubview(heading)
        let copy = label(detail, size: 14, weight: .regular, color: .secondaryLabelColor)
        copy.alignment = .center
        copy.maximumNumberOfLines = 2
        stack.addArrangedSubview(copy)
        setContent(stack)
    }

    private func discoverFolders(editing: Bool) {
        showProgress(title: "Finding your folders…", detail: "This usually takes a few seconds.")
        executeDiscoveryCLI(arguments: ["--gui-list-folders-json"]) { [weak self] code, output in
            guard let self else { return }
            self.addDiagnostic("FOLDER DISCOVERY", output)
            guard code == 0, let payload = self.parseDiscovery(output) else {
                let detail = output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .last { !$0.isEmpty && !$0.hasPrefix("ONEDRIVE_GUI_JSON=") }
                let message = detail.map { "Connected, but we couldn’t load your folders. \($0)" }
                    ?? "Connected, but we couldn’t load your folders. Please try again."
                self.showWelcome(message: message)
                return
            }
            self.availableFolders = payload.folders
            self.folderRoots = payload.folders.map { FolderNode(folder: $0) }
            self.folderRoots.forEach(self.hydrateCachedChildren)
            self.saveAccount(payload)
            if payload.accountType?.localizedCaseInsensitiveContains("business") == true {
                self.discoverLibraries(editing: editing)
            } else {
                self.libraryRoots = []
                self.showFolderPicker(editing: editing)
            }
        }
    }

    private func discoverLibraries(editing: Bool) {
        executeDiscoveryCLI(arguments: ["--gui-list-libraries-json"]) { [weak self] code, output in
            guard let self else { return }
            self.addDiagnostic("LIBRARY DISCOVERY", output)
            if code == 0, let payload = self.parseLibraries(output) {
                var shortcutsByDrive: [String: RemoteShortcut] = [:]
                for shortcut in payload.shortcuts ?? [] where shortcutsByDrive[shortcut.driveId] == nil {
                    shortcutsByDrive[shortcut.driveId] = shortcut
                }
                var knownDriveIds = Set<String>()
                var roots = payload.libraries
                    .sorted {
                        let left = "\($0.siteName) \($0.name)"
                        let right = "\($1.siteName) \($1.name)"
                        return left.localizedStandardCompare(right) == .orderedAscending
                    }
                    .map { library in
                        knownDriveIds.insert(library.driveId)
                        let shortcut = shortcutsByDrive[library.driveId]
                        let display = shortcut.map { self.libraryDisplayName(from: $0.name) }
                        return FolderNode(folder: RemoteFolder(
                            id: library.id,
                            name: display?.library ?? library.name,
                            path: "/",
                            childCount: library.childCount,
                            driveId: library.driveId,
                            siteName: display?.site ?? library.siteName,
                            libraryName: display?.library ?? library.name,
                            isLibraryRoot: true
                        ))
                    }
                for shortcut in payload.shortcuts ?? [] where !knownDriveIds.contains(shortcut.driveId) {
                    let display = self.libraryDisplayName(from: shortcut.name)
                    roots.append(FolderNode(folder: RemoteFolder(
                        id: shortcut.id,
                        name: display.library,
                        path: shortcut.path,
                        childCount: shortcut.childCount,
                        driveId: shortcut.driveId,
                        siteName: display.site,
                        libraryName: display.library,
                        isLibraryRoot: true
                    )))
                }
                self.libraryRoots = roots.sorted {
                    let left = "\($0.folder.siteName ?? "") \($0.folder.name)"
                    let right = "\($1.folder.siteName ?? "") \($1.folder.name)"
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                self.libraryRoots.forEach(self.hydrateCachedChildren)
            } else {
                self.libraryRoots = []
            }
            self.showFolderPicker(editing: editing)
        }
    }

    private func parseDiscovery(_ output: String) -> DiscoveryPayload? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("ONEDRIVE_GUI_JSON=") }) else { return nil }
        let json = line.dropFirst("ONEDRIVE_GUI_JSON=".count)
        return try? JSONDecoder().decode(DiscoveryPayload.self, from: Data(json.utf8))
    }

    private func parseLibraries(_ output: String) -> LibraryPayload? {
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("ONEDRIVE_GUI_LIBRARIES=") }) else { return nil }
        let json = line.dropFirst("ONEDRIVE_GUI_LIBRARIES=".count)
        return try? JSONDecoder().decode(LibraryPayload.self, from: Data(json.utf8))
    }

    private var folderMetadataCacheURL: URL {
        configDirectory.appendingPathComponent(folderMetadataCacheFilename, isDirectory: false)
    }

    private func folderMetadataCacheKey(for folder: RemoteFolder) -> String {
        let account = UserDefaults.standard.string(forKey: accountEmailKey) ?? "account"
        return "\(account)|\(folder.driveId ?? "personal")|\(folder.id)"
    }

    private func loadFolderMetadataCache() {
        guard let data = try? Data(contentsOf: folderMetadataCacheURL),
              let cache = try? JSONDecoder().decode([String: [RemoteFolder]].self, from: data) else { return }
        folderMetadataCache = cache
    }

    private func saveFolderMetadataCache() {
        guard let data = try? JSONEncoder().encode(folderMetadataCache) else { return }
        try? data.write(to: folderMetadataCacheURL, options: .atomic)
    }

    private func cachedChildren(for node: FolderNode, visited: inout Set<String>) -> [FolderNode]? {
        let key = folderMetadataCacheKey(for: node.folder)
        guard visited.insert(key).inserted, let cached = folderMetadataCache[key] else { return nil }
        return cached.map { folder in
            let child = FolderNode(folder: RemoteFolder(
                id: folder.id,
                name: folder.name,
                path: folder.path,
                childCount: folder.childCount,
                driveId: node.folder.driveId,
                siteName: node.folder.siteName,
                libraryName: node.folder.libraryName
            ), parent: node)
            child.children = cachedChildren(for: child, visited: &visited)
            return child
        }
    }

    private func hydrateCachedChildren(for node: FolderNode) {
        var visited = Set<String>()
        node.children = cachedChildren(for: node, visited: &visited)
    }

    private func cacheChildren(_ folders: [RemoteFolder], for node: FolderNode) {
        folderMetadataCache[folderMetadataCacheKey(for: node.folder)] = folders.map { folder in
            RemoteFolder(
                id: folder.id,
                name: folder.name,
                path: folder.path,
                childCount: folder.childCount,
                driveId: node.folder.driveId,
                siteName: node.folder.siteName,
                libraryName: node.folder.libraryName
            )
        }
        saveFolderMetadataCache()
    }

    private func libraryDisplayName(from shortcutName: String) -> (site: String, library: String) {
        let parts = shortcutName.components(separatedBy: " - ")
        guard parts.count > 1 else { return ("Company shortcuts", shortcutName) }
        return (parts[0], parts.dropFirst().joined(separator: " - "))
    }

    private func saveAccount(_ payload: DiscoveryPayload) {
        let defaults = UserDefaults.standard
        defaults.set(payload.accountName, forKey: accountNameKey)
        defaults.set(payload.accountEmail, forKey: accountEmailKey)
        defaults.set(payload.accountType, forKey: accountTypeKey)
        defaults.set(payload.driveId, forKey: primaryDriveIDKey)
        defaults.set(payload.rootId, forKey: primaryRootIDKey)
    }

    private func recoverSavedLocationsFromProviderIfNeeded() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: locationsKey),
           let locations = try? JSONDecoder().decode([SyncLocation].self, from: data),
           !locations.isEmpty { return }
        guard let configuration = providerCoordinator.existingConfiguration(),
              !configuration.drives.isEmpty else { return }
        if let currentEmail = defaults.string(forKey: accountEmailKey),
           !currentEmail.isEmpty,
           currentEmail.localizedCaseInsensitiveCompare(configuration.accountEmail) != .orderedSame { return }

        let personalRoot = configuration.personalRootDrive
        let locations = configuration.drives.compactMap { drive -> SyncLocation? in
            guard !drive.rootFilesOnly else { return nil }
            if let personalRoot, drive.driveID == personalRoot.driveID, drive.siteName == nil {
                if drive.remoteRootItemID == personalRoot.remoteRootItemID {
                    return SyncLocation(id: "__all__", name: "Everything in OneDrive", path: "/")
                }
                return SyncLocation(id: drive.remoteRootItemID, name: drive.displayName, path: drive.displayName)
            }
            let siteName = drive.siteName ?? "Company"
            let prefix = "\(siteName) — "
            let libraryName = drive.displayName.hasPrefix(prefix)
                ? String(drive.displayName.dropFirst(prefix.count))
                : drive.displayName
            return SyncLocation(
                id: "\(drive.driveID):\(drive.remoteRootItemID)",
                name: "\(siteName) — \(libraryName)",
                path: "/",
                driveId: drive.driveID,
                siteName: siteName,
                libraryName: libraryName
            )
        }
        guard !locations.isEmpty, let data = try? JSONEncoder().encode(locations) else { return }
        defaults.set(data, forKey: locationsKey)
        if defaults.string(forKey: accountNameKey) == nil { defaults.set(configuration.accountName, forKey: accountNameKey) }
        if defaults.string(forKey: accountEmailKey) == nil { defaults.set(configuration.accountEmail, forKey: accountEmailKey) }
    }

    private func showFolderPicker(editing: Bool) {
        if availableFolders.isEmpty && editing {
            discoverFolders(editing: true)
            return
        }
        if folderRoots.isEmpty {
            folderRoots = availableFolders.map { FolderNode(folder: $0) }
            folderRoots.forEach(hydrateCachedChildren)
        }

        selectedFolderIDs = Set(savedLocations.map(\.id))
        selectedGlobalCachePolicy = savedGlobalCachePolicy()
        selectedCacheOverrides = savedCacheOverrides()
        selectionWasAutoInferred = false
        if selectedFolderIDs.isEmpty {
            let localMatches = inferredSelectionsForCurrentSetup(in: syncDirectory)
            selectedFolderIDs = localMatches.isEmpty ? ["__all__"] : localMatches
            for id in localMatches { selectedCacheOverrides[id] = .alwaysAvailable }
            selectionWasAutoInferred = !localMatches.isEmpty
            expandSitesContainingSelectedLibraries()
        }

        let root = SurfaceView()
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 12
        page.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 42),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -42),
            page.topAnchor.constraint(equalTo: root.topAnchor, constant: 48),
        page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28)
        ])

        page.addArrangedSubview(label("Choose what appears in Finder", size: 28, weight: .bold, color: .labelColor))
        let pickerHelp = label("Choose one storage default, then override only the folders that need different behavior.", size: 14, weight: .regular, color: .secondaryLabelColor)
        pickerHelp.maximumNumberOfLines = 2
        page.addArrangedSubview(pickerHelp)

        let destination = NSStackView()
        destination.orientation = .horizontal
        destination.spacing = 6
        let storageIcon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: nil) ?? NSImage())
        storageIcon.contentTintColor = oneDriveBlue
        destination.addArrangedSubview(storageIcon)
        destination.addArrangedSubview(label("Default storage", size: 13, weight: .medium, color: .secondaryLabelColor))
        destination.addArrangedSubview(cachePolicyPopUp(folderID: nil, selection: selectedGlobalCachePolicy, inherits: false, action: #selector(changeGlobalCachePolicy(_:))))
        if !selectedCacheOverrides.isEmpty {
            destination.addArrangedSubview(linkButton("Reset folder overrides", action: #selector(resetCacheOverrides)))
        }
        page.addArrangedSubview(destination)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        let everything = NSButton(checkboxWithTitle: "Show all OneDrive folders", target: self, action: #selector(toggleEverything(_:)))
        everything.font = .systemFont(ofSize: 14, weight: .semibold)
        everything.state = selectedFolderIDs.contains("__all__") ? .on : .off
        syncEverythingButton = everything
        controls.addArrangedSubview(everything)
        let controlSpacer = NSView()
        controlSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.addArrangedSubview(controlSpacer)
        let search = NSSearchField()
        search.placeholderString = "Search folders"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filterFolders(_:))
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        folderSearchField = search
        controls.addArrangedSubview(search)
        page.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true

        let list = FolderListStack()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        folderListStack = list
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        page.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scroll.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        rebuildFolderList()

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        let selected = label(selectionSummary(), size: 13, weight: .regular, color: .secondaryLabelColor)
        selectionSummaryLabel = selected
        footer.addArrangedSubview(selected)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(primaryButton(editing ? "Save changes" : "Set up in Finder", action: #selector(saveFolderSelection)))
        page.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        setContent(root)
    }

    @objc private func toggleEverything(_ sender: NSButton) {
        selectionWasAutoInferred = false
        for node in allFolderNodes() where node.folder.driveId == nil {
            selectedFolderIDs.remove(node.selectionID)
            if sender.state == .off { selectedCacheOverrides.removeValue(forKey: node.selectionID) }
        }
        if sender.state == .on { selectedFolderIDs.insert("__all__") }
        else { selectedFolderIDs.remove("__all__") }
        rebuildFolderList()
        updateSelectionSummary()
    }

    @objc private func filterFolders(_ sender: NSSearchField) { rebuildFolderList() }

    @objc private func toggleFolder(_ sender: FolderActionButton) {
        guard let node = node(withID: sender.folderID) else { return }
        selectionWasAutoInferred = false
        selectedFolderIDs.remove("__all__")
        if selectedFolderIDs.contains(node.selectionID) {
            selectedFolderIDs.remove(node.selectionID)
            selectedCacheOverrides.removeValue(forKey: node.selectionID)
        } else {
            selectedFolderIDs.insert(node.selectionID)
            for candidate in allFolderNodes() where candidate.folder.driveId == node.folder.driveId && candidate.folder.path.hasPrefix(node.folder.path == "/" ? "" : node.folder.path + "/") && candidate !== node {
                selectedFolderIDs.remove(candidate.selectionID)
            }
            var ancestor = node.parent
            while let current = ancestor {
                selectedFolderIDs.remove(current.selectionID)
                ancestor = current.parent
            }
        }
        if node.folder.driveId == nil {
            selectedFolderIDs.remove("__all__")
            syncEverythingButton?.state = .off
        }
        rebuildFolderList()
        updateSelectionSummary()
    }

    @objc private func changeFolderCachePolicy(_ sender: FolderCachePopUpButton) {
        guard let folderID = sender.folderID, let node = node(withID: folderID) else { return }
        if let raw = sender.selectedItem?.representedObject as? String, let policy = ProviderCachePolicy(rawValue: raw) {
            selectedCacheOverrides[node.selectionID] = policy
            if node.folder.driveId != nil && !selectedFolderIDs.contains(node.selectionID) {
                selectedFolderIDs.insert(node.selectionID)
            }
        } else {
            selectedCacheOverrides.removeValue(forKey: node.selectionID)
        }
        rebuildFolderList()
        updateSelectionSummary()
    }

    @objc private func changeGlobalCachePolicy(_ sender: FolderCachePopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let policy = ProviderCachePolicy(rawValue: raw) else { return }
        selectedGlobalCachePolicy = policy
        rebuildFolderList()
        updateSelectionSummary()
    }

    @objc private func resetCacheOverrides() {
        selectedCacheOverrides.removeAll()
        rebuildFolderList()
        updateSelectionSummary()
    }

    @objc private func toggleFolderExpansion(_ sender: FolderActionButton) {
        guard let node = node(withID: sender.folderID) else { return }
        if node.children != nil {
            node.isExpanded.toggle()
            rebuildFolderList()
        } else {
            loadChildren(for: node)
        }
    }

    private func loadChildren(for node: FolderNode) {
        guard !node.isLoading else { return }
        node.isLoading = true
        rebuildFolderList()
        var arguments = ["--gui-list-folders-json", "--gui-folder-id", node.folder.id, "--gui-folder-path", node.folder.path == "/" ? "" : node.folder.path]
        if let driveId = node.folder.driveId { arguments += ["--gui-drive-id", driveId] }
        executeDiscoveryCLI(arguments: arguments) { [weak self, weak node] code, output in
            guard let self, let node else { return }
            node.isLoading = false
            self.addDiagnostic("FOLDER EXPANSION", output)
            guard code == 0, let payload = self.parseDiscovery(output) else {
                self.showAlert(title: "Couldn’t open that folder", message: "OneDrive couldn’t load its subfolders. Please try again.")
                self.rebuildFolderList()
                return
            }
            self.cacheChildren(payload.folders, for: node)
            node.children = payload.folders.map { folder in
                FolderNode(folder: RemoteFolder(
                    id: folder.id,
                    name: folder.name,
                    path: folder.path,
                    childCount: folder.childCount,
                    driveId: node.folder.driveId,
                    siteName: node.folder.siteName,
                    libraryName: node.folder.libraryName
                ), parent: node)
            }
            node.children?.forEach(self.hydrateCachedChildren)
            node.isExpanded = true
            self.rebuildFolderList()
        }
    }

    private func rebuildFolderList() {
        guard let list = folderListStack else { return }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let personalNodes = visibleFolderNodes(from: folderRoots)
        let libraryNodes = visibleFolderNodes(from: libraryRoots)
        if personalNodes.isEmpty && libraryNodes.isEmpty {
            let empty = label("No matching folders", size: 13, weight: .regular, color: .secondaryLabelColor)
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.heightAnchor.constraint(equalToConstant: 54).isActive = true
            empty.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(empty)
            NSLayoutConstraint.activate([empty.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 16), empty.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
            list.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return
        }
        addFolderSection("OneDrive", nodes: personalNodes, to: list)
        addLibrarySection(nodes: libraryNodes, to: list)
    }

    private func addFolderSection(_ title: String, nodes: [FolderNode], to list: NSStackView) {
        guard !nodes.isEmpty else { return }
        let header = label(title.uppercased(), size: 11, weight: .semibold, color: .secondaryLabelColor)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.heightAnchor.constraint(equalToConstant: 34).isActive = true
        header.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
            header.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -7)
        ])
        list.addArrangedSubview(holder)
        holder.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        for (index, node) in nodes.enumerated() {
            let row = folderRow(node)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if index < nodes.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -52).isActive = true
            }
        }
    }

    private func addLibrarySection(nodes: [FolderNode], to list: NSStackView) {
        guard !nodes.isEmpty else { return }
        let header = label("COMPANY LIBRARIES", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let headerHolder = NSView()
        headerHolder.translatesAutoresizingMaskIntoConstraints = false
        headerHolder.heightAnchor.constraint(equalToConstant: 38).isActive = true
        header.translatesAutoresizingMaskIntoConstraints = false
        headerHolder.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerHolder.leadingAnchor, constant: 14),
            header.bottomAnchor.constraint(equalTo: headerHolder.bottomAnchor, constant: -7)
        ])
        list.addArrangedSubview(headerHolder)
        headerHolder.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

        let grouped = Dictionary(grouping: nodes, by: { $0.folder.siteName ?? "Company" })
        let query = folderSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for siteName in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let libraries = grouped[siteName] ?? []
            let isExpanded = expandedLibrarySites.contains(siteName) || !query.isEmpty
            let siteRow = librarySiteRow(siteName: siteName, libraryCount: libraries.filter { $0.folder.isLibraryRoot }.count, expanded: isExpanded)
            list.addArrangedSubview(siteRow)
            siteRow.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if isExpanded {
                for node in libraries {
                    let row = folderRow(node)
                    list.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
            }
        }
    }

    private func librarySiteRow(siteName: String, libraryCount: Int, expanded: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let disclosure = SiteActionButton(siteName: siteName, target: self, action: #selector(toggleLibrarySite(_:)))
        disclosure.isBordered = false
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Collapse \(siteName)" : "Expand \(siteName)")
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(disclosure)

        let icon = NSImageView(image: NSImage(systemSymbolName: "building.2.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label(siteName, size: 13, weight: .semibold, color: .labelColor))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(label("\(libraryCount) librar\(libraryCount == 1 ? "y" : "ies")", size: 11, weight: .regular, color: .tertiaryLabelColor))
        return row
    }

    @objc private func toggleLibrarySite(_ sender: SiteActionButton) {
        if expandedLibrarySites.contains(sender.siteName) { expandedLibrarySites.remove(sender.siteName) }
        else { expandedLibrarySites.insert(sender.siteName) }
        rebuildFolderList()
    }

    private func folderRow(_ node: FolderNode) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let sourceDepth = node.folder.driveId == nil ? node.depth : node.depth + 1
        row.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(12 + sourceDepth * 20), bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let disclosure = FolderActionButton(folderID: node.selectionID, target: self, action: #selector(toggleFolderExpansion(_:)))
        disclosure.isBordered = false
        let hasChildren = (node.folder.childCount ?? 0) > 0
        disclosure.image = hasChildren ? NSImage(systemSymbolName: node.isLoading ? "ellipsis" : (node.isExpanded ? "chevron.down" : "chevron.right"), accessibilityDescription: node.isExpanded ? "Collapse" : "Expand") : nil
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.isEnabled = hasChildren
        disclosure.setAccessibilityHidden(!hasChildren)
        disclosure.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(disclosure)

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = oneDriveBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(icon)

        let checkbox = FolderActionButton(folderID: node.selectionID, title: node.folder.name, target: self, action: #selector(toggleFolder(_:)))
        checkbox.setButtonType(.switch)
        checkbox.title = node.folder.name
        checkbox.state = selectedFolderIDs.contains(node.selectionID) ? .on : .off
        checkbox.isEnabled = node.folder.driveId != nil || !selectedFolderIDs.contains("__all__")
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(checkbox)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        let isShown = selectedFolderIDs.contains(node.selectionID) || (node.folder.driveId == nil && selectedFolderIDs.contains("__all__"))
        let cache = cachePolicyPopUp(
            folderID: node.selectionID,
            selection: selectedCacheOverrides[node.selectionID],
            inherits: true,
            action: #selector(changeFolderCachePolicy(_:))
        )
        cache.isEnabled = isShown
        cache.toolTip = "Use the global default or choose storage behavior for this folder"
        row.addArrangedSubview(cache)
        if let count = node.folder.childCount, count > 0 {
            row.addArrangedSubview(label("\(count) items", size: 11, weight: .regular, color: .tertiaryLabelColor))
        }
        return row
    }

    private func visibleFolderNodes(from roots: [FolderNode]) -> [FolderNode] {
        let query = folderSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty {
            return flattenedFolderNodes(roots).filter {
                $0.folder.name.localizedCaseInsensitiveContains(query) ||
                ($0.folder.siteName?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        var result: [FolderNode] = []
        func append(_ nodes: [FolderNode]) {
            for node in nodes {
                result.append(node)
                if node.isExpanded, let children = node.children { append(children) }
            }
        }
        append(roots)
        return result
    }

    private func flattenedFolderNodes(_ roots: [FolderNode]) -> [FolderNode] {
        var result: [FolderNode] = []
        func append(_ nodes: [FolderNode]) {
            for node in nodes {
                result.append(node)
                if let children = node.children { append(children) }
            }
        }
        append(roots)
        return result
    }

    private func allFolderNodes() -> [FolderNode] {
        var result: [FolderNode] = []
        func append(_ nodes: [FolderNode]) {
            for node in nodes {
                result.append(node)
                if let children = node.children { append(children) }
            }
        }
        append(folderRoots)
        append(libraryRoots)
        return result
    }

    private func node(withID id: String) -> FolderNode? { allFolderNodes().first { $0.folder.id == id || $0.selectionID == id } }

    private func updateSelectionSummary() { selectionSummaryLabel?.stringValue = selectionSummary() }

    private func selectionSummary() -> String {
        let libraryCount = selectedFolderIDs.filter { $0 != "__all__" && $0.contains(":") }.count
        let overrides = selectedCacheOverrides.count
        let cacheSummary = overrides == 0 ? cachePolicyTitle(selectedGlobalCachePolicy) : "\(cachePolicyTitle(selectedGlobalCachePolicy)) · \(overrides) override\(overrides == 1 ? "" : "s")"
        if selectedFolderIDs.contains("__all__") {
            return libraryCount == 0 ? "All OneDrive folders · \(cacheSummary)" : "All OneDrive folders + \(libraryCount) librar\(libraryCount == 1 ? "y" : "ies") · \(cacheSummary)"
        }
        if selectedFolderIDs.isEmpty { return "Choose at least one folder" }
        return "\(selectedFolderIDs.count) folder\(selectedFolderIDs.count == 1 ? "" : "s") · \(cacheSummary)"
    }

    private func cachePolicyTitle(_ policy: ProviderCachePolicy) -> String {
        switch policy {
        case .spaceSaver: return "Online only"
        case .smart: return "Smart cache"
        case .alwaysAvailable: return "Available offline"
        }
    }

    private func cachePolicyDetail(_ policy: ProviderCachePolicy) -> String {
        switch policy {
        case .spaceSaver: return "Downloads files only when you open them"
        case .smart: return "Downloads on open and lets macOS manage space"
        case .alwaysAvailable: return "Downloads everything and keeps it available offline"
        }
    }

    private func effectiveCachePolicy(for node: FolderNode) -> ProviderCachePolicy {
        selectedCacheOverrides[node.selectionID] ?? selectedGlobalCachePolicy
    }

    private func cachePolicyPopUp(
        folderID: String?,
        selection: ProviderCachePolicy?,
        inherits: Bool,
        action: Selector
    ) -> FolderCachePopUpButton {
        let popUp = FolderCachePopUpButton(folderID: folderID, target: self, action: action)
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: 11)
        if inherits {
            let inherited = NSMenuItem(title: "Use \(cachePolicyTitle(selectedGlobalCachePolicy))", action: nil, keyEquivalent: "")
            inherited.representedObject = "inherit"
            popUp.menu?.addItem(inherited)
            popUp.menu?.addItem(.separator())
        }
        for policy in ProviderCachePolicy.allCases {
            let item = NSMenuItem(title: cachePolicyTitle(policy), action: nil, keyEquivalent: "")
            item.representedObject = policy.rawValue
            popUp.menu?.addItem(item)
        }
        if let selection,
           let index = popUp.itemArray.firstIndex(where: { ($0.representedObject as? String) == selection.rawValue }) {
            popUp.selectItem(at: index)
        } else {
            popUp.selectItem(at: 0)
        }
        return popUp
    }

    private func isFileProviderManaged(_ url: URL) -> Bool {
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
            .standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedPath == cloudStorage || resolvedPath.hasPrefix(cloudStorage + "/")
    }

    private func inferredLocalSelections(in destination: URL) -> Set<String> {
        var matches = Set<String>()
        for node in folderRoots {
            if localDirectoryExists(destination.appendingPathComponent(node.folder.path, isDirectory: true)) {
                matches.insert(node.selectionID)
            }
        }
        let companyLibraries = destination.appendingPathComponent("Company Libraries", isDirectory: true)
        for node in libraryRoots {
            let siteName = node.folder.siteName ?? "Company"
            let libraryName = node.folder.libraryName ?? node.folder.name
            let localName = safeFilename("\(siteName) — \(libraryName)")
            let officialName = safeFilename("\(siteName) - \(libraryName)")
            if localDirectoryExists(companyLibraries.appendingPathComponent(localName, isDirectory: true)) ||
                localDirectoryExists(destination.appendingPathComponent(localName, isDirectory: true)) ||
                localDirectoryExists(destination.appendingPathComponent(officialName, isDirectory: true)) {
                matches.insert(node.selectionID)
            }
        }
        return matches
    }

    private func inferredSelectionsForCurrentSetup(in destination: URL) -> Set<String> {
        var matches = inferredLocalSelections(in: destination)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDestination = home.appendingPathComponent("OneDrive", isDirectory: true).standardizedFileURL.path
        guard destination.standardizedFileURL.path == defaultDestination else { return matches }

        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { candidate in
            candidate.lastPathComponent.hasPrefix("OneDrive - ") && isFileProviderManaged(candidate)
        }
        if candidates.count == 1, let existingOneDrive = candidates.first {
            matches.formUnion(inferredLocalSelections(in: existingOneDrive))
        }
        return matches
    }

    private func localDirectoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func expandSitesContainingSelectedLibraries() {
        for node in libraryRoots where selectedFolderIDs.contains(node.selectionID) {
            if let siteName = node.folder.siteName { expandedLibrarySites.insert(siteName) }
        }
    }

    @objc private func saveFolderSelection() {
        guard !selectedFolderIDs.isEmpty else {
            showAlert(title: "Choose something to sync", message: "Turn on Sync everything or select at least one folder.")
            return
        }
        var locationsByID = Dictionary(uniqueKeysWithValues: savedLocations.map { ($0.id, $0) })
        locationsByID["__all__"] = SyncLocation(id: "__all__", name: "Everything in OneDrive", path: "/")
        for node in allFolderNodes() + allDashboardNodes() {
            guard node.selectionID != "__all__" else { continue }
            let displayName = node.folder.isLibraryRoot
                ? "\(node.folder.siteName ?? "Company") — \(node.folder.name)"
                : node.folder.name
            locationsByID[node.selectionID] = SyncLocation(
                id: node.selectionID,
                name: displayName,
                path: node.folder.path,
                driveId: node.folder.driveId,
                siteName: node.folder.siteName,
                libraryName: node.folder.libraryName
            )
        }
        let chosen = selectedFolderIDs.compactMap { locationsByID[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let wasConfigured = !savedLocations.isEmpty
        guard let data = try? JSONEncoder().encode(chosen) else { return }
        UserDefaults.standard.set(data, forKey: locationsKey)
        saveCachePreferences()
        UserDefaults.standard.set(false, forKey: providerReadyKey)
        activateProvider(
            locations: chosen,
            title: wasConfigured ? "Updating Finder…" : "Adding OneDrive to Finder…"
        )
    }

    private func activateProvider(
        locations: [SyncLocation],
        title: String,
        mutationReserved: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if !mutationReserved {
            guard !providerMutationInFlight else { return }
            providerMutationInFlight = true
        }
        let finishMutation = {
            if !mutationReserved { self.providerMutationInFlight = false }
            completion?()
        }
        if selectedFolderIDs.isEmpty {
            selectedGlobalCachePolicy = savedGlobalCachePolicy()
            selectedCacheOverrides = savedCacheOverrides()
        }
        let providerConfiguration: ProviderConfiguration
        do {
            providerConfiguration = try makeProviderConfiguration(locations)
        } catch {
            finishMutation()
            showDashboard(error: error.localizedDescription)
            return
        }
        showProgress(title: title, detail: "Your folders will appear immediately. File contents download only when you open them.")
        stopMonitoring()
        providerCoordinator.activate(
            configuration: providerConfiguration,
            legacyConfigurationDirectory: configDirectory
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    UserDefaults.standard.set(false, forKey: self.providerReadyKey)
                    self.addDiagnostic("FILE PROVIDER", error.localizedDescription)
                    self.showDashboard(error: "Couldn’t start Files On-Demand: \(error.localizedDescription)")
                case .success:
                    UserDefaults.standard.set(true, forKey: self.providerReadyKey)
                    UserDefaults.standard.set(self.currentProviderStorageVersion, forKey: self.providerStorageVersionKey)
                    UserDefaults.standard.set(false, forKey: self.syncReadyKey)
                    self.registerLaunchAtLogin()
                    self.showDashboard()
                }
                finishMutation()
            }
        }
    }

    private func registerLaunchAtLogin() {
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            addDiagnostic("START AT LOGIN", error.localizedDescription)
        }
    }

    private func makeProviderConfiguration(_ locations: [SyncLocation]) throws -> ProviderConfiguration {
        let defaults = UserDefaults.standard
        let primaryDriveID = defaults.string(forKey: primaryDriveIDKey)
        let primaryRootID = defaults.string(forKey: primaryRootIDKey)
        var drives: [ProviderDrive] = []
        var cacheOverrides = Set<ProviderCacheOverride>()
        for node in allFolderNodes() + allDashboardNodes() {
            guard let policy = selectedCacheOverrides[node.selectionID] else { continue }
            if let driveID = node.folder.driveId {
                cacheOverrides.insert(ProviderCacheOverride(driveID: driveID, itemID: node.folder.id, policy: policy))
            } else if let primaryDriveID {
                cacheOverrides.insert(ProviderCacheOverride(driveID: primaryDriveID, itemID: node.folder.id, policy: policy))
            }
        }
        for location in locations {
            guard let policy = selectedCacheOverrides[location.id] else { continue }
            if let driveID = location.driveId {
                let prefix = "\(driveID):"
                let itemID = location.id.hasPrefix(prefix) ? String(location.id.dropFirst(prefix.count)) : location.id
                cacheOverrides.insert(ProviderCacheOverride(driveID: driveID, itemID: itemID, policy: policy))
            } else if let primaryDriveID {
                let itemID = location.id == "__all__" ? primaryRootID : location.id
                if let itemID {
                    cacheOverrides.insert(ProviderCacheOverride(driveID: primaryDriveID, itemID: itemID, policy: policy))
                }
            }
        }
        if let primaryDriveID, !primaryDriveID.isEmpty,
           let primaryRootID, !primaryRootID.isEmpty {
            drives.append(ProviderDrive(
                driveID: primaryDriveID,
                remoteRootItemID: primaryRootID,
                displayName: "Root files",
                siteName: nil,
                keepDownloaded: false,
                rootFilesOnly: true
            ))
        }
        for location in locations {
            if let driveID = location.driveId {
                let prefix = "\(driveID):"
                let remoteItemID = location.id.hasPrefix(prefix) ? String(location.id.dropFirst(prefix.count)) : location.id
                drives.append(ProviderDrive(
                    driveID: driveID,
                    remoteRootItemID: remoteItemID,
                    displayName: location.name,
                    siteName: location.siteName,
                    keepDownloaded: selectedCacheOverrides[location.id] == .alwaysAvailable
                ))
            } else {
                guard let primaryDriveID, !primaryDriveID.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "OneDrive needs to refresh your account details before Files On-Demand can start."
                    ])
                }
                if location.id == "__all__", primaryRootID == nil {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "Refresh your OneDrive folder list once so Files On-Demand can identify the account root."
                    ])
                }
                drives.append(ProviderDrive(
                    driveID: primaryDriveID,
                    remoteRootItemID: location.id == "__all__" ? (primaryRootID ?? "root") : location.id,
                    displayName: location.id == "__all__" ? "My files" : location.name,
                    siteName: nil,
                    keepDownloaded: selectedCacheOverrides[location.id] == .alwaysAvailable
                ))
            }
        }
        return ProviderConfiguration(
            accountName: defaults.string(forKey: accountNameKey) ?? "OneDrive",
            accountEmail: defaults.string(forKey: accountEmailKey) ?? "",
            drives: drives,
            globalCachePolicy: selectedGlobalCachePolicy,
            cacheOverrides: cacheOverrides
        )
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return value.components(separatedBy: invalid).joined(separator: "-")
    }

    private func showDashboard(error: String? = nil) {
        selectedGlobalCachePolicy = savedGlobalCachePolicy()
        selectedCacheOverrides = savedCacheOverrides()
        setStatus(error == nil ? "Files On-Demand" : "Setup needed")
        let root = SurfaceView()
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 18
        page.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 42),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -42),
            page.topAnchor.constraint(equalTo: root.topAnchor, constant: 50),
            page.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -34)
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 14
        top.addArrangedSubview(brandIcon(size: 48))
        let account = NSStackView()
        account.orientation = .vertical
        account.alignment = .leading
        account.spacing = 2
        account.addArrangedSubview(label(previewAccountName ?? UserDefaults.standard.string(forKey: accountNameKey) ?? "OneDrive", size: 18, weight: .semibold, color: .labelColor))
        let kind = accountKind()
        let email = previewAccountEmail ?? UserDefaults.standard.string(forKey: accountEmailKey) ?? "Connected"
        account.addArrangedSubview(label("\(kind) · \(email)", size: 12, weight: .regular, color: .secondaryLabelColor))
        top.addArrangedSubview(account)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(spacer)
        let state = label(statusText, size: 13, weight: .semibold, color: error == nil ? .systemGreen : .systemOrange)
        top.addArrangedSubview(state)
        page.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true

        page.addArrangedSubview(label("Your OneDrive", size: 28, weight: .bold, color: .labelColor))
        page.addArrangedSubview(label("Choose a storage default for everything, with optional folder overrides.", size: 14, weight: .regular, color: .secondaryLabelColor))

        let storage = NSStackView()
        storage.orientation = .horizontal
        storage.alignment = .centerY
        storage.spacing = 8
        storage.addArrangedSubview(label("Default storage", size: 13, weight: .medium, color: .secondaryLabelColor))
        storage.addArrangedSubview(cachePolicyPopUp(folderID: nil, selection: selectedGlobalCachePolicy, inherits: false, action: #selector(changeDashboardGlobalCachePolicy(_:))))
        storage.addArrangedSubview(label(cachePolicyDetail(selectedGlobalCachePolicy), size: 12, weight: .regular, color: .tertiaryLabelColor))
        page.addArrangedSubview(storage)

        if let error {
            let notice = dashboardSetupNotice(for: error)
            page.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }

        let legacyMirror = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OneDrive", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyMirror.path) {
            let legacy = NSStackView()
            legacy.orientation = .horizontal
            legacy.alignment = .centerY
            legacy.spacing = 8
            let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            legacy.addArrangedSubview(icon)
            let legacyCopy = label("Your previous downloaded copy is untouched in ~/OneDrive.", size: 12, weight: .regular, color: .secondaryLabelColor)
            legacy.addArrangedSubview(legacyCopy)
            DispatchQueue.global(qos: .utility).async { [weak self, weak legacyCopy] in
                guard let self, let byteCount = self.allocatedSize(of: legacyMirror) else { return }
                let formatted = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                DispatchQueue.main.async {
                    legacyCopy?.stringValue = "Your previous \(formatted) downloaded copy is untouched in ~/OneDrive."
                }
            }
            let legacySpacer = NSView()
            legacySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            legacy.addArrangedSubview(legacySpacer)
            legacy.addArrangedSubview(linkButton("Review in Finder", action: #selector(openLegacyMirror)))
            page.addArrangedSubview(legacy)
            legacy.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }

        let locations = savedLocations.isEmpty ? [SyncLocation(id: "__all__", name: "Everything", path: "/")] : savedLocations
        syncDashboardRoots(with: locations)
        let list = FolderListStack()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        dashboardListStack = list
        rebuildDashboardList()
        for node in dashboardRoots.values where node.selectionID == "__all__" && node.children == nil {
            loadDashboardChildren(for: node)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        page.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.addArrangedSubview(linkButton("Choose folders…", action: #selector(manageFolders)))
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(footerSpacer)
        footer.addArrangedSubview(primaryButton("Open in Finder", action: #selector(openSyncFolder)))
        page.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        setContent(root)
    }

    private func dashboardSetupNotice(for error: String) -> NSView {
        let capabilityIssue = error.localizedCaseInsensitiveContains("entitlement") ||
            error.localizedCaseInsensitiveContains("signed app") ||
            error.localizedCaseInsensitiveContains("application group")

        let notice = NSStackView()
        notice.orientation = .horizontal
        notice.alignment = .centerY
        notice.spacing = 12
        notice.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        notice.wantsLayer = true
        notice.layer?.cornerRadius = 12
        notice.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.09).cgColor
        notice.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.24).cgColor
        notice.layer?.borderWidth = 1

        let icon = NSImageView(image: NSImage(
            systemSymbolName: capabilityIssue ? "lock.shield" : "arrow.clockwise.circle",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])
        notice.addArrangedSubview(icon)

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3
        copy.addArrangedSubview(label(
            capabilityIssue ? "Finish Files On-Demand setup" : "OneDrive needs a moment",
            size: 13,
            weight: .semibold,
            color: .labelColor
        ))
        let detail = label(
            capabilityIssue
                ? "This development copy can’t add OneDrive to Finder. Install the signed release in Applications, then reopen it. Your files are untouched."
                : error,
            size: 12,
            weight: .regular,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 2
        copy.addArrangedSubview(detail)
        notice.addArrangedSubview(copy)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        notice.addArrangedSubview(spacer)
        let action = primaryButton(
            capabilityIssue ? "Open Applications" : "Try again",
            action: capabilityIssue ? #selector(openApplicationsFolder) : #selector(retryProviderSetup)
        )
        action.controlSize = .small
        notice.addArrangedSubview(action)
        return notice
    }

    @objc private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    @objc private func retryProviderSetup() {
        guard !savedLocations.isEmpty else {
            discoverFolders(editing: false)
            return
        }
        activateProvider(locations: savedLocations, title: "Adding OneDrive to Finder…")
    }

    private func syncDashboardRoots(with locations: [SyncLocation]) {
        let defaults = UserDefaults.standard
        let primaryDriveID = defaults.string(forKey: primaryDriveIDKey)
        let primaryRootID = defaults.string(forKey: primaryRootIDKey)
        var next: [String: FolderNode] = [:]
        for location in locations {
            if let existing = dashboardRoots[location.id] {
                next[location.id] = existing
                continue
            }
            let isWholePersonalDrive = location.id == "__all__"
            let driveID = isWholePersonalDrive ? primaryDriveID : location.driveId
            let remoteID: String
            if isWholePersonalDrive {
                remoteID = primaryRootID ?? "root"
            } else if let driveID = location.driveId, location.id.hasPrefix("\(driveID):") {
                remoteID = String(location.id.dropFirst(driveID.count + 1))
            } else {
                remoteID = location.id
            }
            let node = FolderNode(folder: RemoteFolder(
                id: remoteID,
                name: location.name,
                path: location.path,
                childCount: isWholePersonalDrive ? max(availableFolders.count, 1) : 1,
                driveId: driveID,
                siteName: location.siteName,
                libraryName: location.libraryName,
                isLibraryRoot: location.siteName != nil
            ), selectionIDOverride: isWholePersonalDrive ? "__all__" : nil)
            if isWholePersonalDrive, !availableFolders.isEmpty {
                node.children = availableFolders.map { folder in
                    let child = FolderNode(folder: RemoteFolder(
                        id: folder.id,
                        name: folder.name,
                        path: folder.path,
                        childCount: folder.childCount,
                        driveId: driveID
                    ), parent: node, selectionIDOverride: folder.siteName == nil ? folder.id : nil)
                    hydrateCachedChildren(for: child)
                    return child
                }
                node.isExpanded = true
            } else {
                hydrateCachedChildren(for: node)
                if isWholePersonalDrive { node.isExpanded = true }
            }
            next[location.id] = node
        }
        dashboardRoots = next
    }

    private func rebuildDashboardList() {
        guard let list = dashboardListStack else { return }
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let roots = Array(dashboardRoots.values)
        let personal = roots.filter { $0.folder.siteName == nil }.sorted { $0.folder.name.localizedStandardCompare($1.folder.name) == .orderedAscending }
        let company = roots.filter { $0.folder.siteName != nil }.sorted { $0.folder.name.localizedStandardCompare($1.folder.name) == .orderedAscending }
        addDashboardSection("OneDrive", sectionID: "personal", nodes: personal, to: list)
        addDashboardSection("Company libraries", sectionID: "company", nodes: company, to: list)
    }

    private func visibleDashboardNodes(from roots: [FolderNode]) -> [FolderNode] {
        var result: [FolderNode] = []
        func append(_ nodes: [FolderNode]) {
            for node in nodes {
                result.append(node)
                if node.isExpanded, let children = node.children { append(children) }
            }
        }
        append(roots)
        return result
    }

    private func allDashboardNodes() -> [FolderNode] {
        var result: [FolderNode] = []
        func append(_ nodes: [FolderNode]) {
            for node in nodes {
                result.append(node)
                if let children = node.children { append(children) }
            }
        }
        append(Array(dashboardRoots.values))
        return result
    }

    private func dashboardNode(withID id: String) -> FolderNode? {
        allDashboardNodes().first { $0.selectionID == id }
    }

    private func addDashboardSection(_ title: String, sectionID: String, nodes: [FolderNode], to list: NSStackView) {
        guard !nodes.isEmpty else { return }
        let expanded = expandedDashboardSections.contains(sectionID)
        let header = DashboardSectionButton(sectionID: sectionID, target: self, action: #selector(toggleDashboardSection(_:)))
        header.isBordered = false
        let disclosure = NSImageView(image: NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Collapse \(title)" : "Expand \(title)"
        ) ?? NSImage())
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(disclosure)
        header.setAccessibilityLabel("\(title), \(nodes.count) folder\(nodes.count == 1 ? "" : "s")")
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(label(title.uppercased(), size: 11, weight: .semibold, color: .secondaryLabelColor))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        content.addArrangedSubview(spacer)
        content.addArrangedSubview(label("\(nodes.count) folder\(nodes.count == 1 ? "" : "s")", size: 11, weight: .regular, color: .tertiaryLabelColor))
        header.addSubview(content)
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            disclosure.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 12),
            content.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 34),
            content.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            content.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        list.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true

        guard expanded else { return }
        let visibleNodes = visibleDashboardNodes(from: nodes)
        for (index, node) in visibleNodes.enumerated() {
            let row = dashboardLocationRow(node)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            if index < visibleNodes.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -52).isActive = true
            }
        }
    }

    @objc private func toggleDashboardSection(_ sender: DashboardSectionButton) {
        if expandedDashboardSections.contains(sender.sectionID) {
            expandedDashboardSections.remove(sender.sectionID)
        } else {
            expandedDashboardSections.insert(sender.sectionID)
        }
        rebuildDashboardList()
    }

    @objc private func toggleDashboardFolderExpansion(_ sender: FolderActionButton) {
        guard let node = dashboardNode(withID: sender.folderID) else { return }
        if node.children != nil {
            node.isExpanded.toggle()
            rebuildDashboardList()
            if node.isExpanded { loadDashboardChildren(for: node, preservingCachedChildren: true) }
        } else {
            loadDashboardChildren(for: node)
        }
    }

    private func loadDashboardChildren(for node: FolderNode, preservingCachedChildren: Bool = false) {
        guard !node.isLoading else { return }
        node.isLoading = true
        if !preservingCachedChildren { rebuildDashboardList() }
        var arguments = ["--gui-list-folders-json", "--gui-folder-id", node.folder.id, "--gui-folder-path", node.folder.path == "/" ? "" : node.folder.path]
        if let driveID = node.folder.driveId { arguments += ["--gui-drive-id", driveID] }
        executeDiscoveryCLI(arguments: arguments) { [weak self, weak node] code, output in
            guard let self, let node else { return }
            node.isLoading = false
            self.addDiagnostic("DASHBOARD FOLDER EXPANSION", output)
            guard code == 0, let payload = self.parseDiscovery(output) else {
                node.providerError = self.dashboardProviderErrorSummary(from: output)
                if !preservingCachedChildren {
                    self.showAlert(title: "Couldn’t open that folder", message: "OneDrive couldn’t load its subfolders. Please try again.")
                }
                self.rebuildDashboardList()
                return
            }
            self.cacheChildren(payload.folders, for: node)
            node.children = payload.folders.map { folder in
                FolderNode(folder: RemoteFolder(
                    id: folder.id,
                    name: folder.name,
                    path: folder.path,
                    childCount: folder.childCount,
                    driveId: node.folder.driveId,
                    siteName: node.folder.siteName,
                    libraryName: node.folder.libraryName
                ), parent: node, selectionIDOverride: node.folder.siteName == nil ? folder.id : nil)
            }
            node.children?.forEach(self.hydrateCachedChildren)
            node.providerError = nil
            if !preservingCachedChildren { node.isExpanded = true }
            self.rebuildDashboardList()
        }
    }

    private func dashboardProviderErrorSummary(from output: String) -> String {
        let detail = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty && !$0.hasPrefix("ONEDRIVE_GUI_JSON=") }
        guard let detail else { return "OneDrive couldn’t load this folder." }
        return String(detail.prefix(180))
    }

    private func dashboardLocationRow(_ node: FolderNode) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(14 + node.depth * 20), bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let knownChildren = node.children.map { !$0.isEmpty }
        let hasChildren = knownChildren ?? ((node.folder.childCount ?? 0) > 0)
        let disclosure = FolderActionButton(folderID: node.selectionID, target: self, action: #selector(toggleDashboardFolderExpansion(_:)))
        disclosure.isBordered = false
        disclosure.image = hasChildren ? NSImage(
            systemSymbolName: node.isLoading ? "ellipsis" : (node.isExpanded ? "chevron.down" : "chevron.right"),
            accessibilityDescription: node.isExpanded ? "Collapse \(node.folder.name)" : "Expand \(node.folder.name)"
        ) : nil
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.isEnabled = hasChildren
        disclosure.setAccessibilityHidden(!hasChildren)
        disclosure.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(disclosure)

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = oneDriveBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(icon)

        let effectivePolicy = effectiveCachePolicy(for: node)
        let stateTitle = node.providerError == nil ? cachePolicyTitle(effectivePolicy) : "Provider error"
        let nameAndState = NSStackView()
        nameAndState.orientation = .vertical
        nameAndState.alignment = .leading
        nameAndState.spacing = 2
        let name = label(node.folder.name, size: 13, weight: .medium, color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        nameAndState.addArrangedSubview(name)
        let state = label(stateTitle, size: 11, weight: .regular, color: node.providerError == nil ? .secondaryLabelColor : .systemOrange)
        state.lineBreakMode = .byTruncatingTail
        state.setAccessibilityLabel(node.providerError == nil ? stateTitle : "Provider error")
        if let providerError = node.providerError {
            state.toolTip = providerError
            state.setAccessibilityValue(providerError)
        }
        nameAndState.addArrangedSubview(state)
        nameAndState.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(nameAndState)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        let cachePolicy = cachePolicyPopUp(
            folderID: node.selectionID,
            selection: selectedCacheOverrides[node.selectionID],
            inherits: true,
            action: #selector(changeDashboardFolderCachePolicy(_:))
        )
        cachePolicy.setAccessibilityLabel("Cache policy for \(node.folder.name)")
        cachePolicy.setAccessibilityValue(stateTitle)
        row.addArrangedSubview(cachePolicy)
        row.setAccessibilityLabel("\(node.folder.name), \(stateTitle)")
        return row
    }

    @objc private func changeDashboardGlobalCachePolicy(_ sender: FolderCachePopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let policy = ProviderCachePolicy(rawValue: raw) else { return }
        selectedGlobalCachePolicy = policy
        applyDashboardCacheChanges()
    }

    @objc private func changeDashboardFolderCachePolicy(_ sender: FolderCachePopUpButton) {
        guard let folderID = sender.folderID else { return }
        if let raw = sender.selectedItem?.representedObject as? String,
           let policy = ProviderCachePolicy(rawValue: raw) {
            selectedCacheOverrides[folderID] = policy
        } else {
            selectedCacheOverrides.removeValue(forKey: folderID)
        }
        applyDashboardCacheChanges()
    }

    private func applyDashboardCacheChanges() {
        saveCachePreferences()
        activateProvider(locations: savedLocations, title: "Updating storage settings…")
    }

    private func accountKind() -> String {
        let type = (previewAccountType ?? UserDefaults.standard.string(forKey: accountTypeKey) ?? "").lowercased()
        return type.contains("business") ? "Work" : "Personal"
    }

    @objc private func manageFolders() {
        if availableFolders.isEmpty { discoverFolders(editing: true) } else { showFolderPicker(editing: true); showMainWindow() }
    }

    @objc private func syncNow() {
        guard currentProcess == nil else { return }
        activateProvider(locations: savedLocations, title: "Refreshing Finder…")
    }

    @objc private func repairFinderLayout() {
        guard !providerMutationInFlight else { return }
        guard !savedLocations.isEmpty else {
            showWelcome(message: "Choose your OneDrive folders first.")
            return
        }
        guard isAuthenticated else {
            showDashboard(error: "Your Microsoft session is unavailable. Sign in again before repairing Finder.")
            return
        }
        do {
            _ = try makeProviderConfiguration(savedLocations)
        } catch {
            showDashboard(error: error.localizedDescription)
            return
        }
        providerMutationInFlight = true
        UserDefaults.standard.set(false, forKey: providerReadyKey)
        setStatus("Repairing Finder…")
        providerCoordinator.resetDomainPreservingDownloadedUserData { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.providerMutationInFlight = false
                    self.addDiagnostic("FINDER REPAIR", error.localizedDescription)
                    self.showDashboard(error: "Couldn’t repair Finder’s OneDrive layout. Your files were kept.")
                case .success:
                    self.activateProvider(
                        locations: self.savedLocations,
                        title: "Rebuilding Finder layout…",
                        mutationReserved: true
                    ) {
                        self.providerMutationInFlight = false
                    }
                }
            }
        }
    }

    private func stopMonitoring() {
        let processes = Array(monitorProcesses.values)
        monitorProcesses.removeAll()
        for process in processes { process.terminate() }
    }

    @objc private func openSyncFolder() {
        providerCoordinator.rootURL { url in
            DispatchQueue.main.async {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else { self.showDashboard(error: "OneDrive is not available in Finder yet. Click Refresh Finder to retry.") }
            }
        }
    }

    @objc private func openLegacyMirror() {
        let mirror = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("OneDrive", isDirectory: true)
        NSWorkspace.shared.open(mirror)
    }

    private func allocatedSize(of directory: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private func savedGlobalCachePolicy() -> ProviderCachePolicy {
        guard let raw = UserDefaults.standard.string(forKey: globalCachePolicyKey),
              let policy = ProviderCachePolicy(rawValue: raw) else { return .smart }
        return policy
    }

    private func savedCacheOverrides() -> [String: ProviderCachePolicy] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: cacheOverridesKey),
           let values = try? JSONDecoder().decode([String: ProviderCachePolicy].self, from: data) {
            return values
        }
        guard let legacyData = defaults.data(forKey: offlineLocationsKey),
              let legacy = try? JSONDecoder().decode([String].self, from: legacyData) else { return [:] }
        return Dictionary(uniqueKeysWithValues: legacy.map { ($0, .alwaysAvailable) })
    }

    private func saveCachePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(selectedGlobalCachePolicy.rawValue, forKey: globalCachePolicyKey)
        if let data = try? JSONEncoder().encode(selectedCacheOverrides) {
            defaults.set(data, forKey: cacheOverridesKey)
        }
        defaults.removeObject(forKey: offlineLocationsKey)
    }

    @objc private func showDiagnostics() {
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = diagnostics.isEmpty ? "No diagnostic activity yet." : diagnostics
        text.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let panel = diagnosticsWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "OneDrive Diagnostics"
        panel.contentView = scroll
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        diagnosticsWindow = panel
        NSApp.activate(ignoringOtherApps: true)
    }

    private func executeCLI(arguments: [String], onOutput: ((String) -> Void)? = nil, completion: @escaping (Int32, String) -> Void) {
        guard currentProcess == nil, let executable = cliURL else {
            completion(1, "The OneDrive engine is unavailable or already busy.")
            return
        }
        let process = configuredProcess(executable: executable, arguments: arguments)
        let pipe = Pipe()
        let collector = OutputCollector()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
            if let onOutput {
                let currentOutput = collector.string()
                DispatchQueue.main.async { onOutput(currentOutput) }
            }
        }
        process.terminationHandler = { [weak self, weak process] processResult in
            pipe.fileHandleForReading.readabilityHandler = nil
            let remainder = pipe.fileHandleForReading.readDataToEndOfFile()
            collector.append(remainder)
            DispatchQueue.main.async {
                guard let self, self.currentProcess === process else { return }
                self.currentProcess = nil
                completion(processResult.terminationStatus, collector.string())
            }
        }
        do {
            currentProcess = process
            try process.run()
        } catch {
            currentProcess = nil
            completion(1, error.localizedDescription)
        }
    }

    private func executeDiscoveryCLI(
        arguments: [String],
        retriedAfterRecovery: Bool = false,
        completion: @escaping (Int32, String) -> Void
    ) {
        executeCLI(arguments: arguments) { [weak self] code, output in
            guard let self else { return }
            let configurationChangeMarker = "An application configuration change has been detected where a --resync is required"
            let requiresPrivateRecovery = code == 126 && output.contains(configurationChangeMarker)
            guard requiresPrivateRecovery, !retriedAfterRecovery else {
                completion(code, output)
                return
            }

            do {
                let archived = try self.archiveStalePrivateEngineMetadata()
                let detail = archived.isEmpty
                    ? "No stale comparison files were present; retrying discovery once."
                    : "Archived \(archived.joined(separator: ", ")); retrying discovery once."
                self.addDiagnostic("PRIVATE CACHE RECOVERY", detail)
                self.executeDiscoveryCLI(
                    arguments: arguments,
                    retriedAfterRecovery: true,
                    completion: completion
                )
            } catch {
                self.addDiagnostic("PRIVATE CACHE RECOVERY FAILED", error.localizedDescription)
                completion(code, "\(output)\nAutomatic private-cache recovery was stopped: \(error.localizedDescription)")
            }
        }
    }

    private func archiveStalePrivateEngineMetadata() throws -> [String] {
        let fileManager = FileManager.default
        let configuredValues = try configDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard configuredValues.isSymbolicLink != true else {
            throw NSError(
                domain: "OneDrive.PrivateCacheRecovery",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The engine configuration folder is a symbolic link."]
            )
        }
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath()
        let privateConfiguration = configDirectory.resolvingSymlinksInPath()
        let supportPrefix = applicationSupport.path.hasSuffix("/")
            ? applicationSupport.path
            : applicationSupport.path + "/"
        guard privateConfiguration.path.hasPrefix(supportPrefix) else {
            throw NSError(
                domain: "OneDrive.PrivateCacheRecovery",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The engine configuration is outside this app’s private Application Support folder."]
            )
        }

        let suffix = "pre-files-on-demand-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        let names = [".config.backup", ".config.hash", ".sync_list.hash"]
        let moves = names.compactMap { name -> (name: String, source: URL, destination: URL)? in
            let source = privateConfiguration.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: source.path) else { return nil }
            return (
                name,
                source,
                privateConfiguration.appendingPathComponent("\(name).\(suffix)", isDirectory: false)
            )
        }
        var completedMoves: [(source: URL, destination: URL)] = []
        do {
            for move in moves {
                try fileManager.moveItem(at: move.source, to: move.destination)
                completedMoves.append((move.source, move.destination))
            }
        } catch {
            for move in completedMoves.reversed() {
                try? fileManager.moveItem(at: move.destination, to: move.source)
            }
            throw error
        }
        return moves.map(\.name)
    }

    private var cliURL: URL? { Bundle.main.url(forResource: "onedrive", withExtension: nil) }

    private func configuredProcess(executable: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--confdir", configDirectory.path,
            "--syncdir", engineDirectory.path
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment
        return process
    }

    private func setStatus(_ value: String) {
        statusText = value
        statusMenuLabel?.title = value
        statusItem?.button?.toolTip = "OneDrive — \(value)"
    }

    private func addDiagnostic(_ heading: String, _ output: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        diagnostics += "\n[\(stamp)] \(heading)\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    private func setContent(_ view: NSView) {
        window.contentView = view
    }

    private func pageStack(alignment: NSLayoutConstraint.Attribute, spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func brandIcon(size: CGFloat) -> NSImageView {
        let image = Bundle.main.image(forResource: "OneDriveLogo") ?? NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "OneDrive") ?? NSImage()
        image.isTemplate = false
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        return field
    }

    private func primaryButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.bezelColor = oneDriveBlue
        button.contentTintColor = .white
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        return button
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = oneDriveBlue
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    private func findView(identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews {
            if let found = findView(identifier: identifier, in: child) { return found }
        }
        return nil
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private func seedPreviewData() {
        availableFolders = [
            RemoteFolder(id: "documents", name: "Documents", path: "Documents", childCount: 38),
            RemoteFolder(id: "projects", name: "Work projects", path: "Work projects", childCount: 12),
            RemoteFolder(id: "pictures", name: "Pictures", path: "Pictures", childCount: 214),
            RemoteFolder(id: "archive", name: "Archive", path: "Archive", childCount: 7)
        ]
        libraryRoots = [
            FolderNode(folder: RemoteFolder(id: "library-root", name: "Documents", path: "/", childCount: 46, driveId: "company-drive", siteName: "Contoso", libraryName: "Documents", isLibraryRoot: true)),
            FolderNode(folder: RemoteFolder(id: "marketing-root", name: "Documents", path: "/", childCount: 18, driveId: "marketing-drive", siteName: "Marketing", libraryName: "Documents", isLibraryRoot: true))
        ]
        expandedLibrarySites = ["Contoso"]
        let sample = [
            SyncLocation(id: "documents", name: "Documents", path: "Documents"),
            SyncLocation(id: "projects", name: "Work projects", path: "Work projects"),
            SyncLocation(id: "pictures", name: "Pictures", path: "Pictures"),
            SyncLocation(id: "company-drive:library-root", name: "Contoso — Documents", path: "/", driveId: "company-drive", siteName: "Contoso", libraryName: "Documents")
        ]
        previewLocations = sample
        previewAccountName = "Alex’s OneDrive"
        previewAccountEmail = "alex@example.com"
        previewAccountType = "business"
    }
}

@main
private enum OneDriveApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = OneDriveAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
