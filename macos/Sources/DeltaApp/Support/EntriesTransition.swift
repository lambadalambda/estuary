import Foundation

/// How the entry list changed between two assemblies — the AppKit table's
/// update brain (issue: appkit-message-table-port). Clean shapes get
/// surgical row edits; anything ambiguous degrades to `.reset`, where the
/// table reloads and restores position via the anchor machinery. Pure over
/// id sequences so it is exhaustively testable.
enum EntriesTransition: Equatable {
    case none
    case initial
    /// Same ids: refresh visible rows' content (state/reaction changes).
    case inPlace
    case appended(Int)
    case prepended(Int)
    /// Newest-window slide: rows dropped at the top, rows appended at the
    /// bottom (the at-capacity chat receiving messages while pinned).
    case slide(droppedTop: Int, appended: Int)
    case reset
}

func entriesTransition(from old: [String], to new: [String]) -> EntriesTransition {
    if old.isEmpty, new.isEmpty { return .none }
    if old.isEmpty { return .initial }
    if new.isEmpty { return .reset }
    if old == new { return .inPlace }

    if new.count > old.count, Array(new.prefix(old.count)) == old {
        return .appended(new.count - old.count)
    }
    if new.count > old.count, Array(new.suffix(old.count)) == old {
        return .prepended(new.count - old.count)
    }
    // Slide: some suffix of old is a prefix of new, with the remainder
    // appended. Require a non-trivial overlap so unrelated lists that
    // happen to share an id do not masquerade as slides.
    if let overlapStart = new.firstIndex(of: old[old.count - 1]) {
        let overlap = overlapStart + 1
        let dropped = old.count - overlap
        if dropped > 0, overlap > 0,
           Array(old.suffix(overlap)) == Array(new.prefix(overlap)) {
            return .slide(droppedTop: dropped, appended: new.count - overlap)
        }
    }
    return .reset
}
