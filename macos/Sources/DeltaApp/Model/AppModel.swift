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

    // Login / onboarding state.
    var loginEmail = ""
    var loginPassword = ""
    private(set) var isConfiguring = false
    /// 0...1, driven by ConfigureProgress events.
    private(set) var configureProgress: Double = 0
    private(set) var configureComment: String?
    var loginError: String?

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
        // Dev/smoke-test hook: jump straight into the demo account.
        if screen == .onboarding,
           ProcessInfo.processInfo.environment["DCNATIVE_AUTODEMO"] == "1" {
            await tryDemo()
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

    func logIn() async {
        loginError = nil
        configureProgress = 0
        configureComment = nil
        isConfiguring = true
        defer { isConfiguring = false }
        do {
            let addr = loginEmail.trimmingCharacters(in: .whitespaces)
            let accountId: UInt32
            if let unconfigured = accounts.first(where: { !$0.isConfigured }) {
                accountId = unconfigured.id
            } else {
                accountId = try await service.addAccount()
            }
            try await service.login(accountId: accountId, addr: addr, password: loginPassword)
            try await service.selectAccount(id: accountId)
            selectedAccountId = accountId
            try await service.startIo()
            accounts = try await service.accounts()
            loginPassword = ""
            await reloadChats()
            screen = .main
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

    // MARK: Main-screen actions

    func reloadChats() async {
        guard let accountId = selectedAccountId else { return }
        do {
            chats = try await service.chatList(accountId: accountId)
            if let selected = selectedChatId, !chats.contains(where: { $0.id == selected }) {
                selectedChatId = nil
                messages = []
            }
        } catch {
            // Keep the last known list; a follow-up event will retry.
        }
    }

    func reloadMessages() async {
        guard let accountId = selectedAccountId, let chatId = selectedChatId else {
            messages = []
            return
        }
        do {
            messages = try await service.messages(accountId: accountId, chatId: chatId)
        } catch {
            messages = []
        }
    }

    /// Called when the sidebar selection changes.
    func chatSelectionChanged() async {
        await reloadMessages()
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
            _ = try await service.sendText(accountId: accountId, chatId: chatId, text: trimmed)
        } catch {
            loginError = error.localizedDescription
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

        case .accountsChanged:
            accounts = (try? await service.accounts()) ?? accounts

        case .chatlistChanged:
            if screen == .main, accountId == selectedAccountId {
                await reloadChats()
            }

        case .chatChanged(let chatId):
            if accountId == selectedAccountId, chatId == selectedChatId {
                await reloadMessages()
            }

        case .incomingMessage(let chatId, _):
            if accountId == selectedAccountId, chatId == selectedChatId {
                await reloadMessages()
                await markSelectedChatNoticed()
            }

        case .connectivityChanged:
            break
        }
    }
}
