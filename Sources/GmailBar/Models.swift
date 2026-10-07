import Foundation

struct MailMessage: Identifiable, Equatable {
    let id: String
    let threadId: String
    let account: String
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let date: Date

    init(meta: GmailMessageMeta, account: String) {
        id = meta.id
        threadId = meta.threadId
        self.account = account
        (senderName, senderEmail) = Self.parseFrom(meta.header("From") ?? "")
        let subject = meta.header("Subject")?.trimmingCharacters(in: .whitespaces) ?? ""
        self.subject = subject.isEmpty ? "(no subject)" : subject
        snippet = (meta.snippet ?? "").decodingHTMLEntities
        let millis = Double(meta.internalDate ?? "") ?? 0
        date = Date(timeIntervalSince1970: millis / 1000)
    }

    var gmailURL: URL { GmailLinks.thread(account: account, threadId: threadId) }

    /// `"Jane Doe" <jane@example.com>` -> ("Jane Doe", "jane@example.com")
    private static func parseFrom(_ raw: String) -> (String, String) {
        guard let lt = raw.lastIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt else {
            return (raw.isEmpty ? "(unknown sender)" : raw, raw)
        }
        let email = String(raw[raw.index(after: lt)..<gt])
        let name = raw[..<lt]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (name.isEmpty ? email : name, email)
    }
}

/// Hides unread mail whose sender, subject or preview contains `pattern`.
struct MailFilter: Codable, Identifiable, Equatable {
    var id = UUID()
    var pattern: String
    var markRead = false

    func matches(_ message: MailMessage) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        return [message.senderName, message.senderEmail, message.subject, message.snippet].contains {
            $0.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

struct AccountState: Identifiable, Equatable {
    let email: String
    var unread = 0
    var messages: [MailMessage] = []
    var error: String?
    var needsReauth = false
    var loaded = false

    var id: String { email }
}

enum GmailLinks {
    /// `/mail/u/<email>/` 404s in some browsers. `authuser` makes Google redirect
    /// to the right `/mail/u/<n>/` for however the browser numbers its accounts.
    private static func base(_ account: String) -> String {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        comps.queryItems = [URLQueryItem(name: "authuser", value: account)]
        return comps.string!
    }

    static func inbox(account: String) -> URL {
        URL(string: base(account) + "#inbox")!
    }

    static func thread(account: String, threadId: String) -> URL {
        URL(string: base(account) + "#all/\(threadId)")!
    }
}

extension String {
    /// Gmail snippets come HTML-escaped (`&#39;`, `&amp;`, ...).
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        var out = ""
        var i = startIndex
        while i < endIndex {
            if self[i] == "&",
               let semi = self[i...].prefix(12).firstIndex(of: ";"),
               let ch = Self.entity(String(self[index(after: i)..<semi])) {
                out.append(ch)
                i = index(after: semi)
            } else {
                out.append(self[i])
                i = index(after: i)
            }
        }
        return out
    }

    private static func entity(_ name: String) -> Character? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        var code: UInt32?
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            code = UInt32(name.dropFirst(2), radix: 16)
        } else if name.hasPrefix("#") {
            code = UInt32(name.dropFirst())
        }
        return code.flatMap(Unicode.Scalar.init).map(Character.init)
    }
}
