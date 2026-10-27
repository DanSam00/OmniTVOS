import SwiftUI
#if os(iOS) || os(macOS)
import UserNotifications
#endif

/// First run on a device, after sign-in and choosing a profile: bring the
/// account's sign-ins over (`CredentialVault`), pick a Home layout and
/// favourite teams, and allow alerts. Once per device; Settings → Account
/// reopens the sign-ins step.
enum OnboardingState {
    private static let doneKey = "omni.onboarding.v1.done"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    static func markDone() { UserDefaults.standard.set(true, forKey: doneKey) }

    /// Settings → Account → Sync Passphrase: the sign-ins step on its own.
    static let openVaultNotification = Notification.Name("omni.onboarding.openVault")
}

struct OnboardingView: View {
    /// Signed in to an account; a guest has nothing to bring over.
    let isSignedIn: Bool
    /// Only the sign-ins step, reopened from Settings.
    var vaultOnly = false
    let onFinish: () -> Void

    private enum Step: CaseIterable { case vault, layout, collections, alerts, done }

    @ObservedObject private var vault = CredentialVault.shared
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = SettingsDefault.homeLayout
    @State private var step: Step = .vault
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var restored = false
    @State private var teams: [String] = FavouriteTeamsStore.teams()
    @State private var newTeam = ""
    @State private var community: [CommunityCollections.Item] = []
    @State private var communityLoading = false
    @State private var communityError: String?
    @State private var addingCollection: String?
    @State private var addedCollections: Set<String> = []
    private var isKidsProfile: Bool { ProfileSettings.current.bool(forKey: SettingsKey.kidsProfile) }
    #if os(macOS)
    @ObservedObject private var macFocus = MacSettingsRowFocus.shared
    #endif

