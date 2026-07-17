import AppKit
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

    func removeAccount(id: UInt32) throws {
        guard let account = accountsById.removeValue(forKey: id) else {
            throw ServiceError.core(msg: "no such account: \(id)")
        }
        _ = account
        for chat in chatsByAccount.removeValue(forKey: id) ?? [] {
            messagesByChat.removeValue(forKey: chat.id)
            echoChats.remove(chat.id)
        }
        if selected == id {
            selected = accountsById.keys.sorted().first
        }
        emit(0, .accountsChanged)
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

    func chatById(accountId: UInt32, chatId: UInt32) -> ChatItem? {
        chatsByAccount[accountId]?.first { $0.id == chatId }
    }

    func chatList(accountId: UInt32) throws -> [ChatItem] {
        guard let chats = chatsByAccount[accountId] else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        return chats.filter { !$0.isArchived }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    func messages(
        accountId: UInt32, chatId: UInt32, limit: UInt32, beforeMsgId: UInt32?
    ) throws -> [MessageItem] {
        guard chatsByAccount[accountId]?.contains(where: { $0.id == chatId }) == true else {
            throw ServiceError.core(msg: "no such chat: \(chatId)")
        }
        var all = messagesByChat[chatId] ?? []
        if let beforeMsgId {
            guard let pos = all.firstIndex(where: { $0.id == beforeMsgId }) else {
                return [] // anchor gone: match dcvm, never the newest page
            }
            all = Array(all[..<pos])
        }
        if limit > 0 && all.count > Int(limit) {
            all = Array(all.suffix(Int(limit)))
        }
        return all
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

    func maybeNetwork() {}

    // MARK: Messages (media, reactions, management)

    func sendMessage(
        accountId: UInt32, chatId: UInt32,
        text: String?, filePath: String?, quotedMsgId: UInt32?
    ) async throws -> UInt32 {
        var quote: QuoteInfo?
        if let quotedMsgId,
           let quoted = messagesByChat[chatId]?.first(where: { $0.id == quotedMsgId }) {
            quote = QuoteInfo(
                text: quoted.text, senderName: quoted.senderName,
                senderColor: quoted.senderColor)
        }
        let msgId = try sendText(accountId: accountId, chatId: chatId, text: text ?? "")
        if var messages = messagesByChat[chatId],
           let index = messages.firstIndex(where: { $0.id == msgId }) {
            messages[index].quote = quote
            if let filePath {
                let url = URL(fileURLWithPath: filePath)
                messages[index].file = filePath
                messages[index].fileName = url.lastPathComponent
                messages[index].fileSize = 1234
                messages[index].kind = ["png", "jpg", "jpeg", "webp"]
                    .contains(url.pathExtension.lowercased()) ? .image : .file
            }
            messagesByChat[chatId] = messages
        }
        emit(accountId, .chatChanged(chatId: chatId))
        return msgId
    }

    func sendReaction(accountId: UInt32, msgId: UInt32, emoji: String) {
        for (chatId, var messages) in messagesByChat {
            guard let index = messages.firstIndex(where: { $0.id == msgId }) else { continue }
            var reactions = messages[index].reactions.filter { !$0.isFromSelf || $0.count > 1 }
            // Drop the own share of any previous reaction.
            reactions = messages[index].reactions.compactMap { r in
                guard r.isFromSelf else { return r }
                return r.count > 1
                    ? ReactionItem(emoji: r.emoji, count: r.count - 1, isFromSelf: false) : nil
            }
            if !emoji.isEmpty {
                if let i = reactions.firstIndex(where: { $0.emoji == emoji }) {
                    reactions[i].count += 1
                    reactions[i].isFromSelf = true
                } else {
                    reactions.append(ReactionItem(emoji: emoji, count: 1, isFromSelf: true))
                }
            }
            messages[index].reactions = reactions
            messagesByChat[chatId] = messages
            emit(accountId, .chatChanged(chatId: chatId))
            return
        }
    }

    func deleteMessages(accountId: UInt32, msgIds: [UInt32]) {
        for (chatId, messages) in messagesByChat {
            let remaining = messages.filter { !msgIds.contains($0.id) }
            guard remaining.count != messages.count else { continue }
            messagesByChat[chatId] = remaining
            emit(accountId, .chatChanged(chatId: chatId))
        }
    }

    func forwardMessages(accountId: UInt32, msgIds: [UInt32], chatId: UInt32) throws {
        let all = messagesByChat.values.flatMap { $0 }
        for msgId in msgIds {
            guard let original = all.first(where: { $0.id == msgId }) else { continue }
            _ = try sendText(accountId: accountId, chatId: chatId, text: original.text)
        }
    }

    func markSeen(accountId: UInt32, msgIds: [UInt32]) {
        for (chatId, _) in messagesByChat where messagesByChat[chatId]!.contains(where: { msgIds.contains($0.id) }) {
            markNoticed(accountId: accountId, chatId: chatId)
        }
    }

    // MARK: Chat management

    func acceptChat(accountId: UInt32, chatId: UInt32) {
        mutateChat(accountId: accountId, chatId: chatId) { $0.isContactRequest = false }
    }

    func blockChat(accountId: UInt32, chatId: UInt32) {
        chatsByAccount[accountId]?.removeAll { $0.id == chatId }
        messagesByChat.removeValue(forKey: chatId)
        emit(accountId, .chatlistChanged)
    }

    func setChatArchived(accountId: UInt32, chatId: UInt32, archived: Bool) {
        mutateChat(accountId: accountId, chatId: chatId) { $0.isArchived = archived }
    }

    func setChatMuted(accountId: UInt32, chatId: UInt32, durationSeconds: Int64) {
        mutateChat(accountId: accountId, chatId: chatId) { $0.isMuted = durationSeconds != 0 }
    }

    func archivedChats(accountId: UInt32) throws -> [ChatItem] {
        try chatListAll(accountId: accountId).filter(\.isArchived)
    }

    func searchChats(accountId: UInt32, query: String) throws -> [ChatItem] {
        try chatListAll(accountId: accountId).filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    func searchMessages(accountId: UInt32, query: String) -> [MessageItem] {
        messagesByChat.values.flatMap { $0 }
            .filter { $0.text.localizedCaseInsensitiveContains(query) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func contacts(accountId: UInt32) -> [ContactItem] {
        [
            ContactItem(id: 1, displayName: "Alice", addr: "alice@example.com",
                        color: "#e56555", avatar: nil, isVerified: true),
            ContactItem(id: 2, displayName: "Bob", addr: "bob@example.com",
                        color: "#3d7bde", avatar: nil, isVerified: false),
            ContactItem(id: 3, displayName: "Carol", addr: "carol@example.com",
                        color: "#9b59b6", avatar: nil, isVerified: true),
        ]
    }

    func createGroup(accountId: UInt32, name: String, memberContactIds: [UInt32]) throws -> UInt32 {
        let id = nextChatId
        nextChatId += 1
        chatsByAccount[accountId, default: []].append(ChatItem(
            id: id, name: name, preview: "", timestamp: Int64(Date().timeIntervalSince1970),
            freshCount: 0, isSelfTalk: false, isPinned: false, isMuted: false,
            isContactRequest: false, color: Self.palette[Int(id) % Self.palette.count],
            isGroup: true))
        messagesByChat[id] = []
        emit(accountId, .chatlistChanged)
        return id
    }

    // MARK: Profile / status

    func setDisplayName(accountId: UInt32, name: String) {
        accountsById[accountId]?.displayName = name.isEmpty ? nil : name
        emit(0, .accountsChanged)
    }

    func setAvatar(accountId: UInt32, path: String?) {
        accountsById[accountId]?.avatar = path
        emit(0, .accountsChanged)
    }

    func connectivity(accountId: UInt32) -> UInt32 { 4000 }

    private func mutateChat(
        accountId: UInt32, chatId: UInt32, _ change: (inout ChatItem) -> Void
    ) {
        guard var chats = chatsByAccount[accountId],
              let index = chats.firstIndex(where: { $0.id == chatId })
        else { return }
        change(&chats[index])
        chatsByAccount[accountId] = chats
        emit(accountId, .chatlistChanged)
        emit(accountId, .chatChanged(chatId: chatId))
    }

    private func chatListAll(accountId: UInt32) throws -> [ChatItem] {
        guard let chats = chatsByAccount[accountId] else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        return chats
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
        // The chat may have been blocked/removed while we slept; the
        // dictionary default would silently resurrect it.
        guard chatsByAccount[accountId]?.contains(where: { $0.id == chatId }) == true else {
            return
        }
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

        // Media/quote/reaction samples in the Alice chat.
        if let last = messagesByChat[aliceChat]?.last {
            let id = nextMsgId
            nextMsgId += 1
            messagesByChat[aliceChat]?.append(MessageItem(
                id: id, chatId: aliceChat, text: "This! 💯",
                timestamp: now - 2 * 60,
                isOutgoing: true, isInfo: false,
                senderName: "Me", senderColor: Self.selfColor, state: .read,
                quote: QuoteInfo(
                    text: last.text, senderName: last.senderName,
                    senderColor: last.senderColor),
                reactions: [
                    ReactionItem(emoji: "👍", count: 2, isFromSelf: false),
                    ReactionItem(emoji: "🎉", count: 1, isFromSelf: true),
                ]))
        }
        if let imagePath = Self.sampleFile(name: "mock-photo.png", png: true) {
            let id = nextMsgId
            nextMsgId += 1
            messagesByChat[aliceChat]?.append(MessageItem(
                id: id, chatId: aliceChat, text: "sunset from the pier",
                timestamp: now - 60,
                isOutgoing: false, isInfo: false,
                senderName: alice.name, senderColor: alice.color, state: .noState,
                kind: .image, file: imagePath, fileName: "photo.png",
                fileSize: 4096, width: 64, height: 64))
        }
        if let filePath = Self.sampleFile(name: "notes.txt", png: false) {
            let id = nextMsgId
            nextMsgId += 1
            messagesByChat[aliceChat]?.append(MessageItem(
                id: id, chatId: aliceChat, text: "",
                timestamp: now - 30,
                isOutgoing: false, isInfo: false,
                senderName: alice.name, senderColor: alice.color, state: .noState,
                kind: .file, file: filePath, fileName: "notes.txt", fileSize: 280))
        }

        // Old thread from last year for timestamp-bucket coverage.
        let dave = (name: "Dave", color: "#2aa198")
        let daveChat = makeChat(name: dave.name, color: dave.color)
        echoChats.insert(daveChat)
        addMessage(daveChat, "Happy new year!", minutesAgo: 220 * day, sender: dave)
        addMessage(daveChat, "Happy new year to you too!", minutesAgo: 220 * day - 15, outgoing: true, state: .read)

        chatsByAccount[accountId] = chats
    }

    /// Writes a small sample blob (solid-color PNG or text) to the temp dir.
    private static func sampleFile(name: String, png: Bool) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcnative-mock-\(name)")
        if !FileManager.default.fileExists(atPath: url.path) {
            if png {
                let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                    NSColor.systemOrange.setFill()
                    rect.fill()
                    return true
                }
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:])
                else { return nil }
                try? data.write(to: url)
            } else {
                try? Data("mock file contents\n".utf8).write(to: url)
            }
        }
        return url.path
    }
}
