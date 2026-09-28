#if os(iOS)
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

/// "Who's watching?" for the phone. Selection goes through the same
/// `ProfileViewModel.requestSwitch`, which handles PIN-protected profiles.
struct PhoneProfilePickerView: View {
    @ObservedObject var viewModel: ProfileViewModel
    var accountSyncError: String?
    var onRetryAccountSync: () -> Void

    @State private var pin = ""

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
                                Circle()
                                    .fill(avatarColor(for: profile))
                                    .frame(width: 96, height: 96)
                                    .overlay {
                                        Text(String(profile.name.prefix(1)).uppercased())
                                            .font(.largeTitle.weight(.bold))
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        if profile.isPinProtected {
                                            Image(systemName: "lock.fill")
                                                .font(.caption)
                                                .padding(6)
                                                .background(.black.opacity(0.6), in: Circle())
                                        }
                                    }
                                Text(profile.name).font(.headline).lineLimit(1)
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
        .onAppear { viewModel.loadProfiles() }
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

    private func avatarColor(for profile: Profile) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        // `hashValue` is reseeded every launch; this stays put.
        let index = profile.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count
        return palette[index].opacity(0.8)
    }
}
#endif
