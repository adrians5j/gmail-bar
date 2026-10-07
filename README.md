# GmailBar

A small macOS menu bar app for Gmail. It shows the unread count next to an envelope icon. Click it to see unread inbox mail for every connected account, and it posts a notification when new mail arrives.

From the popover you can:

- click a message to open it in Gmail in your default browser
- hover a message to mark it read, archive it, or delete it
- mark all read or open the inbox per account (or click the account name)
- right-click a message for the same actions

The settings menu (gear icon) has notifications on/off, sound, launch at login, and the poll interval (default 1 minute). It also checks right after the Mac wakes up.

Filters (gear icon > Filters…) hide unread mail whose sender, subject or preview contains a pattern, ignoring case. Hidden mail isn't listed, counted or notified. Tick "Mark as read" on a filter to also mark matching mail as read in Gmail.

Links open in your default browser, even if you've installed Gmail as a Safari web app.

## Vibe Bridge

Every new message goes to [Vibe Bridge](../vibe-bridge) as an `email.received` event, with its PDF and image attachments (15 MB max each). Filtered mail goes too, flagged `filtered`, because bill senders often end up behind a filter. After a restart, the app publishes unread mail newer than the last message it published. The first run publishes nothing old. To send what's already in the inbox, use gear icon > Publish inbox to Vibe Bridge, or launch with `open -a GmailBar --args --publish-inbox`. Both send every unread message, filtered ones included, and the bridge ignores ids it already has. If the bridge isn't running, events wait in its inbox folder.

## Build and install

Needs Xcode or the Swift toolchain, macOS 13 or newer.

```sh
./build.sh           # builds build/GmailBar.app
./build.sh install   # also copies it to ~/Applications and launches it
```

Turn on "Launch at login" from the gear menu after installing to ~/Applications.

## One-time Google Cloud setup

GmailBar uses the Gmail API with an OAuth client you own. Google doesn't hand these out, so you create one. It takes about five minutes.

1. Go to https://console.cloud.google.com and create a project, for example "GmailBar".
2. Open APIs & Services > Library, search for "Gmail API", and click Enable.
3. Open APIs & Services > OAuth consent screen (called "Google Auth Platform" in newer consoles).
   - User type: External, so both @gmail.com and Workspace accounts can sign in.
   - Fill in the app name and your email. Skip logo and domains.
   - Scopes: you can leave this empty. The app asks for `gmail.modify` at sign-in.
   - Under Audience, add every address you want to connect as a test user.
4. Publish the app (Audience > Publish app). Do this. In "Testing" mode Google expires refresh tokens after 7 days, and you'd have to reconnect every week. Published but unverified is fine for personal use. You'll see a "Google hasn't verified this app" screen at sign-in. Click Advanced, then continue.
5. Open APIs & Services > Credentials > Create credentials > OAuth client ID, choose **Desktop app**, and download the JSON.
6. In GmailBar, click "Choose client JSON…" and pick that file. The app copies it to `~/Library/Application Support/GmailBar/client_secret.json`.
7. Click the add-account icon and sign in in the browser. Repeat for each account.

For a Workspace account (like webiny.com), the admin console can block third-party apps from Gmail scopes. If sign-in fails with an "access blocked" or admin policy error, allow the client ID under Security > API controls > App access control.

## Where things live

- Refresh tokens: login keychain, service `dev.adrian.GmailBar`, one item per email address.
- Account list and settings: `defaults read dev.adrian.GmailBar`.
- OAuth client: `~/Library/Application Support/GmailBar/client_secret.json`.

The app is ad-hoc signed, so every rebuild has a new signature. After a rebuild macOS asks once whether GmailBar may read its keychain items. Click "Always Allow".

## Code

- `GmailBarApp.swift` sets up the `MenuBarExtra` scene.
- `AppModel.swift` handles polling, new-mail detection, message actions, and accounts.
- `GmailClient.swift` is the Gmail REST client plus access-token refresh.
- `OAuth.swift` runs the browser sign-in with PKCE and a loopback redirect on 127.0.0.1.
- `Views.swift` is the popover UI.
- `Notifier.swift` posts notifications. Clicking one opens the message.
- `AppModel.publish` sends new mail to Vibe Bridge. `GmailClient.attachments` downloads the files.
