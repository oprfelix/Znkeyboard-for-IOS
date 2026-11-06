import UIKit

/// A translation or a polished text above the keys, so the keyboard stays up.
final class ReadingCardView: UIView {
    var onClose: (() -> Void)?
    var onAction: (() -> Void)?

    private let title = UILabel()
    private let close = UIButton(type: .system)
    private let body = UITextView()
    private let action = UIButton(type: .system)
    private let loading = UIActivityIndicatorView(style: .medium)
    private var bodyHeight: NSLayoutConstraint!
    private static let topInset: CGFloat = 8
    private static let headerHeight: CGFloat = 30
    private static let sideInset: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabel
        close.setTitle("✕", for: .normal)
        close.setTitleColor(.secondaryLabel, for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        body.font = .systemFont(ofSize: 16)
        body.backgroundColor = .clear
        body.isEditable = false
        body.isSelectable = false
        body.textContainerInset = .zero
        body.textContainer.lineFragmentPadding = 0
        action.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        action.setTitleColor(.white, for: .normal)
        action.backgroundColor = .systemBlue
        action.layer.cornerRadius = 10
        action.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        action.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        for item in [title, close, body, action, loading] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        bodyHeight = body.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            // The header is as tall as the button, so the button clears the keyboard's top edge.
            action.topAnchor.constraint(equalTo: topAnchor, constant: Self.topInset),
            action.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            action.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: action.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            close.centerYAnchor.constraint(equalTo: action.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 36),
            loading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            loading.topAnchor.constraint(equalTo: action.bottomAnchor, constant: 8),
            body.topAnchor.constraint(equalTo: action.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            bodyHeight,
        ])
        // Yields to the zero height the keyboard gives the card while it is hidden.
        let bottom = body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        bottom.priority = .defaultHigh
        bottom.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    func showWorking(title text: String) {
        title.text = text
        body.text = ""
        action.isHidden = true
        loading.startAnimating()
        bodyHeight.constant = 24
    }

    /// About six lines at most; longer text scrolls.
    func showResult(title text: String, body value: String, actionTitle: String?) {
        title.text = text
        body.text = value
        loading.stopAnimating()
        action.setTitle(actionTitle, for: .normal)
        action.isHidden = actionTitle == nil
        let width = max(bounds.width, UIScreen.main.bounds.width) - 2 * Self.sideInset
        let needed = body.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        bodyHeight.constant = min(ceil(needed), 124)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func actionTapped() { onAction?() }
}
