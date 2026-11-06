import UIKit

/// The pinyin above and a row of candidates, as on Android.
final class CandidateBarView: UIView {
    var onTap: ((Int) -> Void)?
    var onFix: (() -> Void)?

    private let label = UILabel()
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let fix = UIButton(type: .system)
    private var buttons: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingHead
        row.axis = .horizontal
        row.spacing = 2
        row.alignment = .center
        scroller.showsHorizontalScrollIndicator = false
        fix.titleLabel?.font = .systemFont(ofSize: 15)
        fix.setTitleColor(.label, for: .normal)
        fix.addTarget(self, action: #selector(fixTapped), for: .touchUpInside)
        for item in [label, scroller, fix] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroller.topAnchor.constraint(equalTo: label.bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            fix.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            fix.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            fix.widthAnchor.constraint(equalToConstant: 48),
            scroller.trailingAnchor.constraint(equalTo: fix.leadingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: scroller.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroller.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    func show(label text: String, items: [String], fixTitle: String?) {
        label.text = text
        fix.setTitle(fixTitle, for: .normal)
        fix.isHidden = fixTitle == nil
        while buttons.count < min(items.count, Self.maxShown) {
            let button = UIButton(type: .system)
            button.tag = buttons.count
            button.titleLabel?.font = .systemFont(ofSize: 20)
            button.setTitleColor(.label, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            button.addTarget(self, action: #selector(itemTapped), for: .touchUpInside)
            buttons.append(button)
            row.addArrangedSubview(button)
        }
        for (index, button) in buttons.enumerated() {
            let shown = index < items.count
            button.isHidden = !shown
            if shown {
                button.setTitle(items[index], for: .normal)
                button.titleLabel?.font = index == 0 ? .systemFont(ofSize: 20, weight: .semibold) : .systemFont(ofSize: 20)
            }
        }
        layoutIfNeeded()
        // A sentence wider than the row shows its end: that is where the typing is.
        let first = buttons.first
        let offset = first.flatMap { !$0.isHidden && $0.frame.width > scroller.bounds.width ? $0.frame.maxX - scroller.bounds.width : nil } ?? 0
        scroller.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
    }

    @objc private func itemTapped(_ sender: UIButton) { onTap?(sender.tag) }
    @objc private func fixTapped() { onFix?() }

    private static let maxShown = 40
}
