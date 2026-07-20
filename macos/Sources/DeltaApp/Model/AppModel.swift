import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    private struct ConversationKey: Hashable {
        let accountId: UInt32
        let chatId: UInt32
    }

    private struct VisibleMessageKey: Hashable {
        let accountId: UInt32
        let chatId: UInt32
        let msgId: UInt32
        let selectionGeneration: UInt64
    }

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
    var selectedChatId: UInt32? {
        didSet {
            if selectedChatId != oldValue {
                selectionGeneration &+= 1
                visibleMessages.removeAll()
                seenReceiptRequests.removeAll()
                receiptAttempts.removeAll()
                replyTo = nil
                resetMessageWindow()
            }
        }
    }
    private var selectedChatCache: ChatItem?
    private var visibleMessages: [VisibleMessageKey: MessageItem] = [:]
    private var seenReceiptRequests: Set<VisibleMessageKey> = []
    private(set) var messageListEntries: [MessageListEntry] = []
    private(set) var messageListAssemblyCount = 0
    /// Bumped when the entry list gains a new LAST message while the view
    /// reports at-bottom; the view answers by scrolling to the bottom
    /// anchor. Decided here because the model sees the PRE-append sentinel
    /// state — by the time view-side callbacks run, the grown content has
    /// already pushed the sentinel out of the viewport (see
    /// meta/issues/send-scroll-regression.md).
    private(set) var followBottomGeneration: UInt64 = 0
    private(set) var messages: [MessageItem] = [] {
        didSet { refreshMessageListEntries() }
    }
    /// Whether older history exists beyond the currently loaded window.
    private(set) var hasMoreMessages = false
    /// Set once a load-older returned empty: stops the page-boundary flicker
    /// where count == loadedLimit keeps re-asserting "more history".
    private var historyExhausted = false
    /// Size of the loaded window; grows as the user scrolls into history.
    private var loadedLimit: UInt32 = AppModel.messagePageSize
    /// Invalidates in-flight reload/prepend operations whenever the window
    /// changes under them, including account and chat transitions.
    private var messageWindowGeneration: UInt64 = 0
    private var accountTransitionGeneration: UInt64 = 0
    private var desiredAccountId: UInt32?
    private var coreSelectedAccountId: UInt32?
    private var accountTransitionInFlight = false
    private var selectionGeneration: UInt64 = 0
    private var pendingSends: Set<ConversationKey> = []
    // Eager layout renders the whole window (see ChatDetailView's VStack
    // note) — keep pages small; a viewport shows ~10 messages at most.
    static let messagePageSize: UInt32 = 50
    /// Reported by the chat view's bottom sentinel; gates window growth.
    var viewIsAtBottom = true
    private var reloadChatsScheduled = false
    private var reloadChatsRequested = false
    private var reloadMessagesScheduled = false
    private var reloadMessagesRequested = false
    private var dockBadgeReloadScheduled = false
    private var dockBadgeReloadRequested = false
    /// Main-screen action failures (send/accept/block/…), shown as an alert.
    var actionError: String?
    /// Message being replied to (composer banner); sent as quote.
    var replyTo: MessageItem?
    private var drafts: [ConversationKey: String] = [:]
    var draft: String {
        get {
            guard let key = selectedConversationKey else { return "" }
            return drafts[key, default: ""]
        }
        set {
            guard let key = selectedConversationKey else { return }
            if newValue.isEmpty {
                drafts.removeValue(forKey: key)
            } else {
                drafts[key] = newValue
            }
        }
    }
    var isSendingCurrentConversation: Bool {
        selectedConversationKey.map(pendingSends.contains) ?? false
    }
    /// Sidebar shows the archive instead of the normal list.
    var showingArchive = false
    /// Sidebar search field text; non-empty switches the list to search hits.
    var searchQuery = ""
    var showSettings = false
    var showNewChat = false
    var showNewGroup = false
    private(set) var connectivityValue: UInt32 = 0
    private(set) var dockUnreadCount: UInt32 = 0

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
    @ObservationIgnored private let postIncomingNotification:
        @MainActor @Sendable (String, String) -> Void
    @ObservationIgnored private let isAppActive: @MainActor @Sendable () -> Bool
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var chatListRequestGeneration: UInt64 = 0
    private var receiptAttempts: [VisibleMessageKey: Int] = [:]

    nonisolated init(
        service: any ChatService,
        isAppActive: @escaping @MainActor @Sendable () -> Bool = {
            NSApplication.shared.isActive
        },
        postIncomingNotification: @escaping @MainActor @Sendable (String, String) -> Void = {
            chatName, preview in
            NotificationManager.postIncoming(chatName: chatName, preview: preview)
        }
    ) {
        self.service = service
        self.postIncomingNotification = postIncomingNotification
        self.isAppActive = isAppActive
    }

    deinit {
        eventTask?.cancel()
        searchTask?.cancel()
    }

    var selectedChat: ChatItem? {
        guard let id = selectedChatId else { return nil }
        return chats.first { $0.id == id }
            ?? selectedChatCache.flatMap { $0.id == id ? $0 : nil }
    }

    private var selectedConversationKey: ConversationKey? {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return nil }
        return ConversationKey(accountId: accountId, chatId: chatId)
    }

    var currentSelectionGeneration: UInt64 { selectionGeneration }

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
                coreSelectedAccountId = account.id
                desiredAccountId = account.id
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
        // Send-scroll probe (issue: send-scroll-regression): seed past one
        // window so the probe exercises the full-window slide, then send a
        // probe message. Pair with DCNATIVE_DEBUG_SCROLL=1 and read whether
        // the bottom anchor stays visible through the probe append.
        if screen == .main, env["DCNATIVE_AUTOSEND"] == "1", selectedChatId != nil {
            Task {
                for i in 1 ... Int(Self.messagePageSize) + 5 {
                    draft = "autosend seed \(i)"
                    await send(draft)
                }
                try? await Task.sleep(for: .seconds(3))
                scrollDebug("model: AUTOSEND probe (messages=\(messages.count))")
                await send("autosend probe")
                try? await Task.sleep(for: .seconds(2))
                scrollDebug(
                    "model: AUTOSEND done (messages=\(messages.count), "
                        + "atBottom=\(viewIsAtBottom))")
                // Probe runs are disposable: exit so stdio flushes and no
                // stray windows accumulate on unattended reruns.
                exit(0)
            }
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
        eventTask = Task { [weak self, service] in
            for await (accountId, event) in service.events {
                guard let self else { return }
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
        coreSelectedAccountId = accountId
        resetAccountScopedState()
        desiredAccountId = accountId
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
            coreSelectedAccountId = accountId
            resetAccountScopedState()
            desiredAccountId = accountId
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
        accountTransitionGeneration &+= 1
        desiredAccountId = id
        guard !accountTransitionInFlight else { return }
        accountTransitionInFlight = true
        defer { accountTransitionInFlight = false }

        while let target = desiredAccountId {
            if target == selectedAccountId, target == coreSelectedAccountId { return }
            let generation = accountTransitionGeneration
            do {
                try await service.selectAccount(id: target)
                coreSelectedAccountId = target
            } catch {
                guard generation == accountTransitionGeneration,
                      desiredAccountId == target
                else { continue }

                actionError = error.localizedDescription
                desiredAccountId = selectedAccountId
                if let selectedAccountId {
                    do {
                        try await service.selectAccount(id: selectedAccountId)
                        coreSelectedAccountId = selectedAccountId
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                if generation != accountTransitionGeneration { continue }
                return
            }

            guard generation == accountTransitionGeneration,
                  desiredAccountId == target
            else { continue }

            if selectedAccountId != target {
                resetAccountScopedState()
                selectedAccountId = target
                await reloadChats()
            }
            if generation == accountTransitionGeneration,
               desiredAccountId == target {
                return
            }
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
            drafts = drafts.filter { $0.key.accountId != id }
            resetAccountScopedState()
            if let next = await service.selectedAccount(),
               accounts.contains(where: { $0.id == next && $0.isConfigured }) {
                coreSelectedAccountId = next
                selectedAccountId = next
                desiredAccountId = next
                await reloadChats()
                screen = .main
            } else if let next = accounts.first(where: \.isConfigured) {
                try await service.selectAccount(id: next.id)
                coreSelectedAccountId = next.id
                selectedAccountId = next.id
                desiredAccountId = next.id
                await reloadChats()
                screen = .main
            } else {
                selectedAccountId = nil
                coreSelectedAccountId = nil
                desiredAccountId = nil
                searchQuery = ""
                showingArchive = false
                dockUnreadCount = 0
                NSApp.dockTile.badgeLabel = nil
                screen = .onboarding
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Main-screen actions

    func reloadChats(searchGeneration expectedSearchGeneration: UInt64? = nil) async {
        guard let accountId = selectedAccountId else { return }
        chatListRequestGeneration &+= 1
        let requestGeneration = chatListRequestGeneration
        do {
            let query = searchQuery.trimmingCharacters(in: .whitespaces)
            let searchSnapshot = expectedSearchGeneration
                ?? (!query.isEmpty ? searchGeneration : nil)
            let archiveSnapshot = showingArchive
            let list: [ChatItem]
            if !query.isEmpty {
                list = try await service.searchChats(accountId: accountId, query: query)
            } else if archiveSnapshot {
                list = try await service.archivedChats(accountId: accountId)
            } else {
                list = try await service.chatList(accountId: accountId)
            }
            // A slow fetch may resume after the user switched accounts or
            // changed the filter — never let stale results clobber the view.
            guard accountId == selectedAccountId,
                  requestGeneration == chatListRequestGeneration,
                  query == searchQuery.trimmingCharacters(in: .whitespaces),
                  archiveSnapshot == showingArchive,
                  searchSnapshot == nil || searchSnapshot == searchGeneration
            else { return }

            let selectedSnapshot = selectedChatId
            var selectedRow = selectedSnapshot.flatMap { selected in
                list.first { $0.id == selected }
            }
            var selectedConfirmedMissing = false
            if let selectedSnapshot, selectedRow == nil, !query.isEmpty {
                do {
                    selectedRow = try await service.chatById(
                        accountId: accountId, chatId: selectedSnapshot)
                    selectedConfirmedMissing = selectedRow == nil
                } catch {
                    // Keep the last selected row on a transient point-lookup
                    // failure; the next event/search change retries.
                }
                guard accountId == selectedAccountId,
                      requestGeneration == chatListRequestGeneration,
                      selectedSnapshot == selectedChatId,
                      query == searchQuery.trimmingCharacters(in: .whitespaces),
                      archiveSnapshot == showingArchive,
                      searchSnapshot == nil || searchSnapshot == searchGeneration
                else { return }
            }

            chats = list
            if let selectedRow {
                selectedChatCache = selectedRow
            }
            refreshMessageListEntries()
            // Only drop the selection outside search: a filtered list not
            // containing the open chat is expected and must not destroy the
            // open conversation (and its draft) on every keystroke.
            if let selected = selectedChatId,
               (query.isEmpty && !chats.contains(where: { $0.id == selected })
                   || selectedConfirmedMissing) {
                selectedChatId = nil
                selectedChatCache = nil
                resetMessageWindow()
            }
            scheduleUpdateDockBadge()
        } catch {
            // Keep the last known list; a follow-up event will retry.
        }
    }

    private func updateDockBadge() async {
        guard let unread = try? await service.unreadCount() else { return }
        dockUnreadCount = unread
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    func reloadMessages() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else {
            resetMessageWindow()
            return
        }
        let generation = messageWindowGeneration
        let requestedLimit = loadedLimit
        let previousOldest = messages.first?.id
        do {
            // Refresh the whole loaded window so state/reaction changes on
            // already-visible history are picked up.
            var page = try await service.messages(
                accountId: accountId, chatId: chatId,
                limit: requestedLimit, beforeMsgId: nil)
            // New messages slide the newest-N window; grow it so history the
            // user has scrolled to doesn't fall off the top mid-read. The
            // shared loadedLimit is only written after the selection guard.
            var grownLimit = requestedLimit
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
            guard accountId == selectedAccountId, chatId == selectedChatId,
                  generation == messageWindowGeneration
            else { return }
            if grownLimit != loadedLimit {
                loadedLimit = grownLimit
                // The window moved under us (new msgs or a deletion) — any
                // earlier "history exhausted" verdict is stale now.
                historyExhausted = false
            }
            messages = page
            hasMoreMessages = !historyExhausted && page.count >= Int(loadedLimit)
            messageWindowGeneration &+= 1
        } catch {
            // Preserve the last valid window; a later event retries.
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
        let generation = messageWindowGeneration
        do {
            let older = try await service.messages(
                accountId: accountId, chatId: chatId,
                limit: Self.messagePageSize, beforeMsgId: oldest.id)
            // Stale-await guard: the user may have switched chats while the
            // page was in flight; never splice A's history into B.
            guard accountId == selectedAccountId, chatId == selectedChatId,
                  messages.first?.id == oldest.id,
                  generation == messageWindowGeneration
            else { return .nothing }
            guard !older.isEmpty else {
                historyExhausted = true
                hasMoreMessages = false
                return .nothing
            }
            messages.insert(contentsOf: older, at: 0)
            loadedLimit += UInt32(older.count)
            hasMoreMessages = older.count >= Int(Self.messagePageSize)
            messageWindowGeneration &+= 1
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
        reloadChatsRequested = true
        guard !reloadChatsScheduled else { return }
        reloadChatsScheduled = true
        Task {
            repeat {
                try? await Task.sleep(for: .milliseconds(80))
                reloadChatsRequested = false
                await reloadChats()
            } while reloadChatsRequested
            reloadChatsScheduled = false
        }
    }

    private func scheduleReloadMessages() {
        reloadMessagesRequested = true
        guard !reloadMessagesScheduled else { return }
        reloadMessagesScheduled = true
        Task {
            repeat {
                try? await Task.sleep(for: .milliseconds(80))
                reloadMessagesRequested = false
                await reloadMessages()
            } while reloadMessagesRequested
            reloadMessagesScheduled = false
        }
    }

    private func scheduleUpdateDockBadge() {
        dockBadgeReloadRequested = true
        guard !dockBadgeReloadScheduled else { return }
        dockBadgeReloadScheduled = true
        Task {
            repeat {
                try? await Task.sleep(for: .milliseconds(80))
                dockBadgeReloadRequested = false
                await updateDockBadge()
            } while dockBadgeReloadRequested
            dockBadgeReloadScheduled = false
        }
    }

    /// App became active: catch up and mark the visible chat read now that
    /// the user can actually see it.
    func appDidBecomeActive() async {
        guard screen == .main else { return }
        await reloadChats()
        await reloadMessages()
        await markCurrentlyVisibleMessagesSeen()
        await markSelectedChatNoticed()
    }

    /// Called synchronously from scroll visibility so account-local identity is
    /// captured before an asynchronous receipt task can run.
    func messageVisibilityChanged(
        accountId: UInt32, chatId: UInt32, selectionGeneration: UInt64,
        message: MessageItem, visible: Bool
    ) {
        let key = VisibleMessageKey(
            accountId: accountId, chatId: chatId, msgId: message.id,
            selectionGeneration: selectionGeneration)
        guard accountId == selectedAccountId, chatId == selectedChatId,
              selectionGeneration == self.selectionGeneration,
              message.chatId == chatId
        else { return }
        if visible {
            visibleMessages[key] = message
            Task { [weak self] in await self?.markVisibleMessageSeen(key) }
        } else {
            visibleMessages.removeValue(forKey: key)
        }
    }

    private func markVisibleMessageSeen(_ key: VisibleMessageKey) async {
        guard isAppActive(), key.accountId == selectedAccountId,
              key.chatId == selectedChatId,
              key.selectionGeneration == selectionGeneration,
              let message = visibleMessages[key],
              !message.isOutgoing, !message.isInfo,
              selectedChat?.isContactRequest == false,
              receiptAttempts[key, default: 0] < 3,
              seenReceiptRequests.insert(key).inserted
        else { return }
        receiptAttempts[key, default: 0] += 1
        do {
            try await service.markSeen(accountId: key.accountId, msgIds: [key.msgId])
        } catch {
            seenReceiptRequests.remove(key)
            guard visibleMessages[key] != nil,
                  key.accountId == selectedAccountId,
                  key.chatId == selectedChatId,
                  key.selectionGeneration == selectionGeneration
            else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                await self?.markVisibleMessageSeen(key)
            }
        }
    }

    private func markCurrentlyVisibleMessagesSeen() async {
        guard isAppActive(), let accountId = selectedAccountId,
              let chatId = selectedChatId,
              selectedChat?.isContactRequest == false
        else { return }
        let keys = visibleMessages.compactMap { key, message in
            key.accountId == accountId && key.chatId == chatId
                && key.selectionGeneration == selectionGeneration
                && !message.isOutgoing && !message.isInfo ? key : nil
        }
        for key in keys {
            await markVisibleMessageSeen(key)
        }
    }

    func searchChanged() async {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.reloadChats(searchGeneration: generation)
        }
    }

    /// Executes the latest debounced search immediately. Also used when a
    /// caller needs deterministic completion rather than wall-clock waiting.
    func flushPendingSearch() async {
        searchTask?.cancel()
        searchTask = nil
        await reloadChats(searchGeneration: searchGeneration)
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
        let generation = selectionGeneration
        do {
            try await service.acceptChat(accountId: accountId, chatId: chatId)
            guard accountId == selectedAccountId, chatId == selectedChatId,
                  generation == selectionGeneration
            else { return }
            await reloadChats()
            guard accountId == selectedAccountId, chatId == selectedChatId,
                  generation == selectionGeneration
            else { return }
            await reloadMessages()
            await markCurrentlyVisibleMessagesSeen()
            await markSelectedChatNoticed()
        } catch {
            if accountId == selectedAccountId, chatId == selectedChatId,
               generation == selectionGeneration {
                actionError = error.localizedDescription
            }
        }
    }

    func blockSelectedChat() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        let generation = selectionGeneration
        do {
            try await service.blockChat(accountId: accountId, chatId: chatId)
            guard accountId == selectedAccountId, chatId == selectedChatId,
                  generation == selectionGeneration
            else { return }
            selectedChatId = nil
            selectedChatCache = nil
            messages = []
            await reloadChats()
        } catch {
            if accountId == selectedAccountId, chatId == selectedChatId,
               generation == selectionGeneration {
                actionError = error.localizedDescription
            }
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

    func sendAttachment(
        accountId: UInt32, chatId: UInt32, path: String,
        caption: String, quotedMsgId: UInt32?
    ) async {
        guard accountId == selectedAccountId, chatId == selectedChatId else { return }
        let conversationKey = ConversationKey(accountId: accountId, chatId: chatId)
        guard pendingSends.insert(conversationKey).inserted else { return }
        defer { pendingSends.remove(conversationKey) }
        let generation = selectionGeneration
        let draftAtStart = drafts[conversationKey]
        let replyId = quotedMsgId
        do {
            _ = try await service.sendMessage(
                accountId: accountId, chatId: chatId,
                text: caption.isEmpty ? nil : caption,
                filePath: path,
                quotedMsgId: replyId)
            if accountId == selectedAccountId, chatId == selectedChatId,
               replyTo?.id == replyId, generation == selectionGeneration {
                replyTo = nil
            }
            clearDraft(
                conversationKey, ifUnchanged: draftAtStart,
                sentText: caption.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            if accountId == selectedAccountId, chatId == selectedChatId,
               generation == selectionGeneration {
                actionError = error.localizedDescription
            }
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
        let generation = selectionGeneration
        do {
            let chatId = try await service.createGroup(
                accountId: accountId, name: name, memberContactIds: memberIds)
            guard accountId == selectedAccountId, generation == selectionGeneration else {
                return nil
            }
            return await selectCreatedChat(
                accountId: accountId, chatId: chatId,
                originatingGeneration: generation)
        } catch {
            return error.localizedDescription
        }
    }

    private func selectCreatedChat(
        accountId: UInt32, chatId: UInt32, originatingGeneration: UInt64
    ) async -> String? {
        guard accountId == selectedAccountId,
              originatingGeneration == selectionGeneration
        else { return nil }
        searchTask?.cancel()
        searchGeneration &+= 1
        searchQuery = ""
        showingArchive = false
        selectedChatId = nil
        selectedChatCache = nil
        let loadingGeneration = selectionGeneration
        await reloadChats()
        guard accountId == selectedAccountId,
              loadingGeneration == selectionGeneration
        else { return nil }

        let row: ChatItem?
        if let listed = chats.first(where: { $0.id == chatId }) {
            row = listed
        } else {
            do {
                row = try await service.chatById(accountId: accountId, chatId: chatId)
            } catch {
                guard accountId == selectedAccountId,
                      loadingGeneration == selectionGeneration
                else { return nil }
                return "Chat was created but could not be loaded: \(error.localizedDescription)"
            }
            guard accountId == selectedAccountId,
                  loadingGeneration == selectionGeneration
            else { return nil }
        }
        guard let row else { return "Chat was created but could not be loaded." }
        selectedChatCache = row
        selectedChatId = chatId
        return nil
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
        if let selectedChatId {
            if let row = chats.first(where: { $0.id == selectedChatId }) {
                selectedChatCache = row
            } else if selectedChatCache?.id != selectedChatId {
                selectedChatCache = nil
            }
        } else {
            selectedChatCache = nil
        }
        // Clear immediately so the stale-window growth check in
        // reloadMessages never compares against the previous chat.
        resetMessageWindow()
        await reloadMessages()
        scrollDebug(
            "open chat=\(selectedChatId.map(String.init) ?? "-") "
                + "msgs=\(messages.count) hasMore=\(hasMoreMessages)")
        await markSelectedChatNoticed()
    }

    private func resetMessageWindow() {
        messageWindowGeneration &+= 1
        messages = []
        loadedLimit = Self.messagePageSize
        hasMoreMessages = false
        historyExhausted = false
        viewIsAtBottom = true
    }

    private func refreshMessageListEntries() {
        let previousLast = messageListEntries.last?.id
        messageListEntries = buildMessageListEntries(
            messages, inGroup: selectedChat?.isGroup == true)
        messageListAssemblyCount += 1
        // New newest entry (append or full-window slide — count can stay
        // constant, so compare ids) while at the bottom: follow it. Prepends
        // keep the last entry, scrolled-up readers report !atBottom; neither
        // fires.
        if viewIsAtBottom, let newLast = messageListEntries.last?.id,
           newLast != previousLast {
            followBottomGeneration &+= 1
        }
    }

    private func resetAccountScopedState() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        selectedChatId = nil
        selectedChatCache = nil
        visibleMessages.removeAll()
        seenReceiptRequests.removeAll()
        receiptAttempts.removeAll()
        replyTo = nil
        chats = []
        searchQuery = ""
        showingArchive = false
        actionError = nil
        resetMessageWindow()
    }

    private func markSelectedChatNoticed() async {
        guard isAppActive(),
              let accountId = selectedAccountId,
              let chat = selectedChat,
              chat.freshCount > 0, !chat.isContactRequest
        else { return }
        try? await service.markNoticed(accountId: accountId, chatId: chat.id)
    }

    func send(_ text: String) async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else { return }
        let conversationKey = ConversationKey(accountId: accountId, chatId: chatId)
        guard pendingSends.insert(conversationKey).inserted else { return }
        defer { pendingSends.remove(conversationKey) }
        let generation = selectionGeneration
        let draftAtStart = drafts[conversationKey]
        let replyId = replyTo?.id
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await service.sendMessage(
                accountId: accountId, chatId: chatId,
                text: trimmed, filePath: nil, quotedMsgId: replyId)
            if accountId == selectedAccountId, chatId == selectedChatId,
               replyTo?.id == replyId, generation == selectionGeneration {
                replyTo = nil
            }
            clearDraft(conversationKey, ifUnchanged: draftAtStart, sentText: trimmed)
        } catch {
            if accountId == selectedAccountId, chatId == selectedChatId,
               generation == selectionGeneration {
                actionError = error.localizedDescription
            }
        }
    }

    private func clearDraft(
        _ key: ConversationKey, ifUnchanged original: String?, sentText: String
    ) {
        guard drafts[key] == original,
              original?.trimmingCharacters(in: .whitespacesAndNewlines) == sentText
        else { return }
        drafts.removeValue(forKey: key)
    }

    func createChat(email: String, name: String) async -> String? {
        guard let accountId = selectedAccountId else { return nil }
        let generation = selectionGeneration
        do {
            let chatId = try await service.createChat(accountId: accountId, email: email, name: name)
            guard accountId == selectedAccountId, generation == selectionGeneration else {
                return nil
            }
            return await selectCreatedChat(
                accountId: accountId, chatId: chatId,
                originatingGeneration: generation)
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Event handling (refresh rules from docs/specs/ui-needs.md §5)

    private func handle(accountId: UInt32, event: ServiceEvent) async {
        switch event {
        case .configureProgress(let permille, let comment):
            guard isConfiguring, accountId == onboardingAccountId else { return }
            if permille > 0 {
                configureProgress = Double(permille) / 1000
            }
            if let comment { configureComment = comment }

        case .imexProgress(let permille):
            guard isConfiguring, accountId == onboardingAccountId else { return }
            // Same progress bar as configure; 0 (error/cancel) is surfaced
            // through the thrown error of joinSecondDevice instead.
            if permille > 0 {
                configureProgress = Double(permille) / 1000
                configureComment = permille >= 1000 ? nil : "Transferring account…"
            }

        case .accountsChanged:
            accounts = (try? await service.accounts()) ?? accounts
            scheduleUpdateDockBadge()

        case .fullRefreshRequired:
            accounts = (try? await service.accounts()) ?? accounts
            scheduleUpdateDockBadge()
            if screen == .main {
                scheduleReloadChats()
                scheduleReloadMessages()
            }
            if showSettings {
                await refreshConnectivity()
            }

        case .chatlistChanged:
            scheduleUpdateDockBadge()
            if screen == .main, accountId == selectedAccountId {
                scheduleReloadChats()
                // Overflow recovery maps to ChatlistChanged; per-chat events
                // may have been dropped, so refresh the open chat too.
                scheduleReloadMessages()
            }

        case .chatChanged(let chatId):
            scheduleUpdateDockBadge()
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

        case .incomingMessage(let chatId, let msgId):
            scheduleUpdateDockBadge()
            if accountId == selectedAccountId {
                scheduleReloadChats()
                if chatId == selectedChatId {
                    scheduleReloadMessages()
                    if isAppActive() {
                        await markSelectedChatNoticed()
                    }
                }
            }
            // Notifications work for EVERY account, not just the selected one.
            await notifyIncoming(accountId: accountId, chatId: chatId, msgId: msgId)

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
    private func notifyIncoming(accountId: UInt32, chatId: UInt32, msgId: UInt32) async {
        // Always a fresh point lookup: the sidebar list may be filtered
        // (hiding muted chats). Load the event's exact message separately:
        // the chat preview may already point at a later message in a burst.
        guard let message = try? await service.messageById(accountId: accountId, msgId: msgId),
              let chat = try? await service.chatById(accountId: accountId, chatId: chatId),
              !chat.isMuted, !chat.isDeviceTalk
        else { return }

        let isCurrentChat = accountId == selectedAccountId && chatId == selectedChatId
        if !isCurrentChat || !isAppActive() {
            postIncomingNotification(chat.name, message.text)
        }
    }
}
