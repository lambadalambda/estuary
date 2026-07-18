import Foundation
import Testing
@testable import DeltaApp

// The mock seed doubles as the screenshot showcase (DCNATIVE_MOCK=1 +
// DCNATIVE_AUTOSELECT=1): these pin the properties the captures rely on.

@Suite struct MockShowcaseTests {
    @Test func autoselectOpensTheMediaRichChat() async throws {
        let mock = MockChatService()
        let id = await mock.addDemoAccount()
        let chats = try await mock.chatList(accountId: id)
        let first = try #require(chats.first)
        // AUTOSELECT opens chats.first — it must be a real conversation
        // (not pinned Saved Messages) showcasing media, a quote, and
        // reactions in one screen.
        #expect(!first.isSelfTalk)
        let msgs = try await mock.messages(
            accountId: id, chatId: first.id, limit: 0, beforeMsgId: nil)
        let image = try #require(msgs.first { $0.kind == .image })
        // The photo must be a real, existing file (bundled CC0 sunset) —
        // a dangling path renders an empty bubble in the screenshot.
        #expect(FileManager.default.fileExists(atPath: image.file ?? ""))
        #expect(image.width >= 640)
        #expect(msgs.contains { $0.quote != nil })
        #expect(msgs.contains { !$0.reactions.isEmpty })
        // Sidebar row must reflect the newest message, not a stale preview.
        let newest = try #require(msgs.map(\.timestamp).max())
        #expect(first.timestamp == newest)
    }

    @Test func seedHasGroupWithMultipleSendersAndUnread() async throws {
        let mock = MockChatService()
        let id = await mock.addDemoAccount()
        let chats = try await mock.chatList(accountId: id)
        let group = try #require(chats.first { $0.isGroup })
        let msgs = try await mock.messages(
            accountId: id, chatId: group.id, limit: 0, beforeMsgId: nil)
        let senders = Set(
            msgs.filter { !$0.isOutgoing && !$0.isInfo }.map(\.senderName))
        #expect(senders.count >= 3)
        #expect(chats.contains { $0.freshCount > 0 && !$0.isMuted })
    }

    @Test func accountLocalIdsDoNotCrossMutate() async throws {
        let mock = MockChatService()
        let firstAccount = await mock.addAccount()
        let secondAccount = await mock.addAccount()
        let firstChat = try await mock.createChat(
            accountId: firstAccount, email: "one@example.org", name: "One")
        let secondChat = try await mock.createChat(
            accountId: secondAccount, email: "two@example.org", name: "Two")
        #expect(firstChat == secondChat)

        let firstMessage = try await mock.sendText(
            accountId: firstAccount, chatId: firstChat, text: "first account")
        let secondMessage = try await mock.sendText(
            accountId: secondAccount, chatId: secondChat, text: "second account")
        #expect(firstMessage == secondMessage)

        await mock.deleteMessages(accountId: firstAccount, msgIds: [firstMessage])
        let firstMessages = try await mock.messages(
            accountId: firstAccount, chatId: firstChat, limit: 0, beforeMsgId: nil)
        let secondMessages = try await mock.messages(
            accountId: secondAccount, chatId: secondChat, limit: 0, beforeMsgId: nil)
        #expect(firstMessages.isEmpty)
        #expect(secondMessages.map(\.text) == ["second account"])
        #expect(await mock.searchMessages(accountId: firstAccount, query: "second").isEmpty)
    }

    @Test func markSeenOnlyDecrementsMessagesThatWereFresh() async throws {
        let mock = MockChatService()
        let accountId = await mock.addDemoAccount()
        let chats = try await mock.chatList(accountId: accountId)
        let chat = try #require(chats.first { $0.freshCount >= 2 })
        let messages = try await mock.messages(
            accountId: accountId, chatId: chat.id, limit: 0, beforeMsgId: nil)
        let incoming = messages.filter { !$0.isOutgoing && !$0.isInfo }
        let historical = try #require(incoming.first)
        let newest = try #require(incoming.last)

        await mock.markSeen(accountId: accountId, msgIds: [historical.id])
        #expect(await mock.chatById(accountId: accountId, chatId: chat.id)?.freshCount
            == chat.freshCount)

        await mock.markSeen(accountId: accountId, msgIds: [newest.id])
        #expect(await mock.chatById(accountId: accountId, chatId: chat.id)?.freshCount
            == chat.freshCount - 1)
    }
}
