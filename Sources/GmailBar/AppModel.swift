import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import VibeBridgeKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountState] = []
    @Published private(set) var hasClient = false
    @Published private(set) var refreshing = false
    @Published private(set) var addingAccount = false
    @Published var banner: String?

    @Published var pollMinutes: Int {
        didSet {
            defaults.set(pollMinutes, forKey: "pollMinutes")
            restartTimer()
        }
    }
    @Published var notificationsOn: Bool {
        didSet { defaults.set(notificationsOn, forKey: "notificationsOn") }
    }
    @Published var soundOn: Bool {
        didSet { defaults.set(soundOn, forKey: "soundOn") }
    }
    @Published var filters: [MailFilter] {
        didSet {
            defaults.set(try? JSONEncoder().encode(filters), forKey: "filters")
            for account in accounts {
                show(account.email)
                markFilteredRead(account.email)
            }
        }
    }

    var totalUnread: Int { accounts.reduce(0) { $0 + $1.unread } }
    var needsAttention: Bool { accounts.contains { $0.needsReauth } }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private static let maxMessages = 25

    private let defaults = UserDefaults.standard
    private var oauth: OAuthClient?
    private var clients: [String: GmailClient] = [:]
    /// Message ids already shown per account, so only new ones notify.
    /// Missing entry means the account hasn't loaded yet (no notifications on first load).
    private var seen: [String: Set<String>] = [:]
    private var cache: [String: MailMessage] = [:]
    /// Unfiltered unread inbox per account, as of the last refresh.
    private var inboxes: [String: (messages: [MailMessage], unread: Int)] = [:]
    private var timer: Timer?
    private var lastRefresh = Date.distantPast
    private var lastSound = Date.distantPast
    private var activity: NSObjectProtocol?

    init() {
        pollMinutes = defaults.object(forKey: "pollMinutes") as? Int ?? 1
        notificationsOn = defaults.object(forKey: "notificationsOn") as? Bool ?? true
        soundOn = defaults.object(forKey: "soundOn") as? Bool ?? true
        filters = defaults.data(forKey: "filters").flatMap { try? JSONDecoder().decode([MailFilter].self, from: $0) } ?? []

        oauth = OAuthClient.load()
        hasClient = oauth != nil
        let emails = defaults.stringArray(forKey: "accounts") ?? []
        accounts = emails.map { AccountState(email: $0) }
        if let oauth {
            for email in emails { clients[email] = GmailClient(email: email, oauth: oauth) }
        }

        // Keep App Nap from stretching the poll timer while the popover is closed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Polling Gmail"
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.refreshAll()
            }
        }

        restartTimer()
        refreshAll()
    }

    // MARK: - Refresh

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 30 { refreshAll() }
    }

    func refreshAll() {
        guard !refreshing, !accounts.isEmpty else { return }
        refreshing = true
        lastRefresh = Date()
        let emails = accounts.map(\.email)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for email in emails {
                    group.addTask { await self.refresh(email) }
                }
            }
            refreshing = false
        }
    }

    private func refresh(_ email: String) async {
        guard let client = clients[email] else {
            update(email) { $0.error = "No OAuth client configured." }
            return
        }
        do {
            async let count = client.inboxUnreadCount()
            let refs = try await client.unreadInbox(max: Self.maxMessages)
            let missing = refs.filter { cache[$0.id] == nil }
            let fetched = try await withThrowingTaskGroup(of: MailMessage.self, returning: [MailMessage].self) { group in
                for ref in missing {
                    group.addTask { MailMessage(meta: try await client.message(ref.id), account: email) }
                }
                var out: [MailMessage] = []
                for try await message in group { out.append(message) }
                return out
            }
            for message in fetched { cache[message.id] = message }
            let messages = refs.compactMap { cache[$0.id] }.sorted { $0.date > $1.date }
            let ids = Set(messages.map(\.id))
            cache = cache.filter { $0.value.account != email || ids.contains($0.key) }

            if let previous = seen[email] {
                let arrived = messages.filter { !previous.contains($0.id) }
                notify(account: email, messages: arrived.filter { !isFiltered($0) })
                publish(arrived, client: client)
            } else if publishInboxOnLaunch {
                // Launched with --publish-inbox: hand over everything unread, not just what's new.
                publish(messages, client: client)
            } else {
                // First load since launch: catch up on mail that came in while the app wasn't running.
                publish(messages.filter { $0.date > bridgeWatermark }, client: client)
            }
            seen[email, default: []].formUnion(ids)

            inboxes[email] = (messages, try await count)
            show(email)
            markFilteredRead(email)
            update(email) {
                $0.error = nil
                $0.needsReauth = false
                $0.loaded = true
            }
        } catch is AuthExpired {
            update(email) {
                $0.needsReauth = true
                $0.error = nil
                $0.loaded = true
            }
        } catch {
            update(email) {
                $0.error = error.localizedDescription
                $0.loaded = true
            }
        }
    }

    private func isFiltered(_ message: MailMessage) -> Bool {
        filters.contains { $0.matches(message) }
    }

    /// Publishes the account's inbox with filtered mail left out of the list and the count.
    private func show(_ email: String) {
        guard let inbox = inboxes[email] else { return }
        let visible = inbox.messages.filter { !isFiltered($0) }
        let hidden = inbox.messages.count - visible.count
        update(email) {
            $0.messages = visible
            $0.unread = max(inbox.unread - hidden, visible.count)
        }
    }

    /// Marks mail matching an "auto mark as read" filter as read in Gmail.
    private func markFilteredRead(_ email: String) {
        guard let client = clients[email], let inbox = inboxes[email] else { return }
        let ids = inbox.messages.filter { message in
            filters.contains { $0.markRead && $0.matches(message) }
        }.map(\.id)
        guard !ids.isEmpty else { return }
        forget(ids, in: email)
        Task {
            do {
                try await client.removeLabels(["UNREAD"], from: ids)
            } catch {
                banner = "Couldn't mark filtered mail as read: \(error.localizedDescription)"
            }
        }
    }

    private func forget(_ ids: [String], in email: String) {
        guard var inbox = inboxes[email] else { return }
        let before = inbox.messages.count
        inbox.messages.removeAll { ids.contains($0.id) }
        inbox.unread = max(0, inbox.unread - (before - inbox.messages.count))
        inboxes[email] = inbox
        show(email)
    }

    private func notify(account: String, messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        playNewMailSound()
        guard notificationsOn else { return }
        if messages.count > 3 {
            let senders = Array(NSOrderedSet(array: messages.map(\.senderName))) as? [String] ?? []
            Notifier.shared.post(
                title: "\(messages.count) new emails",
                subtitle: account,
                body: senders.prefix(4).joined(separator: ", "),
                url: GmailLinks.inbox(account: account)
            )
            return
        }
        for message in messages {
            Notifier.shared.post(
                title: message.senderName,
                subtitle: message.subject,
                body: message.snippet,
                url: message.gmailURL
            )
        }
    }

    /// Set by launching with `--publish-inbox` (`open -a GmailBar --args --publish-inbox`).
    private let publishInboxOnLaunch = CommandLine.arguments.contains("--publish-inbox")

    /// Sends every unread inbox message, filtered ones included, to the bridge.
    /// For mail that was already there before the bridge existed; the bridge drops
    /// ids it has seen, so running it twice is harmless.
    func publishInbox() {
        var total = 0
        for (email, inbox) in inboxes {
            guard let client = clients[email] else { continue }
            publish(inbox.messages, client: client)
            total += inbox.messages.count
        }
        banner = total == 0 ? "No unread mail to publish." : "Publishing \(total) emails to Vibe Bridge."
    }

    /// Newest message date handed to the bridge, so a relaunch only publishes what's newer.
    /// Starts at the first launch with the bridge, so the existing inbox isn't replayed.
    private var bridgeWatermark: Date {
        get {
            if let d = defaults.object(forKey: "bridgeWatermark") as? Date { return d }
            let now = Date()
            defaults.set(now, forKey: "bridgeWatermark")
            return now
        }
        set { defaults.set(newValue, forKey: "bridgeWatermark") }
    }

    /// Sends new mail to Vibe Bridge as `email.received`, with PDF and image attachments.
    /// Filtered mail goes too, flagged, since that's often where bills end up.
    private func publish(_ messages: [MailMessage], client: GmailClient) {
        guard !messages.isEmpty else { return }
        if let newest = messages.map(\.date).max(), newest > bridgeWatermark { bridgeWatermark = newest }
        let items = messages.map { m in
            (m, EmailReceived(account: m.account, messageId: m.id, threadId: m.threadId, fromName: m.senderName,
                              fromEmail: m.senderEmail, subject: m.subject, snippet: m.snippet, date: m.date,
                              url: m.gmailURL.absoluteString, filtered: isFiltered(m)))
        }
        Task {
            for (message, payload) in items {
                var files: [VibeBridge.File] = []
                do {
                    files = try await client.attachments(message.id).map { VibeBridge.File(name: $0.name, mime: $0.mime, data: $0.data) }
                } catch {
                    // Still publish the email; a consumer that needs the file can open it in Gmail.
                    NSLog("GmailBar: attachments for \(message.id): \(error.localizedDescription)")
                }
                do {
                    try VibeBridge.publish(type: EmailReceived.type, source: "gmail-bar",
                                           id: "gmail:\(message.account):\(message.id)", data: payload, files: files)
                } catch {
                    NSLog("GmailBar: publish to Vibe Bridge failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Played by the app rather than attached to the notification, so it isn't
    /// silenced by the notification settings. Accounts refresh in parallel, so
    /// several with new mail in one check still play it once.
    private func playNewMailSound() {
        guard soundOn, Date().timeIntervalSince(lastSound) > 3 else { return }
        lastSound = Date()
        NSSound(named: "Glass")?.play()
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, pollMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer?.tolerance = 5
    }

    private func update(_ email: String, _ change: (inout AccountState) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        change(&accounts[index])
    }

    // MARK: - Message actions

    func open(_ message: MailMessage) {
        Browser.open(message.gmailURL)
    }

    func openInbox(_ email: String) {
        Browser.open(GmailLinks.inbox(account: email))
    }

    func markRead(_ message: MailMessage) {
        perform(on: [message]) { try await $0.removeLabels(["UNREAD"], from: [message.id]) }
    }

    func archive(_ message: MailMessage) {
        perform(on: [message]) { try await $0.removeLabels(["INBOX", "UNREAD"], from: [message.id]) }
    }

    func trash(_ message: MailMessage) {
        perform(on: [message]) { try await $0.trash(message.id) }
    }

    func markAllRead(_ email: String) {
        guard let account = accounts.first(where: { $0.email == email }), !account.messages.isEmpty else { return }
        let messages = account.messages
        perform(on: messages) { try await $0.removeLabels(["UNREAD"], from: messages.map(\.id)) }
    }

    /// Removes the messages from the list right away, then calls the API.
    /// On failure, shows the error and reloads the account.
    private func perform(on messages: [MailMessage], _ action: @escaping (GmailClient) async throws -> Void) {
        guard let email = messages.first?.account, let client = clients[email] else { return }
        forget(messages.map(\.id), in: email)
        Task {
            do {
                try await action(client)
            } catch {
                banner = error.localizedDescription
                await refresh(email)
            }
        }
    }

    // MARK: - Accounts and settings

    func chooseClientFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Select the OAuth client JSON you downloaded from Google Cloud Console"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let client = try OAuthClient.install(from: url)
            oauth = client
            hasClient = true
            banner = nil
            for account in accounts {
                clients[account.email] = GmailClient(email: account.email, oauth: client)
            }
            refreshAll()
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Also used to reconnect an expired account: signing in with the same
    /// address overwrites its stored token.
    func addAccount() {
        guard let oauth else {
            chooseClientFile()
            return
        }
        guard !addingAccount else { return }
        addingAccount = true
        banner = nil
        Task {
            defer { addingAccount = false }
            do {
                let tokens = try await OAuth.authorize(client: oauth)
                guard let refreshToken = tokens.refresh_token else {
                    throw AppError("Google didn't return a refresh token. Remove GmailBar at myaccount.google.com/permissions and try again.")
                }
                let probe = GmailClient(email: "", oauth: oauth, accessToken: tokens.access_token, expiresIn: tokens.expires_in)
                let email = try await probe.profile().emailAddress
                try Keychain.set(refreshToken, for: email)
                clients[email] = GmailClient(email: email, oauth: oauth, accessToken: tokens.access_token, expiresIn: tokens.expires_in)
                if !accounts.contains(where: { $0.email == email }) {
                    accounts.append(AccountState(email: email))
                    saveAccounts()
                }
                NSApp.activate(ignoringOtherApps: true)
                await refresh(email)
            } catch {
                banner = error.localizedDescription
            }
        }
    }

    func removeAccount(_ email: String) {
        Keychain.delete(email)
        clients[email] = nil
        seen[email] = nil
        inboxes[email] = nil
        cache = cache.filter { $0.value.account != email }
        accounts.removeAll { $0.email == email }
        saveAccounts()
    }

    func moveAccount(_ email: String, by offset: Int) {
        guard let from = accounts.firstIndex(where: { $0.email == email }) else { return }
        let to = from + offset
        guard accounts.indices.contains(to) else { return }
        accounts.swapAt(from, to)
        saveAccounts()
    }

    func addFilter(_ pattern: String, markRead: Bool) {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        filters.append(MailFilter(pattern: pattern, markRead: markRead))
    }

    func removeFilter(_ id: UUID) {
        filters.removeAll { $0.id == id }
    }

    func setMarkRead(_ markRead: Bool, for id: UUID) {
        guard let index = filters.firstIndex(where: { $0.id == id }) else { return }
        filters[index].markRead = markRead
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            banner = "Launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    private func saveAccounts() {
        defaults.set(accounts.map(\.email), forKey: "accounts")
    }
}
