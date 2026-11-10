import AppKit
import SwiftUI

/// Sign-in status with Sign In / Sign Out, and the code to enter while signing in.
struct BCCAccountView: View {
    @ObservedObject var account: BCCMediaAccount

    var body: some View {
        switch account.state {
        case .signedOut:
            HStack {
                Text("Not signed in").foregroundStyle(.secondary)
                Spacer()
                Button("Sign In…") { account.signIn() }
                    .help("Sign in with your BCC account. You sign in in your browser or on your phone; CueDeck never sees your password.")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Try Again") { account.signIn() }
                }
            }
        case .waiting(let code, let url):
            VStack(alignment: .leading, spacing: 10) {
                Text("Open the sign-in page, check that it shows this code and sign in with your BCC account:")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the code")
                }
                HStack {
                    Button("Open Sign-in Page") { NSWorkspace.shared.open(url) }
                        .keyboardShortcut(.defaultAction)
                        .help(url.absoluteString)
                    Text(url.host ?? "").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                    Button("Cancel") { account.cancelSignIn() }
                }
                Text("You can also open \(url.absoluteString) on your phone.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .signedIn(let name):
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Signed in as \(name)")
                Spacer()
                Button("Sign Out") { account.signOut() }
                    .help("Forget the BCC Media sign-in on this Mac")
            }
        }
    }
}

/// File › Add BCC Media Link…: sign in if needed, paste a link from
/// app.bcc.media, and the episode becomes a cue.
struct BCCLinkSheet: View {
    @EnvironmentObject var engine: PlaybackEngine
    @ObservedObject var account: BCCMediaAccount
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add BCC Media Link", systemImage: "globe").font(.title3.weight(.semibold))

            if account.isSignedIn, case .signedIn = account.state {
                Text("Paste the link of an episode from app.bcc.media. It plays from the internet with all its audio languages and subtitles.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $link, prompt: Text("https://app.bcc.media/episode/…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    BCCAccountView(account: account).font(.caption)
                }
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Add") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || BCCMedia.episodeID(from: link) == nil)
                }
            } else {
                Text("To play BCC Media episodes, sign in with your BCC account once.")
                    .font(.callout).foregroundStyle(.secondary)
                BCCAccountView(account: account)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            // A BCC Media link on the clipboard is filled in.
            if let s = NSPasteboard.general.string(forType: .string), BCCMedia.episodeID(from: s) != nil, s.contains("bcc.media") {
                link = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func add() {
        guard !busy, BCCMedia.episodeID(from: link) != nil else { return }
        busy = true
        error = nil
        Task {
            do {
                try await engine.addBCCEpisode(link: link)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Settings › BCC Media.
struct BCCSettings: View {
    @EnvironmentObject var engine: PlaybackEngine

    var body: some View {
        Form {
            Section {
                BCCAccountView(account: engine.bcc)
            } header: {
                Text("BCC account")
            } footer: {
                Text("Add episodes with File › Add BCC Media Link… (⇧⌘L). They play from the internet, so this Mac needs a connection during the show. You sign in in your browser or on your phone; CueDeck never sees your password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
