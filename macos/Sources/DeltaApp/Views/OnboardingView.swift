import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Delta Native")
                .font(.largeTitle.bold())
            Text("Decentralized chat over e-mail.\nLog in with any e-mail account.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(spacing: 12) {
                    TextField("E-mail address", text: $model.loginEmail)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $model.loginPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)

                    if model.isConfiguring {
                        VStack(spacing: 4) {
                            ProgressView(value: model.configureProgress)
                            if let comment = model.configureComment {
                                Text(comment)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let error = model.loginError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: submit) {
                        Text("Log in")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isConfiguring || model.loginEmail.isEmpty)
                }
                .padding(8)
            }
            .frame(maxWidth: 340)

            HStack(spacing: 4) {
                Text("No account yet?")
                    .foregroundStyle(.secondary)
                Button("Try the demo") {
                    Task { await model.tryDemo() }
                }
                .disabled(model.isConfiguring)
            }

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 460, minHeight: 480)
    }

    private func submit() {
        guard !model.isConfiguring, !model.loginEmail.isEmpty else { return }
        Task { await model.logIn() }
    }
}

#Preview("Onboarding") {
    OnboardingView(model: AppModel(service: MockChatService()))
}
