import FileProvider
import Foundation

private enum ProviderActivationError: LocalizedError {
    case existingDomainUpdateFailed(Error)

    var errorDescription: String? {
        switch self {
        case .existingDomainUpdateFailed:
            return "OneDrive couldn’t update Finder without removing your existing files. Your current Finder files were kept. Click Try again to finish the update."
        }
    }

    var failureReason: String? {
        switch self {
        case let .existingDomainUpdateFailed(error):
            return error.localizedDescription
        }
    }
}

final class ProviderCoordinator {
    private let configurationStore = ProviderConfigurationStore()
    private let credentialStore = SharedCredentialStore()

    func hasConfiguration() -> Bool {
        guard let configuration = try? configurationStore.load() else { return false }
        return !configuration.drives.isEmpty
    }

    func existingConfiguration() -> ProviderConfiguration? {
        try? configurationStore.load()
    }

    func resetDomainPreservingDownloadedUserData(completion: @escaping (Result<Void, Error>) -> Void) {
        let domain = makeDomain()
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, lookupError in
            if let lookupError {
                completion(.failure(lookupError))
                return
            }
            guard let registeredDomain = domains.first(where: { $0.identifier == domain.identifier }) else {
                completion(.success(()))
                return
            }
            NSFileProviderManager.remove(registeredDomain, mode: .preserveDownloadedUserData) { _, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }

    func activate(
        configuration: ProviderConfiguration,
        legacyConfigurationDirectory: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("OneDriveFileProvider.appex", isDirectory: true)
        guard let extensionURL, FileManager.default.fileExists(atPath: extensionURL.path) else {
            completion(.failure(CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "This app copy is missing its Finder Files On-Demand extension. Build and install the signed OneDrive app, not the UI preview."
            ])))
            return
        }
        let previousConfiguration = try? configurationStore.load()
        let previousCredential = try? credentialStore.load()
        do {
            try configurationStore.save(configuration)
            try migrateCredential(from: legacyConfigurationDirectory)
        } catch {
            restore(previousConfiguration, credential: previousCredential)
            completion(.failure(error))
            return
        }

