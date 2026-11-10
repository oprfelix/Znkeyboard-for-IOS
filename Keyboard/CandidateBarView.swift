import UIKit

/// Buttons answer at once, yet a drag that starts on one still scrolls.
class CandidateScroller: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// The pinyin above and a row of candidates, as on Android.
final class CandidateBarView: UIView, UIScrollViewDelegate {
    var onTap: ((Int) -> Void)?
    var onFix: (() -> Void)?
    var onExpand: (() -> Void)?
    var onPolish: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onOffer: (() -> Void)?
    var onDismissOffer: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onPhrases: (() -> Void)?
    /// Translate what was copied, there whether or not anything new was.
    var onRead: (() -> Void)?

    private let label = UILabel()
    private let scroller = CandidateScroller()
    private let fix = UIButton(type: .system)
    private let expand = UIButton(type: .system)
    private let divider = UIView()
    private var fixWidth: NSLayoutConstraint!
    private var expandShownUp: Bool?
    private var buttons: [UIButton] = []
    private var items: [String] = []
    private var selectedItem: Int?
    private var placed = 0
    private var rowEnd: CGFloat = 0
    private var placedSize = CGSize.zero
    private let tools = UIStackView()
    private let polish = UIButton(type: .system)
    private let translate = UIButton(type: .system)
    private let offer = UIButton(type: .system)
    private let offerClose = UIButton(type: .system)
    private let clipboardButton = UIButton(type: .system)
    private let phrasesButton = UIButton(type: .system)
    private let readButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingHead
        scroller.showsHorizontalScrollIndicator = false
        scroller.delegate = self
        scroller.delaysContentTouches = false
        scroller.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(itemTapped)))
        fixWidth = fix.widthAnchor.constraint(equalToConstant: 0)
        fixWidth.isActive = true
        fix.titleLabel?.font = .systemFont(ofSize: 15)
        fix.setTitleColor(.label, for: .normal)
        fix.addTarget(self, action: #selector(fixTapped), for: .touchUpInside)
        expand.tintColor = .label
        expand.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        divider.backgroundColor = .separator
        for item in [label, scroller, fix, divider, expand] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        for (button, title, symbol) in [(polish, "润色", "wand.and.stars"), (translate, "翻译", "translate")] {
            button.setTitle(title, for: .normal)
            styleTool(button)
            styleAI(button, symbol: symbol)
        }
        polish.addTarget(self, action: #selector(polishTapped), for: .touchUpInside)
        translate.addTarget(self, action: #selector(translateTapped), for: .touchUpInside)
        styleTool(offer)
        // Copied text waits for an answer, so this is the one solid button.
        offer.setTitleColor(.white, for: .normal)
        offer.backgroundColor = .systemBlue
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
        let icons = [(readButton, Self.readSymbol, #selector(readTapped), "翻译复制的外文"),
                     (clipboardButton, Self.clipboardSymbol, #selector(clipboardTapped), "剪贴板"),
                     (phrasesButton, Self.phrasesSymbol, #selector(phrasesTapped), "常用语")]
        for (button, symbol, action, name) in icons {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = name
            button.addTarget(self, action: action, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        // A long language name gives way before the icons do.
        translate.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translate.titleLabel?.lineBreakMode = .byTruncatingTail
        for item in [polish, translate, offer, offerClose, spacer, readButton, clipboardButton, phrasesButton] as [UIView] { tools.addArrangedSubview(item) }
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
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -8),
            scroller.topAnchor.constraint(equalTo: label.bottomAnchor),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            expand.trailingAnchor.constraint(equalTo: trailingAnchor),
            expand.centerYAnchor.constraint(equalTo: centerYAnchor),
            expand.widthAnchor.constraint(equalToConstant: 44),
            expand.heightAnchor.constraint(equalTo: heightAnchor),
            divider.trailingAnchor.constraint(equalTo: expand.leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            divider.heightAnchor.constraint(equalToConstant: 26),
            fix.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            fix.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            scroller.trailingAnchor.constraint(equalTo: fix.leadingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    func show(label text: String, items: [String], fixTitle: String?, expanded: Bool, selected: Int? = nil) {
        selectedItem = selected
        tools.isHidden = true
        label.isHidden = false
        scroller.isHidden = false
        label.text = text
        if fix.title(for: .normal) != fixTitle { fix.setTitle(fixTitle, for: .normal) }
        fix.isHidden = fixTitle == nil
        let width: CGFloat = fixTitle == nil ? 0 : 48
        if fixWidth.constant != width { fixWidth.constant = width }
        setExpand(hidden: items.isEmpty, up: expanded)
        self.items = items
        layoutIfNeeded()
        placeItems()
    }

    /// The 9-key keyboard spells in its own row, so the candidates take all of this one.
    var showsLabel = true {
        didSet { labelHeight.isActive = !showsLabel }
    }
    private lazy var labelHeight = label.heightAnchor.constraint(equalToConstant: 0)

    func clearLabel() { label.text = "" }

    /// The letter shows at once; the candidates follow when the engine has them.
    func appendToLabel(_ character: Character) {
        tools.isHidden = true
        label.isHidden = false
        label.text = (label.text ?? "") + String(character)
    }

    /// The small pinyin line sits over the candidates' column: a tap there picks the one below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Anywhere in the bar's height over the candidates reaches them, so a swipe that starts a
        // little above or below the words still scrolls them.
        if !scroller.isHidden, point.x < scroller.frame.maxX, self.point(inside: point, with: event),
           point.y < scroller.frame.minY || point.y >= scroller.frame.maxY {
            return super.hitTest(CGPoint(x: point.x, y: min(max(point.y, scroller.frame.minY + 1), scroller.frame.maxY - 1)), with: event)
        }
        return super.hitTest(point, with: event)
    }

    private func setExpand(hidden: Bool, up: Bool) {
        expand.isHidden = hidden
        divider.isHidden = hidden
        guard expandShownUp != up else { return }
        expandShownUp = up
        let symbol = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        expand.setImage(UIImage(systemName: up ? "chevron.up" : "chevron.down", withConfiguration: symbol), for: .normal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scroller.bounds.size != placedSize { placeItems() }
    }

    /// Lays the row out by hand, this runs on every key. Only what can be seen soon is placed.
    private func placeItems() {
        placedSize = scroller.bounds.size
        placed = 0
        rowEnd = 0
        placeMore(upTo: placedSize.width * Self.screensAhead)
        for index in placed..<max(placed, buttons.count) { buttons[index].isHidden = true }
        // A sentence wider than the row shows its end: that is where the typing is.
        let first = placed > 0 ? buttons[0].frame.maxX : 0
        let offset = first > placedSize.width ? first - placedSize.width : 0
        scroller.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
    }

    private func placeMore(upTo end: CGFloat) {
        let limit = min(items.count, Self.maxShown)
        while placed < limit, rowEnd < end {
            let button = button(at: placed)
            let text = items[placed]
            let font = placed == 0 ? Self.firstFont : Self.itemFont
            if button.title(for: .normal) != text { button.setTitle(text, for: .normal) }
            if button.titleLabel?.font !== font { button.titleLabel?.font = font }
            let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + Self.itemPadding
            let selected = placed == selectedItem
            let inset = selected ? Self.selectedInset : 0
            button.frame = CGRect(x: rowEnd, y: inset, width: width, height: placedSize.height - 2 * inset)
            button.backgroundColor = selected ? KeyboardKeysView.letterKey : .clear
            button.isHidden = false
            rowEnd += width + 2
            placed += 1
        }
        let more = placed < limit ? placedSize.width : 0
        scroller.contentSize = CGSize(width: rowEnd + more, height: placedSize.height)
    }

    private func button(at index: Int) -> UIButton {
        if index < buttons.count { return buttons[index] }
        let button = UIButton(type: .custom)
        button.tag = index
        button.setTitleColor(.label, for: .normal)
        // The row takes the touches, or a quick flick that lands on a word would not scroll it.
        button.isUserInteractionEnabled = false
        button.layer.cornerRadius = 8
        buttons.append(button)
        scroller.addSubview(button)
        return button
    }

    func scrollViewDidScroll(_ view: UIScrollView) {
        placeMore(upTo: view.contentOffset.x + placedSize.width * Self.screensAhead)
    }

    /// The toolbar when nothing is being typed; [offering] asks whether to translate what was copied.
    func showTools(languageName: String, offering: Bool, saved: SavedTextPanelView.Tab? = nil) {
        // The icon of the open panel stands out; tapping it again closes the panel.
        for (button, tab) in [(clipboardButton, SavedTextPanelView.Tab.clipboard), (phrasesButton, .phrases)] {
            button.backgroundColor = saved == tab ? KeyboardKeysView.letterKey : .clear
            button.layer.cornerRadius = 8
        }
        label.isHidden = true
        scroller.isHidden = true
        fix.isHidden = true
        setExpand(hidden: true, up: false)
        tools.isHidden = false
        translate.setTitle("翻译为\(languageName)", for: .normal)
        polish.isHidden = offering
        translate.isHidden = offering
        offer.isHidden = !offering
        offerClose.isHidden = !offering
        offer.setTitle("翻译刚复制的外文", for: .normal)
        // The offer already does what this icon does.
        readButton.isHidden = offering
    }

    private func styleTool(_ button: UIButton) {
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = KeyboardKeysView.letterKey
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    }

    /// The AI tools are tinted, so they don't read as keys that type something.
    private func styleAI(_ button: UIButton, symbol: String) {
        button.tintColor = .systemBlue
        button.setTitleColor(.systemBlue, for: .normal)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)), for: .normal)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 14)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
    }

    @objc private func polishTapped() { onPolish?() }
    @objc private func translateTapped() { onTranslate?() }
    @objc private func offerTapped() { onOffer?() }
    @objc private func offerCloseTapped() { onDismissOffer?() }
    @objc private func clipboardTapped() { onClipboard?() }
    @objc private func phrasesTapped() { onPhrases?() }
    @objc private func readTapped() { onRead?() }

    static let clipboardSymbol = "doc.on.clipboard"
    static let phrasesSymbol = "text.bubble"
    static let readSymbol = "character.bubble"
    @objc private func itemTapped(_ tap: UITapGestureRecognizer) {
        let x = tap.location(in: scroller).x
        if let index = buttons.prefix(placed).firstIndex(where: { $0.frame.minX <= x && x < $0.frame.maxX + 2 }) { onTap?(index) }
    }

    @objc private func fixTapped() { onFix?() }
    @objc private func expandTapped() { onExpand?() }

    private static let maxShown = 40
    private static let selectedInset: CGFloat = 7
    private static let screensAhead: CGFloat = 2
    private static let itemPadding: CGFloat = 20
    private static let itemFont = UIFont.systemFont(ofSize: 20)
    private static let firstFont = UIFont.systemFont(ofSize: 20, weight: .semibold)
}
