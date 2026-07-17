import SwiftUI

// Pure helpers — kept free-standing so they are unit-testable once a test
// target is allowed in Package.swift.

extension Color {
    /// Parses "#rrggbb"; falls back to gray on malformed input.
    init(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }
}

/// First grapheme of the name, uppercased ("Alice" -> "A").
func avatarInitial(for name: String) -> String {
    guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
    return String(first).uppercased()
}

/// Chat-list relative timestamp, following the desktop `formatRelativeTime`
/// buckets: now / N min / N h (same day) / weekday (≤ 6 days) / "Jul 2"
/// (same year) / "Jul 2, 2024" (older).
func chatListTimestamp(_ epochSeconds: Int64, now: Date = Date()) -> String {
    guard epochSeconds > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    let calendar = Calendar.current
    let elapsed = now.timeIntervalSince(date)
    if elapsed < 60 { return "now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60)) min" }
    if calendar.isDate(date, inSameDayAs: now) { return "\(Int(elapsed / 3600)) h" }
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)).day ?? .max
    if days <= 6 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
}

/// Day-separator label: Today / Yesterday / long date.
func dayMarkerLabel(_ epochSeconds: Int64, now: Date = Date()) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday"
    }
    return date.formatted(date: .long, time: .omitted)
}

/// Detects URLs and returns text with tappable links (underlined, colored).
/// `linkColor` must contrast with the bubble background — white on outgoing
/// accent bubbles, accent on incoming ones.
func linkified(_ text: String, linkColor: Color) -> AttributedString {
    var attributed = AttributedString(text)
    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return attributed }
    let matches = detector.matches(
        in: text, range: NSRange(text.startIndex..., in: text))
    for match in matches {
        guard let url = match.url,
              let range = Range(match.range, in: text),
              let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { continue }
        attributed[lower..<upper].link = url
        attributed[lower..<upper].underlineStyle = .single
        attributed[lower..<upper].foregroundColor = linkColor
    }
    return attributed
}

/// Message footer time, "14:03".
func messageTime(_ epochSeconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        .formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
}

/// Message-footer timestamp: relative while fresh ("now", "5 min"), clock
/// time afterwards. Day context comes from the day separators.
func messageTimestamp(_ epochSeconds: Int64, now: Date = Date()) -> String {
    let elapsed = now.timeIntervalSince(
        Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
    if elapsed < 60 { return "now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60)) min" }
    return messageTime(epochSeconds)
}

/// Whether the text contains at least one detectable URL.
func containsLink(_ text: String) -> Bool {
    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return false }
    return detector.firstMatch(
        in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

// MARK: - Message list assembly (messages + day separators)

enum MessageListEntry: Identifiable, Equatable {
    case dayMarker(key: String, label: String)
    case message(MessageItem, showAuthor: Bool)

    var id: String {
        switch self {
        case .dayMarker(let key, _): return "day-\(key)"
        case .message(let message, _): return "msg-\(message.id)"
        }
    }
}

/// Interleaves day markers and decides whether to show the author line
/// (incoming messages in chats with more than one distinct sender, mirroring
/// `showAuthor = hasMultipleParticipants` in the desktop UI).
func buildMessageListEntries(_ messages: [MessageItem], now: Date = Date()) -> [MessageListEntry] {
    let incomingSenders = Set(
        messages.filter { !$0.isOutgoing && !$0.isInfo }.map(\.senderName))
    let showAuthors = incomingSenders.count > 1
    let calendar = Calendar.current

    var entries: [MessageListEntry] = []
    var lastDayKey: String?
    for message in messages {
        let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let dayKey = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        if dayKey != lastDayKey {
            entries.append(.dayMarker(key: dayKey, label: dayMarkerLabel(message.timestamp, now: now)))
            lastDayKey = dayKey
        }
        entries.append(.message(
            message,
            showAuthor: showAuthors && !message.isOutgoing && !message.isInfo))
    }
    return entries
}