        let domain = makeDomain()
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, lookupError in
            if let lookupError {
                self.restore(previousConfiguration, credential: previousCredential)
                completion(.failure(lookupError))
                return
            }
            let registeredDomain = domains.first { $0.identifier == domain.identifier }
            let alreadyRegistered = registeredDomain != nil
            let fail: (Error, NSFileProviderDomain?, Bool) -> Void = { error, domainToRestore, removeNewDomain in
                let finishFailure = {
                    if alreadyRegistered {
                        self.restore(previousConfiguration, credential: previousCredential)
                        completion(.failure(ProviderActivationError.existingDomainUpdateFailed(error)))
                    } else {
                        completion(.failure(error))
                    }
                }
                let restoreOldDomain = {
                    guard let domainToRestore else {
                        finishFailure()
                        return
                    }
                    NSFileProviderManager.add(domainToRestore) { _ in finishFailure() }
                }
                if removeNewDomain {
                    NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData) { _, _ in
                        restoreOldDomain()
                    }
                } else {
                    restoreOldDomain()
                }
            }
            let finish: (Error?, NSFileProviderDomain?, Bool) -> Void = { registrationError, domainToRestore, newDomainRegistered in
                if let registrationError {
                    fail(registrationError, domainToRestore, newDomainRegistered)
                    return
                }
                guard let manager = NSFileProviderManager(for: domain) else {
                    fail(CocoaError(.featureUnsupported, userInfo: [
                        NSLocalizedDescriptionKey: "macOS could not start the OneDrive File Provider extension."
                    ]), domainToRestore, newDomainRegistered)
                    return
                }
                manager.signalEnumerator(for: .rootContainer) { signalError in
                    if let signalError {
                        fail(signalError, domainToRestore, newDomainRegistered)
                        return
                    }
                    manager.signalEnumerator(for: .workingSet) { workingSetError in
                        if let workingSetError {
                            fail(workingSetError, domainToRestore, newDomainRegistered)
                            return
                        }
                        manager.getUserVisibleURL(for: .rootContainer) { url, urlError in
                            if let url { completion(.success(url)) }
                            else { fail(urlError ?? CocoaError(.fileNoSuchFile), domainToRestore, newDomainRegistered) }
                        }
                    }
                }
            }
            let addDomain = {
                NSFileProviderManager.add(domain) { registrationError in
                    finish(registrationError, nil, registrationError == nil)
                }
            }
            if let registeredDomain, registeredDomain.supportsSyncingTrash {
                // Older registrations used File Provider's default synced
                // Trash behavior, which this extension does not implement.
                // Re-register once while preserving the local materialized
                // data so existing installations receive the safer setting.
                NSFileProviderManager.remove(registeredDomain, mode: .preserveDownloadedUserData) { _, removalError in
                    if let removalError {
                        fail(removalError, nil, false)
                    } else {
                        NSFileProviderManager.add(domain) { registrationError in
                            finish(registrationError, registeredDomain, registrationError == nil)
                        }
                    }
                }
            } else if alreadyRegistered {
                finish(nil, nil, false)
            } else {
                addDomain()
            }
        }
    }

    func rootURL(completion: @escaping (URL?) -> Void) {
        let domain = makeDomain()
        guard let manager = NSFileProviderManager(for: domain) else { completion(nil); return }
        manager.getUserVisibleURL(for: .rootContainer) { url, _ in completion(url) }
    }

    private func makeDomain() -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: ProviderConstants.domainIdentifier),
            displayName: "OneDrive"
        )
        // OneDrive's DELETE API moves items to Microsoft's recycle bin. We do
        // not expose a local File Provider trash container, so let macOS
        // route deletes through deleteItem instead of querying `.trash`.
        domain.supportsSyncingTrash = false
        return domain
    }

    private func migrateCredential(from directory: URL) throws {
        let refreshTokenURL = directory.appendingPathComponent("refresh_token")
        let refreshToken = try String(contentsOf: refreshTokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshToken.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Your Microsoft session is empty. Sign in again."])
        }
        let values = configurationValues(at: directory.appendingPathComponent("config"))
        let endpoints = cloudEndpoints(for: values["azure_ad_endpoint"])
        let credential = ProviderCredential(
            refreshToken: refreshToken,
            clientID: values["application_id"] ?? ProviderConstants.defaultClientID,
            tenantID: values["azure_tenant_id"].flatMap { $0.isEmpty ? nil : $0 } ?? "common",
            authEndpoint: endpoints.auth,
            graphEndpoint: values["microsoft_graph_endpoint"].flatMap(validHTTPSURL) ?? endpoints.graph
        )
        try credentialStore.save(credential)
    }

    private func restore(_ configuration: ProviderConfiguration?, credential: ProviderCredential?) {
        if let configuration { try? configurationStore.save(configuration) }
        if let credential { try? credentialStore.save(credential) }
    }

    private func cloudEndpoints(for value: String?) -> (auth: String, graph: String) {
        switch value?.uppercased() {
        case "USL4": return ("https://login.microsoftonline.us", "https://graph.microsoft.us")
        case "USL5": return ("https://login.microsoftonline.us", "https://dod-graph.microsoft.us")
        case "DE": return ("https://login.microsoftonline.de", "https://graph.microsoft.de")
        case "CN": return ("https://login.chinacloudapi.cn", "https://microsoftgraph.chinacloudapi.cn")
        default: return ("https://login.microsoftonline.com", "https://graph.microsoft.com")
        }
    }

    private func validHTTPSURL(_ value: String) -> String? {
        guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func configurationValues(at url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value.removeFirst(); value.removeLast() }
            result[key] = value
        }
        return result
    }
}
