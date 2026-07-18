import AppKit
import Foundation
import Testing
@testable import DeltaApp

@MainActor
@Suite struct AppModelTests {
    @Test func concurrentReloadDoesNotClobberPrependedHistory() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await service.setMessages(testMessages(51 ... 100))
        await model.chatSelectionChanged()
        #expect(model.messages.count == 50)
        #expect(model.hasMoreMessages)

        await service.enqueueMessages(.suspended("older"))
        let olderTask = Task { await model.loadOlderMessages() }
        try await service.waitUntilMessagesSuspended("older")

        await service.enqueueMessages(.suspended("reload"))
        let reloadTask = Task { await model.reloadMessages() }
        try await service.waitUntilMessagesSuspended("reload")

        await service.resumeMessages("older", with: testMessages(1 ... 50))
        _ = await olderTask.value
        #expect(model.messages.count == 100)

        await service.resumeMessages("reload", with: testMessages(51 ... 100))
        await reloadTask.value
        #expect(model.messages.map(\.id) == Array(1 ... 100).map(UInt32.init))
        #expect(model.hasMoreMessages)
    }

    @Test func staleNormalListCannotOverwriteArchive() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()

        await service.enqueueChatList(.suspended("normal"))
        let normalTask = Task { await model.reloadChats() }
        try await service.waitUntilChatListSuspended("normal")

        model.showingArchive = true
        await model.reloadChats()
        #expect(model.chats.map(\.name) == ["Archived"])

        await service.resumeChatList("normal", with: [testChat(name: "Stale normal")])
        await normalTask.value
        #expect(model.chats.map(\.name) == ["Archived"])
    }

    @Test func demoAccountTransitionClearsCollidingChatState() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await service.setMessages(testMessages(51 ... 100))
        await model.chatSelectionChanged()
        #expect(!model.messages.isEmpty)

        await model.tryDemo()

        #expect(model.selectedAccountId == 2)
        #expect(model.selectedChatId == nil)
        #expect(model.messages.isEmpty)
        #expect(model.replyTo == nil)
        #expect(model.searchQuery.isEmpty)
        #expect(!model.showingArchive)
    }

    @Test func reloadCannotWriteAfterChatSwitch() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await service.setMessages(testMessages(51 ... 100))
        await model.chatSelectionChanged()

        await service.enqueueMessages(.suspended("old-chat-reload"))
        let reloadTask = Task { await model.reloadMessages() }
        try await service.waitUntilMessagesSuspended("old-chat-reload")

        model.selectedChatId = 11
        await service.setMessages(testMessages(201 ... 210, chatId: 11))
        await model.chatSelectionChanged()
        await service.resumeMessages("old-chat-reload", with: testMessages(51 ... 100))
        await reloadTask.value

        #expect(model.messages.map(\.chatId) == Array(repeating: 11, count: 10))
    }

    @Test func olderPageCannotSpliceAfterChatSwitch() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await service.setMessages(testMessages(51 ... 100))
        await model.chatSelectionChanged()

        await service.enqueueMessages(.suspended("old-chat-history"))
        let olderTask = Task { await model.loadOlderMessages() }
        try await service.waitUntilMessagesSuspended("old-chat-history")

        model.selectedChatId = 11
        await service.setMessages(testMessages(201 ... 210, chatId: 11))
        await model.chatSelectionChanged()
        await service.resumeMessages("old-chat-history", with: testMessages(1 ... 50))

        #expect(await olderTask.value == .nothing)
        #expect(model.messages.map(\.chatId) == Array(repeating: 11, count: 10))
    }

    @Test func staleFailedReloadCannotErasePrependedHistory() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await service.setMessages(testMessages(51 ... 100))
        await model.chatSelectionChanged()

        await service.enqueueMessages(.suspended("failed-reload"))
        let reloadTask = Task { await model.reloadMessages() }
        try await service.waitUntilMessagesSuspended("failed-reload")

        await service.setMessages(testMessages(1 ... 50))
        #expect(await model.loadOlderMessages() != .nothing)
        #expect(model.messages.count == 100)

        await service.failMessages("failed-reload")
        await reloadTask.value
        #expect(model.messages.map(\.id) == Array(1 ... 100).map(UInt32.init))
    }

    @Test func sidebarSearchPreservesSelectedChatAndDraft() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await model.chatSelectionChanged()
        model.draft = "keep this"

        model.searchQuery = "no match"
        await model.searchChanged()
        await model.flushPendingSearch()

        #expect(model.chats.isEmpty)
        #expect(model.selectedChat?.id == 10)
        #expect(model.draft == "keep this")
    }

    @Test func filteredSelectedChatCacheStillRefreshes() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        await model.chatSelectionChanged()

        model.searchQuery = "no match"
        await model.searchChanged()
        await model.flushPendingSearch()
        await service.setChat(testChat(name: "Renamed"), accountId: 1)
        await model.searchChanged()
        await model.flushPendingSearch()

        #expect(model.selectedChat?.name == "Renamed")
    }

    @Test func sidebarSearchDebouncesRapidEdits() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()

        for query in ["n", "no", "none"] {
            model.searchQuery = query
            await model.searchChanged()
        }
        await model.flushPendingSearch()

        #expect(await service.searchCallCount() == 1)
    }

    @Test func canceledSameQuerySearchCannotOverwriteNewestResults() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()

        model.searchQuery = "same"
        await model.searchChanged()
        await service.enqueueSearch(.suspended("old-same"))
        let oldSearch = Task { await model.reloadChats() }
        try await service.waitUntilSearchSuspended("old-same")

        model.searchQuery = "different"
        await model.searchChanged()
        model.searchQuery = "same"
        await model.searchChanged()
        await service.enqueueSearch(.suspended("new-same"))
        let newSearch = Task { await model.flushPendingSearch() }
        try await service.waitUntilSearchSuspended("new-same")

        await service.resumeSearch("new-same", with: [testChat(name: "Newest")])
        await newSearch.value
        await service.resumeSearch("old-same", with: [testChat(name: "Stale")])
        await oldSearch.value

        #expect(model.chats.map(\.name) == ["Newest"])
    }

    @Test func rapidAccountSwitchesKeepLatestIntentSelected() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        await service.addSwitchingAccounts()
        let model = AppModel(service: service)
        await model.bootstrap()

        await service.enqueueSelectAccount("two")
        let switchTwo = Task { await model.switchAccount(to: 2) }
        try await service.waitUntilSelectAccountSuspended("two")

        await service.enqueueSelectAccount("three")
        let switchThree = Task { await model.switchAccount(to: 3) }
        await service.resumeSelectAccount("two")
        try await service.waitUntilSelectAccountSuspended("three")
        await service.resumeSelectAccount("three")
        await switchTwo.value
        await switchThree.value

        #expect(model.selectedAccountId == 3)
        #expect(await service.selectedAccount() == 3)
    }

    @Test func selectingDisplayedAccountCancelsPendingSwitch() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        await service.addSwitchingAccounts()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.draft = "preserve"
        await service.setMessages(testMessages(51 ... 100))
        await model.chatSelectionChanged()

        await service.enqueueSelectAccount("two")
        let switchTwo = Task { await model.switchAccount(to: 2) }
        try await service.waitUntilSelectAccountSuspended("two")
        await model.switchAccount(to: 1)
        await service.resumeSelectAccount("two")
        await switchTwo.value

        #expect(model.selectedAccountId == 1)
        #expect(await service.selectedAccount() == 1)
        #expect(model.selectedChatId == 10)
        #expect(model.draft == "preserve")
        #expect(model.messages.count == 50)
    }

    @Test func failedLatestSwitchRestoresDisplayedAccount() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        await service.addSwitchingAccounts()
        let model = AppModel(service: service)
        await model.bootstrap()

        await service.enqueueSelectAccount("two")
        let switchTwo = Task { await model.switchAccount(to: 2) }
        try await service.waitUntilSelectAccountSuspended("two")
        await service.enqueueSelectAccount("three")
        let switchThree = Task { await model.switchAccount(to: 3) }

        await service.resumeSelectAccount("two")
        try await service.waitUntilSelectAccountSuspended("three")
        await service.failSelectAccount("three")
        await switchTwo.value
        await switchThree.value

        #expect(model.selectedAccountId == 1)
        #expect(await service.selectedAccount() == 1)
    }

    @Test func staleSendCompletionCannotClearNewReplyTarget() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.replyTo = testMessages(55 ... 55)[0]

        await service.enqueueSendMessage("send")
        let sendTask = Task { await model.send("hello") }
        try await service.waitUntilSendMessageSuspended("send")

        model.selectedChatId = 11
        model.replyTo = testMessages(205 ... 205, chatId: 11)[0]
        await service.resumeSendMessage("send", result: 999)
        await sendTask.value

        #expect(model.replyTo?.id == 205)
    }

    @Test func staleBlockCompletionCannotClearNewSelection() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10

        await service.enqueueBlockChat("block")
        let blockTask = Task { await model.blockSelectedChat() }
        try await service.waitUntilBlockChatSuspended("block")

        model.selectedChatId = 11
        await service.resumeBlockChat("block")
        await blockTask.value

        #expect(model.selectedChatId == 11)
    }

    @Test func successfulSendClearsOnlyTheUnchangedDraft() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.draft = "first draft"

        await service.enqueueSendMessage("first-send")
        let firstSend = Task { await model.send(model.draft) }
        try await service.waitUntilSendMessageSuspended("first-send")
        await service.resumeSendMessage("first-send", result: 1)
        await firstSend.value
        #expect(model.draft.isEmpty)

        model.draft = "sending"
        await service.enqueueSendMessage("edited-send")
        let editedSend = Task { await model.send(model.draft) }
        try await service.waitUntilSendMessageSuspended("edited-send")
        model.draft = "edited while sending"
        await service.resumeSendMessage("edited-send", result: 2)
        await editedSend.value
        #expect(model.draft == "edited while sending")
    }

    @Test func failedSendKeepsDraft() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.draft = "retry me"

        await service.enqueueSendMessage("failed-send")
        let sendTask = Task { await model.send(model.draft) }
        try await service.waitUntilSendMessageSuspended("failed-send")
        await service.failSendMessage("failed-send")
        await sendTask.value

        #expect(model.draft == "retry me")
        #expect(model.actionError == "scripted failure")
    }

    @Test func pendingSendCannotBeSubmittedTwice() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.draft = "once"

        await service.enqueueSendMessage("pending")
        let first = Task { await model.send(model.draft) }
        try await service.waitUntilSendMessageSuspended("pending")
        let second = Task { await model.send(model.draft) }
        await second.value

        #expect(await service.sendMessageCallCount() == 1)
        await service.resumeSendMessage("pending", result: 1)
        await first.value
    }

    @Test func successfulSendClearsOriginDraftAfterSwitchAway() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.draft = "sent"

        await service.enqueueSendMessage("switch-send")
        let sendTask = Task { await model.send(model.draft) }
        try await service.waitUntilSendMessageSuspended("switch-send")
        model.selectedChatId = 11
        await model.chatSelectionChanged()
        await service.resumeSendMessage("switch-send", result: 1)
        await sendTask.value

        model.selectedChatId = 10
        #expect(model.draft.isEmpty)
    }

    @Test func sendFailureAfterSelectionMutationDoesNotLeakError() async throws {
        _ = NSApplication.shared
        let service = ScriptedChatService()
        let model = AppModel(service: service)
        await model.bootstrap()
        model.selectedChatId = 10
        model.draft = "fail"

        await service.enqueueSendMessage("selection-failure")
        let sendTask = Task { await model.send(model.draft) }
        try await service.waitUntilSendMessageSuspended("selection-failure")
        model.selectedChatId = 11
        await service.failSendMessage("selection-failure")
        await sendTask.value

        #expect(model.actionError == nil)
    }
}

