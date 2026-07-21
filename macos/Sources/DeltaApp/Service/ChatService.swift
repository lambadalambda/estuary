import Foundation

// MARK: - Value types mirroring the fixed FFI contract 1:1
//
// These deliberately have the exact same shape (names camelCased the way
// UniFFI generates them) as the Rust records/enums exported by dcvm, so the
// later CoreChatService adapter over the generated DeltaCore bindings is a
// trivial field-by-field mapping.

/// Mirrors Rust `AccountInfo`.
struct AccountInfo: Identifiable, Equatable, Sendable {
    var id: UInt32
    var addr: String?
    var displayName: String?
    var isConfigured: Bool
    /// Self-avatar image path, if set.
    var avatar: String?
}

/// Mirrors Rust `ChatItem`.
struct ChatItem: Identifiable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var preview: String
    /// Epoch seconds; 0 if none.
    var timestamp: Int64
    var freshCount: UInt32
    var isSelfTalk: Bool
    var isPinned: Bool
    var isMuted: Bool
    var isContactRequest: Bool
    /// "#rrggbb"
    var color: String
    var isGroup: Bool = false
    var isArchived: Bool = false
    var isDeviceTalk: Bool = false
    /// Chat profile image path, if any.
    var avatar: String?
}

/// Mirrors Rust `ContactItem`.
struct ContactItem: Identifiable, Equatable, Sendable {
    var id: UInt32
    var displayName: String
    var addr: String
    var color: String
    var avatar: String?
    var isVerified: Bool
}

/// Mirrors Rust `MessageKind` (core Viewtype).
enum MessageKind: Equatable, Sendable {
    case text, image, gif, sticker, audio, voice, video, webxdc, file, vcard, unknown
}

/// Mirrors Rust `QuoteInfo`.
struct QuoteInfo: Equatable, Sendable {
    var text: String
    var senderName: String
    var senderColor: String
}

/// Mirrors Rust `ReactionItem`.
struct ReactionItem: Equatable, Sendable {
    var emoji: String
    var count: UInt32
    var isFromSelf: Bool
    /// Up to three reactor identities for the avatar pill; `count` keeps
    /// the full number (the pill falls back to it past the cap).
    var reactors: [ReactionContact] = []
}

/// Mirrors Rust `ReactionContact`.
struct ReactionContact: Equatable, Sendable {
    var name: String
    var color: String
    var avatarPath: String?
}

/// Mirrors Rust `MessageItem`.
struct MessageItem: Identifiable, Equatable, Sendable {
    var id: UInt32
    var chatId: UInt32
    var text: String
    /// Epoch seconds.
    var timestamp: Int64
    var isOutgoing: Bool
    var isInfo: Bool
    var senderName: String
    /// "#rrggbb"
    var senderColor: String
    /// Sender profile image path (in-chat avatars in groups).
    var senderAvatar: String?
    var state: MessageState
    var kind: MessageKind = .text
    /// Absolute path into the account's blobdir.
    var file: String?
    var fileName: String?
    /// Bytes; 0 if no file.
    var fileSize: UInt64 = 0
    /// Pixels; 0 if not applicable.
    var width: UInt32 = 0
    var height: UInt32 = 0
    /// Milliseconds; 0 if not applicable.
    var durationMs: UInt32 = 0
    var quote: QuoteInfo?
    var reactions: [ReactionItem] = []
}

/// Mirrors Rust `MessageState`.
enum MessageState: Equatable, Sendable {
    case noState
    case pending
    case delivered
    case read
    case failed
}

/// Mirrors Rust `VmEvent`.
enum ServiceEvent: Equatable, Sendable {
    case accountsChanged
    case fullRefreshRequired
    case chatlistChanged
    case chatChanged(chatId: UInt32)
    case incomingMessage(chatId: UInt32, msgId: UInt32)
    case configureProgress(permille: UInt32, comment: String?)
    /// Backup transfer progress ("add second device"): 0 = error, 1000 = done.
    case imexProgress(permille: UInt32)
    case connectivityChanged
}

/// Mirrors Rust `QrKind`.
enum QrKind: Equatable, Sendable {
    case account(domain: String)
    case backup
    case backupTooNew
    case login(address: String)
    case unsupported
}

/// Mirrors Rust `VmError`.
enum ServiceError: Error, LocalizedError, Equatable, Sendable {
    case core(msg: String)
    case callback(msg: String)

    var errorDescription: String? {
        switch self {
        case .core(let msg): return msg
        case .callback(let msg): return msg
        }
    }
}

// MARK: - Service protocol
//
// Method-for-method mirror of the exported `DcApp` object. The core adapter
// (later stage) implements this by delegating to the generated bindings and
// pumping the `EventListener` foreign-trait callbacks into `events`.

protocol ChatService: Sendable {
    /// Per-account event stream: (accountId, event). accountId 0 = manager-level.
    /// Single-consumer (the app model owns it), like the Rust event pump.
    var events: AsyncStream<(UInt32, ServiceEvent)> { get }

