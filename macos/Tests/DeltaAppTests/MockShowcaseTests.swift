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
}
