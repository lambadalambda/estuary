import Foundation

/// Offline stand-in for the UniFFI-backed core service.
///
/// Behavior intentionally mimics dcvm: login emits ConfigureProgress permille
/// steps, sendText appends a pending message and emits ChatChanged (then walks
/// it to delivered/read), 1:1 chats echo a reply via IncomingMessage.
actor MockChatService: ChatService {
    nonisolated let events: AsyncStream<(UInt32, ServiceEvent)>
    private let eventSink: AsyncStream<(UInt32, ServiceEvent)>.Continuation

    private var accountsById: [UInt32: AccountInfo] = [:]
    private var selected: UInt32?
    private var chatsByAccount: [UInt32: [ChatItem]] = [:]
    private var messagesByChat: [UInt32: [MessageItem]] = [:]
    /// 1:1 chats that auto-reply to outgoing messages.
    private var echoChats: Set<UInt32> = []
    private var nextAccountId: UInt32 = 1
    private var nextChatId: UInt32 = 10
    private var nextMsgId: UInt32 = 1000
    private var ioRunning = false

    private static let selfColor = "#2f9e44"
    private static let palette = [
        "#e56555", "#3d7bde", "#66a350", "#9b59b6",
        "#c98a2b", "#2aa198", "#d33682", "#5f7a8a",
    ]

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: (UInt32, ServiceEvent).self)
        self.events = stream
        self.eventSink = continuation
    }

    private func emit(_ accountId: UInt32, _ event: ServiceEvent) {
        eventSink.yield((accountId, event))
    }

    // MARK: ChatService

    func accounts() -> [AccountInfo] {
        accountsById.values.sorted { $0.id < $1.id }
    }

    func addAccount() -> UInt32 {
        let id = nextAccountId
        nextAccountId += 1
        accountsById[id] = AccountInfo(id: id, addr: nil, displayName: nil, isConfigured: false)
        chatsByAccount[id] = []
        emit(0, .accountsChanged)
        return id
    }

    func selectAccount(id: UInt32) throws {
        guard accountsById[id] != nil else {
            throw ServiceError.core(msg: "no such account: \(id)")
        }
        selected = id
    }

    func selectedAccount() -> UInt32? { selected }

    func login(accountId: UInt32, addr: String, password: String) async throws {
        guard var account = accountsById[accountId] else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        guard addr.contains("@") else {
            emit(accountId, .configureProgress(permille: 0, comment: "Invalid address"))
            throw ServiceError.core(msg: "\"\(addr)\" is not a valid e-mail address")
        }
        guard !password.isEmpty else {
            emit(accountId, .configureProgress(permille: 0, comment: "Bad credentials"))
            throw ServiceError.core(msg: "Cannot log in: password is empty")
        }
        let steps: [(UInt32, String)] = [
            (100, "Resolving provider…"),
            (330, "Connecting to IMAP…"),
            (660, "Connecting to SMTP…"),
            (900, "Finishing configuration…"),
        ]
        for (permille, comment) in steps {
            emit(accountId, .configureProgress(permille: permille, comment: comment))
            try? await Task.sleep(for: .milliseconds(250))
        }
        account.addr = addr
        account.displayName = addr.split(separator: "@").first.map(String.init)
        account.isConfigured = true
        accountsById[accountId] = account
        if chatsByAccount[accountId, default: []].isEmpty {
            seedDemoContent(accountId: accountId)
        }
        emit(accountId, .configureProgress(permille: 1000, comment: nil))
        emit(0, .accountsChanged)
        emit(accountId, .chatlistChanged)
    }

    func startIo() { ioRunning = true }
    func stopIo() { ioRunning = false }

    func chatList(accountId: UInt32) throws -> [ChatItem] {
        guard let chats = chatsByAccount[accountId] else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        return chats.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    func messages(accountId: UInt32, chatId: UInt32) throws -> [MessageItem] {
        guard chatsByAccount[accountId]?.contains(where: { $0.id == chatId }) == true else {
            throw ServiceError.core(msg: "no such chat: \(chatId)")
        }
        return messagesByChat[chatId] ?? []
    }

    func sendText(accountId: UInt32, chatId: UInt32, text: String) throws -> UInt32 {
        guard var chats = chatsByAccount[accountId],
              let index = chats.firstIndex(where: { $0.id == chatId })
        else {
            throw ServiceError.core(msg: "no such chat: \(chatId)")
        }
        let msgId = nextMsgId
        nextMsgId += 1
        let now = Int64(Date().timeIntervalSince1970)
        let message = MessageItem(
            id: msgId, chatId: chatId, text: text, timestamp: now,
            isOutgoing: true, isInfo: false,
            senderName: "Me", senderColor: Self.selfColor, state: .pending)
        messagesByChat[chatId, default: []].append(message)
        chats[index].preview = "Me: \(text)"
        chats[index].timestamp = now
        chatsByAccount[accountId] = chats
        emit(accountId, .chatChanged(chatId: chatId))
        emit(accountId, .chatlistChanged)

        let echo = echoChats.contains(chatId)
        let echoSender = (name: chats[index].name, color: chats[index].color)
        Task {
            await self.simulateDelivery(
                accountId: accountId, chatId: chatId, msgId: msgId,
                echo: echo, echoSender: echoSender, originalText: text)
        }
        return msgId
    }

    func markNoticed(accountId: UInt32, chatId: UInt32) {
        guard var chats = chatsByAccount[accountId],
              let index = chats.firstIndex(where: { $0.id == chatId }),
              chats[index].freshCount > 0
        else { return }
        chats[index].freshCount = 0
        chatsByAccount[accountId] = chats
        emit(accountId, .chatlistChanged)
    }

    func createChat(accountId: UInt32, email: String, name: String) throws -> UInt32 {
        guard chatsByAccount[accountId] != nil else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        let id = nextChatId
        nextChatId += 1
        let chat = ChatItem(
            id: id,
            name: name.isEmpty ? email : name,
            preview: "", timestamp: 0, freshCount: 0,
            isSelfTalk: false, isPinned: false, isMuted: false, isContactRequest: false,
            color: Self.palette[Int(id) % Self.palette.count])
        chatsByAccount[accountId]?.append(chat)
        messagesByChat[id] = []
        echoChats.insert(id)
        emit(accountId, .chatlistChanged)
        return id
    }

    func addDemoAccount() -> UInt32 {
        let id = addAccount()
        accountsById[id] = AccountInfo(
            id: id, addr: "demo@example.org", displayName: "Demo", isConfigured: true)
        seedDemoContent(accountId: id)
        selected = id
        emit(0, .accountsChanged)
        emit(id, .chatlistChanged)
        return id
    }

    func checkQr(accountId: UInt32, qr: String) -> QrKind {
        let payload = qr.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = payload.uppercased()
        if upper.hasPrefix("DCACCOUNT:") {
            let rest = payload.dropFirst("DCACCOUNT:".count)
            let domain = rest
                .replacingOccurrences(of: "https://", with: "")
                .split(separator: "/").first.map(String.init) ?? String(rest)
            return .account(domain: domain)
        }
        if upper.hasPrefix("DCBACKUP9") { return .backupTooNew }
        if upper.hasPrefix("DCBACKUP") { return .backup }
        if upper.hasPrefix("DCLOGIN:") {
            return .login(address: String(payload.dropFirst("DCLOGIN:".count)))
        }
        return .unsupported
    }

    func createInstantAccount(
        accountId: UInt32, displayName: String, instance: String?
    ) async throws {
        guard var account = accountsById[accountId] else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        let steps: [(UInt32, String)] = [
            (150, "Creating account on relay…"),
            (500, "Connecting…"),
            (900, "Finishing configuration…"),
        ]
        for (permille, comment) in steps {
            emit(accountId, .configureProgress(permille: permille, comment: comment))
            try? await Task.sleep(for: .milliseconds(250))
        }
        let domain = (instance ?? "nine.testrun.org")
            .replacingOccurrences(of: "https://", with: "")
            .split(separator: "/").first.map(String.init) ?? "nine.testrun.org"
        account.addr = "mock-\(accountId)@\(domain)"
        account.displayName = displayName.isEmpty ? nil : displayName
        account.isConfigured = true
        accountsById[accountId] = account
        if chatsByAccount[accountId, default: []].isEmpty {
            seedDemoContent(accountId: accountId)
        }
        emit(accountId, .configureProgress(permille: 1000, comment: nil))
        emit(0, .accountsChanged)
        emit(accountId, .chatlistChanged)
    }

    func joinSecondDevice(accountId: UInt32, qr: String) async throws {
        guard var account = accountsById[accountId] else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        guard account.isConfigured == false else {
            throw ServiceError.core(msg: "account is already configured")
        }
        guard case .backup = checkQr(accountId: accountId, qr: qr) else {
            throw ServiceError.core(msg: "this is not an \"Add Second Device\" QR code")
        }
        emit(accountId, .imexProgress(permille: 1))
        for permille: UInt32 in [250, 500, 750] {
            try? await Task.sleep(for: .milliseconds(300))
            emit(accountId, .imexProgress(permille: permille))
        }
        account.addr = "transferred@nine.testrun.org"
        account.displayName = "Transferred"
        account.isConfigured = true
        accountsById[accountId] = account
        if chatsByAccount[accountId, default: []].isEmpty {
            seedDemoContent(accountId: accountId)
        }
        emit(accountId, .imexProgress(permille: 1000))
        emit(0, .accountsChanged)
        emit(accountId, .chatlistChanged)
    }

    func cancelOngoing(accountId: UInt32) {
        emit(accountId, .imexProgress(permille: 0))
    }

    // MARK: Simulation helpers

    private func simulateDelivery(
        accountId: UInt32, chatId: UInt32, msgId: UInt32,
        echo: Bool, echoSender: (name: String, color: String), originalText: String
    ) async {
        try? await Task.sleep(for: .milliseconds(500))
        setMessageState(chatId: chatId, msgId: msgId, state: .delivered)
        emit(accountId, .chatChanged(chatId: chatId))

        try? await Task.sleep(for: .milliseconds(800))
        setMessageState(chatId: chatId, msgId: msgId, state: .read)
        emit(accountId, .chatChanged(chatId: chatId))

        guard echo else { return }
        try? await Task.sleep(for: .milliseconds(700))
        let replyId = nextMsgId
        nextMsgId += 1
        let now = Int64(Date().timeIntervalSince1970)
        let replyText = "Echo: \(originalText)"
        messagesByChat[chatId, default: []].append(MessageItem(
            id: replyId, chatId: chatId, text: replyText, timestamp: now,
            isOutgoing: false, isInfo: false,
            senderName: echoSender.name, senderColor: echoSender.color, state: .noState))
        if var chats = chatsByAccount[accountId],
           let index = chats.firstIndex(where: { $0.id == chatId }) {
            chats[index].preview = replyText
            chats[index].timestamp = now
            chats[index].freshCount += 1
            chatsByAccount[accountId] = chats
        }
        emit(accountId, .incomingMessage(chatId: chatId, msgId: replyId))
        emit(accountId, .chatlistChanged)
    }

    private func setMessageState(chatId: UInt32, msgId: UInt32, state: MessageState) {
        guard var messages = messagesByChat[chatId],
              let index = messages.firstIndex(where: { $0.id == msgId })
        else { return }
        messages[index].state = state
        messagesByChat[chatId] = messages
    }

    // MARK: Seed data

    private func seedDemoContent(accountId: UInt32) {
        let now = Int64(Date().timeIntervalSince1970)
        var chats: [ChatItem] = []

        func makeChat(
            name: String, color: String,
            pinned: Bool = false, muted: Bool = false,
            request: Bool = false, selfTalk: Bool = false, fresh: UInt32 = 0
        ) -> UInt32 {
            let id = nextChatId
            nextChatId += 1
            chats.append(ChatItem(
                id: id, name: name, preview: "", timestamp: 0, freshCount: fresh,
                isSelfTalk: selfTalk, isPinned: pinned, isMuted: muted,
                isContactRequest: request, color: color))
            messagesByChat[id] = []
            return id
        }

        func addMessage(
            _ chatId: UInt32, _ text: String, minutesAgo: Int64,
            outgoing: Bool = false, sender: (name: String, color: String)? = nil,
            info: Bool = false, state: MessageState = .noState
        ) {
            let id = nextMsgId
            nextMsgId += 1
            let timestamp = now - minutesAgo * 60
            let senderName = outgoing ? "Me" : (sender?.name ?? "")
            let senderColor = outgoing ? Self.selfColor : (sender?.color ?? "#999999")
            messagesByChat[chatId, default: []].append(MessageItem(
                id: id, chatId: chatId, text: text, timestamp: timestamp,
                isOutgoing: outgoing, isInfo: info,
                senderName: senderName, senderColor: senderColor, state: state))
            if let index = chats.firstIndex(where: { $0.id == chatId }) {
                chats[index].timestamp = timestamp
                if info {
                    chats[index].preview = text
                } else if outgoing {
                    chats[index].preview = "Me: \(text)"
                } else {
                    chats[index].preview = text
                }
            }
        }

        let day: Int64 = 24 * 60

        // Saved Messages (self talk, pinned).
        let saved = makeChat(name: "Saved Messages", color: "#c98a2b", pinned: true, selfTalk: true)
        addMessage(saved, "Remember: uniffi bindings must be regenerated after every API change.", minutesAgo: day + 120, outgoing: true, state: .delivered)
        addMessage(saved, "Shopping list: coffee, rye bread, batteries", minutesAgo: 200, outgoing: true, state: .delivered)

        // Alice — active 1:1 chat with fresh messages.
        let alice = (name: "Alice", color: "#e56555")
        let aliceChat = makeChat(name: alice.name, color: alice.color, fresh: 3)
        echoChats.insert(aliceChat)
        addMessage(aliceChat, "Hey! Did you see the native prototype?", minutesAgo: 2 * day + 300, sender: alice)
        addMessage(aliceChat, "Yes! SwiftUI shell over a Rust core, wild times.", minutesAgo: 2 * day + 290, outgoing: true, state: .read)
        addMessage(aliceChat, "Ship it :)", minutesAgo: day + 60, sender: alice)
        addMessage(aliceChat, "Working on it. Chat list is already rendering.", minutesAgo: day + 55, outgoing: true, state: .read)
        addMessage(aliceChat, "Nice, send me a build when you can", minutesAgo: 42, sender: alice)
        addMessage(aliceChat, "Also the avatars look great", minutesAgo: 41, sender: alice)
        addMessage(aliceChat, "OK I'll stop spamming now", minutesAgo: 3, sender: alice)

        // Bob — muted, quiet chat.
        let bob = (name: "Bob", color: "#3d7bde")
        let bobChat = makeChat(name: bob.name, color: bob.color, muted: true)
        echoChats.insert(bobChat)
        addMessage(bobChat, "lunch tomorrow?", minutesAgo: 3 * day + 30, sender: bob)
        addMessage(bobChat, "Sure, 12:30 at the usual place.", minutesAgo: 3 * day + 10, outgoing: true, state: .read)

        // Team Chatmail — group with multiple senders and an info message.
        let carol = (name: "Carol", color: "#9b59b6")
        let team = makeChat(name: "Team Chatmail", color: "#66a350")
        addMessage(team, "You added member Carol.", minutesAgo: 5 * day, info: true)
        addMessage(team, "Welcome Carol!", minutesAgo: 5 * day - 5, sender: alice)
        addMessage(team, "Hi everyone, happy to be here", minutesAgo: 5 * day - 10, sender: carol)
        addMessage(team, "Standup moved to 10:00 tomorrow.", minutesAgo: day + 400, sender: bob)
        addMessage(team, "Works for me.", minutesAgo: day + 390, outgoing: true, state: .read)
        addMessage(team, "The 2.49 core builds green on arm64, FYI", minutesAgo: 130, sender: carol)

        // Mallory — contact request.
        let mallory = makeChat(name: "Mallory", color: "#d33682", request: true, fresh: 1)
        addMessage(mallory, "Hi! We met at the conference — is this the right address?", minutesAgo: 310, sender: (name: "Mallory", color: "#d33682"))

        // Old thread from last year for timestamp-bucket coverage.
        let dave = (name: "Dave", color: "#2aa198")
        let daveChat = makeChat(name: dave.name, color: dave.color)
        echoChats.insert(daveChat)
        addMessage(daveChat, "Happy new year!", minutesAgo: 220 * day, sender: dave)
        addMessage(daveChat, "Happy new year to you too!", minutesAgo: 220 * day - 15, outgoing: true, state: .read)

        chatsByAccount[accountId] = chats
    }
}
