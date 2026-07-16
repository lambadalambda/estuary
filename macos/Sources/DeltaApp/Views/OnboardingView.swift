import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var showEmailLogin = false

    var body: some View {
        VStack(spacing: 20) {
            if model.canReturnToMain {
                HStack {
                    Button {
                        model.returnToMain()
                    } label: {
                        Label("Back to Chats", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            Spacer()

            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Delta Native")
                .font(.largeTitle.bold())
            Text("Instant, decentralized messaging.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // Primary: instant chatmail profile — no visible e-mail.
            GroupBox {
                VStack(spacing: 12) {
                    TextField("Your name", text: $model.profileName)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.name)
                        .onSubmit(createProfile)

                    if model.isConfiguring, !model.showSecondDeviceSheet, !showEmailLogin {
                        progressSection
                    }
                    if let error = model.loginError, !model.showSecondDeviceSheet, !showEmailLogin {
                        errorText(error)
                    }

                    Button(action: createProfile) {
                        Text("Create New Profile")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isConfiguring)

                    Text("A chat profile is created for you on a privacy-preserving relay. No sign-up, no phone number.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
            }
            .frame(maxWidth: 360)

            // Secondary: bring an existing account over from another device.
            Button {
                model.loginError = nil
                model.showSecondDeviceSheet = true
            } label: {
                Label("Already using Delta Chat? Add this Mac as a second device", systemImage: "qrcode")
            }
            .disabled(model.isConfiguring)

            // Tertiary: classic e-mail login and the offline demo.
            DisclosureGroup("Other options", isExpanded: $showEmailLogin) {
                emailLoginForm
                    .padding(.top, 8)
            }
            .frame(maxWidth: 360)

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 560)
        .sheet(isPresented: $model.showSecondDeviceSheet) {
            SecondDeviceSheet(model: model)
        }
    }

    private var progressSection: some View {
        VStack(spacing: 4) {
            ProgressView(value: model.configureProgress)
            if let comment = model.configureComment {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorText(_ error: String) -> some View {
        Text(error)
            .font(.callout)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
    }

    private var emailLoginForm: some View {
        VStack(spacing: 12) {
            TextField("E-mail address", text: $model.loginEmail)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Password", text: $model.loginPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitEmail)

            if model.isConfiguring, showEmailLogin {
                progressSection
            }
            if let error = model.loginError, showEmailLogin {
                errorText(error)
            }

            Button(action: submitEmail) {
                Text("Log in with e-mail")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.isConfiguring || model.loginEmail.isEmpty)

            HStack(spacing: 4) {
                Text("Just looking around?")
                    .foregroundStyle(.secondary)
                Button("Try the demo") {
                    Task { await model.tryDemo() }
                }
                .disabled(model.isConfiguring)
            }
            .font(.callout)
        }
    }

    private func createProfile() {
        guard !model.isConfiguring else { return }
        Task { await model.createProfile() }
    }

    private func submitEmail() {
        guard !model.isConfiguring, !model.loginEmail.isEmpty else { return }
        Task { await model.logIn() }
    }
}

/// "Add Second Device": on the other device open Settings → Add Second Device,
/// then bring the QR here via clipboard (image or text) or an image file.
struct SecondDeviceSheet: View {
    @Bindable var model: AppModel
    @State private var showFilePicker = false
    @State private var pasteFailed = false
    @State private var scanner: QrCameraScanner?
    @State private var cameraError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add as Second Device", systemImage: "qrcode.viewfinder")
                .font(.title2.bold())

            Text("""
            1. On your other device, open **Settings → Add Second Device**.
            2. Scan the QR code with this Mac's camera — or copy a screenshot \
            of it and use **Paste** / **Load QR image…**.
            3. Both devices must be online (ideally the same network).
            """)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    scanner == nil ? startScan() : stopScan()
                } label: {
                    Label(
                        scanner == nil ? "Scan with Camera" : "Stop Scanning",
                        systemImage: scanner == nil ? "camera" : "camera.fill")
                }
                Button {
                    if let payload = QrDecode.payloadFromPasteboard() {
                        model.joinQrPayload = payload
                        pasteFailed = false
                    } else {
                        pasteFailed = true
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                Button {
                    showFilePicker = true
                } label: {
                    Label("Load QR image…", systemImage: "photo")
                }
            }
            .disabled(model.isConfiguring)

            if let scanner {
                CameraPreview(session: scanner.session)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the QR code")
                            .font(.caption)
                            .padding(6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 8)
                    }
            }
            if let cameraError {
                Text(cameraError)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            TextField("DCBACKUP… code", text: $model.joinQrPayload, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 4)
                .font(.caption.monospaced())
                .disabled(model.isConfiguring)

            if pasteFailed {
                Text("No QR code found in the clipboard.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if model.isConfiguring {
                VStack(spacing: 4) {
                    ProgressView(value: model.configureProgress)
                    Text(model.configureComment ?? "Connecting to the other device…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    if model.isConfiguring {
                        Task { await model.cancelOnboarding() }
                    } else {
                        model.showSecondDeviceSheet = false
                    }
                }
                Spacer()
                Button("Add Second Device") {
                    Task { await model.joinSecondDevice() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isConfiguring || model.joinQrPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onDisappear { stopScan() }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image]
        ) { result in
            if case .success(let url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let payload = QrDecode.payload(inFileAt: url) {
                    model.joinQrPayload = payload
                    pasteFailed = false
                } else {
                    pasteFailed = true
                }
            }
        }
    }

    // MARK: Camera scanning

    private func startScan() {
        cameraError = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        beginSession()
                    } else {
                        cameraError = "Camera access was denied."
                    }
                }
            }
        default:
            cameraError = "Camera access is denied — allow it in System Settings → Privacy & Security → Camera."
        }
    }

    private func beginSession() {
        let model = self.model
        guard let scanner = QrCameraScanner(onFound: { payload in
            Task { @MainActor in
                model.joinQrPayload = payload
                stopScan()
                // Scanned straight off the other device: join immediately.
                await model.joinSecondDevice()
            }
        }) else {
            cameraError = "No usable camera found."
            return
        }
        self.scanner = scanner
        scanner.start()
    }

    private func stopScan() {
        scanner?.stop()
        scanner = nil
    }
}

#Preview("Onboarding") {
    OnboardingView(model: AppModel(service: MockChatService()))
}

#Preview("Second device sheet") {
    SecondDeviceSheet(model: AppModel(service: MockChatService()))
}