    private var steps: [Step] {
        var list: [Step] = []
        if isSignedIn { list.append(.vault) }
        if vaultOnly { return list }
        list.append(.layout)
        // The community list needs a Nuvio sign-in.
        if isSignedIn, AppEdition.isOmniX { list.append(.collections) }
        #if os(iOS) || os(macOS)
        list.append(.alerts)
        #endif
        list.append(.done)
        return list
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    progress
                    switch step {
                    case .vault: vaultStep
                    case .layout: layoutStep
                    case .collections: collectionsStep
                    case .alerts: alertsStep
                    case .done: doneStep
                    }
                }
                .frame(maxWidth: Metrics.width, alignment: .leading)
                .padding(Metrics.padding)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            step = steps.first ?? .done
            // A box made on another device minutes ago would otherwise only
            // show up at the next full account pull.
            if isSignedIn { vault.refreshFromAccount() }
        }
        #if os(macOS)
        .modifier(MacSheetKeyboardHost())
        #endif
    }

    // MARK: Steps

    @ViewBuilder
    private var vaultStep: some View {
        title("Bring your sign-ins over")
        if vault.isChecking {
            HStack(spacing: 12) {
                ProgressView()
                text("Checking your account…")
            }
            .onAppear {}
        } else {
            vaultStepBody
        }
    }

    @ViewBuilder
    private var vaultStepBody: some View {
        switch vault.status {
        case .locked:
            text("This account keeps its IPTV logins, Trakt, Simkl, Jellyfin and SMB sign-ins encrypted with your sync passphrase. Enter it once on this device.")
            secure("Sync passphrase", $passphrase)
            #if os(tvOS)
            hint("Your iPhone can type it: look for the Apple TV keyboard alert.")
            #endif
            errorLine
            primary("Unlock", id: "onboard.unlock", enabled: !passphrase.isEmpty) {
                if vault.unlock(with: passphrase) {
                    passphrase = ""
                    message = nil
                    restored = true
                } else {
                    message = "That passphrase doesn't open this account's sign-ins."
                }
            }
            secondary("Skip — sign in on this device instead", id: "onboard.skipvault") { advance() }
        case .notSetUp:
            text("Choose a sync passphrase. Your IPTV logins and Trakt, Simkl, Jellyfin and SMB sign-ins are then encrypted with it and follow this account to your other devices. Nuvio's server only ever sees them scrambled.")
            secure("New passphrase (8 or more characters)", $passphrase)
            secure("Type it again", $confirmation)
            hint("Keep it somewhere safe. If it's lost, you sign in to those services again; nothing else is affected.")
            errorLine
            primary("Turn On Sync", id: "onboard.create", enabled: passphrase.count >= 8 && passphrase == confirmation) {
                vault.create(passphrase: passphrase)
                passphrase = ""
                confirmation = ""
                message = nil
                restored = true
            }
            secondary("Not now", id: "onboard.skipcreate") { advance() }
        case .unlocked:
            if restored, let summary = vault.lastRestore, !summary.isEmpty {
                text("Brought over to this device:")
                summaryList(summary)
            } else if restored {
                text("Sync is on. Sign-ins you add on this device now follow your account.")
            } else {
                text("This device already has your sync passphrase, so its sign-ins follow your account.")
            }
            primary(vaultOnly ? "Done" : "Continue", id: "onboard.vaultnext", enabled: true) { advance() }
            if vaultOnly {
                secondary("Forget the passphrase on this device", id: "onboard.lock") {
                    vault.lockThisDevice()
                    restored = false
                }
            }
        case .unavailable:
            text("Sign in to an account to bring your sign-ins over.")
            primary("Continue", id: "onboard.vaultnext", enabled: true) { advance() }
        }
    }

    @ViewBuilder
    private var layoutStep: some View {
        title("Make Home yours")
        text("Home layout")
        HStack(spacing: Metrics.chipSpacing) {
            ForEach(["Modern", "Compact", "Grid View"], id: \.self) { layout in
                chip(layout, isOn: homeLayout == layout, id: "onboard.layout.\(layout)") { homeLayout = layout }
            }
        }
        text("Favourite teams — their next match joins Continue Watching")
        HStack(spacing: Metrics.chipSpacing) {
            field("Team, e.g. Liverpool", $newTeam)
            primary("Add", id: "onboard.addteam", enabled: !newTeam.trimmingCharacters(in: .whitespaces).isEmpty, fill: false) {
                FavouriteTeamsStore.add(newTeam)
                teams = FavouriteTeamsStore.teams()
                newTeam = ""
            }
        }
        if !teams.isEmpty {
            FlowRow(spacing: Metrics.chipSpacing) {
                ForEach(teams, id: \.self) { team in
                    chip("\(team)  ✕", isOn: true, id: "onboard.team.\(team)") {
                        FavouriteTeamsStore.remove(team)
                        teams = FavouriteTeamsStore.teams()
                    }
                }
            }
        }
        primary("Continue", id: "onboard.layoutnext", enabled: true) { advance() }
    }

    @ViewBuilder
    private var collectionsStep: some View {
        title("Add some collections")
        text(isKidsProfile
            ? "Collections for kids and families, shared on nuvio.tv. From a big library only its children's sections are added."
            : "Collections people have shared on nuvio.tv: themed rows and folders for Home.")
        if communityLoading && community.isEmpty {
            HStack(spacing: 12) { ProgressView(); text("Loading…") }
        } else if let communityError, community.isEmpty {
            hint(communityError)
        } else {
            VStack(alignment: .leading, spacing: Metrics.chipSpacing) {
                ForEach(community.prefix(10)) { item in
                    collectionRow(item)
                }
            }
        }
        primary(addedCollections.isEmpty ? "Skip" : "Continue", id: "onboard.collectionsnext", enabled: true) { advance() }
    }

    private func collectionRow(_ item: CommunityCollections.Item) -> some View {
        let added = addedCollections.contains(item.id)
        return HStack(alignment: .center, spacing: Metrics.chipSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Metrics.button).lineLimit(1)
                if !item.description.isEmpty {
                    Text(item.description).font(Metrics.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
            }
            Spacer(minLength: Metrics.chipSpacing)
            if addingCollection == item.id {
                ProgressView()
            } else {
                chip(added ? "Added" : "Add", isOn: added, id: "onboard.collection.\(item.id)") {
                    guard !added, addingCollection == nil else { return }
                    addingCollection = item.id
                    Task {
                        let count = (try? await CommunityCollections.install(item, forKids: isKidsProfile)) ?? 0
                        addingCollection = nil
                        if count > 0 { addedCollections.insert(item.id) }
                    }
                }
            }
        }
    }

    private func loadCommunity() async {
        guard community.isEmpty, !communityLoading else { return }
        communityLoading = true
        defer { communityLoading = false }
        do {
            community = isKidsProfile
                ? try await CommunityCollections.kidsAndFamily()
                : try await CommunityCollections.list(sort: .popular, limit: 48).items
            if community.isEmpty {
                communityError = isKidsProfile
                    ? "No kids or family collections are shared right now."
                    : "No collections are shared right now."
            }
        } catch {
            communityError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var alertsStep: some View {
        title("Stay in the loop")
        text("Omni can tell you when a match you set a reminder for is about to start, and when a show you follow has a new episode.")
        primary("Allow Notifications", id: "onboard.allow", enabled: true) {
            #if os(iOS) || os(macOS)
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await MainActor.run { advance() }
            }
            #endif
        }
        secondary("Not now", id: "onboard.noalerts") { advance() }
    }

    @ViewBuilder
    private var doneStep: some View {
        title("You're all set")
        text("Everything here can be changed later in Settings.")
        primary("Start Watching", id: "onboard.finish", enabled: true) { finish() }
    }

    private func advance() {
        message = nil
        let list = steps
        guard let index = list.firstIndex(of: step), index + 1 < list.count else {
            finish()
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { step = list[index + 1] }
        if list[index + 1] == .collections { Task { await loadCommunity() } }
    }

    private func finish() {
        if !vaultOnly { OnboardingState.markDone() }
        onFinish()
    }

    // MARK: Pieces

    private var progress: some View {
        let list = steps.filter { $0 != .done }
        let index = list.firstIndex(of: step) ?? list.count
        return HStack(spacing: 8) {
            ForEach(list.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i <= index ? 0.9 : 0.25))
                    .frame(width: Metrics.dot, height: 5)
            }
        }
        .opacity(list.count > 1 ? 1 : 0)
    }

    private func summaryList(_ summary: CredentialVault.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if summary.iptvSources > 0 { bullet("\(summary.iptvSources) IPTV source\(summary.iptvSources == 1 ? "" : "s")") }
            if summary.trakt { bullet("Trakt sign-in") }
            if summary.simkl { bullet("Simkl sign-in") }
            if summary.jellyfinServers > 0 { bullet("\(summary.jellyfinServers) Jellyfin server\(summary.jellyfinServers == 1 ? "" : "s")") }
            if summary.smbShares > 0 { bullet("\(summary.smbShares) SMB share\(summary.smbShares == 1 ? "" : "s")") }
        }
    }

    private func bullet(_ value: String) -> some View {
        Label(value, systemImage: "checkmark.circle.fill").font(Metrics.body)
    }

    private func title(_ value: String) -> some View {
        Text(value).font(Metrics.title).fixedSize(horizontal: false, vertical: true)
    }

    private func text(_ value: String) -> some View {
        Text(value).font(Metrics.body).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ value: String) -> some View {
        Text(value).font(Metrics.caption).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var errorLine: some View {
        if let message {
            Text(message).font(Metrics.caption).foregroundStyle(.red)
        }
    }

    private func secure(_ placeholder: String, _ value: Binding<String>) -> some View {
        SecureField(placeholder, text: value)
            .font(Metrics.body)
            .textContentType(.password)
            .modifier(OnboardingFieldBackground())
    }

    private func field(_ placeholder: String, _ value: Binding<String>) -> some View {
        TextField(placeholder, text: value)
            .font(Metrics.body)
            .modifier(OnboardingFieldBackground())
    }

    private func primary(_ label: String, id: String, enabled: Bool, fill: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { if enabled { action() } }) {
            Text(label)
                .font(Metrics.button)
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.horizontal, Metrics.buttonPadding)
                .padding(.vertical, Metrics.buttonPadding * 0.6)
                .background(Color.white.opacity(enabled ? 1 : 0.4), in: Capsule())
                .foregroundStyle(.black)
                .overlay(focusRing(id))
        }
        .buttonStyle(OnboardingButtonStyle())
        .disabled(!enabled)
        .macSettingsRow(id) { if enabled { action() } }
    }

    private func secondary(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Metrics.body)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .overlay(focusRing(id))
        }
        .buttonStyle(OnboardingButtonStyle())
        .macSettingsRow(id, action: action)
    }

    private func chip(_ label: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Metrics.body)
                .padding(.horizontal, Metrics.buttonPadding * 0.8)
                .padding(.vertical, Metrics.buttonPadding * 0.4)
                .background(isOn ? Color.white : Color.white.opacity(0.12), in: Capsule())
                .foregroundStyle(isOn ? Color.black : Color.white)
                .overlay(focusRing(id))
        }
        .buttonStyle(OnboardingButtonStyle())
        .macSettingsRow(id, action: action)
    }

    @ViewBuilder
    private func focusRing(_ id: String) -> some View {
        #if os(macOS)
        if macFocus.focusedRowID == id {
            Capsule().strokeBorder(Color.accentColor, lineWidth: 3)
        }
        #endif
    }
}

