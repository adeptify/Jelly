import AppKit
import Foundation

@MainActor
protocol ContinuousBlockEditorHost: AnyObject {
    var textView: ContinuousBlockEditorTextView { get }
    var semanticAppearance: CalendarSemanticAppearance { get }
    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    )
}

@MainActor
final class ContinuousBlockEditorHostView: NSView, ContinuousBlockEditorHost {
    let textView = ContinuousBlockEditorTextView(frame: .zero)
    let taskCheckboxOverlay = TaskBlockCheckboxOverlay(frame: .zero)
    var semanticAppearance: CalendarSemanticAppearance {
        didSet { needsLayout = true }
    }
    private var measuredHeight: CGFloat = 80

    init(appearance: CalendarSemanticAppearance) {
        semanticAppearance = appearance
        super.init(frame: .zero)
        addSubview(textView)
        addSubview(taskCheckboxOverlay)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        semanticAppearance = CalendarTheme.light
        super.init(coder: coder)
        addSubview(textView)
        addSubview(taskCheckboxOverlay)
        setAccessibilityElement(false)
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        .init(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        textView.frame = .init(x: 0, y: 0, width: width, height: max(measuredHeight, bounds.height))
        taskCheckboxOverlay.frame = textView.frame
        taskCheckboxOverlay.updateFrames()
        updateMeasuredHeight(width: width)
    }

    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    ) {
        textView.apply(diff: diff, projection: projection, selectedRange: selectedRange)
        taskCheckboxOverlay.apply(document: projection.document, textView: textView)
        updateMeasuredHeight(width: max(1, bounds.width))
    }

    private func updateMeasuredHeight(width: CGFloat) {
        let next = max(80, textView.measuredContentHeight(for: width))
        guard abs(next - measuredHeight) > 0.5 else { return }
        measuredHeight = next
        textView.frame.size.height = next
        taskCheckboxOverlay.frame.size.height = next
        taskCheckboxOverlay.updateFrames()
        invalidateIntrinsicContentSize()
    }
}
