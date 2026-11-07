import UIKit

/// What the 9-key digits could spell, above the candidates; the locked one is marked.
final class SpellingRowView: UIView {
    var onTap: ((Int) -> Void)?

    private static let padding: CGFloat = 20
    private let scroller = CandidateScroller()
    private let divider = UIView()
    private var buttons: [UIButton] = []
    private var shown: [String] = []
    private var selected: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroller.showsHorizontalScrollIndicator = false
        scroller.delaysContentTouches = false
        scroller.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addSubview(scroller)
        divider.backgroundColor = .separator
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    func show(_ spellings: [String], selected: Int?) {
        if spellings == shown, selected == self.selected { return }
        shown = spellings
        self.selected = selected
        place()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroller.frame = bounds
        divider.frame = CGRect(x: 0, y: bounds.height - 1 / UIScreen.main.scale, width: bounds.width, height: 1 / UIScreen.main.scale)
        place()
    }

    private func place() {
        var x: CGFloat = 6
        for (index, spelling) in shown.enumerated() {
            let button = button(at: index)
            button.setTitle(spelling, for: .normal)
            let width = ceil((spelling as NSString).size(withAttributes: [.font: button.titleLabel!.font!]).width) + Self.padding
            button.frame = CGRect(x: x, y: 4, width: width, height: max(bounds.height - 8, 0))
            button.backgroundColor = index == selected ? KeyboardKeysView.letterKey : .clear
            button.isHidden = false
            x += width + 2
        }
        for index in shown.count..<max(shown.count, buttons.count) { buttons[index].isHidden = true }
        scroller.contentSize = CGSize(width: x, height: bounds.height)
    }

    private func button(at index: Int) -> UIButton {
        if index < buttons.count { return buttons[index] }
        let button = UIButton(type: .custom)
        button.tag = index
        button.titleLabel?.font = .systemFont(ofSize: 17)
        button.setTitleColor(.label, for: .normal)
        button.layer.cornerRadius = 8
        button.isUserInteractionEnabled = false
        buttons.append(button)
        scroller.addSubview(button)
        return button
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let x = tap.location(in: scroller).x
        if let index = buttons.prefix(shown.count).firstIndex(where: { $0.frame.minX <= x && x < $0.frame.maxX + 2 }) { onTap?(index) }
    }
}
