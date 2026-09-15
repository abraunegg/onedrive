import Foundation
import OSLog

struct GraphParentReference: Codable, Sendable {
    let driveId: String?
    let id: String?
}

struct GraphFolderFacet: Codable, Sendable {
    let childCount: Int?
}

struct GraphFileFacet: Codable, Sendable {
    let mimeType: String?
    let hashes: [String: String]?
}

struct GraphDeletedFacet: Codable, Sendable {}

struct GraphDriveItem: Codable, Sendable {
    let id: String
    let name: String
    let size: Int64?
    let eTag: String?
    let cTag: String?
    let createdDateTime: Date?
    let lastModifiedDateTime: Date?
    let parentReference: GraphParentReference?
    let folder: GraphFolderFacet?
    let file: GraphFileFacet?
    let deleted: GraphDeletedFacet?
    let downloadURL: URL?

    var isFolder: Bool { folder != nil }
    var versionToken: String { eTag ?? cTag ?? "\(lastModifiedDateTime?.timeIntervalSince1970 ?? 0)" }

    private enum CodingKeys: String, CodingKey {
        case id, name, size, eTag, cTag, createdDateTime, lastModifiedDateTime, parentReference, folder, file, deleted
        case downloadURL = "@microsoft.graph.downloadUrl"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        size = try values.decodeIfPresent(Int64.self, forKey: .size)
        eTag = try values.decodeIfPresent(String.self, forKey: .eTag)
        cTag = try values.decodeIfPresent(String.self, forKey: .cTag)
        createdDateTime = try values.decodeIfPresent(Date.self, forKey: .createdDateTime)
        lastModifiedDateTime = try values.decodeIfPresent(Date.self, forKey: .lastModifiedDateTime)
        parentReference = try values.decodeIfPresent(GraphParentReference.self, forKey: .parentReference)
        folder = try values.decodeIfPresent(GraphFolderFacet.self, forKey: .folder)
        file = try values.decodeIfPresent(GraphFileFacet.self, forKey: .file)
        deleted = try values.decodeIfPresent(GraphDeletedFacet.self, forKey: .deleted)
        downloadURL = try values.decodeIfPresent(URL.self, forKey: .downloadURL)
    }
}

extension GraphDriveItem: ProviderVisibilityItem {
    var providerItemIsDeleted: Bool { deleted != nil }
    var providerItemIsFolder: Bool { isFolder }
    var providerItemParentID: String? { parentReference?.id }
}

struct GraphPage: Decodable, Sendable {
    let value: [GraphDriveItem]
    let nextLink: URL?
    let deltaLink: URL?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
        case deltaLink = "@odata.deltaLink"
    }
}

enum GraphError: Error, LocalizedError {
    case invalidResponse
    case http(Int, String)
    case missingContent
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Microsoft Graph returned an invalid response."
        case let .http(code, message): return "Microsoft Graph returned \(code): \(message)"
        case .missingContent: return "The requested OneDrive item has no downloadable content."
        case .cancelled: return "The transfer was cancelled."
        }
    }
}

final class GraphClient {
    typealias ResultHandler<T> = (Result<T, Error>) -> Void

    private let session: URLSession
    private let logger = Logger(subsystem: "org.onedrive.cli.macos.fileprovider", category: "Microsoft Graph")
    private let credentialStore: SharedCredentialStore
    private let downloadDirectory: () throws -> URL
    private let lock = NSLock()
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var tokenRefreshInFlight = false
    private var tokenWaiters: [ResultHandler<String>] = []

    init(
        session: URLSession = .shared,
        credentialStore: SharedCredentialStore = SharedCredentialStore(),
        testingAccessToken: String? = nil,
        downloadDirectory: @escaping () throws -> URL = { FileManager.default.temporaryDirectory }
    ) {
        self.session = session
        self.credentialStore = credentialStore
        self.downloadDirectory = downloadDirectory
        accessToken = testingAccessToken
        if testingAccessToken != nil { accessTokenExpiry = .distantFuture }
    }

