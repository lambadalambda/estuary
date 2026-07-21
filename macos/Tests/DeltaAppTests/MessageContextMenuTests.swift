import Testing

@testable import DeltaApp

/// Composition rules for the Telegram-style message context menu
/// (issue: telegram-style-context-menu). The view renders exactly this
/// descriptor, so these tests pin which rows appear for which message.
@Suite struct MessageContextMenuTests {
    private let defaults = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

    private func message(
        text: String = "hello",
        kind: MessageKind = .text,
        file: String? = nil,
        reactions: [ReactionItem] = []
    ) -> MessageItem {
        MessageItem(
            id: 1, chatId: 1, text: text, timestamp: 0, isOutgoing: false,
            isInfo: false, senderName: "Elena", senderColor: "#e56555",
            senderAvatar: nil, state: .read, kind: kind, file: file,
            reactions: reactions)
    }

    @Test func textOnlyMessageHasBasicGroups() {
        let entries = messageContextMenuEntries(
            for: message(), quickReactions: defaults)
        #expect(entries == [
            .reactionPalette(emojis: defaults, selected: nil),
            .divider,
            .reply, .copyText,
            .divider,
            .forward,
            .divider,
            .delete,
        ])
    }

    @Test func emptyTextOmitsCopyText() {
        let entries = messageContextMenuEntries(
            for: message(text: "", kind: .image, file: "/tmp/x.png"),
            quickReactions: defaults)
        #expect(!entries.contains(.copyText))
    }

    @Test func imageMessageOffersMediaActions() {
        let entries = messageContextMenuEntries(
            for: message(kind: .image, file: "/tmp/x.png"),
            quickReactions: defaults)
        #expect(entries.contains(.copyMedia))
        #expect(entries.contains(.saveAs))
        #expect(entries.contains(.quickLook))
        #expect(entries.contains(.openInApp))
    }

    @Test func plainFileHasSaveButNoCopyMedia() {
        let entries = messageContextMenuEntries(
            for: message(kind: .file, file: "/tmp/report.pdf"),
            quickReactions: defaults)
        #expect(!entries.contains(.copyMedia))
        #expect(entries.contains(.saveAs))
    }

    @Test func reactionsAddReactedRowWithTotalAcrossEmojis() {
        let entries = messageContextMenuEntries(
            for: message(reactions: [
                ReactionItem(emoji: "❤️", count: 2, isFromSelf: false),
                ReactionItem(emoji: "👍", count: 3, isFromSelf: false),
            ]),
            quickReactions: defaults)
        #expect(entries.contains(.reacted(total: 5)))
    }

    @Test func selfReactionSelectsPaletteEmoji() {
        let entries = messageContextMenuEntries(
            for: message(reactions: [
                ReactionItem(emoji: "❤️", count: 1, isFromSelf: true)
            ]),
            quickReactions: defaults)
        #expect(entries.first == .reactionPalette(emojis: defaults, selected: "❤️"))
    }

    @Test func selfReactionOutsideDefaultsIsAppendedToPalette() {
        let entries = messageContextMenuEntries(
            for: message(reactions: [
                ReactionItem(emoji: "🌅", count: 1, isFromSelf: true)
            ]),
            quickReactions: defaults)
        #expect(entries.first
            == .reactionPalette(emojis: defaults + ["🌅"], selected: "🌅"))
    }

    @Test func selfReactionDifferingOnlyByVariationSelectorReplacesTheDefaultSlot() {
        // Another client may store the heart without U+FE0F; the palette
        // must not show two identical hearts, and the shown slot must be
        // the exact stored string so tapping it CLEARS instead of
        // re-sending a "different" emoji.
        let bareHeart = "\u{2764}"
        let entries = messageContextMenuEntries(
            for: message(reactions: [
                ReactionItem(emoji: bareHeart, count: 1, isFromSelf: true)
            ]),
            quickReactions: defaults)
        var expected = defaults
        expected[1] = bareHeart
        #expect(entries.first
            == .reactionPalette(emojis: expected, selected: bareHeart))
    }

    @Test func defaultPaletteConstantIsExposed() {
        // The view and these tests must share one list; a private copy in
        // the view let palette regressions go untested.
        #expect(defaultQuickReactions == defaults)
    }

    @Test func reactedRowsListKnownReactorsWithTheirEmoji() {
        let elena = ReactionContact(name: "Elena", color: "#e56555", avatarPath: nil)
        let marco = ReactionContact(name: "Marco", color: "#3d7bde", avatarPath: "/tmp/m.png")
        let summary = reactedSummary(for: message(reactions: [
            ReactionItem(emoji: "❤️", count: 2, isFromSelf: false, reactors: [elena, marco]),
            ReactionItem(emoji: "🌅", count: 1, isFromSelf: true,
                reactors: [ReactionContact(name: "Me", color: "#888888", avatarPath: nil)]),
        ]))
        #expect(summary.rows == [
            ReactedRow(name: "Elena", color: "#e56555", avatarPath: nil, emoji: "❤️"),
            ReactedRow(name: "Marco", color: "#3d7bde", avatarPath: "/tmp/m.png", emoji: "❤️"),
            ReactedRow(name: "Me", color: "#888888", avatarPath: nil, emoji: "🌅"),
        ])
        #expect(summary.othersCount == 0)
    }

    @Test func cappedReactionReportsOverflowCount() {
        // dcvm caps carried identities at 3; a 👍×5 reaction should list the
        // 3 known reactors and report 2 more.
        let reactors = (1...3).map {
            ReactionContact(name: "R\($0)", color: "#123456", avatarPath: nil)
        }
        let summary = reactedSummary(for: message(reactions: [
            ReactionItem(emoji: "👍", count: 5, isFromSelf: false, reactors: reactors)
        ]))
        #expect(summary.rows.count == 3)
        #expect(summary.othersCount == 2)
    }
}
