import Foundation

// Telegram-style message context menu composition (issue:
// telegram-style-context-menu). Pure functions decide which rows a message
// gets; ChatDetailView only renders the descriptor.

/// One row (or the top emoji palette) of the message context menu, in
/// display order. Dividers separate Telegram's groups: actions | forward |
/// reacted | delete.
enum MessageMenuEntry: Equatable {
    /// Horizontal quick-reaction strip; `selected` is the user's current
    /// reaction, appended to `emojis` when outside the default set.
    case reactionPalette(emojis: [String], selected: String?)
    case reply
    case copyText
    case copyMedia
    case saveAs
    case quickLook
    case openInApp
    case forward
    /// "N Reacted" submenu row; total counts every reactor across emojis.
    case reacted(total: UInt32)
    case delete
    case divider
}

/// One reactor line inside the "N Reacted" submenu.
struct ReactedRow: Equatable {
    var name: String
    var color: String
    var avatarPath: String?
    var emoji: String
}

/// Known reactors (identities the core carried) plus how many reacted
/// beyond them (dcvm caps identities per emoji).
struct ReactedSummary: Equatable {
    var rows: [ReactedRow]
    var othersCount: UInt32
}

/// The quick-reaction strip shown at the top of every message menu.
/// Shared with the tests so palette regressions test against the real list.
let defaultQuickReactions = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

/// Media kinds whose blob is a pasteboard-copyable image.
private let copyableImageKinds: Set<MessageKind> = [.image, .gif, .sticker]

/// Other clients store emoji with or without the U+FE0F variation
/// selector; treating those as different would show two identical hearts
/// and break clear-on-tap.
private func sameEmoji(_ a: String, _ b: String) -> Bool {
    a.replacingOccurrences(of: "\u{FE0F}", with: "")
        == b.replacingOccurrences(of: "\u{FE0F}", with: "")
}

func messageContextMenuEntries(
    for message: MessageItem, quickReactions: [String]
) -> [MessageMenuEntry] {
    let selfEmoji = message.reactions.first(where: \.isFromSelf)?.emoji
    var palette = quickReactions
    if let selfEmoji {
        // The slot must carry the EXACT stored string: the view's toggle
        // compares/sends it verbatim, and only an exact match clears.
        if let slot = palette.firstIndex(where: { sameEmoji($0, selfEmoji) }) {
            palette[slot] = selfEmoji
        } else {
            palette.append(selfEmoji)
        }
    }

    var actions: [MessageMenuEntry] = [.reply]
    if !message.text.isEmpty { actions.append(.copyText) }
    if message.file != nil {
        if copyableImageKinds.contains(message.kind) { actions.append(.copyMedia) }
        actions.append(.saveAs)
        actions.append(.quickLook)
        actions.append(.openInApp)
    }

    let total = reactionTotal(message)
    let groups: [[MessageMenuEntry]] = [
        [.reactionPalette(emojis: palette, selected: selfEmoji)],
        actions,
        [.forward],
        total > 0 ? [.reacted(total: total)] : [],
        [.delete],
    ]
    return Array(groups.filter { !$0.isEmpty }.joined(separator: [.divider]))
}

/// Every reactor across emojis (Delta Chat allows one reaction per user,
/// so the sum of counts is the number of people).
private func reactionTotal(_ message: MessageItem) -> UInt32 {
    message.reactions.reduce(UInt32(0)) { $0 + $1.count }
}

func reactedSummary(for message: MessageItem) -> ReactedSummary {
    let rows = message.reactions.flatMap { reaction in
        reaction.reactors.map {
            ReactedRow(
                name: $0.name, color: $0.color,
                avatarPath: $0.avatarPath, emoji: reaction.emoji)
        }
    }
    let total = reactionTotal(message)
    let known = UInt32(rows.count)
    return ReactedSummary(rows: rows, othersCount: total > known ? total - known : 0)
}
