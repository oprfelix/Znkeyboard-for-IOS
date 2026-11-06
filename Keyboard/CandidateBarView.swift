import UIKit

/// The pinyin above and a row of candidates, as on Android.
final class CandidateBarView: UIView {
    var onTap: ((Int) -> Void)?
    var onFix: (() -> Void)?
    var onPolish: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onOffer: (() -> Void)?
    var onDismissOffer: (() -> Void)?

    private let label = UILabel()
    private let scroller = UIScrollView()
    private let row = UIStackView()
    private let fix = UIButton(type: .system)
    private var buttons: [UIButton] = []
    private let tools = UIStackView()
    private let polish = UIButton(type: .system)
    private let translate = UIButton(type: .system)
    private let offer = UIButton(type: .system)
    private let offerClose = UIButton(type: .system)

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
        for (button, title) in [(polish, "润色"), (translate, "翻译")] {
            button.setTitle(title, for: .normal)
            styleTool(button)
        }
        polish.addTarget(self, action: #selector(polishTapped), for: .touchUpInside)
        translate.addTarget(self, action: #selector(translateTapped), for: .touchUpInside)
        styleTool(offer)
        offer.contentHorizontalAlignment = .leading
        offer.titleLabel?.lineBreakMode = .byTruncatingTail
        offer.addTarget(self, action: #selector(offerTapped), for: .touchUpInside)
        offerClose.setTitle("✕", for: .normal)
        styleTool(offerClose)
        offerClose.addTarget(self, action: #selector(offerCloseTapped), for: .touchUpInside)
        tools.axis = .horizontal
        tools.spacing = 8
        tools.alignment = .center
        tools.isHidden = true
        tools.translatesAutoresizingMaskIntoConstraints = false
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for item in [polish, translate, offer, offerClose, spacer] as [UIView] { tools.addArrangedSubview(item) }
        addSubview(tools)
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tools.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tools.centerYAnchor.constraint(equalTo: centerYAnchor),
            tools.heightAnchor.constraint(equalToConstant: 34),
            polish.heightAnchor.constraint(equalToConstant: 34),
            translate.heightAnchor.constraint(equalToConstant: 34),
            offer.heightAnchor.constraint(equalToConstant: 34),
            offerClose.heightAnchor.constraint(equalToConstant: 34),
            offerClose.widthAnchor.constraint(equalToConstant: 40),
        ])
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
        tools.isHidden = true
        label.isHidden = false
        scroller.isHidden = false
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

    /// The toolbar when nothing is being typed; [offering] asks whether to translate what was copied.
    func showTools(languageName: String, offering: Bool) {
        label.isHidden = true
        scroller.isHidden = true
        fix.isHidden = true
        tools.isHidden = false
        translate.setTitle("翻译为\(languageName)", for: .normal)
        polish.isHidden = offering
        translate.isHidden = offering
        offer.isHidden = !offering
        offerClose.isHidden = !offering
        offer.setTitle("翻译复制的内容", for: .normal)
    }

    private func styleTool(_ button: UIButton) {
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    }

    @objc private func polishTapped() { onPolish?() }
    @objc private func translateTapped() { onTranslate?() }
    @objc private func offerTapped() { onOffer?() }
    @objc private func offerCloseTapped() { onDismissOffer?() }
    @objc private func itemTapped(_ sender: UIButton) { onTap?(sender.tag) }
    @objc private func fixTapped() { onFix?() }

    private static let maxShown = 40
}