private func testChat(name: String = "Chat", id: UInt32 = 10) -> ChatItem {
    ChatItem(
        id: id, name: name, preview: "", timestamp: 0, freshCount: 0,
        isSelfTalk: false, isPinned: false, isMuted: false,
        isContactRequest: false, color: "#123456")
}

private func testMessages(_ ids: ClosedRange<Int>, chatId: UInt32 = 10) -> [MessageItem] {
    ids.map { id in
        MessageItem(
            id: UInt32(id), chatId: chatId, text: "message \(id)",
            timestamp: Int64(id), isOutgoing: true, isInfo: false,
            senderName: "Me", senderColor: "#123456", senderAvatar: nil,
            state: .delivered)
    }
}

private actor ScriptedChatService: ChatService {
    enum MessagesPlan: Sendable {
        case immediate([MessageItem])
        case suspended(String)
    }

    enum ChatListPlan: Sendable {
        case immediate([ChatItem])
        case suspended(String)
    }

    nonisolated let events: AsyncStream<(UInt32, ServiceEvent)> = AsyncStream { $0.finish() }

    private var accountItems = [
        AccountInfo(
            id: 1, addr: "one@example.org", displayName: "One",
            isConfigured: true, avatar: nil),
    ]
    private var selected: UInt32? = 1
    private var chatsByAccount: [UInt32: [ChatItem]] = [1: [testChat()]]
    private var archivedByAccount: [UInt32: [ChatItem]] = [
        1: [testChat(name: "Archived", id: 20)],
    ]
    private var currentMessages: [MessageItem] = []
    private var messagesPlans: [MessagesPlan] = []
    private var chatListPlans: [ChatListPlan] = []
    private var messagesWaiters: [String: CheckedContinuation<[MessageItem], any Error>] = [:]
    private var chatListWaiters: [String: CheckedContinuation<[ChatItem], any Error>] = [:]
    private var selectAccountPlans: [String] = []
    private var selectAccountWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    private var sendMessagePlans: [String] = []
    private var sendMessageWaiters: [String: CheckedContinuation<UInt32, any Error>] = [:]
    private var sendMessageCalls = 0
    private var blockChatPlans: [String] = []
    private var blockChatWaiters: [String: CheckedContinuation<Void, any Error>] = [:]
    private var searchCalls = 0
    private var searchPlans: [ChatListPlan] = []
    private var searchWaiters: [String: CheckedContinuation<[ChatItem], any Error>] = [:]

    func setMessages(_ messages: [MessageItem]) { currentMessages = messages }
    func setChat(_ chat: ChatItem, accountId: UInt32) {
        chatsByAccount[accountId] = [chat]
    }
    func enqueueMessages(_ plan: MessagesPlan) { messagesPlans.append(plan) }
    func enqueueChatList(_ plan: ChatListPlan) { chatListPlans.append(plan) }
    func enqueueSelectAccount(_ label: String) { selectAccountPlans.append(label) }
    func enqueueSendMessage(_ label: String) { sendMessagePlans.append(label) }
    func enqueueBlockChat(_ label: String) { blockChatPlans.append(label) }
    func sendMessageCallCount() -> Int { sendMessageCalls }
    func searchCallCount() -> Int { searchCalls }
    func enqueueSearch(_ plan: ChatListPlan) { searchPlans.append(plan) }

    func addSwitchingAccounts() {
        accountItems.append(AccountInfo(
            id: 2, addr: "two@example.org", displayName: "Two",
            isConfigured: true, avatar: nil))
        accountItems.append(AccountInfo(
            id: 3, addr: "three@example.org", displayName: "Three",
            isConfigured: true, avatar: nil))
        chatsByAccount[2] = [testChat(name: "Two")]
        chatsByAccount[3] = [testChat(name: "Three")]
    }

    func waitUntilMessagesSuspended(_ label: String) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while messagesWaiters[label] == nil {
            guard ContinuousClock.now < deadline else { throw GateError.timedOut(label) }
            await Task.yield()
        }
    }

    func waitUntilChatListSuspended(_ label: String) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while chatListWaiters[label] == nil {
            guard ContinuousClock.now < deadline else { throw GateError.timedOut(label) }
            await Task.yield()
        }
    }

    func waitUntilSelectAccountSuspended(_ label: String) async throws {
        try await waitFor(label) { selectAccountWaiters[$0] != nil }
    }

    func waitUntilSendMessageSuspended(_ label: String) async throws {
        try await waitFor(label) { sendMessageWaiters[$0] != nil }
    }

    func waitUntilBlockChatSuspended(_ label: String) async throws {
        try await waitFor(label) { blockChatWaiters[$0] != nil }
    }

    func waitUntilSearchSuspended(_ label: String) async throws {
        try await waitFor(label) { searchWaiters[$0] != nil }
    }

    func resumeMessages(_ label: String, with messages: [MessageItem]) {
        messagesWaiters.removeValue(forKey: label)?.resume(returning: messages)
    }

    func failMessages(_ label: String) {
        messagesWaiters.removeValue(forKey: label)?.resume(
            throwing: ServiceError.core(msg: "scripted failure"))
    }

    func resumeChatList(_ label: String, with chats: [ChatItem]) {
        chatListWaiters.removeValue(forKey: label)?.resume(returning: chats)
    }

    func resumeSelectAccount(_ label: String) {
        selectAccountWaiters.removeValue(forKey: label)?.resume(returning: ())
    }

    func failSelectAccount(_ label: String) {
        selectAccountWaiters.removeValue(forKey: label)?.resume(
            throwing: ServiceError.core(msg: "scripted selection failure"))
    }

    func resumeSendMessage(_ label: String, result: UInt32) {
        sendMessageWaiters.removeValue(forKey: label)?.resume(returning: result)
    }

    func failSendMessage(_ label: String) {
        sendMessageWaiters.removeValue(forKey: label)?.resume(
            throwing: ServiceError.core(msg: "scripted failure"))
    }

    func resumeBlockChat(_ label: String) {
        blockChatWaiters.removeValue(forKey: label)?.resume(returning: ())
    }

    func resumeSearch(_ label: String, with chats: [ChatItem]) {
        searchWaiters.removeValue(forKey: label)?.resume(returning: chats)
    }

    func accounts() -> [AccountInfo] { accountItems }
    func selectedAccount() -> UInt32? { selected }

    func addAccount() -> UInt32 {
        let id = UInt32(accountItems.count + 1)
        accountItems.append(AccountInfo(
            id: id, addr: nil, displayName: nil,
            isConfigured: false, avatar: nil))
        chatsByAccount[id] = []
        return id
    }

    func addDemoAccount() -> UInt32 {
        let id: UInt32 = 2
        if !accountItems.contains(where: { $0.id == id }) {
            accountItems.append(AccountInfo(
                id: id, addr: "two@example.org", displayName: "Two",
                isConfigured: true, avatar: nil))
        }
        selected = id
        chatsByAccount[id] = [testChat(name: "Other account")]
        return id
    }

    func removeAccount(id: UInt32) { accountItems.removeAll { $0.id == id } }
    func selectAccount(id: UInt32) async throws {
        if !selectAccountPlans.isEmpty {
            let label = selectAccountPlans.removeFirst()
            try await withCheckedThrowingContinuation {
                selectAccountWaiters[label] = $0
            }
        }
        selected = id
    }
    func startIo() {}
    func stopIo() {}

    func chatList(accountId: UInt32) async throws -> [ChatItem] {
        guard !chatListPlans.isEmpty else { return chatsByAccount[accountId] ?? [] }
        switch chatListPlans.removeFirst() {
        case .immediate(let chats): return chats
        case .suspended(let label):
            return try await withCheckedThrowingContinuation {
                chatListWaiters[label] = $0
            }
        }
    }

    func archivedChats(accountId: UInt32) -> [ChatItem] {
        archivedByAccount[accountId] ?? []
    }

    func messages(
        accountId: UInt32, chatId: UInt32, limit: UInt32, beforeMsgId: UInt32?
    ) async throws -> [MessageItem] {
        guard !messagesPlans.isEmpty else { return currentMessages }
        switch messagesPlans.removeFirst() {
        case .immediate(let messages): return messages
        case .suspended(let label):
            return try await withCheckedThrowingContinuation {
                messagesWaiters[label] = $0
            }
        }
    }

    func login(accountId: UInt32, addr: String, password: String) throws { throw unused() }
    func chatById(accountId: UInt32, chatId: UInt32) -> ChatItem? {
        chatsByAccount[accountId]?.first { $0.id == chatId }
    }
    func sendText(accountId: UInt32, chatId: UInt32, text: String) throws -> UInt32 { throw unused() }
    func markNoticed(accountId: UInt32, chatId: UInt32) {}
    func createChat(accountId: UInt32, email: String, name: String) throws -> UInt32 { throw unused() }
    func checkQr(accountId: UInt32, qr: String) throws -> QrKind { throw unused() }
    func createInstantAccount(accountId: UInt32, displayName: String, instance: String?) throws { throw unused() }
    func joinSecondDevice(accountId: UInt32, qr: String) throws { throw unused() }
    func cancelOngoing(accountId: UInt32) {}
    func maybeNetwork() {}
    func sendMessage(
        accountId: UInt32, chatId: UInt32, text: String?, filePath: String?, quotedMsgId: UInt32?
    ) async throws -> UInt32 {
        sendMessageCalls += 1
        guard !sendMessagePlans.isEmpty else { throw unused() }
        let label = sendMessagePlans.removeFirst()
        return try await withCheckedThrowingContinuation {
            sendMessageWaiters[label] = $0
        }
    }
    func sendReaction(accountId: UInt32, msgId: UInt32, emoji: String) throws { throw unused() }
    func deleteMessages(accountId: UInt32, msgIds: [UInt32]) throws { throw unused() }
    func forwardMessages(accountId: UInt32, msgIds: [UInt32], chatId: UInt32) throws { throw unused() }
    func markSeen(accountId: UInt32, msgIds: [UInt32]) {}
    func acceptChat(accountId: UInt32, chatId: UInt32) throws { throw unused() }
    func blockChat(accountId: UInt32, chatId: UInt32) async throws {
        guard !blockChatPlans.isEmpty else { throw unused() }
        let label = blockChatPlans.removeFirst()
        try await withCheckedThrowingContinuation {
            blockChatWaiters[label] = $0
        }
    }
    func setChatArchived(accountId: UInt32, chatId: UInt32, archived: Bool) throws { throw unused() }
    func setChatMuted(accountId: UInt32, chatId: UInt32, durationSeconds: Int64) throws { throw unused() }
    func searchChats(accountId: UInt32, query: String) async throws -> [ChatItem] {
        searchCalls += 1
        guard !searchPlans.isEmpty else { return [] }
        switch searchPlans.removeFirst() {
        case .immediate(let chats): return chats
        case .suspended(let label):
            return try await withCheckedThrowingContinuation {
                searchWaiters[label] = $0
            }
        }
    }
    func searchMessages(accountId: UInt32, query: String) -> [MessageItem] { [] }
    func contacts(accountId: UInt32) -> [ContactItem] { [] }
    func createGroup(accountId: UInt32, name: String, memberContactIds: [UInt32]) throws -> UInt32 { throw unused() }
    func setDisplayName(accountId: UInt32, name: String) throws { throw unused() }
    func setAvatar(accountId: UInt32, path: String?) throws { throw unused() }
    func connectivity(accountId: UInt32) -> UInt32 { 0 }

    private func unused() -> ServiceError { .core(msg: "unused test operation") }

    private func waitFor(
        _ label: String, predicate: (String) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(label) {
            guard ContinuousClock.now < deadline else { throw GateError.timedOut(label) }
            await Task.yield()
        }
    }
}

private enum GateError: Error {
    case timedOut(String)
}
