import UIKit

/// What was copied, or the user's phrases, in the place of the keys: the list alone. The bar's
/// icon that opened it closes it. A tap types an entry; a long press offers to delete it, or to
/// keep a copy as a phrase.
final class SavedTextPanelView: UIView {
    enum Tab { case clipboard, phrases }

    var onPick: ((String) -> Void)?
    var onDelete: ((Tab, Int) -> Void)?
    var onKeep: ((Int) -> Void)?
    var onClear: (() -> Void)?

    private static let inset: CGFloat = 8
    private static let rowGap: CGFloat = 6
    /// A row's tag is its index, and viewWithTag finds the row itself first, so these stay clear
    /// of any index: with tag 1, the second row was taken for its own label and crashed.
    private static let labelTag = -1
    private static let actionsTag = -2

    /// Last in the clipboard list, so the panel needs no header.
    private let clear = UIButton(type: .system)
    private static let clearHeight: CGFloat = 40
    private let list = CandidateScroller()
    private let empty = UILabel()
    private var rows: [UIView] = []
    private var items: [String] = []
    private var tab = Tab.clipboard
    private var opened: Int?
    private var note: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clear.setTitle("清空剪贴板", for: .normal)
        clear.titleLabel?.font = .systemFont(ofSize: 15)
        clear.tintColor = .systemRed
        clear.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        list.alwaysBounceVertical = true
        list.showsVerticalScrollIndicator = false
        list.delaysContentTouches = false
        empty.numberOfLines = 0
        empty.textAlignment = .center
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .secondaryLabel
        list.addSubview(clear)
        for view in [list, empty] as [UIView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    /// [note] replaces the empty-list hint, as when reading the clipboard needs full access.
    func show(_ tab: Tab, _ items: [String], note: String? = nil) {
        if tab != self.tab || items != self.items { opened = nil }
        self.tab = tab
        self.items = items
        self.note = note
        clear.isHidden = tab != .clipboard || items.isEmpty
        rebuild()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        list.frame = bounds
        empty.frame = list.frame.insetBy(dx: 24, dy: 16)
        placeRows()
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, text in row(index, text) }
        rows.forEach(list.addSubview)
        empty.isHidden = !items.isEmpty
        empty.text = note ?? (tab == .clipboard
            ? "还没有记录。复制文字后打开这里，就会保存下来。"
            : "还没有常用语。可以在 ZnKeyboard App 的「键盘」页添加，或在剪贴板里长按一条，存为常用语。")
        list.contentOffset = .zero
        setNeedsLayout()
    }

    private func row(_ index: Int, _ text: String) -> UIView {
        let row = UIView()
        row.backgroundColor = KeyboardKeysView.letterKey
        row.layer.cornerRadius = 9
        let label = UILabel()
        label.text = text.replacingOccurrences(of: "\n", with: " ")
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 2
        label.tag = Self.labelTag
        row.addSubview(label)
        row.tag = index
        row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(rowTapped)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(rowHeld))
        hold.minimumPressDuration = 0.4
        row.addGestureRecognizer(hold)
        if opened == index {
            let actions = UIStackView()
            actions.axis = .horizontal
            actions.spacing = 6
            actions.tag = Self.actionsTag
            if tab == .clipboard { actions.addArrangedSubview(action("存为常用语", #selector(keepTapped))) }
            actions.addArrangedSubview(action("删除", #selector(deleteTapped), destructive: true))
            row.addSubview(actions)
        }
        return row
    }

    private func action(_ title: String, _ selector: Selector, destructive: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.setTitleColor(destructive ? .white : .systemBlue, for: .normal)
        button.backgroundColor = destructive ? .systemRed : UIColor.systemBlue.withAlphaComponent(0.15)
        button.layer.cornerRadius = 7
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        button.addTarget(self, action: selector, for: .touchUpInside)
        return button
    }

    private func placeRows() {
        let width = bounds.width - 2 * Self.inset
        guard width > 0 else { return }
        var y: CGFloat = 4
        for row in rows {
            let actions = row.viewWithTag(Self.actionsTag)
            let actionsWidth = (actions as? UIStackView).map { Self.width(of: $0) + 8 } ?? 0
            let label = row.viewWithTag(Self.labelTag) as! UILabel
            let textWidth = width - 24 - actionsWidth
            let textHeight = min(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height, 44)
            let height = max(textHeight + 20, 46)
            row.frame = CGRect(x: Self.inset, y: y, width: width, height: height)
            label.frame = CGRect(x: 12, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
            actions?.frame = CGRect(x: width - actionsWidth, y: (height - 32) / 2, width: actionsWidth - 8, height: 32)
            y += height + Self.rowGap
        }
        if !clear.isHidden {
            clear.frame = CGRect(x: Self.inset, y: y, width: width, height: Self.clearHeight)
            y += Self.clearHeight
        }
        list.contentSize = CGSize(width: bounds.width, height: y + 4)
    }

    /// A stack's buttons side by side; its fitting size alone comes out zero before layout.
    private static func width(of stack: UIStackView) -> CGFloat {
        let views = stack.arrangedSubviews
        return views.reduce(0) { $0 + $1.intrinsicContentSize.width } + stack.spacing * CGFloat(max(views.count - 1, 0))
    }

    @objc private func rowTapped(_ tap: UITapGestureRecognizer) {
        guard let index = tap.view?.tag else { return }
        if opened != nil {
            opened = nil
            rebuild()
            return
        }
        if let text = items[safe: index] { onPick?(text) }
    }

    @objc private func rowHeld(_ hold: UILongPressGestureRecognizer) {
        guard hold.state == .began, let index = hold.view?.tag else { return }
        opened = index
        rebuild()
    }

    @objc private func keepTapped() { if let index = opened { opened = nil; onKeep?(index) } }
    @objc private func deleteTapped() { if let index = opened { opened = nil; onDelete?(tab, index) } }
    @objc private func clearTapped() { onClear?() }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
