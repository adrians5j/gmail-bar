import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let unread = model.totalUnread
        HStack(spacing: 3) {
            if model.needsAttention {
                Image(systemName: "envelope.badge.shield.half.filled")
            } else {
                Image(systemName: unread > 0 ? "envelope.badge.fill" : "envelope")
            }
            if unread > 0 {
                Text("\(unread)")
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingFilters = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model) { showingFilters = true }
            Divider()
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
                Divider()
            }
            if model.addingAccount {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                Divider()
            }
            if showingFilters {
                FiltersView(model: model) { showingFilters = false }
            } else if !model.hasClient {
                SetupView(model: model)
            } else if model.accounts.isEmpty {
                EmptyAccountsView(model: model)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.accounts) { account in
                            Section {
                                AccountBody(account: account, model: model)
                            } header: {
                                AccountHeader(account: account, model: model)
                            }
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
        .frame(width: 400)
        .onAppear { model.refreshIfStale() }
    }

    /// MenuBarExtra windows size to their content, and a ScrollView has no
    /// useful ideal height, so estimate one from the rows.
    private var listHeight: CGFloat {
        var height: CGFloat = 0
        for account in model.accounts {
            let hasStatusRow = account.messages.isEmpty || account.error != nil || account.needsReauth
            height += 38
            height += hasStatusRow ? 36 : 0
            height += CGFloat(account.messages.count) * 82
        }
        return min(max(height, 80), 560)
    }
}

private struct HeaderBar: View {
    @ObservedObject var model: AppModel
    let showFilters: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.fill")
                .foregroundStyle(.red)
            Text("Gmail")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if model.refreshing {
                ProgressView().controlSize(.small).frame(width: 18)
            } else {
                IconButton(systemName: "arrow.clockwise", help: "Check now") { model.refreshAll() }
            }
            IconButton(systemName: "person.badge.plus", help: "Add account") { model.addAccount() }
            SettingsMenu(model: model, showFilters: showFilters)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SettingsMenu: View {
    @ObservedObject var model: AppModel
    let showFilters: () -> Void

    var body: some View {
        Menu {
            Button("Add account…") { model.addAccount() }
            Button("Choose OAuth client file…") { model.chooseClientFile() }
            Button("Filters…", action: showFilters)
            Button("Publish inbox to Vibe Bridge") { model.publishInbox() }
            Divider()
            Toggle("Notifications", isOn: $model.notificationsOn)
            Toggle("Sound on new mail", isOn: $model.soundOn)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Picker("Check every", selection: $model.pollMinutes) {
                ForEach([1, 2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
            }
            Divider()
            Button("Quit GmailBar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }
}

private struct AccountHeader: View {
    let account: AccountState
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.openInbox(account.email) } label: {
                HStack(spacing: 8) {
                    Text(account.email)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if account.unread > 0 {
                        Text("\(account.unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.red))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open inbox")
            Spacer()
            if !account.messages.isEmpty {
                IconButton(systemName: "envelope.open", help: "Mark all as read") { model.markAllRead(account.email) }
            }
            IconButton(systemName: "tray", help: "Open inbox") { model.openInbox(account.email) }
            Menu {
                Button("Reconnect…") { model.addAccount() }
                Button("Move up") { model.moveAccount(account.email, by: -1) }
                Button("Move down") { model.moveAccount(account.email, by: 1) }
                Divider()
                Button("Remove account") { model.removeAccount(account.email) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FiltersView: View {
    @ObservedObject var model: AppModel
    let done: () -> Void
    @State private var pattern = ""
    @State private var markRead = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconButton(systemName: "chevron.left", help: "Back", action: done)
                Text("Filters")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.bar)
            Divider()
            Text("Mail whose sender, subject or preview contains a pattern isn't shown, counted or notified. Case doesn't matter.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            ForEach(model.filters) { filter in
                HStack(spacing: 8) {
                    Text(filter.pattern)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Toggle("Mark as read", isOn: Binding(
                        get: { filter.markRead },
                        set: { model.setMarkRead($0, for: filter.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    IconButton(systemName: "trash", help: "Remove filter") { model.removeFilter(filter.id) }
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Pattern, e.g. slop cop", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Toggle("Mark as read", isOn: $markRead)
                    .toggleStyle(.checkbox)
                Button("Add", action: add)
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.system(size: 11))
            .controlSize(.small)
            .padding(12)
        }
    }

    private func add() {
        model.addFilter(pattern, markRead: markRead)
        pattern = ""
        markRead = false
    }
}

private struct AccountBody: View {
    let account: AccountState
    @ObservedObject var model: AppModel

    var body: some View {
        if account.needsReauth {
            HStack {
                Label("Sign-in expired", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Reconnect") { model.addAccount() }
                    .controlSize(.small)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 36)
        } else if let error = account.error {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
        } else if !account.loaded {
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
        } else if account.messages.isEmpty {
            Text("No unread mail")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
        }
        ForEach(account.messages) { message in
            MessageRow(message: message, model: model)
        }
    }
}

private struct MessageRow: View {
    let message: MailMessage
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.senderName, key: message.senderEmail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.senderName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hovering {
                        IconButton(systemName: "envelope.open", help: "Mark as read") { model.markRead(message) }
                        IconButton(systemName: "archivebox", help: "Archive") { model.archive(message) }
                        IconButton(systemName: "trash", help: "Delete") { model.trash(message) }
                    } else {
                        Text(Self.format(message.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 16)
                Text(message.subject)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(message.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.open(message) }
        .contextMenu {
            Button("Open in Gmail") { model.open(message) }
            Button("Mark as read") { model.markRead(message) }
            Button("Archive") { model.archive(message) }
            Button("Delete") { model.trash(message) }
        }
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    private static let fullFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    private static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormat.string(from: date) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) { return dayFormat.string(from: date) }
        return fullFormat.string(from: date)
    }
}

private struct Avatar: View {
    let name: String
    let key: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay(
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var color: Color {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.72)
    }
}

private struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            IconButton(systemName: "xmark", help: "Dismiss", action: dismiss)
        }
        .padding(12)
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-time setup")
                .font(.system(size: 13, weight: .semibold))
            Text("GmailBar talks to the Gmail API with your own Google Cloud OAuth client. Create a Desktop app client, download its JSON, then pick that file here. The README has the full steps.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose client JSON…") { model.chooseClientFile() }
                Button("Open Google Cloud Console") {
                    Browser.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
    }
}

private struct EmptyAccountsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Text("No accounts yet")
                .font(.system(size: 13, weight: .semibold))
            Button("Add Gmail account") { model.addAccount() }
                .disabled(model.addingAccount)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}
