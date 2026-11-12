import PinyinCore
import UIKit

/// The languages translate can go to, in the place of the keys: the language chip on the bar
/// opens it, and a tap picks one and closes it, as on Android.
final class LanguagePanelView: UIView {
    var onPick: ((TranslateLanguage) -> Void)?

    private let title = UILabel()
    private var buttons: [UIButton] = []
    private static let columns = 4
    private static let inset: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let titleHeight: CGFloat = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.text = "翻译成"
        title.font = .systemFont(ofSize: 13)
        title.textColor = .secondaryLabel
        addSubview(title)
        for (index, language) in TranslateLanguage.all.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(language.chineseName, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.8
            button.layer.cornerRadius = 8
            button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
            buttons.append(button)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    /// Marks [selected] as the one in use.
    func show(selected: TranslateLanguage) {
        for (button, language) in zip(buttons, TranslateLanguage.all) {
            let picked = language == selected
            button.backgroundColor = picked ? .systemBlue : KeyboardKeysView.letterKey
            button.setTitleColor(picked ? .white : .label, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: picked ? .semibold : .regular)
            button.accessibilityTraits = picked ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = Self.inset, gap = Self.gap, columns = Self.columns
        title.frame = CGRect(x: inset + 4, y: 0, width: bounds.width - 2 * inset, height: Self.titleHeight)
        let rows = (buttons.count + columns - 1) / columns
        let width = (bounds.width - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let height = min(46, (bounds.height - Self.titleHeight - inset - CGFloat(rows - 1) * gap) / CGFloat(rows))
        for (index, button) in buttons.enumerated() {
            let row = index / columns, column = index % columns
            button.frame = CGRect(x: inset + CGFloat(column) * (width + gap),
                                  y: Self.titleHeight + CGFloat(row) * (height + gap),
                                  width: width, height: height)
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        onPick?(TranslateLanguage.all[sender.tag])
    }
}
