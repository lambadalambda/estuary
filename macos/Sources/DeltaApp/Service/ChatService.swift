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
    var state: MessageState
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
    func addAccount() async throws -> UInt32
    func selectAccount(id: UInt32) async throws
    func selectedAccount() async -> UInt32?
    /// Progress arrives via `.configureProgress` events (permille 0 = error, 1000 = done).
    func login(accountId: UInt32, addr: String, password: String) async throws
    func startIo() async throws
    func stopIo() async throws
    func chatList(accountId: UInt32) async throws -> [ChatItem]
    func messages(accountId: UInt32, chatId: UInt32) async throws -> [MessageItem]
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
