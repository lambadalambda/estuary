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
    /// Set once a load-older returned empty: stops the page-boundary flicker
    /// where count == loadedLimit keeps re-asserting "more history".
    private var historyExhausted = false
    /// Size of the loaded window; grows as the user scrolls into history.
    private var loadedLimit: UInt32 = AppModel.messagePageSize
    // Eager layout renders the whole window (see ChatDetailView's VStack
    // note) — keep pages small; a viewport shows ~10 messages at most.
    static let messagePageSize: UInt32 = 50
    /// Reported by the chat view's bottom sentinel; gates window growth.
    var viewIsAtBottom = true
    private var reloadChatsScheduled = false
    private var reloadMessagesScheduled = false
    /// Main-screen action failures (send/accept/block/…), shown as an alert.
    var actionError: String?
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
        // Screenshot hook: open the newest chat so captures show a
        // conversation. Untestable as-is (ProcessInfo read, like the hooks
        // around it); the selection path itself is covered elsewhere.
        if screen == .main, env["DCNATIVE_AUTOSELECT"] == "1",
           let first = chats.first {
            selectedChatId = first.id
            await chatSelectionChanged()
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
        // One setup at a time: a second flow would steal onboardingAccountId
        // (killing the first flow's Cancel) and could reuse the same
        // unconfigured account a backup transfer is writing into.
        guard !isConfiguring else {
            throw ServiceError.core(msg: "Another profile setup is already running.")
        }
        loginError = nil
        configureProgress = 0
        configureComment = nil
        isConfiguring = true
        // If acquisition itself fails, release the flag HERE: callers only
        // install their cleanup defer after we return successfully, so a
        // throw below would otherwise brick onboarding until relaunch.
        do {
            let accountId: UInt32
            if let unconfigured = accounts.first(where: { !$0.isConfigured }) {
                accountId = unconfigured.id
            } else {
                accountId = try await service.addAccount()
            }
            onboardingAccountId = accountId
            return accountId
        } catch {
            isConfiguring = false
            throw error
        }
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
        // Acquire first: if another flow is running, we must NOT run the
        // defer below — it would clear the running flow's state.
        let accountId: UInt32
        do { accountId = try await beginOnboarding() } catch {
            loginError = error.localizedDescription
            return
        }
        defer { isConfiguring = false; onboardingAccountId = nil }
        do {
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
        let payload = joinQrPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        let accountId: UInt32
        do { accountId = try await beginOnboarding() } catch {
            loginError = error.localizedDescription
            return
        }
        defer { isConfiguring = false; onboardingAccountId = nil }
        do {
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
        let accountId: UInt32
        do { accountId = try await beginOnboarding() } catch {
            loginError = error.localizedDescription
            return
        }
        defer { isConfiguring = false; onboardingAccountId = nil }
        do {
            let addr = loginEmail.trimmingCharacters(in: .whitespaces)
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
            searchQuery = ""
            showingArchive = false
            await reloadChats()
        } catch {
            actionError = error.localizedDescription
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
                searchQuery = ""
                showingArchive = false
                NSApp.dockTile.badgeLabel = nil
                screen = .onboarding
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Main-screen actions

    func reloadChats() async {
        guard let accountId = selectedAccountId else { return }
        do {
            let query = searchQuery.trimmingCharacters(in: .whitespaces)
            let list: [ChatItem]
            if !query.isEmpty {
                list = try await service.searchChats(accountId: accountId, query: query)
            } else if showingArchive {
                list = try await service.archivedChats(accountId: accountId)
            } else {
                list = try await service.chatList(accountId: accountId)
            }
            // A slow fetch may resume after the user switched accounts or
            // changed the filter — never let stale results clobber the view.
            let archiveSnapshot = showingArchive
            guard accountId == selectedAccountId,
                  query == searchQuery.trimmingCharacters(in: .whitespaces),
                  archiveSnapshot == showingArchive
            else { return }
            chats = list
            // Only drop the selection outside search: a filtered list not
            // containing the open chat is expected and must not destroy the
            // open conversation (and its draft) on every keystroke.
            if query.isEmpty, let selected = selectedChatId,
               !chats.contains(where: { $0.id == selected }) {
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
        let previousOldest = messages.first?.id
        do {
            // Refresh the whole loaded window so state/reaction changes on
            // already-visible history are picked up.
            var page = try await service.messages(
                accountId: accountId, chatId: chatId,
                limit: loadedLimit, beforeMsgId: nil)
            // New messages slide the newest-N window; grow it so history the
            // user has scrolled to doesn't fall off the top mid-read. The
            // shared loadedLimit is only written after the selection guard.
            var grownLimit = loadedLimit
            if windowNeedsGrowth(
                previousOldest: previousOldest, page: page,
                viewIsAtBottom: viewIsAtBottom) {
                grownLimit += Self.messagePageSize
                page = try await service.messages(
                    accountId: accountId, chatId: chatId,
                    limit: grownLimit, beforeMsgId: nil)
            }
            // Selection may have moved while we awaited — a slow fetch for
            // chat A must never render inside chat B.
            guard accountId == selectedAccountId, chatId == selectedChatId else { return }
            if grownLimit != loadedLimit {
                loadedLimit = grownLimit
                // The window moved under us (new msgs or a deletion) — any
                // earlier "history exhausted" verdict is stale now.
                historyExhausted = false
            }
            messages = page
            hasMoreMessages = !historyExhausted && page.count >= Int(loadedLimit)
            // Read receipts only for something the user can actually see.
            if NSApplication.shared.isActive {
                await markVisibleMessagesSeen(accountId: accountId, chatId: chatId)
            }
        } catch {
            if accountId == selectedAccountId, chatId == selectedChatId {
                messages = []
            }
        }
    }

    /// What the view must do with the scroll position after a history load.
    enum HistoryLoadOutcome: Equatable, Sendable {
        /// Nothing was prepended (no more history, stale switch, error).
        case nothing
        /// Keep this id anchored at the top: preserves a scrolled-up
        /// reading position through the prepend.
        case restore(anchor: UInt32)
        /// Prepended while genuinely pinned at the bottom (e.g. a
        /// viewport-filling load): keep the newest message pinned — a
        /// top-anchor restore would scroll away from it.
        case pinBottom
    }

    /// Loads one more page of history above the current window.
    func loadOlderMessages() async -> HistoryLoadOutcome {
        guard let accountId = selectedAccountId, let chatId = selectedChatId,
              hasMoreMessages, let oldest = messages.first
        else { return .nothing }
        do {
            let older = try await service.messages(
                accountId: accountId, chatId: chatId,
                limit: Self.messagePageSize, beforeMsgId: oldest.id)
            // Stale-await guard: the user may have switched chats while the
            // page was in flight; never splice A's history into B.
            guard accountId == selectedAccountId, chatId == selectedChatId,
                  messages.first?.id == oldest.id
            else { return .nothing }
            guard !older.isEmpty else {
                historyExhausted = true
                hasMoreMessages = false
                return .nothing
            }
            messages.insert(contentsOf: older, at: 0)
            loadedLimit += UInt32(older.count)
            hasMoreMessages = older.count >= Int(Self.messagePageSize)
            let outcome = Self.historyLoadOutcome(
                previousOldest: oldest.id, viewIsAtBottom: viewIsAtBottom)
            scrollDebug(
                "loadOlder: +\(older.count) before #\(oldest.id), "
                    + "atBottom=\(viewIsAtBottom) -> \(outcome)")
            return outcome
        } catch {
            return .nothing
        }
    }

    nonisolated static func historyLoadOutcome(
        previousOldest: UInt32, viewIsAtBottom: Bool
    ) -> HistoryLoadOutcome {
        viewIsAtBottom ? .pinBottom : .restore(anchor: previousOldest)
    }

    /// Computed once: process env is constant, and reading it bridges the
    /// whole environ per call — too costly for scroll-frame call sites.
    nonisolated static let scrollDebugEnabled =
        ProcessInfo.processInfo.environment["DCNATIVE_DEBUG_SCROLL"] == "1"

    /// Scroll diagnostics, opt-in via DCNATIVE_DEBUG_SCROLL=1 (launch from
    /// a terminal to see them).
    nonisolated func scrollDebug(_ message: @autoclosure () -> String) {
        if Self.scrollDebugEnabled {
            print("[scroll] \(message())")
        }
    }

    /// Coalesced reloads: core bursts events during sync; one pending reload
    /// absorbs the whole burst instead of a full RPC round-trip per event.
    private func scheduleReloadChats() {
        guard !reloadChatsScheduled else { return }
        reloadChatsScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            reloadChatsScheduled = false
            await reloadChats()
        }
    }

    private func scheduleReloadMessages() {
        guard !reloadMessagesScheduled else { return }
        reloadMessagesScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            reloadMessagesScheduled = false
            await reloadMessages()
        }
    }

    /// App became active: catch up and mark the visible chat read now that
    /// the user can actually see it.
    func appDidBecomeActive() async {
        guard screen == .main else { return }
        await reloadChats()
        await reloadMessages()
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
        // Search takes priority in reloadChats; leaving it active would flip
        // the title while the list keeps showing search hits.
        searchQuery = ""
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

    /// 0 = unmute, negative = forever, positive = seconds from now.
    func setMuted(chatId: UInt32, durationSeconds: Int64) async {
        guard let accountId = selectedAccountId else { return }
        try? await service.setChatMuted(
            accountId: accountId, chatId: chatId, durationSeconds: durationSeconds)
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
            actionError = error.localizedDescription
        }
    }

    func blockSelectedChat() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        do {
            try await service.blockChat(accountId: accountId, chatId: chatId)
            selectedChatId = nil
            messages = []
            await reloadChats()
        } catch {
            actionError = error.localizedDescription
        }
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
        if replyTo?.id == msgId {
            replyTo = nil
        }
        try? await service.deleteMessages(accountId: accountId, msgIds: [msgId])
        await reloadMessages()
        await reloadChats()
    }

    /// Forward targets are always the full, unfiltered chat list — the
    /// sidebar may be showing search/archive results.
    func forwardTargets() async -> [ChatItem] {
        guard let accountId = selectedAccountId else { return [] }
        return ((try? await service.chatList(accountId: accountId)) ?? [])
            .filter { !$0.isContactRequest }
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
            actionError = error.localizedDescription
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
        historyExhausted = false
        viewIsAtBottom = true
        // Clear immediately so the stale-window growth check in
        // reloadMessages never compares against the previous chat.
        messages = []
        await reloadMessages()
        scrollDebug(
            "open chat=\(selectedChatId.map(String.init) ?? "-") "
                + "msgs=\(messages.count) hasMore=\(hasMoreMessages)")
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
            actionError = error.localizedDescription
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
                scheduleReloadChats()
                // Overflow recovery maps to ChatlistChanged; per-chat events
                // may have been dropped, so refresh the open chat too.
                scheduleReloadMessages()
            }

        case .chatChanged(let chatId):
            // Core often signals sidebar-row updates *only* via events that
            // map to chatChanged (e.g. marknoticed_chat -> MsgsNoticed +
            // ChatlistItemChanged, send_msg -> MsgsChanged, without any
            // ChatlistChanged), so the chat list must refresh here too or
            // badges/previews go stale.
            if accountId == selectedAccountId {
                scheduleReloadChats()
                if chatId == selectedChatId {
                    scheduleReloadMessages()
                }
            }

        case .incomingMessage(let chatId, _):
            if accountId == selectedAccountId {
                scheduleReloadChats()
                if chatId == selectedChatId {
                    scheduleReloadMessages()
                    if NSApplication.shared.isActive {
                        await markSelectedChatNoticed()
                    }
                }
            }
            // Notifications work for EVERY account, not just the selected one.
            await notifyIncoming(accountId: accountId, chatId: chatId)

        case .connectivityChanged:
            if showSettings {
                await refreshConnectivity()
            }
        }
    }

    /// Notification/sound decision for an incoming message. Never trusts the
    /// filtered sidebar list: a muted chat missing from search/archive
    /// results must still be recognized as muted (bundle builds only; bare
    /// `swift run` has no notification identity).
    private func notifyIncoming(accountId: UInt32, chatId: UInt32) async {
        // Always a fresh point lookup: the sidebar list may be filtered
        // (hiding muted chats) or one event stale (showing the previous
        // message as the preview).
        guard let chat = try? await service.chatById(accountId: accountId, chatId: chatId),
              !chat.isMuted, !chat.isDeviceTalk
        else { return }

        let isCurrentChat = accountId == selectedAccountId && chatId == selectedChatId
        if !isCurrentChat || !NSApplication.shared.isActive {
            NotificationManager.postIncoming(chatName: chat.name, preview: chat.preview)
        }
        // Subtle in-app ping for messages landing outside the open chat
        // (notifications already sound when the app is inactive).
        if NSApplication.shared.isActive, !isCurrentChat,
           accountId == selectedAccountId {
            NSSound(named: "Pop")?.play()
        }
    }
}
