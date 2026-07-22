import AVFoundation
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    @State private var confirmRemoveAccount = false

    var body: some View {
        NavigationSplitView {
            List(model.chats, selection: $model.selectedChatId) { chat in
                ChatRowView(chat: chat)
                    .tag(chat.id)
                    .contextMenu {
                        if chat.isMuted {
                            Button("Unmute") {
                                Task { await model.setMuted(chatId: chat.id, durationSeconds: 0) }
                            }
                        } else {
                            Menu("Mute") {
                                Button("For 1 Hour") {
                                    Task { await model.setMuted(chatId: chat.id, durationSeconds: 3600) }
                                }
                                Button("For 8 Hours") {
                                    Task { await model.setMuted(chatId: chat.id, durationSeconds: 8 * 3600) }
                                }
                                Button("For 1 Week") {
                                    Task { await model.setMuted(chatId: chat.id, durationSeconds: 7 * 24 * 3600) }
                                }
                                Button("Forever") {
                                    Task { await model.setMuted(chatId: chat.id, durationSeconds: -1) }
                                }
                            }
                        }
                        Button(chat.isArchived ? "Unarchive" : "Archive") {
                            Task {
                                await model.setArchived(
                                    chatId: chat.id, archived: !chat.isArchived)
                            }
                        }
                    }
            }
            .listStyle(.sidebar)
            // The List's scroll view is a sibling of this background, not an
            // ancestor — apply() handles that shape.
            .background(OverlayScrollers())
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
            .navigationTitle(model.showingArchive ? "Archived" : "Chats")
            .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search chats")
            .onChange(of: model.searchQuery) {
                Task { await model.searchChanged() }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    accountMenu
                }
                ToolbarItem {
                    Button {
                        Task { await model.toggleArchive() }
                    } label: {
                        Label(
                            model.showingArchive ? "Back to Chats" : "Archived Chats",
                            systemImage: model.showingArchive
                                ? "archivebox.fill" : "archivebox")
                    }
                }
                ToolbarItem {
                    Menu {
                        Button("New Chat…") { model.showNewChat = true }
                        Button("New Group…") { model.showNewGroup = true }
                        Divider()
                        Button("Invite / Join via QR…") { model.showInvite = true }
                    } label: {
                        Label("New", systemImage: "square.and.pencil")
                    }
                }
            }
            .confirmationDialog(
                "Remove \"\(model.currentAccount?.displayName ?? model.currentAccount?.addr ?? "this profile")\"?",
                isPresented: $confirmRemoveAccount
            ) {
                Button("Remove Profile and Delete Its Data", role: .destructive) {
                    Task { await model.removeCurrentAccount() }
                }
            } message: {
                Text("All chats and keys of this profile are deleted from this Mac. Other devices with the same profile are not affected.")
            }
        } detail: {
            Group {
                if let chat = model.selectedChat {
                    ChatDetailView(
                        model: model, accountId: model.selectedAccountId ?? 0,
                        selectionGeneration: model.currentSelectionGeneration,
                        chat: chat)
                } else {
                    ContentUnavailableView(
                        "No Chat Selected",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Pick a conversation from the sidebar."))
                }
            }
            // Fill before backgrounding: ContentUnavailableView hugs its
            // content, which shrank the backdrop to a small box on the
            // empty screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The detail column owns the tiled surface: messages, floating
            // composer, AND the empty state share it — no background flash
            // when selection changes.
            .background(ChatBackdrop())
        }
        .onChange(of: model.selectedChatId) {
            Task { await model.chatSelectionChanged() }
        }
        .sheet(isPresented: $model.showNewChat) {
            NewChatSheet(model: model)
        }
        .sheet(isPresented: $model.showInvite) {
            InviteSheet(model: model)
        }
        .sheet(isPresented: $model.showNewGroup) {
            NewGroupSheet(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var accountMenu: some View {
        Menu {
            ForEach(model.configuredAccounts) { account in
                Button {
                    Task { await model.switchAccount(to: account.id) }
                } label: {
                    if account.id == model.selectedAccountId {
                        Label(accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(accountLabel(account))
                    }
                }
            }
            Divider()
            Button("Profile Settings…") { model.showSettings = true }
            Button("Add Profile…") { model.beginAddAccount() }
            Button("Remove This Profile…", role: .destructive) {
                confirmRemoveAccount = true
            }
        } label: {
            Label("Profiles", systemImage: "person.crop.circle")
        }
    }

    private func accountLabel(_ account: AccountInfo) -> String {
        if let name = account.displayName, !name.isEmpty {
            return "\(name) (\(account.addr ?? "…"))"
        }
        return account.addr ?? "Account \(account.id)"
    }
}

// MARK: - Sidebar row

struct ChatRowView: View {
    let chat: ChatItem

    var body: some View {
        HStack(spacing: 10) {
            ChatAvatarView(
                name: chat.name, colorHex: chat.color,
                avatarPath: chat.avatar, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(chat.name)
                        .fontWeight(chat.freshCount > 0 ? .bold : .medium)
                        .lineLimit(1)
                    if chat.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if chat.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if chat.timestamp > 0 {
                        // Refreshes each minute so "now"/"5 min" stay honest.
                        TimelineView(.everyMinute) { timeline in
                            Text(chatListTimestamp(chat.timestamp, now: timeline.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text(chat.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if chat.isContactRequest {
                        Text("Request")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    } else if chat.freshCount > 0 {
                        // Muted chats keep their count but lose the loud color.
                        Text("\(chat.freshCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(
                                chat.isMuted ? Color.white : EstuaryTheme.badgeText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                chat.isMuted ? Color.gray.opacity(0.55) : EstuaryTheme.badge,
                                in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct AvatarView: View {
    let name: String
    let colorHex: String
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay {
                Text(avatarInitial(for: name))
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Real profile image when available, initials circle otherwise.
struct ChatAvatarView: View {
    let name: String
    let colorHex: String
    let avatarPath: String?
    var size: CGFloat = 36

    var body: some View {
        if let avatarPath, let image = ImageCache.load(avatarPath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            AvatarView(name: name, colorHex: colorHex, size: size)
        }
    }
}

// MARK: - New group sheet

struct NewGroupSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var contacts: [ContactItem] = []
    @State private var selection = Set<UInt32>()
    @State private var error: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Group")
                .font(.title2.bold())
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Members")
                .font(.headline)
            List(contacts, selection: $selection) { contact in
                HStack {
                    ChatAvatarView(
                        name: contact.displayName, colorHex: contact.color,
                        avatarPath: contact.avatar, size: 24)
                    Text(contact.displayName)
                    if contact.isVerified {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(contact.addr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(contact.id)
            }
            .frame(minHeight: 200)
            Text("Groups are end-to-end encrypted: members need an established key (verified contacts work best).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") {
                    Task {
                        guard !isCreating else { return }
                        isCreating = true
                        error = nil
                        defer { isCreating = false }
                        if let failure = await model.createGroup(
                            name: name.trimmingCharacters(in: .whitespaces),
                            memberIds: Array(selection)
                        ) {
                            error = failure
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { contacts = await model.loadContacts() }
    }
}

// MARK: - Settings sheet

struct SettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var showAvatarPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Profile Settings")
                .font(.title2.bold())

            HStack(spacing: 12) {
                ChatAvatarView(
                    name: model.currentAccount?.displayName
                        ?? model.currentAccount?.addr ?? "?",
                    colorHex: "#5f7a8a",
                    avatarPath: model.currentAccount?.avatar,
                    size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Button("Change Avatar…") { showAvatarPicker = true }
                    if model.currentAccount?.avatar != nil {
                        Button("Remove Avatar") {
                            Task { await model.updateAvatar(path: nil) }
                        }
                    }
                }
            }

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.updateDisplayName(displayName) } }

            LabeledContent("Address", value: model.currentAccount?.addr ?? "—")
                .font(.callout)

            LabeledContent(
                "Build",
                value: buildDescription(info: Bundle.main.infoDictionary ?? [:]))
                .font(.callout)

            LabeledContent("Connectivity") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.connectivityValue >= 4000 ? .green : .orange)
                        .frame(width: 9, height: 9)
                    Text(connectivityLabel(model.connectivityValue))
                        .font(.callout)
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    Task {
                        await model.updateDisplayName(displayName)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task {
            displayName = model.currentAccount?.displayName ?? ""
            await model.refreshConnectivity()
        }
        .fileImporter(isPresented: $showAvatarPicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                Task {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    await model.updateAvatar(path: url.path)
                }
            }
        }
    }

    private func connectivityLabel(_ value: UInt32) -> String {
        switch value {
        case 4000...: "Connected"
        case 3000..<4000: "Updating…"
        case 2000..<3000: "Connecting…"
        case 1..<2000: "Not connected"
        default: "Unknown"
        }
    }
}

// MARK: - New chat sheet

/// Securejoin invites, both directions (issue: qr-invite-contact-flow):
/// my QR/link to hand out, and paste-or-scan to join someone else's.
/// This is how first contact works on chatmail — plain first mails are
/// rejected by the relay, invites carry the key exchange.
struct InviteSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var inviteLink: String?
    @State private var inviteLoadFailed = false
    @State private var copied = false
    @State private var pasted = ""
    @State private var inviteeName: String?
    @State private var error: String?
    @State private var isJoining = false
    @State private var scanning = false
    @State private var scanner: QrCameraScanner?
    @State private var cameraError: String?
    @State private var sheetGone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite")
                .font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                if let inviteLink, let image = qrImage(for: inviteLink) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .accessibilityLabel("Your invite QR code")
                } else if inviteLoadFailed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text("Couldn't create your invite.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await loadInvite() }
                        }
                    }
                    .frame(width: 150, height: 150)
                } else {
                    ProgressView()
                        .frame(width: 150, height: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Have them scan this code with Delta Chat, or send the link over any channel. The chat is end-to-end encrypted from the first message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(copied ? "Copied" : "Copy Invite Link") {
                        guard let inviteLink else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inviteLink, forType: .string)
                        copied = true
                    }
                    .disabled(inviteLink == nil)
                }
            }

            Divider()

            Text("Got an invite?")
                .font(.headline)
            TextField("Paste an invite link (https://i.delta.chat/#…)", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .onChange(of: pasted) { _, payload in
                    Task {
                        let name = await model.inviteePreview(payload)
                        // Previews resolve out of order under fast edits:
                        // only the one matching the CURRENT field wins.
                        if pasted == payload { inviteeName = name }
                    }
                }
            if scanning, let scanner {
                CameraPreview(session: scanner.session)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let cameraError {
                Text(cameraError).font(.caption).foregroundStyle(.red)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(scanning ? "Stop Scanning" : "Scan QR Code") {
                    scanning ? stopScan() : startScan()
                }
                Spacer()
                Button("Close") { dismiss() }
                Button(inviteeName.map { "Chat with \($0)" } ?? "Join") {
                    join(pasted)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isJoining)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await loadInvite() }
        .onDisappear {
            sheetGone = true
            stopScan()
        }
    }

    private func loadInvite() async {
        inviteLoadFailed = false
        inviteLink = await model.inviteLink()
        inviteLoadFailed = inviteLink == nil
    }

    private func join(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Easy slip: the Copy button is one click away in the same sheet.
        // Core would only say "Unsupported QR type" for one's own invite.
        if trimmed == inviteLink {
            error = "This is your own invite — send it to the person you want to chat with."
            return
        }
        Task {
            isJoining = true
            error = nil
            defer { isJoining = false }
            if let failure = await model.joinInvite(trimmed) {
                error = failure
            } else {
                dismiss()
            }
        }
    }

    // Same permission dance as onboarding's second-device scan.
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
        // The TCC prompt outlives the sheet: granting access after Close
        // must not switch the camera on against a dead view.
        guard !sheetGone else { return }
        guard let scanner = QrCameraScanner(onFound: { payload in
            Task { @MainActor in
                pasted = payload
                stopScan()
                join(payload)
            }
        }) else {
            cameraError = "No usable camera found."
            return
        }
        self.scanner = scanner
        scanning = true
        scanner.start()
    }

    private func stopScan() {
        scanner?.stop()
        scanner = nil
        scanning = false
    }
}

struct NewChatSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var name = ""
    @State private var error: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Chat")
                .font(.title2.bold())
            Form {
                TextField("E-mail address", text: $email)
                TextField("Name (optional)", text: $name)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create") {
                    let email = email.trimmingCharacters(in: .whitespaces)
                    let name = name.trimmingCharacters(in: .whitespaces)
                    Task {
                        guard !isCreating else { return }
                        isCreating = true
                        error = nil
                        defer { isCreating = false }
                        if let failure = await model.createChat(email: email, name: name) {
                            error = failure
                        } else {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || !email.contains("@"))
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - Previews

#Preview("Chat rows") {
    List {
        ChatRowView(chat: ChatItem(
            id: 1, name: "Alice", preview: "See you tomorrow!",
            timestamp: Int64(Date().timeIntervalSince1970) - 120,
            freshCount: 3, isSelfTalk: false, isPinned: false, isMuted: false,
            isContactRequest: false, color: "#e56555"))
        ChatRowView(chat: ChatItem(
            id: 2, name: "Saved Messages", preview: "Me: shopping list",
            timestamp: Int64(Date().timeIntervalSince1970) - 90_000,
            freshCount: 0, isSelfTalk: true, isPinned: true, isMuted: false,
            isContactRequest: false, color: "#c98a2b"))
        ChatRowView(chat: ChatItem(
            id: 3, name: "Mallory", preview: "Hi! We met at the conference",
            timestamp: Int64(Date().timeIntervalSince1970) - 3600 * 30,
            freshCount: 1, isSelfTalk: false, isPinned: false, isMuted: true,
            isContactRequest: true, color: "#d33682"))
    }
    .frame(width: 300)
}
