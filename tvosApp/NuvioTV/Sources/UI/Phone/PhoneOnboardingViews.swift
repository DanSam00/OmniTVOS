#if os(iOS)
import PhotosUI
import SwiftUI

/// Sign-in for the phone. Email and password rather than the TV's QR code:
/// the phone *is* the device you would scan the code with.
struct PhoneLoginView: View {
    @ObservedObject var auth: AuthManager
    let onContinue: () -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var didContinue = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image("BrandWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180)
                    .padding(.top, 72)

                VStack(spacing: 6) {
                    Text(isSignUp ? "Create account" : "Sign in")
                        .font(.title.weight(.bold))
                    Text("Sync add-ons, profiles and progress with your Apple TV.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .phoneFieldStyle()
                    SecureField("Password", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .phoneFieldStyle()
                }

                if let error = auth.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button(action: submit) {
                        Group {
                            if auth.isBusy { ProgressView().tint(.black) } else { Text(isSignUp ? "Create Account" : "Sign In") }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.black)
                    }
                    .disabled(auth.isBusy || email.isEmpty || password.isEmpty || !auth.isBackendConfigured)

                    Button(isSignUp ? "I already have an account" : "Create an account") {
                        isSignUp.toggle()
                        auth.errorMessage = nil
                    }
                    .font(.subheadline)

                    Button("Continue without account") {
                        auth.skipLogin()
                        continueOnce()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { if auth.isAuthenticated { continueOnce() } }
        .onChange(of: auth.authState) { _, state in
            if state.isAuthenticated { continueOnce() }
        }
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        focusedField = nil
        Task {
            if isSignUp {
                await auth.signUp(email: email, password: password)
            } else {
                await auth.signIn(email: email, password: password)
            }
        }
    }

    private func continueOnce() {
        guard !didContinue else { return }
        didContinue = true
        onContinue()
    }
}

private extension View {
    func phoneFieldStyle() -> some View {
        padding(14)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Syncing your account" for the phone: the Omni wordmark loader at phone
/// size, in place of the TV's 44pt text and system spinner.
struct PhoneAccountSyncWaitView: View {
    var body: some View {
        VStack(spacing: 28) {
            BrandLoadingView(wordmarkWidth: 600)
            VStack(spacing: 6) {
                Text("Syncing your account")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Importing your profiles and watch history.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}

/// "Who's watching?" for the phone. Selection goes through the same
/// `ProfileViewModel.requestSwitch`, which handles PIN-protected profiles.
struct PhoneProfilePickerView: View {
    @ObservedObject var viewModel: ProfileViewModel
    var accountSyncError: String?
    var onRetryAccountSync: () -> Void
    /// Pushes the new profile to the Nuvio account, as the TV does.
    var onProfileCreated: () -> Void = {}
    /// Deletes from the account and this device; returns an error message.
    var onDeleteProfile: (Profile) async -> String? = { _ in nil }

    @State private var pin = ""
    @State private var isAddingProfile = false
    @State private var profilePendingDelete: Profile?
    @State private var deleteError: String?
    /// The account allows six profiles, as on the TV.
    private static let maxProfiles = 6

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("Who's watching?")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 72)

                if let error = accountSyncError {
                    VStack(spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry", action: onRetryAccountSync)
                    }
                }

                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(viewModel.profiles) { profile in
                        Button { viewModel.requestSwitch(to: profile) } label: {
                            VStack(spacing: 10) {
                                // The account's own avatar art, as on the TV.
                                ProfileAvatarView(avatarId: profile.avatarId, size: 96, profileId: profile.id)
                                    .frame(width: 96, height: 96)
                                    .overlay(alignment: .bottomTrailing) {
                                        if profile.isPinProtected {
                                            Image(systemName: "lock.fill")
                                                .font(.caption)
                                                .padding(6)
                                                .background(.black.opacity(0.6), in: Circle())
                                        }
                                    }
                                Text(profile.name).font(.headline).lineLimit(1)
                                if ProfileSettings.store(for: profile.id).bool(forKey: SettingsKey.kidsProfile) {
                                    Text("KIDS")
                                        .font(.caption2.weight(.heavy))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.yellow, in: Capsule())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        // Long-press to delete; the primary profile can't be.
                        .contextMenu {
                            if profile.id != viewModel.primaryProfile?.id {
                                Button("Delete Profile", systemImage: "trash", role: .destructive) {
                                    profilePendingDelete = profile
                                }
                            }
                        }
                    }

                    if viewModel.profiles.count < Self.maxProfiles {
                        Button { isAddingProfile = true } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.largeTitle.weight(.semibold))
                                    .frame(width: 96, height: 96)
                                    .background(Color.white.opacity(0.1), in: Circle())
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                                Text("Add Profile").font(.headline).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.loadProfiles()
            AvatarCatalogStore.shared.loadIfNeeded()
        }
        .sheet(isPresented: $isAddingProfile) {
            PhoneAddProfileSheet(viewModel: viewModel) {
                isAddingProfile = false
                onProfileCreated()
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Delete \(profilePendingDelete?.name ?? "profile")?",
            isPresented: Binding(get: { profilePendingDelete != nil }, set: { if !$0 { profilePendingDelete = nil } }),
            presenting: profilePendingDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                Task { deleteError = await onDeleteProfile(profile) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the profile from your Nuvio account on every device, with its library, watch history and settings.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .alert("Enter PIN", isPresented: $viewModel.isPinEntryVisible) {
            SecureField("PIN", text: $pin).keyboardType(.numberPad)
            Button("Unlock") {
                viewModel.verifyAndSwitch(pin: pin)
                pin = ""
            }
            Button("Cancel", role: .cancel) {
                pin = ""
                viewModel.pendingProfileId = nil
            }
        } message: {
            Text(viewModel.pinError ?? "This profile is locked.")
        }
    }
}
/// New profile: name, Kids, avatar (the account's catalog or a custom image
/// link), an optional PIN, and what to take from the primary profile — all
/// of which is on by default. Saved through `ProfileViewModel.createProfile`,
/// the TV's path; the caller then pushes it to the Nuvio account.
private struct PhoneAddProfileSheet: View {
    @ObservedObject var viewModel: ProfileViewModel
    let onCreated: () -> Void

    @ObservedObject private var catalog = AvatarCatalogStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var avatarId = ProfileAvatarCatalog.defaultId
    @State private var photo: Data?
    @State private var isKids = false
    @State private var usesPin = false
    @State private var pin = ""
    @State private var setup = NewProfileSetup()
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && (!usesPin || pin.count == 4) && !viewModel.isLoading
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ProfileAvatarView(avatarId: avatarId, size: 110, photo: photo)
                        .frame(width: 110, height: 110)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .padding(14)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Toggle("Kids profile", isOn: $isKids)
                            .padding(.top, 4)
                        Text("Only shows films rated up to PG and shows up to TV-PG, and nothing tagged horror, thriller, crime or war.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Avatar").font(.headline)
                        PhoneAvatarGrid(selectedAvatarId: $avatarId, photo: $photo)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Lock with a PIN", isOn: $usesPin.animation())
                        if usesPin {
                            SecureField("4-digit PIN", text: $pin)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .padding(14)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onChange(of: pin) { _, value in
                                    let digits = String(value.filter(\.isNumber).prefix(4))
                                    if digits != value { pin = digits }
                                }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Setup from Primary").font(.headline)
                            Text("Reuse \(viewModel.primaryProfile?.name ?? "Primary")'s add-ons and plugins, and start with a copy of its settings. Turn off anything this profile should set up itself.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Use primary profile add-ons", isOn: $setup.usesPrimaryAddons)
                        Toggle("Use primary profile plugins", isOn: $setup.usesPrimaryPlugins)
                        Toggle("Copy primary settings", isOn: $setup.copiesSettings.animation())
                        Toggle("Also copy API keys and linked services", isOn: $setup.copiesCredentials)
                            .disabled(!setup.copiesSettings)
                            .opacity(setup.copiesSettings ? 1 : 0.45)
                        Text("Settings are copied once; the two profiles change independently after. Linked services are Trakt, Simkl, TMDB, MDBList and your debrid service.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let error = viewModel.profileCreationError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Add Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.profileCreationError = nil
            nameFocused = true
        }
    }

    private func save() {
        guard canSave else { return }
        nameFocused = false
        viewModel.createProfile(
            name: trimmedName,
            pin: usesPin ? pin : nil,
            avatarId: avatarId,
            isKids: isKids,
            setup: setup,
            customAvatarPhoto: photo,
            onCreated: onCreated
        )
    }
}
/// The account's avatars with a "+" tile first: a photo from the library
/// (kept for Omni, with a random catalog avatar for Nuvio's own apps) or an
/// image link. Shared by Add Profile and the Settings avatar picker.
struct PhoneAvatarGrid: View {
    @Binding var selectedAvatarId: String
    @Binding var photo: Data?
    @ObservedObject private var catalog = AvatarCatalogStore.shared
    @State private var isChoosingSource = false
    @State private var isPickingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var isEnteringURL = false
    @State private var urlText = ""

    private var hasCustomAvatar: Bool {
        photo != nil || (!selectedAvatarId.isEmpty && !catalog.items.contains { $0.id == selectedAvatarId })
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
            Button { isChoosingSource = true } label: {
                ZStack {
                    if hasCustomAvatar {
                        ProfileAvatarView(avatarId: selectedAvatarId, size: 64, photo: photo)
                    } else {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .frame(width: 64, height: 64)
                            .background(Color.white.opacity(0.1), in: Circle())
                    }
                }
                .frame(width: 64, height: 64)
                .overlay(
                    Circle().strokeBorder(Color.white, lineWidth: hasCustomAvatar ? 3 : 1)
                        .opacity(hasCustomAvatar ? 1 : 0.3)
                        .padding(hasCustomAvatar ? -4 : 0)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Custom avatar")

            ForEach(catalog.items) { item in
                Button {
                    selectedAvatarId = item.id
                    photo = nil
                } label: {
                    ProfileAvatarView(avatarId: item.id, size: 64)
                        .frame(width: 64, height: 64)
                        .overlay(
                            Circle().strokeBorder(Color.white, lineWidth: photo == nil && selectedAvatarId == item.id ? 3 : 0)
                                .padding(-4)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.displayName)
            }
        }
        .overlay {
            if catalog.items.isEmpty { ProgressView() }
        }
        .onAppear { catalog.loadIfNeeded() }
        .confirmationDialog("Custom avatar", isPresented: $isChoosingSource) {
            Button("Choose from Photos") { isPickingPhoto = true }
            Button("Paste Image Link") {
                urlText = photo == nil && hasCustomAvatar ? selectedAvatarId : ""
                isEnteringURL = true
            }
            if hasCustomAvatar {
                Button("Remove Custom Avatar", role: .destructive) {
                    photo = nil
                    selectedAvatarId = OmniCustomAvatar.randomCatalogAvatarId()
                }
            }
        } message: {
            Text("A photo shows in Omni on all your devices; Nuvio's own apps show one of its avatars instead. A link shows everywhere.")
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                defer { pickedItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let jpeg = OmniCustomAvatar.prepare(data) else { return }
                photo = jpeg
                // Nuvio's apps can't show the photo; give them a catalog avatar.
                if !catalog.items.contains(where: { $0.id == selectedAvatarId }) {
                    selectedAvatarId = OmniCustomAvatar.randomCatalogAvatarId()
                }
            }
        }
        .alert("Image link", isPresented: $isEnteringURL) {
            TextField("https://example.com/avatar.png", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use Image") {
                let link = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isImageLink(link) {
                    selectedAvatarId = link
                    photo = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste a direct link to an image, such as an avatar from Xperience. It shows in Nuvio's apps too.")
        }
    }

    static func isImageLink(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }
}

/// Settings → Account → Choose Avatar on the phone. The TV's picker is laid
/// out for a 1920-point screen and ran off both edges, hiding its buttons.
struct PhoneAvatarPickerSheet: View {
    let title: String
    let profileId: String
    /// The Nuvio avatar, and the Omni photo (nil to remove it).
    let onSave: (String, Data?) -> Void
    @State private var avatarId: String
    @State private var photo: Data?
    @Environment(\.dismiss) private var dismiss

    init(title: String, profileId: String, selectedAvatarId: String, onSave: @escaping (String, Data?) -> Void) {
        self.title = title
        self.profileId = profileId
        self.onSave = onSave
        _avatarId = State(initialValue: selectedAvatarId)
        let stored = ProfileSettings.store(for: profileId).string(forKey: SettingsKey.customAvatarPhoto)
        _photo = State(initialValue: stored.flatMap { Data(base64Encoded: $0) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ProfileAvatarView(avatarId: avatarId, size: 110, photo: photo)
                        .frame(width: 110, height: 110)
                        .padding(.top, 12)
                    PhoneAvatarGrid(selectedAvatarId: $avatarId, photo: $photo)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(avatarId, photo)
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
