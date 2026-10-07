import Foundation

struct GmailProfile: Decodable {
    let emailAddress: String
}

struct GmailLabel: Decodable {
    let messagesUnread: Int?
}

struct GmailMessageList: Decodable {
    struct Ref: Decodable {
        let id: String
        let threadId: String
    }
    let messages: [Ref]?
}

struct GmailMessageMeta: Decodable {
    struct Header: Decodable {
        let name: String
        let value: String
    }
    struct Payload: Decodable {
        let headers: [Header]?
    }
    let id: String
    let threadId: String
    let snippet: String?
    let internalDate: String?
    let payload: Payload?

    func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct GmailMessageFull: Decodable {
    struct Body: Decodable {
        let attachmentId: String?
        let size: Int?
        let data: String?
    }
    struct Part: Decodable {
        let mimeType: String?
        let filename: String?
        let body: Body?
        let parts: [Part]?

        var flattened: [Part] { [self] + (parts ?? []).flatMap(\.flattened) }
    }
    let payload: Part?
}

extension Data {
    /// Gmail returns attachment bytes as unpadded base64url.
    init?(base64URL s: String) {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        self.init(base64Encoded: b64)
    }
}

/// Gmail REST API client for one account. Handles access-token refresh.
@MainActor
final class GmailClient {
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me/"

    let email: String
    private let oauth: OAuthClient
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var refreshing: Task<String, Error>?

    init(email: String, oauth: OAuthClient, accessToken: String? = nil, expiresIn: Int = 0) {
        self.email = email
        self.oauth = oauth
        self.accessToken = accessToken
        self.expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
    }

    func profile() async throws -> GmailProfile {
        try await get("profile")
    }

    func inboxUnreadCount() async throws -> Int {
        let label: GmailLabel = try await get("labels/INBOX")
        return label.messagesUnread ?? 0
    }

    func unreadInbox(max: Int) async throws -> [GmailMessageList.Ref] {
        let list: GmailMessageList = try await get("messages", query: [
            URLQueryItem(name: "labelIds", value: "INBOX"),
            URLQueryItem(name: "labelIds", value: "UNREAD"),
            URLQueryItem(name: "maxResults", value: String(max)),
        ])
        return list.messages ?? []
    }

    func message(_ id: String) async throws -> GmailMessageMeta {
        try await get("messages/\(id)", query: [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
        ])
    }

    /// PDF and image attachments of a message, for the bridge. Skips anything over `maxBytes`.
    func attachments(_ id: String, maxBytes: Int = 15 * 1024 * 1024) async throws -> [(name: String, mime: String, data: Data)] {
        let full: GmailMessageFull = try await get("messages/\(id)", query: [URLQueryItem(name: "format", value: "full")])
        var out: [(name: String, mime: String, data: Data)] = []
        for part in full.payload?.flattened ?? [] {
            guard let name = part.filename, !name.isEmpty, let mime = part.mimeType?.lowercased(),
                  mime == "application/pdf" || mime.hasPrefix("image/") || name.lowercased().hasSuffix(".pdf"),
                  (part.body?.size ?? 0) <= maxBytes else { continue }
            var encoded = part.body?.data
            if encoded == nil, let aid = part.body?.attachmentId {
                let body: GmailMessageFull.Body = try await get("messages/\(id)/attachments/\(aid)")
                encoded = body.data
            }
            guard let encoded, let data = Data(base64URL: encoded) else { continue }
            out.append((name, mime == "application/octet-stream" ? "application/pdf" : mime, data))
        }
        return out
    }

    func removeLabels(_ labels: [String], from ids: [String]) async throws {
        _ = try await send("messages/batchModify", method: "POST", json: ["ids": ids, "removeLabelIds": labels])
    }

    func trash(_ id: String) async throws {
        _ = try await send("messages/\(id)/trash", method: "POST")
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        json: [String: Any]? = nil,
        retryOnUnauthorized: Bool = true
    ) async throws -> Data {
        var comps = URLComponents(string: Self.base + path)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retryOnUnauthorized {
            accessToken = nil
            return try await send(path, method: method, query: query, json: json, retryOnUnauthorized: false)
        }
        guard (200..<300).contains(status) else {
            struct ErrorBody: Decodable {
                struct Inner: Decodable { let message: String? }
                let error: Inner?
            }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
            throw AppError("Gmail API error \(status)\(message.map { ": \($0)" } ?? "")")
        }
        return data
    }

    private func token() async throws -> String {
        if let accessToken, Date() < expiry.addingTimeInterval(-60) {
            return accessToken
        }
        if let refreshing {
            return try await refreshing.value
        }
        guard let refreshToken = Keychain.get(email) else { throw AuthExpired() }
        let task = Task { [oauth] () throws -> String in
            let resp = try await OAuth.refresh(client: oauth, refreshToken: refreshToken)
            self.accessToken = resp.access_token
            self.expiry = Date().addingTimeInterval(TimeInterval(resp.expires_in))
            return resp.access_token
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
}
