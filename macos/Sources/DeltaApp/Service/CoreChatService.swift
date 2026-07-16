import Foundation
import DeltaCore

// MARK: - CoreChatService
//
// ChatService adapter over the UniFFI-generated DeltaCore bindings (DcApp).
// The generated types have the same names as the app's value types, so the
// generated ones are referred to as `DeltaCore.X` throughout this file.
//
// DcApp's constructor is async (it opens the accounts dir and starts the
// event pump) while ServiceFactory.make() is sync, so the DcApp is created
// lazily on first use via a stored Task (safe against concurrent first calls).

actor CoreChatService: ChatService {
    nonisolated let events: AsyncStream<(UInt32, ServiceEvent)>

    private let dataDir: String
    private let listener: CoreEventListener
    private var appTask: Task<DcApp, any Error>?
    /// Generation counter so a failed creation only clears *its own* cached
    /// task (never a newer retry started by another caller).
    private var appTaskGeneration = 0

    init(dataDir: String) {
        self.dataDir = dataDir
        let (stream, continuation) = AsyncStream.makeStream(of: (UInt32, ServiceEvent).self)
        self.events = stream
        self.listener = CoreEventListener(continuation: continuation)
    }

    private func app() async throws -> DcApp {
        let task: Task<DcApp, any Error>
        let generation: Int
        if let appTask {
            task = appTask
            generation = appTaskGeneration
        } else {
            appTaskGeneration += 1
            generation = appTaskGeneration
            task = Task { [dataDir, listener] in
                try await DcApp(dataDir: dataDir, listener: listener)
            }
            appTask = task
        }
        do {
            return try await task.value
        } catch {
            // A transient constructor failure (locked accounts dir, missing
            // data dir, ...) must not poison every future call: drop the
            // failed task so the next call retries.
            if generation == appTaskGeneration {
                appTask = nil
            }
            throw mapError(error)
        }
    }

    // MARK: ChatService

    func accounts() async throws -> [AccountInfo] {
        do { return try await app().accounts().map(mapAccount) }
        catch { throw mapError(error) }
    }

    func addAccount() async throws -> UInt32 {
        do { return try await app().addAccount() }
        catch { throw mapError(error) }
    }

    func removeAccount(id: UInt32) async throws {
        do { try await app().removeAccount(id: id) }
        catch { throw mapError(error) }
    }

    func selectAccount(id: UInt32) async throws {
        do { try await app().selectAccount(id: id) }
        catch { throw mapError(error) }
    }

    func selectedAccount() async -> UInt32? {
        // The contract keeps this non-throwing (mirrors the sync Option-
        // returning Rust method), so at least log instead of hiding the error.
        do {
            return try await app().selectedAccount()
        } catch {
            NSLog("CoreChatService.selectedAccount: DcApp unavailable: %@", "\(error)")
            return nil
        }
    }

    func login(accountId: UInt32, addr: String, password: String) async throws {
        do { try await app().login(accountId: accountId, addr: addr, password: password) }
        catch { throw mapError(error) }
    }

    func startIo() async throws {
        do { try await app().startIo() }
        catch { throw mapError(error) }
    }

    func stopIo() async throws {
        do { try await app().stopIo() }
        catch { throw mapError(error) }
    }

    func chatList(accountId: UInt32) async throws -> [ChatItem] {
        do { return try await app().chatList(accountId: accountId).map(mapChat) }
        catch { throw mapError(error) }
    }

    func messages(accountId: UInt32, chatId: UInt32) async throws -> [MessageItem] {
        do { return try await app().messages(accountId: accountId, chatId: chatId).map(mapMessage) }
        catch { throw mapError(error) }
    }

    func sendText(accountId: UInt32, chatId: UInt32, text: String) async throws -> UInt32 {
        do { return try await app().sendText(accountId: accountId, chatId: chatId, text: text) }
        catch { throw mapError(error) }
    }

    func markNoticed(accountId: UInt32, chatId: UInt32) async throws {
        do { try await app().markNoticed(accountId: accountId, chatId: chatId) }
        catch { throw mapError(error) }
    }

    func createChat(accountId: UInt32, email: String, name: String) async throws -> UInt32 {
        do { return try await app().createChat(accountId: accountId, email: email, name: name) }
        catch { throw mapError(error) }
    }

    func addDemoAccount() async throws -> UInt32 {
        do { return try await app().addDemoAccount() }
        catch { throw mapError(error) }
    }

    func checkQr(accountId: UInt32, qr: String) async throws -> QrKind {
        do { return mapQrKind(try await app().checkQr(accountId: accountId, qr: qr)) }
        catch { throw mapError(error) }
    }

    func createInstantAccount(
        accountId: UInt32, displayName: String, instance: String?
    ) async throws {
        do {
            try await app().createInstantAccount(
                accountId: accountId, displayName: displayName, instance: instance)
        } catch { throw mapError(error) }
    }

    func joinSecondDevice(accountId: UInt32, qr: String) async throws {
        do { try await app().joinSecondDevice(accountId: accountId, qr: qr) }
        catch { throw mapError(error) }
    }

    func cancelOngoing(accountId: UInt32) async throws {
        do { try await app().cancelOngoing(accountId: accountId) }
        catch { throw mapError(error) }
    }

    func maybeNetwork() async throws {
        do { try await app().maybeNetwork() }
        catch { throw mapError(error) }
    }
}

