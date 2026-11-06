import UIKit

/// All the candidates, opened from the bar's arrow, in the place of the keys.
final class CandidateGridView: UIScrollView {
    var onTap: ((Int) -> Void)?

    private static let rowHeight: CGFloat = 46
    private static let inset: CGFloat = 8
    private static let cellPadding: CGFloat = 24
    private static let font = UIFont.systemFont(ofSize: 20)

    private var buttons: [UIButton] = []
    private var items: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    func show(_ items: [String]) {
        self.items = items
        contentOffset = .zero
        place()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    /// Fills each row, then stretches its cells to the full width.
    private func place() {
        let width = bounds.width - 2 * Self.inset
        guard width > 0 else { return }
        while buttons.count < items.count {
            let button = UIButton(type: .custom)
            button.tag = buttons.count
            button.titleLabel?.font = Self.font
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(.label, for: .normal)
            button.setTitleColor(.secondaryLabel, for: .highlighted)
            button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            buttons.append(button)
            addSubview(button)
        }
        var y: CGFloat = 0
        var row: [(button: UIButton, width: CGFloat)] = []
        var used: CGFloat = 0
        func finishRow(fill: Bool) {
            let extra = fill ? (width - used) / CGFloat(max(row.count, 1)) : 0
            var x = Self.inset
            for cell in row {
                cell.button.frame = CGRect(x: x, y: y, width: cell.width + extra, height: Self.rowHeight)
                x += cell.width + extra
            }
            y += Self.rowHeight
            row = []
            used = 0
        }
        for (index, text) in items.enumerated() {
            let button = buttons[index]
            if button.title(for: .normal) != text { button.setTitle(text, for: .normal) }
            button.isHidden = false
            let measured = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + Self.cellPadding
            let cell = min(measured, width)
            if used + cell > width { finishRow(fill: true) }
            row.append((button, cell))
            used += cell
        }
        if !row.isEmpty { finishRow(fill: false) }
        for button in buttons[items.count...] { button.isHidden = true }
        contentSize = CGSize(width: bounds.width, height: y)
    }

    @objc private func tapped(_ sender: UIButton) { onTap?(sender.tag) }
}
