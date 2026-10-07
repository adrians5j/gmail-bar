import AppKit
import CryptoKit
import Foundation
import Network

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The refresh token was revoked or expired; the user has to sign in again.
struct AuthExpired: LocalizedError {
    var errorDescription: String? { "Sign-in expired. Reconnect this account." }
}

enum AppPaths {
    static let support = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GmailBar", isDirectory: true)
}

/// OAuth client credentials from the JSON file Google Cloud Console gives you
/// for a "Desktop app" client.
struct OAuthClient {
    let clientId: String
    let clientSecret: String

    static var fileURL: URL { AppPaths.support.appendingPathComponent("client_secret.json") }

    static func load() -> OAuthClient? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? parse(data)
    }

    static func install(from url: URL) throws -> OAuthClient {
        let data = try Data(contentsOf: url)
        let client = try parse(data)
        try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return client
    }

    private static func parse(_ data: Data) throws -> OAuthClient {
        struct Inner: Decodable {
            let client_id: String
            let client_secret: String
        }
        struct Wrapper: Decodable {
            let installed: Inner?
            let web: Inner?
        }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        guard let inner = wrapper.installed ?? wrapper.web else {
            throw AppError("That file has no \"installed\" section. Create an OAuth client of type Desktop app.")
        }
        return OAuthClient(clientId: inner.client_id, clientSecret: inner.client_secret)
    }
}

struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
}

enum OAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.modify"
    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Opens Google sign-in in the browser and waits for the loopback redirect.
    static func authorize(client: OAuthClient) async throws -> TokenResponse {
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let verifier = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomURLSafe(16)

        var comps = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "state", value: state),
        ]
        Browser.open(comps.url!)

        let timeout = Task {
            try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            receiver.cancel()
        }
        defer { timeout.cancel() }

        let params = try await receiver.waitForCallback()
        guard params["state"] == state else { throw AppError("Sign-in failed: state mismatch.") }
        if let error = params["error"] { throw AppError("Sign-in failed: \(error)") }
        guard let code = params["code"] else { throw AppError("Sign-in failed: no authorization code.") }

        return try await tokenRequest([
            "code": code,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
    }

    static func refresh(client: OAuthClient, refreshToken: String) async throws -> TokenResponse {
        try await tokenRequest([
            "refresh_token": refreshToken,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "grant_type": "refresh_token",
        ])
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(form)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct ErrorBody: Decodable {
                let error: String
                let error_description: String?
            }
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            if body?.error == "invalid_grant" { throw AuthExpired() }
            throw AppError("Token request failed (\(status)): \(body?.error_description ?? body?.error ?? "unknown error")")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func randomURLSafe(_ byteCount: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tiny HTTP server on 127.0.0.1 that catches the OAuth redirect.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "GmailBar.oauth-loopback")
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.portContinuation = cont
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = self.listener.port?.rawValue {
                            self.portContinuation?.resume(returning: port)
                            self.portContinuation = nil
                        }
                    case .failed(let error):
                        self.portContinuation?.resume(throwing: error)
                        self.portContinuation = nil
                        self.finish(.failure(error))
                    default:
                        break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.result {
                    cont.resume(with: result)
                } else {
                    self.callbackContinuation = cont
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(AppError("Sign-in timed out."))) }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2,
                  let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
                conn.cancel()
                return
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] where params[item.name] == nil {
                params[item.name] = item.value ?? ""
            }
            // Browsers also ask for /favicon.ico and similar; ignore those.
            guard params["code"] != nil || params["error"] != nil else {
                self.respond(conn, status: "404 Not Found", html: "")
                return
            }
            let message = params["code"] != nil
                ? "Signed in. You can close this tab and go back to GmailBar."
                : "Sign-in failed: \(params["error"] ?? "unknown error"). You can close this tab."
            self.respond(conn, status: "200 OK", html: """
                <!doctype html><meta charset="utf-8"><title>GmailBar</title>
                <body style="font:16px -apple-system,sans-serif;padding:48px;text-align:center">\(message)</body>
                """)
            self.finish(.success(params))
        }
    }

    private func respond(_ conn: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Must run on `queue`.
    private func finish(_ result: Result<[String: String], Error>) {
        guard self.result == nil else { return }
        self.result = result
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
    }
}