// MARK: - Event listener bridge
//
// Called by Rust on tokio worker threads. Yielding into an AsyncStream is the
// thread hop: the continuation is thread-safe, and the single consumer
// (AppModel's event loop) processes each event on the MainActor. No UI state
// is ever touched on the tokio thread.

private final class CoreEventListener: EventListener, @unchecked Sendable {
    private let continuation: AsyncStream<(UInt32, ServiceEvent)>.Continuation

    init(continuation: AsyncStream<(UInt32, ServiceEvent)>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(accountId: UInt32, event: VmEvent) throws {
        continuation.yield((accountId, mapEvent(event)))
    }
}

// MARK: - Type mapping (generated DeltaCore types -> app value types)

private func mapAccount(_ a: DeltaCore.AccountInfo) -> AccountInfo {
    AccountInfo(id: a.id, addr: a.addr, displayName: a.displayName, isConfigured: a.isConfigured)
}

private func mapChat(_ c: DeltaCore.ChatItem) -> ChatItem {
    ChatItem(
        id: c.id,
        name: c.name,
        preview: c.preview,
        timestamp: c.timestamp,
        freshCount: c.freshCount,
        isSelfTalk: c.isSelfTalk,
        isPinned: c.isPinned,
        isMuted: c.isMuted,
        isContactRequest: c.isContactRequest,
        color: c.color
    )
}

private func mapMessage(_ m: DeltaCore.MessageItem) -> MessageItem {
    MessageItem(
        id: m.id,
        chatId: m.chatId,
        text: m.text,
        timestamp: m.timestamp,
        isOutgoing: m.isOutgoing,
        isInfo: m.isInfo,
        senderName: m.senderName,
        senderColor: m.senderColor,
        state: mapState(m.state)
    )
}

private func mapState(_ s: DeltaCore.MessageState) -> MessageState {
    switch s {
    case .noState: .noState
    case .pending: .pending
    case .delivered: .delivered
    case .read: .read
    case .failed: .failed
    }
}

private func mapEvent(_ e: VmEvent) -> ServiceEvent {
    switch e {
    case .accountsChanged:
        .accountsChanged
    case .chatlistChanged:
        .chatlistChanged
    case .chatChanged(let chatId):
        .chatChanged(chatId: chatId)
    case .incomingMessage(let chatId, let msgId):
        .incomingMessage(chatId: chatId, msgId: msgId)
    case .configureProgress(let permille, let comment):
        .configureProgress(permille: permille, comment: comment)
    case .imexProgress(let permille):
        .imexProgress(permille: permille)
    case .connectivityChanged:
        .connectivityChanged
    }
}

private func mapQrKind(_ k: DeltaCore.QrKind) -> QrKind {
    switch k {
    case .account(let domain): .account(domain: domain)
    case .backup: .backup
    case .backupTooNew: .backupTooNew
    case .login(let address): .login(address: address)
    case .unsupported: .unsupported
    }
}

/// Converts a thrown `VmError` (or anything else) into the app's `ServiceError`.
private func mapError(_ error: any Error) -> ServiceError {
    switch error {
    case let vmError as VmError:
        switch vmError {
        case .Core(let msg): return .core(msg: msg)
        case .Callback(let msg): return .callback(msg: msg)
        }
    case let serviceError as ServiceError:
        return serviceError
    default:
        return .core(msg: error.localizedDescription)
    }
}