    func accounts() async throws -> [AccountInfo]
    /// Fresh, unmuted messages across all configured accounts.
    func unreadCount() async throws -> UInt32
    func addAccount() async throws -> UInt32
    /// Removes the account and deletes its local data.
    func removeAccount(id: UInt32) async throws
    func selectAccount(id: UInt32) async throws
    func selectedAccount() async -> UInt32?
    /// Progress arrives via `.configureProgress` events (permille 0 = error, 1000 = done).
    func login(accountId: UInt32, addr: String, password: String) async throws
    func startIo() async throws
    func stopIo() async throws
    func chatList(accountId: UInt32) async throws -> [ChatItem]
    /// Fresh single row (nil for unknown/deleted chats) — point lookups for
    /// notifications etc.; never rely on the filtered sidebar list.
    func chatById(accountId: UInt32, chatId: UInt32) async throws -> ChatItem?
    /// Exact message referenced by an event; nil if it was already deleted.
    func messageById(accountId: UInt32, msgId: UInt32) async throws -> MessageItem?
    /// Newest last. `limit == 0` means all; `beforeMsgId` pages into history.
    func messages(
        accountId: UInt32, chatId: UInt32, limit: UInt32, beforeMsgId: UInt32?
    ) async throws -> [MessageItem]
    func sendText(accountId: UInt32, chatId: UInt32, text: String) async throws -> UInt32
    func markNoticed(accountId: UInt32, chatId: UInt32) async throws
    func createChat(accountId: UInt32, email: String, name: String) async throws -> UInt32
    func addDemoAccount() async throws -> UInt32

    /// Classifies a scanned/pasted QR payload (pure parsing, no network).
    func checkQr(accountId: UInt32, qr: String) async throws -> QrKind
    /// Creates + configures an account on a chatmail relay (nil = default
    /// instance). Progress arrives via `.configureProgress` events.
    func createInstantAccount(accountId: UInt32, displayName: String, instance: String?) async throws
    /// Receives a full account from another device's "Add Second Device" QR.
    /// Progress arrives via `.imexProgress` events; account must be fresh.
    func joinSecondDevice(accountId: UInt32, qr: String) async throws
    /// Cancels an ongoing configure/backup transfer.
    func cancelOngoing(accountId: UInt32) async throws
    /// Network may be back (wake from sleep, connectivity change): all
    /// accounts retry/fetch immediately instead of awaiting the next poll.
    func maybeNetwork() async throws

    // MARK: Messages (media, reactions, management)

    /// Sends text and/or a file; `quotedMsgId` makes it a reply.
    func sendMessage(
        accountId: UInt32, chatId: UInt32,
        text: String?, filePath: String?, quotedMsgId: UInt32?
    ) async throws -> UInt32
    /// Empty emoji string clears the own reaction.
    func sendReaction(accountId: UInt32, msgId: UInt32, emoji: String) async throws
    func deleteMessages(accountId: UInt32, msgIds: [UInt32]) async throws
    func forwardMessages(accountId: UInt32, msgIds: [UInt32], chatId: UInt32) async throws
    /// Marks messages seen: drives MDN read receipts + cross-device read sync.
    func markSeen(accountId: UInt32, msgIds: [UInt32]) async throws

    // MARK: Chat management

    func acceptChat(accountId: UInt32, chatId: UInt32) async throws
    func blockChat(accountId: UInt32, chatId: UInt32) async throws
    func setChatArchived(accountId: UInt32, chatId: UInt32, archived: Bool) async throws
    /// 0 = unmute, negative = forever, positive = seconds from now.
    /// Synced to other devices.
    func setChatMuted(accountId: UInt32, chatId: UInt32, durationSeconds: Int64) async throws
    func archivedChats(accountId: UInt32) async throws -> [ChatItem]
    func searchChats(accountId: UInt32, query: String) async throws -> [ChatItem]
    func searchMessages(accountId: UInt32, query: String) async throws -> [MessageItem]
    func contacts(accountId: UInt32) async throws -> [ContactItem]
    func createGroup(accountId: UInt32, name: String, memberContactIds: [UInt32]) async throws -> UInt32

    // MARK: Profile / status

    func setDisplayName(accountId: UInt32, name: String) async throws
    func setAvatar(accountId: UInt32, path: String?) async throws
    /// DC connectivity scale; 4000 = fully connected.
    func connectivity(accountId: UInt32) async throws -> UInt32
}

// MARK: - Factory

enum ServiceFactory {
    /// Returns the service implementation for this launch.
    /// Default: the real core (CoreChatService over the UniFFI bindings).
    /// DCNATIVE_MOCK=1 forces the mock; DCNATIVE_DATA_DIR overrides the
    /// default data dir (~/Library/Application Support/DeltaChatNative).
    static func make() -> any ChatService {
        let env = ProcessInfo.processInfo.environment
        if env["DCNATIVE_MOCK"] == "1" {
            return MockChatService()
        }
        return CoreChatService(dataDir: dataDir(env: env))
    }

    private static func dataDir(env: [String: String]) -> String {
        if let override = env["DCNATIVE_DATA_DIR"], !override.isEmpty {
            return override
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("DeltaChatNative", isDirectory: true).path
    }
}
