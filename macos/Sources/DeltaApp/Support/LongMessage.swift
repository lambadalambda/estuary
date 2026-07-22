import Foundation

// Long-message collapse (issue: long-message-height-and-collapse):
// email-sized messages would otherwise produce screen-filling bubbles.
// Pure decision logic; the bubble renders `shown` and offers
// "Show more"/"Show less" from the flags.

/// Only messages beyond this many characters ever collapse.
let longMessageThreshold = 5000

/// How far back from the threshold we search for a whitespace boundary
/// before giving up and cutting mid-word.
private let boundaryWindow = 200

struct LongMessageDisplay: Equatable {
    /// The text the bubble should render.
    var shown: String
    /// Text exceeds the threshold (an expand/collapse control applies).
    var isExpandable: Bool
    /// The cut version is currently shown ("Show more" state).
    var isTruncated: Bool
}

func longMessageDisplay(
    _ text: String, expanded: Bool, threshold: Int = longMessageThreshold
) -> LongMessageDisplay {
    // This runs on every bubble render: utf8.count is O(1) and always
    // >= the character count, so ~all messages short-circuit without
    // paying the O(n) grapheme walk below.
    guard text.utf8.count > threshold, text.count > threshold else {
        return LongMessageDisplay(shown: text, isExpandable: false, isTruncated: false)
    }
    if expanded {
        return LongMessageDisplay(shown: text, isExpandable: true, isTruncated: false)
    }
    var cut = String(text.prefix(threshold))
    // Cut at a whitespace boundary near the threshold when one exists;
    // suffix shares indices with its base, so the found index is valid
    // in `cut`.
    if let boundary = cut.suffix(boundaryWindow).lastIndex(where: \.isWhitespace) {
        cut = String(cut[..<boundary])
    } else if let lastWhitespace = cut.lastIndex(where: \.isWhitespace),
        containsLink(String(cut[cut.index(after: lastWhitespace)...]))
    {
        // Hard cut landed mid-word. If that word is a URL (longer than
        // the boundary window — signed S3 links etc.), drop it whole:
        // the collapsed bubble would otherwise linkify a truncated URL
        // pointing somewhere unintended.
        cut = String(cut[..<lastWhitespace])
    }
    return LongMessageDisplay(shown: cut + "…", isExpandable: true, isTruncated: true)
}
