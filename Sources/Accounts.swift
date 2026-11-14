import SwiftUI
import LocalAuthentication

// MARK: - Multiple accounts

/// A signed-in account. Secrets stay in the Keychain; this is only the list shown in Settings.
struct AccountRef: Codable, Hashable, Identifiable {
    let address: String
    let username: String
    var id: String { address + "|" + username }
    var host: String {
        if let id = ConnectionAddress.quickConnectID(address), address.hasPrefix("quickconnect://") { return id + " (QuickConnect)" }
        return URL(string: address)?.host ?? address
    }
}
enum AccountStore {
    private static let key = "accounts"
    static var all: [AccountRef] {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([AccountRef].self, from: $0) } ?? []
    }
    static func add(_ account: AccountRef) {
        var list = all.filter { $0 != account }
        list.insert(account, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
    static func remove(_ account: AccountRef) {
        UserDefaults.standard.set(try? JSONEncoder().encode(all.filter { $0 != account }), forKey: key)
        AccountVault.discard(account)
    }
}
/// Moves the active Keychain session (and saved password, if any) in and out of per-account slots.
enum AccountVault {
    private static func slot(_ account: AccountRef) -> String { "account-" + LibraryCache.hash(account.id) }
    /// Parks the active account's secrets so another account can sign in.
    static func park(_ account: AccountRef) {
        let parked = slot(account)
        for service in [".session", ".credentials"] {
            if let data = try? Keychain.load(service: service) {
                try? Keychain.save(data, service: service, background: true, slot: parked)
            } else {
                try? Keychain.clear(service: service, slot: parked)
            }
            try? Keychain.clear(service: service)
        }
    }
    /// Restores a parked account into the active slot. Returns false if nothing was parked.
    @discardableResult static func unpark(_ account: AccountRef) -> Bool {
        let parked = slot(account)
        guard let session = try? Keychain.load(service: ".session", slot: parked) else { return false }
        try? Keychain.save(session, service: ".session", background: true)
        if let credentials = try? Keychain.load(service: ".credentials", slot: parked) {
            try? Keychain.save(credentials, service: ".credentials", background: true)
        } else {
            try? Keychain.clear(service: ".credentials")
        }
        discard(account)
        return true
    }
    static func discard(_ account: AccountRef) {
        for service in [".session", ".credentials"] { try? Keychain.clear(service: service, slot: slot(account)) }
    }
}

struct AccountsSection: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let others = AccountStore.all.filter { $0.id != app.account }
        Section {
            ForEach(others) { account in
                Button {
                    dismiss()
                    Task { await app.switchAccount(to: account) }
                } label: {
                    HStack(spacing: 12) {
                        Text(String(account.username.prefix(1)).uppercased())
                            .font(.headline).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Color.secondary, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.username).foregroundStyle(.primary)
                            Text(account.host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Switch").font(.subheadline)
                    }
                }
                .swipeActions { Button("Remove", role: .destructive) { AccountStore.remove(account) } }
                .accessibilityLabel("Switch to \(account.username) on \(account.host)")
            }
            Button { dismiss(); Task { await app.beginAddingAccount() } } label: {
                Label("Add account", systemImage: "person.badge.plus")
            }
        } header: { Text("Accounts") } footer: {
            Text("Backup runs for the account you’re using. Other accounts stay signed in until you switch to them.")
        }
    }
}

// MARK: - Re-sign-in

/// Shown when the NAS session expires and no saved password can renew it. Keeps you on the
/// current screen instead of returning to the login page.
struct ReauthSheet: View {
    @EnvironmentObject private var app: AppModel
    @State private var password = ""
    @State private var otp = ""
    @State private var needsOTP = false
    @State private var remember = true
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Account", value: app.username)
                    LabeledContent("Server", value: AccountRef(address: app.address, username: app.username).host)
                    SecureField("Password", text: $password).textContentType(.password)
                    if needsOTP {
                        TextField("Verification code", text: $otp).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    }
                    Toggle("Stay signed in", isOn: $remember)
                } footer: {
                    Text(failure ?? "Your NAS session expired. Enter your password to continue where you left off.")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle("Sign in again").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out", role: .destructive) { Task { await app.signOut() } }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { Task { await submit() } }.disabled(busy || password.isEmpty)
                }
            }
            .overlay { if busy { ProgressView() } }
            .interactiveDismissDisabled()
        }
    }
    private func submit() async {
        busy = true; failure = nil
        defer { busy = false }
        do {
            try await app.renewSession(password: password, otp: otp, remember: remember)
            password = ""; otp = ""
        } catch AuthError.otpRequired {
            withAnimation { needsOTP = true }
            failure = AuthError.otpRequired.localizedDescription
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - App lock

/// Shows the lock in its own window above everything, including open sheets, so nothing
/// behind it is readable in the app switcher.
@MainActor final class LockWindow {
    static let shared = LockWindow()
    private var window: UIWindow?
    func update(locked: Bool, app: AppModel) {
        if !locked {
            UIView.animate(withDuration: 0.2, animations: { self.window?.alpha = 0 }) { _ in self.window?.isHidden = true; self.window = nil }
            return
        }
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: AppLockView().environmentObject(app))
        window.rootViewController?.view.backgroundColor = .clear
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Face ID / passcode lock, shown at launch and after the app has been in the background.
struct AppLockView: View {
    @EnvironmentObject private var app: AppModel
    @State private var failure: String?
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.tint)
                Text("Fotera is locked").font(.title3.bold())
                Button("Unlock") { Task { await unlock() } }.buttonStyle(.borderedProminent)
                if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }.padding(32)
        }
        .task { await unlock() }
        .accessibilityAddTraits(.isModal)
    }
    private func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Without a passcode there's nothing to check against; don't lock the user out.
            app.locked = false; return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your photo library") {
                withAnimation { app.locked = false }
            }
        } catch {
            failure = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }
}
