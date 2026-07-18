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

    func setMessages(_ messages: [MessageItem]) { currentMessages = messages }
    func enqueueMessages(_ plan: MessagesPlan) { messagesPlans.append(plan) }
    func enqueueChatList(_ plan: ChatListPlan) { chatListPlans.append(plan) }

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
    func selectAccount(id: UInt32) { selected = id }
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
    ) throws -> UInt32 { throw unused() }
    func sendReaction(accountId: UInt32, msgId: UInt32, emoji: String) throws { throw unused() }
    func deleteMessages(accountId: UInt32, msgIds: [UInt32]) throws { throw unused() }
    func forwardMessages(accountId: UInt32, msgIds: [UInt32], chatId: UInt32) throws { throw unused() }
    func markSeen(accountId: UInt32, msgIds: [UInt32]) {}
    func acceptChat(accountId: UInt32, chatId: UInt32) throws { throw unused() }
    func blockChat(accountId: UInt32, chatId: UInt32) throws { throw unused() }
    func setChatArchived(accountId: UInt32, chatId: UInt32, archived: Bool) throws { throw unused() }
    func setChatMuted(accountId: UInt32, chatId: UInt32, durationSeconds: Int64) throws { throw unused() }
    func searchChats(accountId: UInt32, query: String) -> [ChatItem] { [] }
    func searchMessages(accountId: UInt32, query: String) -> [MessageItem] { [] }
    func contacts(accountId: UInt32) -> [ContactItem] { [] }
    func createGroup(accountId: UInt32, name: String, memberContactIds: [UInt32]) throws -> UInt32 { throw unused() }
    func setDisplayName(accountId: UInt32, name: String) throws { throw unused() }
    func setAvatar(accountId: UInt32, path: String?) throws { throw unused() }
    func connectivity(accountId: UInt32) -> UInt32 { 0 }

    private func unused() -> ServiceError { .core(msg: "unused test operation") }
}

private enum GateError: Error {
    case timedOut(String)
}
