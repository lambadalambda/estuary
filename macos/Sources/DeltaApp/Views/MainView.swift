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
                        Button(chat.isArchived ? "Unarchive" : "Archive") {
                            Task {
                                await model.setArchived(
                                    chatId: chat.id, archived: !chat.isArchived)
                            }
                        }
                    }
            }
            .listStyle(.sidebar)
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
            if let chat = model.selectedChat {
                ChatDetailView(model: model, chat: chat)
            } else {
                ContentUnavailableView(
                    "No Chat Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a conversation from the sidebar."))
            }
        }
        .onChange(of: model.selectedChatId) {
            Task { await model.chatSelectionChanged() }
        }
        .sheet(isPresented: $model.showNewChat) {
            NewChatSheet(model: model)
        }
        .sheet(isPresented: $model.showNewGroup) {
            NewGroupSheet(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model)
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
                        Text(chatListTimestamp(chat.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        Text("\(chat.freshCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
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
        if let avatarPath, let image = NSImage(contentsOfFile: avatarPath) {
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
                Button("Create") {
                    Task {
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
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let path = url.path
                Task { await model.updateAvatar(path: path) }
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

struct NewChatSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Chat")
                .font(.title2.bold())
            Form {
                TextField("E-mail address", text: $email)
                TextField("Name (optional)", text: $name)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let email = email.trimmingCharacters(in: .whitespaces)
                    let name = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await model.createChat(email: email, name: name) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!email.contains("@"))
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
