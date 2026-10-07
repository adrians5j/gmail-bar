import AppKit

enum Browser {
    /// Opens the URL in the default browser. A plain `NSWorkspace.open` hands
    /// mail.google.com links to an installed Gmail web app instead, if there is one.
    static func open(_ url: URL) {
        guard let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
    }
}
