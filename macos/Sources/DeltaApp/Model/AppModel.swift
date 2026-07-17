import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    enum Screen: Equatable {
        case loading
        case onboarding
        case main
    }

    // MARK: State

    private(set) var screen: Screen = .loading
    private(set) var accounts: [AccountInfo] = []
    private(set) var selectedAccountId: UInt32?
    private(set) var chats: [ChatItem] = []
    /// Bound to the sidebar List selection.
    var selectedChatId: UInt32?
    private(set) var messages: [MessageItem] = []
    /// Whether older history exists beyond the currently loaded window.
    private(set) var hasMoreMessages = false
    /// Size of the loaded window; grows as the user scrolls into history.
    private var loadedLimit: UInt32 = AppModel.messagePageSize
    static let messagePageSize: UInt32 = 100
    /// Message being replied to (composer banner); sent as quote.
    var replyTo: MessageItem?
    /// Sidebar shows the archive instead of the normal list.
    var showingArchive = false
    /// Sidebar search field text; non-empty switches the list to search hits.
    var searchQuery = ""
    var showSettings = false
    var showNewChat = false
    var showNewGroup = false
    private(set) var connectivityValue: UInt32 = 0

    // Login / onboarding state.
    var profileName = ""
    var loginEmail = ""
    var loginPassword = ""
    var joinQrPayload = ""
    var showSecondDeviceSheet = false
    private(set) var isConfiguring = false
    /// 0...1, driven by ConfigureProgress/ImexProgress events.
    private(set) var configureProgress: Double = 0
    private(set) var configureComment: String?
    var loginError: String?
    /// Account being onboarded right now (target for cancelOngoing).
    private var onboardingAccountId: UInt32?

    let service: any ChatService
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    nonisolated init(service: any ChatService) {
        self.service = service
    }

    var selectedChat: ChatItem? {
        guard let id = selectedChatId else { return nil }
        return chats.first { $0.id == id }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        startEventLoop()
        do {
            accounts = try await service.accounts()
            let selected = await service.selectedAccount()
            let configured = accounts.first { $0.id == selected && $0.isConfigured }
                ?? accounts.first { $0.isConfigured }
            if let account = configured {
                try await service.selectAccount(id: account.id)
                selectedAccountId = account.id
                try await service.startIo()
                await reloadChats()
                screen = .main
            } else {
                screen = .onboarding
            }
        } catch {
            loginError = error.localizedDescription
            screen = .onboarding
        }
        // Dev/smoke-test hooks: jump straight into the demo account, or
        // exercise the real instant-account flow (network!) and report.
        let env = ProcessInfo.processInfo.environment
        if screen == .onboarding, env["DCNATIVE_AUTODEMO"] == "1" {
            await tryDemo()
        }
        if screen == .onboarding, env["DCNATIVE_AUTOCREATE"] == "1" {
            profileName = "Autocreate Test"
            await createProfile()
            let verdict = screen == .main
                ? "OK addr=\(accounts.first { $0.id == selectedAccountId }?.addr ?? "?")"
                : "FAILED: \(loginError ?? "unknown error")"
            FileHandle.standardError.write(Data("DCNATIVE_AUTOCREATE \(verdict)\n".utf8))
        }
    }

    private func startEventLoop() {
        guard eventTask == nil else { return }
        eventTask = Task { [service] in
            for await (accountId, event) in service.events {
                await handle(accountId: accountId, event: event)
            }
        }
    }

    // MARK: Onboarding actions

    /// Reuses a leftover unconfigured account (e.g. from a failed attempt)
    /// or creates a fresh one, and remembers it as the onboarding target.
    private func beginOnboarding() async throws -> UInt32 {
        loginError = nil
        configureProgress = 0
        configureComment = nil
        isConfiguring = true
        let accountId: UInt32
        if let unconfigured = accounts.first(where: { !$0.isConfigured }) {
            accountId = unconfigured.id
        } else {
            accountId = try await service.addAccount()
        }
        onboardingAccountId = accountId
        return accountId
    }

    private func finishOnboarding(accountId: UInt32) async throws {
        try await service.selectAccount(id: accountId)
        selectedAccountId = accountId
        try await service.startIo()
        accounts = try await service.accounts()
        await reloadChats()
        showSecondDeviceSheet = false
        screen = .main
    }

    /// Instant chatmail onboarding: auto-creates an account on the default
    /// relay; no e-mail address or password ever shown.
    func createProfile() async {
        defer { isConfiguring = false; onboardingAccountId = nil }
        do {
            let accountId = try await beginOnboarding()
            // DCNATIVE_INSTANCE overrides the default relay, e.g.
            // "DCACCOUNT:_cm.example" for the local podman relay (dev/chatmail/).
            try await service.createInstantAccount(
                accountId: accountId,
                displayName: profileName.trimmingCharacters(in: .whitespaces),
                instance: ProcessInfo.processInfo.environment["DCNATIVE_INSTANCE"])
            try await finishOnboarding(accountId: accountId)
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// "Add Second Device": receives the full existing account (credentials,
    /// keys, chats) from the QR shown on the other device.
    func joinSecondDevice() async {
        defer { isConfiguring = false; onboardingAccountId = nil }
        let payload = joinQrPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        do {
            let accountId = try await beginOnboarding()
            try await service.joinSecondDevice(accountId: accountId, qr: payload)
            joinQrPayload = ""
            try await finishOnboarding(accountId: accountId)
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Cancels an in-flight configure/backup transfer, if any.
    func cancelOnboarding() async {
        guard let accountId = onboardingAccountId else { return }
        try? await service.cancelOngoing(accountId: accountId)
    }

    func logIn() async {
        defer { isConfiguring = false; onboardingAccountId = nil }
        do {
            let addr = loginEmail.trimmingCharacters(in: .whitespaces)
            let accountId = try await beginOnboarding()
            try await service.login(accountId: accountId, addr: addr, password: loginPassword)
            loginPassword = ""
            try await finishOnboarding(accountId: accountId)
        } catch {
            loginError = error.localizedDescription
        }
    }

    func tryDemo() async {
        loginError = nil
        do {
            let accountId = try await service.addDemoAccount()
            selectedAccountId = accountId
            accounts = try await service.accounts()
            await reloadChats()
            screen = .main
        } catch {
            loginError = error.localizedDescription
        }
    }

    // MARK: Account management

    /// Configured accounts, for the account menu.
    var configuredAccounts: [AccountInfo] {
        accounts.filter(\.isConfigured)
    }

    var currentAccount: AccountInfo? {
        accounts.first { $0.id == selectedAccountId }
    }

    /// Whether onboarding was entered from a working session ("Add Account")
    /// and can simply be left again.
    var canReturnToMain: Bool {
        screen == .onboarding && currentAccount?.isConfigured == true
    }

    func switchAccount(to id: UInt32) async {
        guard id != selectedAccountId else { return }
        do {
            try await service.selectAccount(id: id)
            selectedAccountId = id
            selectedChatId = nil
            messages = []
            await reloadChats()
        } catch {
            loginError = error.localizedDescription
        }
    }

    /// Opens onboarding to add another profile; the current session stays
    /// intact and can be returned to.
    func beginAddAccount() {
        loginError = nil
        screen = .onboarding
    }

    func returnToMain() {
        guard currentAccount?.isConfigured == true else { return }
        loginError = nil
        screen = .main
    }

    /// Removes the current account and its data, then falls back to the next
    /// configured account or onboarding.
    func removeCurrentAccount() async {
        guard let id = selectedAccountId else { return }
        do {
            try await service.removeAccount(id: id)
            accounts = try await service.accounts()
            selectedChatId = nil
            messages = []
            chats = []
            if let next = await service.selectedAccount(),
               accounts.contains(where: { $0.id == next && $0.isConfigured }) {
                selectedAccountId = next
                await reloadChats()
                screen = .main
            } else if let next = accounts.first(where: \.isConfigured) {
                try await service.selectAccount(id: next.id)
                selectedAccountId = next.id
                await reloadChats()
                screen = .main
            } else {
                selectedAccountId = nil
                screen = .onboarding
            }
        } catch {
            loginError = error.localizedDescription
        }
    }

    // MARK: Main-screen actions

    func reloadChats() async {
        guard let accountId = selectedAccountId else { return }
        do {
            let query = searchQuery.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                chats = try await service.searchChats(accountId: accountId, query: query)
            } else if showingArchive {
                chats = try await service.archivedChats(accountId: accountId)
            } else {
                chats = try await service.chatList(accountId: accountId)
            }
            if let selected = selectedChatId, !chats.contains(where: { $0.id == selected }) {
                selectedChatId = nil
                messages = []
            }
            if !showingArchive, query.isEmpty {
                updateDockBadge()
            }
        } catch {
            // Keep the last known list; a follow-up event will retry.
        }
    }

    private func updateDockBadge() {
        let unread = chats.filter { !$0.isMuted }.reduce(0) { $0 + Int($1.freshCount) }
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    func reloadMessages() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else {
            messages = []
            return
        }
        do {
            // Refresh the whole loaded window so state/reaction changes on
            // already-visible history are picked up, but never more.
            let page = try await service.messages(
                accountId: accountId, chatId: chatId,
                limit: loadedLimit, beforeMsgId: nil)
            messages = page
            hasMoreMessages = page.count >= Int(loadedLimit)
            await markVisibleMessagesSeen(accountId: accountId, chatId: chatId)
        } catch {
            messages = []
        }
    }

    /// Loads one more page of history above the current window.
    /// Returns the id to keep anchored at the top, if anything was loaded.
    func loadOlderMessages() async -> UInt32? {
        guard let accountId = selectedAccountId, let chatId = selectedChatId,
              hasMoreMessages, let oldest = messages.first
        else { return nil }
        do {
            let older = try await service.messages(
                accountId: accountId, chatId: chatId,
                limit: Self.messagePageSize, beforeMsgId: oldest.id)
            guard !older.isEmpty else {
                hasMoreMessages = false
                return nil
            }
            messages.insert(contentsOf: older, at: 0)
            loadedLimit += UInt32(older.count)
            hasMoreMessages = older.count >= Int(Self.messagePageSize)
            return oldest.id
        } catch {
            return nil
        }
    }

    /// The chat is on screen: mark incoming messages seen. This sends MDN
    /// read receipts and syncs the read state to other devices.
    private func markVisibleMessagesSeen(accountId: UInt32, chatId: UInt32) async {
        guard let chat = selectedChat, !chat.isContactRequest else { return }
        let incoming = messages.filter { !$0.isOutgoing && !$0.isInfo }.map(\.id)
        guard !incoming.isEmpty else { return }
        try? await service.markSeen(accountId: accountId, msgIds: incoming)
    }

    func searchChanged() async {
        await reloadChats()
    }

    func toggleArchive() async {
        showingArchive.toggle()
        selectedChatId = nil
        messages = []
        await reloadChats()
    }

    func setArchived(chatId: UInt32, archived: Bool) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.setChatArchived(
            accountId: accountId, chatId: chatId, archived: archived)
        await reloadChats()
    }

    // MARK: Contact requests

    func acceptSelectedChat() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        do {
            try await service.acceptChat(accountId: accountId, chatId: chatId)
            await reloadChats()
            await reloadMessages()
        } catch {
            loginError = error.localizedDescription
        }
    }

    func blockSelectedChat() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        try? await service.blockChat(accountId: accountId, chatId: chatId)
        selectedChatId = nil
        messages = []
        await reloadChats()
    }

    // MARK: Message actions

    func sendReaction(msgId: UInt32, emoji: String) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.sendReaction(accountId: accountId, msgId: msgId, emoji: emoji)
        await reloadMessages()
    }

    /// Toggles the own reaction: clicking your current emoji clears it.
    func toggleReaction(message: MessageItem, emoji: String) async {
        let mine = message.reactions.first { $0.isFromSelf }?.emoji
        await sendReaction(msgId: message.id, emoji: mine == emoji ? "" : emoji)
    }

    func deleteMessage(msgId: UInt32) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.deleteMessages(accountId: accountId, msgIds: [msgId])
        await reloadMessages()
        await reloadChats()
    }

    func forwardMessage(msgId: UInt32, to chatId: UInt32) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.forwardMessages(
            accountId: accountId, msgIds: [msgId], chatId: chatId)
    }

    func sendAttachment(path: String, caption: String) async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        do {
            _ = try await service.sendMessage(
                accountId: accountId, chatId: chatId,
                text: caption.isEmpty ? nil : caption,
                filePath: path,
                quotedMsgId: replyTo?.id)
            replyTo = nil
        } catch {
            loginError = error.localizedDescription
        }
    }

    // MARK: Groups / contacts

    func loadContacts() async -> [ContactItem] {
        guard let accountId = selectedAccountId else { return [] }
        return (try? await service.contacts(accountId: accountId)) ?? []
    }

    /// Returns nil on success, or a user-facing error (e.g. core rejecting
    /// non-key-contacts in encrypted groups).
    func createGroup(name: String, memberIds: [UInt32]) async -> String? {
        guard let accountId = selectedAccountId else { return nil }
        do {
            let chatId = try await service.createGroup(
                accountId: accountId, name: name, memberContactIds: memberIds)
            await reloadChats()
            selectedChatId = chatId
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Settings

    func updateDisplayName(_ name: String) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.setDisplayName(accountId: accountId, name: name)
        accounts = (try? await service.accounts()) ?? accounts
    }

    func updateAvatar(path: String?) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.setAvatar(accountId: accountId, path: path)
        accounts = (try? await service.accounts()) ?? accounts
    }

    func refreshConnectivity() async {
        guard let accountId = selectedAccountId else { return }
        connectivityValue = (try? await service.connectivity(accountId: accountId)) ?? 0
    }

    /// Called when the sidebar selection changes.
    func chatSelectionChanged() async {
        replyTo = nil
        loadedLimit = Self.messagePageSize
        hasMoreMessages = false
        await reloadMessages()
        await markSelectedChatNoticed()
    }

    private func markSelectedChatNoticed() async {
        guard let accountId = selectedAccountId,
              let chat = selectedChat,
              chat.freshCount > 0, !chat.isContactRequest
        else { return }
        try? await service.markNoticed(accountId: accountId, chatId: chat.id)
    }

    func send(_ text: String) async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await service.sendMessage(
                accountId: accountId, chatId: chatId,
                text: trimmed, filePath: nil, quotedMsgId: replyTo?.id)
            replyTo = nil
        } catch {
            loginError = error.localizedDescription
        }
    }

    func createChat(email: String, name: String) async {
        guard let accountId = selectedAccountId else { return }
        do {
            let chatId = try await service.createChat(accountId: accountId, email: email, name: name)
            await reloadChats()
            selectedChatId = chatId
        } catch {
            // Non-fatal; ignore in the prototype.
        }
    }

    // MARK: Event handling (refresh rules from docs/specs/ui-needs.md §5)

    private func handle(accountId: UInt32, event: ServiceEvent) async {
        switch event {
        case .configureProgress(let permille, let comment):
            if permille > 0 {
                configureProgress = Double(permille) / 1000
            }
            if let comment { configureComment = comment }

        case .imexProgress(let permille):
            // Same progress bar as configure; 0 (error/cancel) is surfaced
            // through the thrown error of joinSecondDevice instead.
            if permille > 0 {
                configureProgress = Double(permille) / 1000
                configureComment = permille >= 1000 ? nil : "Transferring account…"
            }

        case .accountsChanged:
            accounts = (try? await service.accounts()) ?? accounts

        case .chatlistChanged:
            if screen == .main, accountId == selectedAccountId {
                await reloadChats()
            }

        case .chatChanged(let chatId):
            // Core often signals sidebar-row updates *only* via events that
            // map to chatChanged (e.g. marknoticed_chat -> MsgsNoticed +
            // ChatlistItemChanged, send_msg -> MsgsChanged, without any
            // ChatlistChanged), so the chat list must refresh here too or
            // badges/previews go stale.
            if accountId == selectedAccountId {
                await reloadChats()
                if chatId == selectedChatId {
                    await reloadMessages()
                }
            }

        case .incomingMessage(let chatId, _):
            if accountId == selectedAccountId {
                await reloadChats()
                if chatId == selectedChatId {
                    await reloadMessages()
                    await markSelectedChatNoticed()
                }
                // Notify when the app is in the background or another chat
                // is open (bundle builds only; bare `swift run` has no
                // notification identity).
                let chat = chats.first { $0.id == chatId }
                if chatId != selectedChatId || !NSApplication.shared.isActive {
                    NotificationManager.postIncoming(
                        chatName: chat?.name ?? "New message",
                        preview: chat?.preview ?? "")
                }
                // Subtle in-app ping for messages landing in other chats
                // (notifications already sound when the app is inactive).
                if NSApplication.shared.isActive, chatId != selectedChatId,
                   chat?.isMuted != true {
                    NSSound(named: "Pop")?.play()
                }
            }

        case .connectivityChanged:
            break
        }
    }
}
