import Testing
import SwiftUI
@testable import DeltaApp

// Pure-helper coverage: exactly the logic recent bugs hid in.

@Suite struct ColorHexTests {
    @Test func validHexParses() {
        #expect(Color(hex: "#e56555") != Color.gray)
        #expect(Color(hex: "e56555") == Color(hex: "#e56555"))
    }

    @Test func partialHexFallsBackToGray() {
        // Scanner succeeds on any leading hex digits; the guard must reject
        // strings that are not fully hex instead of producing a wrong color.
        #expect(Color(hex: "ff00zz") == Color.gray)
        #expect(Color(hex: "zzzzzz") == Color.gray)
        #expect(Color(hex: "#12345") == Color.gray)
        #expect(Color(hex: "") == Color.gray)
    }
}

@Suite struct TimestampTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func epoch(secondsAgo: Int64) -> Int64 {
        Int64(now.timeIntervalSince1970) - secondsAgo
    }

    @Test func chatListBuckets() {
        #expect(chatListTimestamp(0, now: now) == "")
        #expect(chatListTimestamp(epoch(secondsAgo: 10), now: now) == "now")
        #expect(chatListTimestamp(epoch(secondsAgo: 5 * 60), now: now) == "5 min")
        // Future timestamps (sender clock skew) must not crash or go negative.
        #expect(chatListTimestamp(epoch(secondsAgo: -120), now: now) == "now")
    }

    @Test func messageFooterRelativeThenClock() {
        #expect(messageTimestamp(epoch(secondsAgo: 30), now: now) == "now")
        #expect(messageTimestamp(epoch(secondsAgo: 5 * 60), now: now) == "5 min")
        // Beyond an hour it falls back to clock time (HH:mm).
        let old = messageTimestamp(epoch(secondsAgo: 3 * 3600), now: now)
        #expect(old.contains(":"))
    }
}

@Suite struct LinkTests {
    @Test func detectsLinks() {
        #expect(containsLink("see https://delta.chat for more"))
        #expect(containsLink("www.example.org"))
        #expect(!containsLink("no links here"))
        #expect(!containsLink(""))
    }

    @Test func linkifiedMarksOnlyTheLinkRange() {
        let text = "see https://delta.chat now"
        let attributed = linkified(text, linkColor: .white)
        let linkRuns = attributed.runs.filter { $0.link != nil }
        #expect(linkRuns.count == 1)
        #expect(attributed.runs.contains { $0.link == nil }) // prose stays plain
    }
}

@Suite struct MessageListEntryTests {
    func message(
        id: UInt32, text: String = "hi", day: Int64 = 0,
        outgoing: Bool = false, info: Bool = false,
        sender: String = "Alice", color: String = "#e56555"
    ) -> MessageItem {
        MessageItem(
            id: id, chatId: 1, text: text,
            timestamp: 1_800_000_000 + day * 86_400,
            isOutgoing: outgoing, isInfo: info,
            senderName: sender, senderColor: color, state: .noState)
    }

    @Test func authorShownOncePerRunInGroups() {
        let entries = buildMessageListEntries([
            message(id: 1, sender: "Alice"),
            message(id: 2, sender: "Alice"),
            message(id: 3, sender: "Bob", color: "#3d7bde"),
            message(id: 4, outgoing: true, sender: "Me"),
            message(id: 5, sender: "Alice"),
        ], inGroup: true)
        let authors = entries.compactMap { entry -> Bool? in
            if case .message(_, let showAuthor) = entry { return showAuthor }
            return nil
        }
        // First of each incoming run only: Alice, (run cont.), Bob, out, Alice.
        #expect(authors == [true, false, true, false, true])
    }

    @Test func noAuthorsOutsideGroups() {
        let entries = buildMessageListEntries([
            message(id: 1, sender: "Alice"),
            message(id: 2, sender: "Bob", color: "#3d7bde"),
        ], inGroup: false)
        let anyAuthor = entries.contains { entry in
            if case .message(_, true) = entry { return true }
            return false
        }
        #expect(!anyAuthor)
    }

    @Test func sameNameDifferentContactStartsNewRun() {
        // Two distinct contacts sharing a display name: color disambiguates.
        let entries = buildMessageListEntries([
            message(id: 1, sender: "Alex", color: "#111111"),
            message(id: 2, sender: "Alex", color: "#222222"),
        ], inGroup: true)
        let authors = entries.compactMap { entry -> Bool? in
            if case .message(_, let showAuthor) = entry { return showAuthor }
            return nil
        }
        #expect(authors == [true, true])
    }

    @Test func dayMarkersInsertedAndResetRuns() {
        let entries = buildMessageListEntries([
            message(id: 1, day: 0),
            message(id: 2, day: 1),
        ], inGroup: true)
        let markers = entries.filter {
            if case .dayMarker = $0 { return true }
            return false
        }
        #expect(markers.count == 2)
        let authors = entries.compactMap { entry -> Bool? in
            if case .message(_, let showAuthor) = entry { return showAuthor }
            return nil
        }
        // Same sender, but a day marker restarts the run -> author again.
        #expect(authors == [true, true])
    }
}

@Suite struct AvatarInitialTests {
    @Test func initials() {
        #expect(avatarInitial(for: "alice") == "A")
        #expect(avatarInitial(for: " Bob") == "B")
        #expect(avatarInitial(for: "") == "?")
        #expect(avatarInitial(for: "😀 party") == "😀")
    }
}

@Suite struct WindowGrowthTests {
    func msg(_ id: UInt32) -> MessageItem {
        MessageItem(
            id: id, chatId: 1, text: "m", timestamp: 0, isOutgoing: false,
            isInfo: false, senderName: "A", senderColor: "#e56555", state: .noState)
    }

    @Test func noGrowthWhileAtBottom() {
        // Sending in a full-window chat slides the window; at the bottom the
        // user needs no history preserved — growing would prepend a page and
        // destabilize the scroll.
        #expect(!windowNeedsGrowth(
            previousOldest: 1, page: [msg(2), msg(3)], viewIsAtBottom: true))
    }

    @Test func growsWhenScrolledUpAndOldestSlidOff() {
        #expect(windowNeedsGrowth(
            previousOldest: 1, page: [msg(2), msg(3)], viewIsAtBottom: false))
    }

    @Test func noGrowthWhenOldestStillCovered() {
        #expect(!windowNeedsGrowth(
            previousOldest: 2, page: [msg(2), msg(3)], viewIsAtBottom: false))
    }

    @Test func noGrowthOnFreshChatOrEmptyPage() {
        #expect(!windowNeedsGrowth(
            previousOldest: nil, page: [msg(2)], viewIsAtBottom: false))
        #expect(!windowNeedsGrowth(
            previousOldest: 1, page: [], viewIsAtBottom: false))
    }
}

@Suite struct NSLinkifiedTests {
    @Test func linkRangeGetsLinkAndCursorAttributes() {
        let attributed = nsLinkified(
            "see https://delta.chat now",
            font: .systemFont(ofSize: 13), textColor: .white, linkColor: .white)
        var foundLink = false
        attributed.enumerateAttribute(
            .link, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            if value != nil {
                foundLink = true
                #expect((attributed.string as NSString).substring(with: range)
                    == "https://delta.chat")
            }
        }
        #expect(foundLink)
    }

    @Test func plainTextHasNoLinkAttribute() {
        let attributed = nsLinkified(
            "no links", font: .systemFont(ofSize: 13), textColor: .white, linkColor: .white)
        var foundLink = false
        attributed.enumerateAttribute(
            .link, in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if value != nil { foundLink = true }
        }
        #expect(!foundLink)
    }
}