    @discardableResult
    func item(driveID: String, itemID: String, completion: @escaping ResultHandler<GraphDriveItem>) -> Progress {
        requestJSON(path: itemPath(driveID: driveID, itemID: itemID), method: "GET", completion: completion)
    }

    @discardableResult
    func children(driveID: String, itemID: String, pageURL: URL?, completion: @escaping ResultHandler<GraphPage>) -> Progress {
        let fields = "id,name,size,eTag,cTag,createdDateTime,lastModifiedDateTime,parentReference,folder,file,deleted,@microsoft.graph.downloadUrl"
        let path = itemPath(driveID: driveID, itemID: itemID) + "/children?$top=200&$select=\(fields)"
        return requestJSON(path: path, absoluteURL: pageURL, method: "GET", completion: completion)
    }

    @discardableResult
    func delta(driveID: String, rootItemID: String, deltaURL: URL?, completion: @escaping ResultHandler<GraphPage>) -> Progress {
        let path = itemPath(driveID: driveID, itemID: rootItemID) + "/delta"
        return requestJSON(path: path, absoluteURL: deltaURL, method: "GET", completion: completion)
    }

    @discardableResult
    func download(_ item: GraphDriveItem, driveID: String, completion: @escaping ResultHandler<URL>) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        if let downloadURL = item.downloadURL {
            download(from: downloadURL, filename: item.name, authorization: nil, progress: progress, completion: completion)
            return progress
        }
        withAccessToken { [weak self] tokenResult in
            guard let self else { return }
            switch tokenResult {
            case let .failure(error): completion(.failure(error))
            case let .success(token):
                let url = self.graphURL(path: self.itemPath(driveID: driveID, itemID: item.id) + "/content")
                self.download(from: url, filename: item.name, authorization: token, progress: progress, completion: completion)
            }
        }
        return progress
    }

    @discardableResult
    func createFolder(driveID: String, parentID: String, name: String, completion: @escaping ResultHandler<GraphDriveItem>) -> Progress {
        let body: [String: Any] = ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"]
        return requestJSON(path: itemPath(driveID: driveID, itemID: parentID) + "/children", method: "POST", body: body, completion: completion)
    }

    @discardableResult
    func upload(driveID: String, parentID: String, name: String, contents: URL, replacing itemID: String?, eTag: String?, completion: @escaping ResultHandler<GraphDriveItem>) -> Progress {
        let size = ((try? contents.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size <= 4 * 1024 * 1024 {
            let path = itemID.map { itemPath(driveID: driveID, itemID: $0) + "/content" }
                ?? itemPath(driveID: driveID, itemID: parentID) + ":/\(encodePathSegment(name)):/content"
            return requestData(path: path, method: "PUT", fileURL: contents, eTag: eTag, completion: completion)
        }
        return uploadLarge(driveID: driveID, parentID: parentID, name: name, contents: contents, replacing: itemID, eTag: eTag, completion: completion)
    }

    @discardableResult
    func patch(driveID: String, itemID: String, name: String?, parentID: String?, eTag: String?, completion: @escaping ResultHandler<GraphDriveItem>) -> Progress {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let parentID { body["parentReference"] = ["id": parentID] }
        return requestJSON(path: itemPath(driveID: driveID, itemID: itemID), method: "PATCH", body: body, eTag: eTag, completion: completion)
    }

    @discardableResult
    func delete(driveID: String, itemID: String, eTag: String?, completion: @escaping ResultHandler<Void>) -> Progress {
        requestVoid(path: itemPath(driveID: driveID, itemID: itemID), method: "DELETE", eTag: eTag, completion: completion)
    }

    private func uploadLarge(driveID: String, parentID: String, name: String, contents: URL, replacing itemID: String?, eTag: String?, completion: @escaping ResultHandler<GraphDriveItem>) -> Progress {
        let progress = Progress(totalUnitCount: Int64((try? contents.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        let path = itemID.map { itemPath(driveID: driveID, itemID: $0) + "/createUploadSession" }
            ?? itemPath(driveID: driveID, itemID: parentID) + ":/\(encodePathSegment(name)):/createUploadSession"
        let body: [String: Any] = ["item": ["@microsoft.graph.conflictBehavior": itemID == nil ? "fail" : "replace", "name": name]]
        let sessionProgress = requestJSON(path: path, method: "POST", body: body, eTag: eTag) { [weak self] (result: Result<UploadSession, Error>) in
            guard let self else { return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(uploadSession):
                self.uploadChunks(fileURL: contents, uploadURL: uploadSession.uploadUrl, offset: 0, progress: progress, completion: completion)
            }
        }
        progress.cancellationHandler = { sessionProgress.cancel() }
        return progress
    }

    private func uploadChunks(fileURL: URL, uploadURL: URL, offset: Int64, progress: Progress, completion: @escaping ResultHandler<GraphDriveItem>) {
        if progress.isCancelled { completion(.failure(GraphError.cancelled)); return }
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            let total = Int64(values.fileSize ?? 0)
            let chunkSize = 10 * 1024 * 1024
            let handle = try FileHandle(forReadingFrom: fileURL)
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: min(chunkSize, Int(total - offset))) ?? Data()
            try handle.close()
            let end = offset + Int64(data.count) - 1
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue("bytes \(offset)-\(end)/\(total)", forHTTPHeaderField: "Content-Range")
            request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                if let error { completion(.failure(error)); return }
                guard let http = response as? HTTPURLResponse, let data else { completion(.failure(GraphError.invalidResponse)); return }
                if http.statusCode == 202 {
                    progress.completedUnitCount = end + 1
                    self.uploadChunks(fileURL: fileURL, uploadURL: uploadURL, offset: end + 1, progress: progress, completion: completion)
                } else {
                    self.decode(GraphDriveItem.self, data: data, response: http, completion: completion)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            task.resume()
        } catch { completion(.failure(error)) }
    }

    private struct UploadSession: Decodable { let uploadUrl: URL }

    private func download(from url: URL, filename: String, authorization: String?, progress: Progress, completion: @escaping ResultHandler<URL>) {
        var request = URLRequest(url: url)
        if let authorization { request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization") }
        let task = session.downloadTask(with: request) { temporaryURL, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let temporaryURL else {
                completion(.failure(GraphError.missingContent)); return
            }
            do {
                let directory = try self.downloadDirectory()
                let pathExtension = (filename as NSString).pathExtension
                var destination = directory.appendingPathComponent("onedrive-provider-\(UUID().uuidString)")
                if !pathExtension.isEmpty { destination.appendPathExtension(pathExtension) }
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                progress.completedUnitCount = 100
                completion(.success(destination))
            } catch { completion(.failure(error)) }
        }
        progress.cancellationHandler = { task.cancel() }
        task.resume()
    }

    @discardableResult
    private func requestJSON<T: Decodable>(path: String, absoluteURL: URL? = nil, method: String, body: [String: Any]? = nil, eTag: String? = nil, completion: @escaping ResultHandler<T>) -> Progress {
        request(path: path, absoluteURL: absoluteURL, method: method, body: body, eTag: eTag) { [weak self] data, response, error in
            guard let self else { return }
            if let error { completion(.failure(error)); return }
            guard let data, let response else { completion(.failure(GraphError.invalidResponse)); return }
            self.decode(T.self, data: data, response: response, completion: completion)
        }
    }

    @discardableResult
    private func requestData<T: Decodable>(path: String, method: String, fileURL: URL, eTag: String?, completion: @escaping ResultHandler<T>) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        withAccessToken { [weak self] tokenResult in
            guard let self else { return }
            switch tokenResult {
            case let .failure(error): completion(.failure(error))
            case let .success(token):
                var request = URLRequest(url: self.graphURL(path: path))
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                if let eTag { request.setValue(eTag, forHTTPHeaderField: "If-Match") }
                let task = self.session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                    if let error { completion(.failure(error)); return }
                    guard let data, let response = response as? HTTPURLResponse else { completion(.failure(GraphError.invalidResponse)); return }
                    self.decode(T.self, data: data, response: response, completion: completion)
                }
                progress.cancellationHandler = { task.cancel() }
                task.resume()
            }
        }
        return progress
    }

    @discardableResult
    private func requestVoid(path: String, method: String, eTag: String?, completion: @escaping ResultHandler<Void>) -> Progress {
        request(path: path, method: method, eTag: eTag) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let response else { completion(.failure(GraphError.invalidResponse)); return }
            guard (200..<300).contains(response.statusCode) else {
                completion(.failure(GraphError.http(response.statusCode, data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error")))
                return
            }
            completion(.success(()))
        }
    }

    @discardableResult
    private func request(path: String, absoluteURL: URL? = nil, method: String, body: [String: Any]? = nil, eTag: String? = nil, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        withAccessToken { [weak self] tokenResult in
            guard let self else { return }
            switch tokenResult {
            case let .failure(error): completion(nil, nil, error)
            case let .success(token):
                var request = URLRequest(url: absoluteURL ?? self.graphURL(path: path))
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let eTag { request.setValue(eTag, forHTTPHeaderField: "If-Match") }
                if let body {
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                let task = self.session.dataTask(with: request) { data, response, error in
                    progress.completedUnitCount = 100
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                        self.logger.error("Graph request \(request.url?.absoluteString ?? path, privacy: .public) failed with HTTP \(http.statusCode, privacy: .public): \(message, privacy: .public)")
                    }
                    completion(data, response as? HTTPURLResponse, error)
                }
                progress.cancellationHandler = { task.cancel() }
                task.resume()
            }
        }
        return progress
    }

    private func withAccessToken(_ completion: @escaping ResultHandler<String>) {
        lock.lock()
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(60) {
            lock.unlock()
            completion(.success(accessToken))
            return
        }
        tokenWaiters.append(completion)
        if tokenRefreshInFlight {
            lock.unlock()
            return
        }
        tokenRefreshInFlight = true
        lock.unlock()
        do {
            let credential = try credentialStore.load()
            let endpoint = URL(string: "\(credential.authEndpoint)/\(credential.tenantID)/oauth2/v2.0/token")!
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let fields = [
                "client_id": credential.clientID,
                "refresh_token": credential.refreshToken,
                "grant_type": "refresh_token",
                "scope": "Files.ReadWrite Files.ReadWrite.All Sites.ReadWrite.All offline_access"
            ]
            request.httpBody = fields.map { "\(formEncode($0.key))=\(formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
            session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                if let error { self.finishTokenRefresh(.failure(error)); return }
                guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                    let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Token refresh failed."
                    self.finishTokenRefresh(.failure(GraphError.http((response as? HTTPURLResponse)?.statusCode ?? 0, message)))
                    return
                }
                self.lock.lock()
                self.accessToken = token.accessToken
                self.accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
                self.lock.unlock()
                if let refreshToken = token.refreshToken, refreshToken != credential.refreshToken {
                    var rotated = credential
                    rotated.refreshToken = refreshToken
                    try? self.credentialStore.save(rotated)
                }
                self.finishTokenRefresh(.success(token.accessToken))
            }.resume()
        } catch { finishTokenRefresh(.failure(error)) }
    }

    private func finishTokenRefresh(_ result: Result<String, Error>) {
        lock.lock()
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        tokenRefreshInFlight = false
        lock.unlock()
        for waiter in waiters { waiter(result) }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private func itemPath(driveID: String, itemID: String) -> String {
        let drive = encodePathSegment(driveID)
        return itemID == "root" ? "/v1.0/drives/\(drive)/root" : "/v1.0/drives/\(drive)/items/\(encodePathSegment(itemID))"
    }

    private func graphURL(path: String) -> URL {
        let endpoint = (try? credentialStore.load().graphEndpoint) ?? "https://graph.microsoft.com"
        return URL(string: endpoint + path)!
    }

    private func encodePathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~!"))) ?? value
    }

    private func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._*"))) ?? value
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data, response: HTTPURLResponse, completion: ResultHandler<T>) {
        guard (200..<300).contains(response.statusCode) else {
            completion(.failure(GraphError.http(response.statusCode, String(data: data, encoding: .utf8) ?? "Unknown error")))
            return
        }
        do { completion(.success(try JSONDecoder.provider.decode(T.self, from: data))) }
        catch { completion(.failure(error)) }
    }
}
