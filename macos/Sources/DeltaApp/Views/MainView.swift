import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    @State private var showNewChat = false
    @State private var confirmRemoveAccount = false

    var body: some View {
        NavigationSplitView {
            List(model.chats, selection: $model.selectedChatId) { chat in
                ChatRowView(chat: chat)
                    .tag(chat.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    accountMenu
                }
                ToolbarItem {
                    Button {
                        showNewChat = true
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
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
        .sheet(isPresented: $showNewChat) {
            NewChatSheet(model: model)
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
            AvatarView(name: chat.name, colorHex: chat.color, size: 36)

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
