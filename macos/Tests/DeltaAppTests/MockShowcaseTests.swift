import Foundation
import Testing
@testable import DeltaApp

// The mock seed doubles as the screenshot showcase (DCNATIVE_MOCK=1 +
// DCNATIVE_AUTOSELECT=1): these pin the properties the captures rely on.

@Suite struct MockShowcaseTests {
    /// Group invite semantics mirror core (issue:
    /// encrypted-group-creation-correctness): the link round-trips the
    /// percent-encoded name, own invites are rejected like core's
    /// withdraw classification, joins are idempotent, and 1:1 chats
    /// cannot generate group links.
    @Test func groupInviteMirrorsRealSemantics() async throws {
        let mock = MockChatService()
        let account = await mock.addAccount()
        let group = try await mock.createGroup(
            accountId: account, name: "Chess Club", memberContactIds: [])

        let link = try await mock.securejoinQr(accountId: account, chatId: group)
        #expect(link.contains("g=Chess%20Club"))
        #expect(
            await mock.checkQr(accountId: account, qr: link)
                == .askVerifyGroup(groupName: "Chess Club"))

        // Own invite: core classifies it as a withdraw QR and join bails.
        await #expect(throws: ServiceError.self) {
            _ = try await mock.joinSecurejoin(accountId: account, qr: link)
        }

        // Someone else's group invite joins once, idempotently.
        let foreign = "https://i.delta.chat/#OTHERFPR&v=3&x=grp9&g=Book%20Circle"
        let joined = try await mock.joinSecurejoin(accountId: account, qr: foreign)
        let again = try await mock.joinSecurejoin(accountId: account, qr: foreign)
        #expect(joined == again)
        let chats = try await mock.chatList(accountId: account)
        #expect(chats.filter { $0.name == "Book Circle" }.count == 1)
        #expect(chats.first { $0.name == "Book Circle" }?.isGroup == true)

        // A 1:1 chat id must not yield a bogus group link.
        let oneToOne = try await mock.createChat(
            accountId: account, email: "pia@example.org", name: "Pia")
        await #expect(throws: ServiceError.self) {
            _ = try await mock.securejoinQr(accountId: account, chatId: oneToOne)
        }
    }

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
