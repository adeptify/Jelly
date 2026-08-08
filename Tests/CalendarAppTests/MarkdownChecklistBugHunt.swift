import AppKit
import Foundation
import Testing
@testable import CalendarApp

@Suite("MarkdownChecklistBugHunt")
struct MarkdownChecklistBugHunt {
    private var metrics: NotesRichTextMetrics {
        NotesRichTextMetrics(
            bodySize: 12.5,
            headingSize: 15.5,
            textColor: .labelColor,
            secondaryColor: .secondaryLabelColor,
            accentColor: .systemOrange
        )
    }

    @Test func toolbarOnEmptySeedsCheckbox() {
        let empty = NSAttributedString(string: "")
        let (r, _) = MarkdownRichTextCodec.apply(.checklist, to: empty, selectedRange: .init(location: 0, length: 0), metrics: metrics)
        print("EMPTY_SEED:", r.string.debugDescription)
        #expect(r.string.hasPrefix("☐"))
    }

    @Test func toolbarOnPlainLines() {
        let base = MarkdownRichTextCodec.attributedString(from: "买菜\n做饭", metrics: metrics)
        // Select all lines to convert both.
        let (r, _) = MarkdownRichTextCodec.apply(
            .checklist,
            to: base,
            selectedRange: .init(location: 0, length: base.length),
            metrics: metrics
        )
        print("PLAIN:", r.string.debugDescription)
        #expect(r.string.contains("☐ 买菜"))
        #expect(r.string.contains("☐ 做饭"))
    }

    @Test func toolbarOnMarkdownChecklist() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] a\n- [x] b", metrics: metrics)
        print("LOAD:", base.string.debugDescription)
        #expect(base.string.contains("☐ a"))
        #expect(base.string.contains("☑ b"))
        let md = MarkdownRichTextCodec.markdown(from: base)
        print("MD:", md.debugDescription)
        #expect(md.contains("- [ ] a"))
        #expect(md.contains("- [x] b"))
    }

    @Test func toggleCheckedPreservesBody() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] 任务ABC", metrics: metrics)
        print("BEFORE:", base.string.debugDescription)
        let t = MarkdownRichTextCodec.toggleChecklistChecked(in: base, at: 0, metrics: metrics)!
        print("AFTER:", t.string.debugDescription)
        #expect(t.string.contains("☑"))
        #expect(t.string.contains("任务ABC"))
        #expect(!t.string.contains("☐ 任务") || t.string.contains("☑ 任务ABC"))
        let md = MarkdownRichTextCodec.markdown(from: t)
        print("MD2:", md.debugDescription)
        #expect(md.contains("- [x]"))
        #expect(md.contains("任务ABC"))
    }

    @Test func toggleOffChecklistRemovesGlyphKeepsBody() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] 任务", metrics: metrics)
        let (off, _) = MarkdownRichTextCodec.apply(.checklist, to: base, selectedRange: .init(location: 0, length: 0), metrics: metrics)
        print("OFF:", off.string.debugDescription)
        #expect(off.string == "任务" || off.string.hasPrefix("任务"))
        #expect(!off.string.contains("☐"))
    }

    @Test func doubleToggleCheckedBack() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] x", metrics: metrics)
        let t1 = MarkdownRichTextCodec.toggleChecklistChecked(in: base, at: 0, metrics: metrics)!
        let t2 = MarkdownRichTextCodec.toggleChecklistChecked(in: t1, at: 0, metrics: metrics)!
        print("T2:", t2.string.debugDescription)
        #expect(t2.string.contains("☐"))
        #expect(t2.string.contains("x"))
    }

    @Test func checklistThenTypeMoreLinesViaApply() {
        // Line1 checklist, line2 plain — apply checklist to all
        let s = NSMutableAttributedString(string: "☐ 一\n二", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .notesBlock: NotesBlockKind.checklist.rawValue
        ])
        // fix line2 as paragraph
        let range2 = (s.string as NSString).range(of: "二")
        s.addAttribute(.notesBlock, value: NotesBlockKind.paragraph.rawValue, range: range2)
        let (r, _) = MarkdownRichTextCodec.apply(.checklist, to: s, selectedRange: .init(location: 0, length: 0), metrics: metrics)
        print("MIX:", r.string.debugDescription)
    }

    @Test func roundTripEmptyChecklistLine() {
        let base = MarkdownRichTextCodec.attributedString(from: "- [ ] ", metrics: metrics)
        print("EMPTY_ITEM:", base.string.debugDescription, "len", base.length)
        let md = MarkdownRichTextCodec.markdown(from: base)
        print("EMPTY_MD:", md.debugDescription)
    }

    @Test func applyChecklistDoesNotWipeSiblingParagraphsWhenSelectedOneLine() {
        let base = MarkdownRichTextCodec.attributedString(from: "标题段\n买菜\n备注", metrics: metrics)
        // select only middle line "买菜"
        let ns = base.string as NSString
        let mid = ns.range(of: "买菜")
        let (r, _) = MarkdownRichTextCodec.apply(.checklist, to: base, selectedRange: mid, metrics: metrics)
        print("PARTIAL:", r.string.debugDescription)
        #expect(r.string.contains("标题段"))
        #expect(r.string.contains("☐ 买菜") || r.string.contains("买菜"))
        #expect(r.string.contains("备注"))
    }
}