/// A field's backing, except on tvOS, whose fields draw their own.
private struct OnboardingFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .padding(Metrics.fieldPadding)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }
}

/// Grows on tvOS focus, as the app's other buttons do; plain elsewhere.
private struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OnboardingButtonBody(configuration: configuration)
    }

    private struct OnboardingButtonBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(isFocused ? 1.06 : (configuration.isPressed ? 0.97 : 1))
                .shadow(color: .white.opacity(isFocused ? 0.35 : 0), radius: 12)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// Wraps its children onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Phone sizes, or the ten-foot sizes the TV and the Mac's scaled canvas use.
private enum Metrics {
    #if os(iOS)
    static let title = Font.largeTitle.weight(.bold)
    static let body = Font.body
    static let caption = Font.footnote
    static let button = Font.headline
    static let spacing: CGFloat = 18
    static let width: CGFloat = 560
    static let padding: CGFloat = 24
    static let fieldPadding: CGFloat = 12
    static let buttonPadding: CGFloat = 20
    static let chipSpacing: CGFloat = 8
    static let dot: CGFloat = 28
    #else
    static let title = Font.system(size: 52, weight: .bold)
    static let body = Font.system(size: 26)
    static let caption = Font.system(size: 21)
    static let button = Font.system(size: 26, weight: .semibold)
    static let spacing: CGFloat = 28
    static let width: CGFloat = 1000
    static let padding: CGFloat = 80
    static let fieldPadding: CGFloat = 18
    static let buttonPadding: CGFloat = 32
    static let chipSpacing: CGFloat = 14
    static let dot: CGFloat = 48
    #endif
}
