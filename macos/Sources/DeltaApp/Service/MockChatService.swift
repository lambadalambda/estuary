import AppKit
import Foundation

/// Offline stand-in for the UniFFI-backed core service.
///
/// Behavior intentionally mimics dcvm: login emits ConfigureProgress permille
/// steps, sendText appends a pending message and emits ChatChanged (then walks
/// it to delivered/read), 1:1 chats echo a reply via IncomingMessage.
actor MockChatService: ChatService {
    private struct ChatKey: Hashable {
        let accountId: UInt32
        let chatId: UInt32
    }

    private struct MessageKey: Hashable {
        let accountId: UInt32
        let chatId: UInt32
        let msgId: UInt32
    }

    nonisolated let events: AsyncStream<(UInt32, ServiceEvent)>
    private let eventSink: AsyncStream<(UInt32, ServiceEvent)>.Continuation

    private var accountsById: [UInt32: AccountInfo] = [:]
    private var selected: UInt32?
    private var chatsByAccount: [UInt32: [ChatItem]] = [:]
    private var messagesByChat: [ChatKey: [MessageItem]] = [:]
    /// 1:1 chats that auto-reply to outgoing messages.
    private var echoChats: Set<ChatKey> = []
    private var seenMessages: Set<MessageKey> = []
    private var freshMessages: Set<MessageKey> = []
    /// Session transcript cache, mirroring dcvm's (repeat calls instant).
    private var transcripts: [MessageKey: String] = [:]
    private var nextAccountId: UInt32 = 1
    private var nextChatIdByAccount: [UInt32: UInt32] = [:]
    private var nextMsgIdByAccount: [UInt32: UInt32] = [:]
    private var ioRunning = false

    private static let selfColor = "#2f9e44"
    /// Mirrors dcvm's REACTOR_DISPLAY_CAP — keep them in step.
    private static let reactorDisplayCap = 3
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

    func unreadCount() -> UInt32 {
        let configured = Set(accountsById.values.filter(\.isConfigured).map(\.id))
        return chatsByAccount
            .filter { configured.contains($0.key) }
            .values.joined().reduce(0) { count, chat in
            guard !chat.isMuted else { return count }
            let (sum, overflow) = count.addingReportingOverflow(chat.freshCount)
            return overflow ? .max : sum
        }
    }

    func addAccount() -> UInt32 {
        let id = nextAccountId
        nextAccountId += 1
        accountsById[id] = AccountInfo(id: id, addr: nil, displayName: nil, isConfigured: false)
        chatsByAccount[id] = []
        nextChatIdByAccount[id] = 10
        nextMsgIdByAccount[id] = 1000
        emit(0, .accountsChanged)
        return id
    }

    func removeAccount(id: UInt32) throws {
        guard let account = accountsById.removeValue(forKey: id) else {
            throw ServiceError.core(msg: "no such account: \(id)")
        }
        _ = account
        for chat in chatsByAccount.removeValue(forKey: id) ?? [] {
            let key = ChatKey(accountId: id, chatId: chat.id)
            messagesByChat.removeValue(forKey: key)
            echoChats.remove(key)
        }
        seenMessages = seenMessages.filter { $0.accountId != id }
        freshMessages = freshMessages.filter { $0.accountId != id }
        nextChatIdByAccount.removeValue(forKey: id)
        nextMsgIdByAccount.removeValue(forKey: id)
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

    func messageById(accountId: UInt32, msgId: UInt32) -> MessageItem? {
        return messagesByChat
            .filter { $0.key.accountId == accountId }
            .lazy
            .flatMap(\.value)
            .first { $0.id == msgId }
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
        var all = messagesByChat[ChatKey(accountId: accountId, chatId: chatId)] ?? []
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
        let msgId = allocateMessageId(accountId: accountId)
        let now = Int64(Date().timeIntervalSince1970)
        let message = MessageItem(
            id: msgId, chatId: chatId, text: text, timestamp: now,
            isOutgoing: true, isInfo: false,
            senderName: "Me", senderColor: Self.selfColor, state: .pending)
        let key = ChatKey(accountId: accountId, chatId: chatId)
        messagesByChat[key, default: []].append(message)
        chats[index].preview = "Me: \(text)"
        chats[index].timestamp = now
        chatsByAccount[accountId] = chats
        emit(accountId, .chatChanged(chatId: chatId))
        emit(accountId, .chatlistChanged)

        let echo = echoChats.contains(key)
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
        freshMessages = freshMessages.filter {
            !($0.accountId == accountId && $0.chatId == chatId)
        }
        emit(accountId, .chatlistChanged)
    }

    func createChat(accountId: UInt32, email: String, name: String) throws -> UInt32 {
        guard chatsByAccount[accountId] != nil else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        let id = allocateChatId(accountId: accountId)
        let chat = ChatItem(
            id: id,
            name: name.isEmpty ? email : name,
            preview: "", timestamp: 0, freshCount: 0,
            isSelfTalk: false, isPinned: false, isMuted: false, isContactRequest: false,
            color: Self.palette[Int(id) % Self.palette.count])
        chatsByAccount[accountId]?.append(chat)
        let key = ChatKey(accountId: accountId, chatId: id)
        messagesByChat[key] = []
        echoChats.insert(key)
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
        // Securejoin invites: honor the real link's params — `g=` carries
        // a group name (group invite), `n=` the inviter's display name.
        if payload.hasPrefix("https://i.delta.chat/#") || upper.hasPrefix("OPENPGP4FPR:") {
            if let groupName = Self.inviteParam("g", from: payload) {
                return .askVerifyGroup(groupName: groupName)
            }
            return .askVerifyContact(
                name: Self.inviteParam("n", from: payload) ?? "Contact")
        }
        return .unsupported
    }

    /// Mirrors core's invite-link fragment: url-encoded `key=value` params.
    private static func inviteParam(_ key: String, from payload: String) -> String? {
        guard let fragment = payload.split(separator: "#").last else { return nil }
        for param in fragment.split(separator: "&") {
            if param.hasPrefix("\(key)=") {
                let raw = String(param.dropFirst(key.count + 1))
                return raw.removingPercentEncoding ?? raw
            }
        }
        return nil
    }

    private static let ownInvite =
        "https://i.delta.chat/#MOCKFPR&v=3&a=me%40mock.example&n=Me"
    /// Real join_securejoin is idempotent — the same invite always yields
    /// the same chat.
    private var joinedInviteChats: [String: UInt32] = [:]

    func securejoinQr(accountId: UInt32, chatId: UInt32?) throws -> String {
        guard accountsById[accountId] != nil else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        guard let chatId else { return Self.ownInvite }
        guard let chat = chatsByAccount[accountId]?.first(where: { $0.id == chatId })
        else {
            throw ServiceError.core(msg: "no such chat: \(chatId)")
        }
        // Core ensure!'s the chat is a group; a 1:1 id must not yield a
        // bogus link the real service would reject.
        guard chat.isGroup else {
            throw ServiceError.core(
                msg: "Can't generate SecureJoin QR code for chat \(chatId) of type Single")
        }
        let encoded = chat.name.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics) ?? chat.name
        return "https://i.delta.chat/#MOCKGRP\(chatId)&v=3&x=grp\(chatId)&g=\(encoded)"
    }

    func joinSecurejoin(accountId: UInt32, qr: String) throws -> UInt32 {
        // Core classifies one's own invites (contact AND group) as
        // withdraw QRs and join bails "Unsupported QR type" — mirror it.
        guard qr != Self.ownInvite,
            !qr.hasPrefix("https://i.delta.chat/#MOCKGRP")
        else {
            throw ServiceError.core(msg: "Unsupported QR type")
        }
        if let existing = joinedInviteChats[qr] { return existing }
        // Real semantics: the chat exists immediately; the handshake
        // finishes in the background.
        let chatId: UInt32
        switch checkQr(accountId: accountId, qr: qr) {
        case .askVerifyContact(let name):
            chatId = try createChat(
                accountId: accountId,
                email: "\(name.lowercased().replacingOccurrences(of: " ", with: "."))@invite.example",
                name: name)
        case .askVerifyGroup(let groupName):
            chatId = try createGroup(
                accountId: accountId, name: groupName, memberContactIds: [])
        default:
            throw ServiceError.core(msg: "not a securejoin invite")
        }
        joinedInviteChats[qr] = chatId
        return chatId
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
        let key = ChatKey(accountId: accountId, chatId: chatId)
        var quote: QuoteInfo?
        if let quotedMsgId,
           let quoted = messagesByChat[key]?.first(where: { $0.id == quotedMsgId }) {
            quote = QuoteInfo(
                text: quoted.text, senderName: quoted.senderName,
                senderColor: quoted.senderColor)
        }
        let msgId = try sendText(accountId: accountId, chatId: chatId, text: text ?? "")
        if var messages = messagesByChat[key],
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
            messagesByChat[key] = messages
        }
        emit(accountId, .chatChanged(chatId: chatId))
        return msgId
    }

    func sendReaction(accountId: UInt32, msgId: UInt32, emoji: String) {
        for (key, var messages) in messagesByChat where key.accountId == accountId {
            guard let index = messages.firstIndex(where: { $0.id == msgId }) else { continue }
            let selfReactor = ReactionContact(
                name: "Me", color: Self.selfColor, avatarPath: nil)
            // Drop the own share of any previous reaction, incl. the self
            // reactor identity (full-identity match, not name-keyed).
            // Mirrors dcvm's shape — reactors carry up to reactorDisplayCap
            // identities, count keeps the full number — though a capped
            // pill that loses the self share keeps fewer identities than
            // dcvm's from-scratch rebuild would; acceptable for the mock.
            var reactions = messages[index].reactions.compactMap { r -> ReactionItem? in
                guard r.isFromSelf else { return r }
                guard r.count > 1 else { return nil }
                var updated = r
                updated.count -= 1
                updated.isFromSelf = false
                if let i = updated.reactors.firstIndex(of: selfReactor) {
                    updated.reactors.remove(at: i)
                }
                return updated
            }
            if !emoji.isEmpty {
                if let i = reactions.firstIndex(where: { $0.emoji == emoji }) {
                    reactions[i].count += 1
                    reactions[i].isFromSelf = true
                    if reactions[i].reactors.count < Self.reactorDisplayCap {
                        reactions[i].reactors.append(selfReactor)
                    }
                } else {
                    reactions.append(ReactionItem(
                        emoji: emoji, count: 1, isFromSelf: true,
                        reactors: [selfReactor]))
                }
            }
            messages[index].reactions = reactions
            messagesByChat[key] = messages
            emit(accountId, .chatChanged(chatId: key.chatId))
            return
        }
    }

    func deleteMessages(accountId: UInt32, msgIds: [UInt32]) {
        for (key, messages) in messagesByChat where key.accountId == accountId {
            let remaining = messages.filter { !msgIds.contains($0.id) }
            guard remaining.count != messages.count else { continue }
            messagesByChat[key] = remaining
            seenMessages = seenMessages.filter {
                !($0.accountId == accountId && $0.chatId == key.chatId
                    && msgIds.contains($0.msgId))
            }
            freshMessages = freshMessages.filter {
                !($0.accountId == accountId && $0.chatId == key.chatId
                    && msgIds.contains($0.msgId))
            }
            emit(accountId, .chatChanged(chatId: key.chatId))
        }
    }

    func forwardMessages(accountId: UInt32, msgIds: [UInt32], chatId: UInt32) throws {
        let all = messagesByChat
            .filter { $0.key.accountId == accountId }
            .values.flatMap { $0 }
        for msgId in msgIds {
            guard let original = all.first(where: { $0.id == msgId }) else { continue }
            _ = try sendText(accountId: accountId, chatId: chatId, text: original.text)
        }
    }

    /// Mirrors real semantics: audio/voice only, first run "transcribes"
    /// with a visible delay + progress event, repeats are instant (dcvm
    /// caches transcripts for the session).
    func transcribeMessage(accountId: UInt32, msgId: UInt32) async throws -> String {
        let all = messagesByChat
            .filter { $0.key.accountId == accountId }
            .values.flatMap { $0 }
        guard let message = all.first(where: { $0.id == msgId }),
              message.kind == .audio || message.kind == .voice,
              message.file != nil
        else { throw ServiceError.core(msg: "message has no audio file") }

        let key = MessageKey(accountId: accountId, chatId: message.chatId, msgId: msgId)
        if let cached = transcripts[key] { return cached }

        emit(accountId, .transcriptionProgress(
            msgId: msgId, phase: .transcribing, permille: 0))
        try? await Task.sleep(for: .milliseconds(900))
        let text = "This is the mock transcript: a short voice note about "
            + "meeting at the pier at sunset."
        transcripts[key] = text
        // Persisted below the FFI in the real service: future message
        // snapshots carry the transcript, so it survives chat switches.
        let chatKey = ChatKey(accountId: accountId, chatId: message.chatId)
        if let index = messagesByChat[chatKey]?.firstIndex(where: { $0.id == msgId }) {
            messagesByChat[chatKey]?[index].transcript = text
        }
        return text
    }

    func warmTranscription() {
        // No engine in mock mode; the real one preloads an on-disk model.
    }

    func markSeen(accountId: UInt32, msgIds: [UInt32]) {
        for (key, messages) in messagesByChat
        where key.accountId == accountId && messages.contains(where: { msgIds.contains($0.id) }) {
            let newlySeen = messages.filter {
                !$0.isOutgoing && !$0.isInfo && msgIds.contains($0.id)
                    && !seenMessages.contains(MessageKey(
                        accountId: accountId, chatId: key.chatId, msgId: $0.id))
            }
            guard !newlySeen.isEmpty else { continue }
            var newlyFresh = 0
            for message in newlySeen {
                let messageKey = MessageKey(
                    accountId: accountId, chatId: key.chatId, msgId: message.id)
                seenMessages.insert(messageKey)
                if freshMessages.remove(messageKey) != nil { newlyFresh += 1 }
            }
            if var chats = chatsByAccount[accountId],
               let index = chats.firstIndex(where: { $0.id == key.chatId }) {
                let seenCount = UInt32(clamping: newlyFresh)
                chats[index].freshCount = chats[index].freshCount > seenCount
                    ? chats[index].freshCount - seenCount : 0
                chatsByAccount[accountId] = chats
                if newlyFresh > 0 { emit(accountId, .chatlistChanged) }
                emit(accountId, .chatChanged(chatId: key.chatId))
            }
        }
    }

    // MARK: Chat management

    func acceptChat(accountId: UInt32, chatId: UInt32) {
        mutateChat(accountId: accountId, chatId: chatId) { $0.isContactRequest = false }
    }

    func blockChat(accountId: UInt32, chatId: UInt32) {
        chatsByAccount[accountId]?.removeAll { $0.id == chatId }
        let key = ChatKey(accountId: accountId, chatId: chatId)
        messagesByChat.removeValue(forKey: key)
        echoChats.remove(key)
        seenMessages = seenMessages.filter {
            !($0.accountId == accountId && $0.chatId == chatId)
        }
        freshMessages = freshMessages.filter {
            !($0.accountId == accountId && $0.chatId == chatId)
        }
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
        messagesByChat
            .filter { $0.key.accountId == accountId }
            .values.flatMap { $0 }
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
        guard chatsByAccount[accountId] != nil else {
            throw ServiceError.core(msg: "no such account: \(accountId)")
        }
        let id = allocateChatId(accountId: accountId)
        chatsByAccount[accountId, default: []].append(ChatItem(
            id: id, name: name, preview: "", timestamp: Int64(Date().timeIntervalSince1970),
            freshCount: 0, isSelfTalk: false, isPinned: false, isMuted: false,
            isContactRequest: false, color: Self.palette[Int(id) % Self.palette.count],
            isGroup: true))
        messagesByChat[ChatKey(accountId: accountId, chatId: id)] = []
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

    private func allocateChatId(accountId: UInt32) -> UInt32 {
        let id = nextChatIdByAccount[accountId, default: 10]
        nextChatIdByAccount[accountId] = id + 1
        return id
    }

    private func allocateMessageId(accountId: UInt32) -> UInt32 {
        let id = nextMsgIdByAccount[accountId, default: 1000]
        nextMsgIdByAccount[accountId] = id + 1
        return id
    }

    // MARK: Simulation helpers

    private func simulateDelivery(
        accountId: UInt32, chatId: UInt32, msgId: UInt32,
        echo: Bool, echoSender: (name: String, color: String), originalText: String
    ) async {
        try? await Task.sleep(for: .milliseconds(500))
        setMessageState(accountId: accountId, chatId: chatId, msgId: msgId, state: .delivered)
        emit(accountId, .chatChanged(chatId: chatId))

        try? await Task.sleep(for: .milliseconds(800))
        setMessageState(accountId: accountId, chatId: chatId, msgId: msgId, state: .read)
        emit(accountId, .chatChanged(chatId: chatId))

        guard echo else { return }
        try? await Task.sleep(for: .milliseconds(700))
        // The chat may have been blocked/removed while we slept; the
        // dictionary default would silently resurrect it.
        guard chatsByAccount[accountId]?.contains(where: { $0.id == chatId }) == true else {
            return
        }
        let replyId = allocateMessageId(accountId: accountId)
        let now = Int64(Date().timeIntervalSince1970)
        let replyText = "Echo: \(originalText)"
        let key = ChatKey(accountId: accountId, chatId: chatId)
        messagesByChat[key, default: []].append(MessageItem(
            id: replyId, chatId: chatId, text: replyText, timestamp: now,
            isOutgoing: false, isInfo: false,
            senderName: echoSender.name, senderColor: echoSender.color, state: .noState))
        freshMessages.insert(MessageKey(
            accountId: accountId, chatId: chatId, msgId: replyId))
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

    private func setMessageState(
        accountId: UInt32, chatId: UInt32, msgId: UInt32, state: MessageState
    ) {
        let key = ChatKey(accountId: accountId, chatId: chatId)
        guard var messages = messagesByChat[key],
              let index = messages.firstIndex(where: { $0.id == msgId })
        else { return }
        messages[index].state = state
        messagesByChat[key] = messages
    }

    // MARK: Seed data

    private func seedDemoContent(accountId: UInt32) {
        let now = Int64(Date().timeIntervalSince1970)
        var chats: [ChatItem] = []

        func makeChat(
            name: String, color: String,
            pinned: Bool = false, muted: Bool = false,
            request: Bool = false, selfTalk: Bool = false, fresh: UInt32 = 0,
            group: Bool = false
        ) -> UInt32 {
            let id = allocateChatId(accountId: accountId)
            chats.append(ChatItem(
                id: id, name: name, preview: "", timestamp: 0, freshCount: fresh,
                isSelfTalk: selfTalk, isPinned: pinned, isMuted: muted,
                isContactRequest: request, color: color, isGroup: group))
            messagesByChat[ChatKey(accountId: accountId, chatId: id)] = []
            return id
        }

        func addMessage(
            _ chatId: UInt32, _ text: String, minutesAgo: Int64,
            outgoing: Bool = false, sender: (name: String, color: String)? = nil,
            info: Bool = false, state: MessageState = .noState
        ) {
            let id = allocateMessageId(accountId: accountId)
            let timestamp = now - minutesAgo * 60
            let senderName = outgoing ? "Me" : (sender?.name ?? "")
            let senderColor = outgoing ? Self.selfColor : (sender?.color ?? "#999999")
            messagesByChat[ChatKey(accountId: accountId, chatId: chatId), default: []]
                .append(MessageItem(
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

        // Saved Messages (self talk). Deliberately NOT pinned: pinned sorts
        // first, and the screenshot autoselect hook opens chats.first.
        let saved = makeChat(name: "Saved Messages", color: "#c98a2b", selfTalk: true)
        addMessage(saved, "Packing list: tent, headlamp, trail mix", minutesAgo: day + 120, outgoing: true, state: .delivered)
        addMessage(saved, "Cabin door code: 4711", minutesAgo: day + 100, outgoing: true, state: .delivered)

        // Elena — the showcase chat: conversation, quote, reactions, media.
        let elena = (name: "Elena", color: "#e56555")
        let elenaChat = makeChat(name: elena.name, color: elena.color, fresh: 2)
        echoChats.insert(ChatKey(accountId: accountId, chatId: elenaChat))
        addMessage(elenaChat, "Hey! Did you get the photos from the coast trip?", minutesAgo: 2 * day + 300, sender: elena)
        addMessage(elenaChat, "Just did — they look amazing! The lighthouse one is my favorite.", minutesAgo: 2 * day + 290, outgoing: true, state: .read)
        addMessage(elenaChat, "Right? Let's print a few for grandma, she'll love them.", minutesAgo: day + 60, sender: elena)
        addMessage(elenaChat, "Good idea, I'll order prints tomorrow.", minutesAgo: day + 55, outgoing: true, state: .read)
        addMessage(elenaChat, "Don't forget the sunset panorama!", minutesAgo: 42, sender: elena)

        // Marco — muted, quiet chat.
        let marco = (name: "Marco", color: "#3d7bde")
        let marcoChat = makeChat(name: marco.name, color: marco.color, muted: true)
        echoChats.insert(ChatKey(accountId: accountId, chatId: marcoChat))
        addMessage(marcoChat, "Are we still on for football on Saturday?", minutesAgo: 3 * day + 30, sender: marco)
        addMessage(marcoChat, "Yes! 10am at the usual field.", minutesAgo: 3 * day + 10, outgoing: true, state: .read)

        // Weekend Hikers — group with multiple senders and an info message.
        let priya = (name: "Priya", color: "#9b59b6")
        let hikers = makeChat(name: "Weekend Hikers", color: "#66a350", fresh: 1, group: true)
        addMessage(hikers, "You added member Priya.", minutesAgo: 5 * day, info: true)
        addMessage(hikers, "Welcome Priya!", minutesAgo: 5 * day - 5, sender: elena)
        addMessage(hikers, "Hi everyone, happy to be here", minutesAgo: 5 * day - 10, sender: priya)
        addMessage(hikers, "Trail plan for Sunday: meet at the falls parking lot, 9am?", minutesAgo: day + 400, sender: marco)
        // Count-fallback showcase: more reactors than the 3 carried
        // identities → the pill shows the number instead of avatars.
        let hikersKey = ChatKey(accountId: accountId, chatId: hikers)
        if var hikersMessages = messagesByChat[hikersKey],
           let trailPlan = hikersMessages.lastIndex(where: { $0.senderName == marco.name }) {
            hikersMessages[trailPlan].reactions = [
                ReactionItem(
                    emoji: "👍", count: 5, isFromSelf: false,
                    reactors: [
                        ReactionContact(
                            name: elena.name, color: elena.color, avatarPath: nil),
                        ReactionContact(
                            name: priya.name, color: priya.color, avatarPath: nil),
                        ReactionContact(
                            name: marco.name, color: marco.color, avatarPath: nil),
                    ])
            ]
            messagesByChat[hikersKey] = hikersMessages
        }
        addMessage(hikers, "Works for me. Weather forecast looks perfect.", minutesAgo: day + 390, outgoing: true, state: .read)
        addMessage(hikers, "Can someone give me a ride? My car's in the shop.", minutesAgo: 130, sender: priya)

        // Sam — contact request.
        let sam = makeChat(name: "Sam", color: "#d33682", request: true, fresh: 1)
        addMessage(sam, "Hi! We met at the conference — is this the right address?", minutesAgo: 310, sender: (name: "Sam", color: "#d33682"))

        // Media/quote/reaction samples in the Elena chat.
        let elenaKey = ChatKey(accountId: accountId, chatId: elenaChat)
        if let last = messagesByChat[elenaKey]?.last {
            let id = allocateMessageId(accountId: accountId)
            messagesByChat[elenaKey]?.append(MessageItem(
                id: id, chatId: elenaChat, text: "Printing that one poster-sized!",
                timestamp: now - 3 * 60,
                isOutgoing: true, isInfo: false,
                senderName: "Me", senderColor: Self.selfColor, state: .read,
                quote: QuoteInfo(
                    text: last.text, senderName: last.senderName,
                    senderColor: last.senderColor),
                reactions: [
                    ReactionItem(
                        emoji: "❤️", count: 2, isFromSelf: false,
                        reactors: [
                            ReactionContact(
                                name: "Elena", color: "#e56555", avatarPath: nil),
                            ReactionContact(
                                name: "Marco", color: "#3d7bde", avatarPath: nil),
                        ]),
                    ReactionItem(
                        emoji: "🌅", count: 1, isFromSelf: true,
                        reactors: [
                            ReactionContact(
                                name: "Me", color: Self.selfColor, avatarPath: nil)
                        ]),
                ]))
        }
        // Voice note before the photo: the photo stays newest so the
        // sidebar preview keeps meaningful text (voice notes have none).
        if let voicePath = AppResources.bundle.url(
            forResource: "mock-voice", withExtension: "m4a")?.path {
            let id = allocateMessageId(accountId: accountId)
            messagesByChat[elenaKey]?.append(MessageItem(
                id: id, chatId: elenaChat, text: "",
                timestamp: now - 75,
                isOutgoing: false, isInfo: false,
                senderName: elena.name, senderColor: elena.color, state: .noState,
                kind: .voice, file: voicePath, fileName: "voice.m4a",
                fileSize: 5_874, durationMs: 1_200))
        }
        if let imagePath = AppResources.bundle.url(
            forResource: "mock-sunset", withExtension: "jpg")?.path {
            let id = allocateMessageId(accountId: accountId)
            messagesByChat[elenaKey]?.append(MessageItem(
                id: id, chatId: elenaChat, text: "sunset from the pier",
                timestamp: now - 60,
                isOutgoing: false, isInfo: false,
                senderName: elena.name, senderColor: elena.color, state: .noState,
                kind: .image, file: imagePath, fileName: "sunset.jpg",
                fileSize: 638_412, width: 960, height: 720))
        }
        // Manual appends bypass addMessage: sync the sidebar row so the
        // preview/timestamp match the newest message (screenshot-visible).
        if let index = chats.firstIndex(where: { $0.id == elenaChat }),
           let newest = messagesByChat[elenaKey]?.last {
            chats[index].timestamp = newest.timestamp
            chats[index].preview = newest.text
        }

        // Old thread from last year for timestamp-bucket coverage.
        let dave = (name: "Dave", color: "#2aa198")
        let daveChat = makeChat(name: dave.name, color: dave.color)
        echoChats.insert(ChatKey(accountId: accountId, chatId: daveChat))
        addMessage(daveChat, "Happy new year!", minutesAgo: 220 * day, sender: dave)
        addMessage(daveChat, "Happy new year to you too!", minutesAgo: 220 * day - 15, outgoing: true, state: .read)

        chatsByAccount[accountId] = chats
        for chat in chats where chat.freshCount > 0 {
            let key = ChatKey(accountId: accountId, chatId: chat.id)
            let fresh = messagesByChat[key, default: []]
                .filter { !$0.isOutgoing && !$0.isInfo }
                .suffix(Int(chat.freshCount))
            for message in fresh {
                freshMessages.insert(MessageKey(
                    accountId: accountId, chatId: chat.id, msgId: message.id))
            }
        }
    }

}
