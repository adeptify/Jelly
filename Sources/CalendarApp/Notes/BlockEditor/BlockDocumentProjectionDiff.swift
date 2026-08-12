import AppKit
import Foundation
import WorkspaceDomain

struct BlockDocumentProjectionDiff: Equatable {
    let oldRange: NSRange
    let replacement: NSAttributedString
    let changedBlockIDs: Set<BlockID>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.oldRange == rhs.oldRange
            && lhs.changedBlockIDs == rhs.changedBlockIDs
            && lhs.replacement.isEqual(to: rhs.replacement)
    }

    static func make(
        from old: BlockDocumentTextProjection,
        to new: BlockDocumentTextProjection
    ) -> Self? {
        if old.attributedString.isEqual(to: new.attributedString), old.segments == new.segments {
            return nil
        }

        let sharedCount = min(old.segments.count, new.segments.count)
        var prefix = 0
        while prefix < sharedCount, blocksEqual(old: old, oldIndex: prefix, new: new, newIndex: prefix) {
            prefix += 1
        }

        var suffix = 0
        while suffix < sharedCount - prefix,
              blocksEqual(
                  old: old,
                  oldIndex: old.segments.count - suffix - 1,
                  new: new,
                  newIndex: new.segments.count - suffix - 1
              ) {
            suffix += 1
        }

        let oldMiddleEnd = old.segments.count - suffix
        let newMiddleEnd = new.segments.count - suffix
        let changedIDs = Set(old.segments[prefix..<oldMiddleEnd].map(\.blockID))
            .union(new.segments[prefix..<newMiddleEnd].map(\.blockID))
        let coarseRegions = replacementRegions(
            old: old,
            new: new,
            prefix: prefix,
            oldMiddleEnd: oldMiddleEnd,
            newMiddleEnd: newMiddleEnd,
            hasSuffix: suffix > 0
        )
        let regions = trimEqualEdges(
            old: old.attributedString,
            oldRange: coarseRegions.old,
            new: new.attributedString,
            newRange: coarseRegions.new
        )
        return .init(
            oldRange: regions.old,
            replacement: new.attributedString.attributedSubstring(from: regions.new),
            changedBlockIDs: changedIDs
        )
    }

    /// Block identity bounds the structural change; this second pass bounds the
    /// actual TextKit mutation to changed composed characters and attributes.
    /// A normal keystroke must not replace and restyle the whole paragraph.
    private static func trimEqualEdges(
        old: NSAttributedString,
        oldRange: NSRange,
        new: NSAttributedString,
        newRange: NSRange
    ) -> (old: NSRange, new: NSRange) {
        var oldStart = oldRange.location
        var newStart = newRange.location
        var oldEnd = NSMaxRange(oldRange)
        var newEnd = NSMaxRange(newRange)
        let oldString = old.string as NSString
        let newString = new.string as NSString

        while oldStart < oldEnd, newStart < newEnd {
            let oldUnit = oldString.rangeOfComposedCharacterSequence(at: oldStart)
            let newUnit = newString.rangeOfComposedCharacterSequence(at: newStart)
            guard NSMaxRange(oldUnit) <= oldEnd,
                  NSMaxRange(newUnit) <= newEnd,
                  old.attributedSubstring(from: oldUnit).isEqual(
                      to: new.attributedSubstring(from: newUnit)
                  )
            else { break }
            oldStart = NSMaxRange(oldUnit)
            newStart = NSMaxRange(newUnit)
        }

        while oldEnd > oldStart, newEnd > newStart {
            let oldUnit = oldString.rangeOfComposedCharacterSequence(at: oldEnd - 1)
            let newUnit = newString.rangeOfComposedCharacterSequence(at: newEnd - 1)
            guard oldUnit.location >= oldStart,
                  newUnit.location >= newStart,
                  old.attributedSubstring(from: oldUnit).isEqual(
                      to: new.attributedSubstring(from: newUnit)
                  )
            else { break }
            oldEnd = oldUnit.location
            newEnd = newUnit.location
        }

        return (
            .init(location: oldStart, length: oldEnd - oldStart),
            .init(location: newStart, length: newEnd - newStart)
        )
    }

    private static func blocksEqual(
        old: BlockDocumentTextProjection,
        oldIndex: Int,
        new: BlockDocumentTextProjection,
        newIndex: Int
    ) -> Bool {
        let oldSegment = old.segments[oldIndex]
        let newSegment = new.segments[newIndex]
        guard oldSegment.blockID == newSegment.blockID,
              oldSegment.kind == newSegment.kind else { return false }
        return old.attributedString.attributedSubstring(from: oldSegment.displayRange).isEqual(
            to: new.attributedString.attributedSubstring(from: newSegment.displayRange)
        )
    }

    private static func replacementRegions(
        old: BlockDocumentTextProjection,
        new: BlockDocumentTextProjection,
        prefix: Int,
        oldMiddleEnd: Int,
        newMiddleEnd: Int,
        hasSuffix: Bool
    ) -> (old: NSRange, new: NSRange) {
        let oldHasMiddle = prefix < oldMiddleEnd
        let newHasMiddle = prefix < newMiddleEnd
        let oldMiddleCount = oldMiddleEnd - prefix
        let newMiddleCount = newMiddleEnd - prefix

        if oldMiddleCount == newMiddleCount, oldMiddleCount > 0 {
            let oldStart = old.segments[prefix].displayRange.location
            let oldLast = old.segments[oldMiddleEnd - 1].displayRange
            let newStart = new.segments[prefix].displayRange.location
            let newLast = new.segments[newMiddleEnd - 1].displayRange
            return (
                .init(location: oldStart, length: NSMaxRange(oldLast) - oldStart),
                .init(location: newStart, length: NSMaxRange(newLast) - newStart)
            )
        }

        if hasSuffix {
            let oldStart = old.segments[prefix].displayRange.location
            let oldEnd = old.segments[oldMiddleEnd].displayRange.location
            let newStart = new.segments[prefix].displayRange.location
            let newEnd = new.segments[newMiddleEnd].displayRange.location
            return (
                .init(location: oldStart, length: oldEnd - oldStart),
                .init(location: newStart, length: newEnd - newStart)
            )
        }

        if oldHasMiddle {
            let oldStart: Int
            let newStart: Int
            if !newHasMiddle, prefix > 0 {
                oldStart = old.segments[prefix].displayRange.location - 1
                newStart = new.attributedString.length
            } else {
                oldStart = prefix == 0 ? 0 : old.segments[prefix].displayRange.location
                newStart = prefix == 0 ? 0 : new.segments[prefix].displayRange.location
            }
            return (
                .init(location: oldStart, length: old.attributedString.length - oldStart),
                .init(location: newStart, length: new.attributedString.length - newStart)
            )
        }

        let oldStart = old.attributedString.length
        let newStart = prefix == 0 ? 0 : new.segments[prefix].displayRange.location - 1
        return (
            .init(location: oldStart, length: 0),
            .init(location: newStart, length: new.attributedString.length - newStart)
        )
    }
}
