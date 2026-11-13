import PinyinCore
import UIKit

/// Buttons answer at once, yet a drag that starts on one still scrolls.
class CandidateScroller: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    /// Where a finger came down, and when it left: the row's taps are settled on the first.
    var onTouchDown: ((CGPoint) -> Void)?
    var onTouchUp: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first { onTouchDown?(touch.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onTouchUp?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        onTouchUp?()
    }
}

/// An icon that answers past its drawn edge: the bar's full height, and half the gap to each
/// neighbour, so a tap a little off still lands.
final class ToolIconButton: UIButton {
    var hitOutset = UIEdgeInsets(top: -7, left: -5, bottom: -7, right: -5)

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: hitOutset).contains(point)
    }
}

/// The pinyin above and a row of candidates, as on Android.
final class CandidateBarView: UIView, UIScrollViewDelegate {
    var onTap: ((Int) -> Void)?
    var onFix: (() -> Void)?
    var onExpand: (() -> Void)?
    var onTranslate: (() -> Void)?
    /// The language chip inside the translate pill: picks where translate goes.
    var onLanguage: (() -> Void)?
    var onOffer: (() -> Void)?
    var onDismissOffer: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onPhrases: (() -> Void)?
    /// How translate and reading what was copied work.
    var onHelp: (() -> Void)?

    private let label = UILabel()
    private let scroller = CandidateScroller()
    private let fix = UIButton(type: .system)
    private let expand = UIButton(type: .system)
    private let divider = UIView()
    private var fixWidth: NSLayoutConstraint!
    /// 文A beside the candidates, as on Android: translates what is being typed.
    private let quickTranslate = ToolIconButton(type: .system)
    private var quickTranslateWidth: NSLayoutConstraint!
    /// The 文A beside the candidates: put the first one in, then translate.
    var onQuickTranslate: (() -> Void)?
    private var expandShownUp: Bool?
    private var buttons: [UIButton] = []
    private var items: [String] = []
    private var selectedItem: Int?
    private var placed = 0
    private var rowEnd: CGFloat = 0
    private var placedSize = CGSize.zero
    private let tools = UIStackView()
    /// The top layer: 翻译 with a slanted edge that casts a shadow on the language under it.
    private let translate = SlantedButton(type: .system)
    /// 翻译 and the language chip share one capsule, 翻译 on top, as on Android.
    private let translatePill = UIView()
    private let languageChip = UIButton(type: .system)
    private let offer = UIButton(type: .system)
    private let offerClose = UIButton(type: .system)
    private let clipboardButton = ToolIconButton(type: .system)
    private let phrasesButton = ToolIconButton(type: .system)
    private let helpButton = ToolIconButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingHead
        scroller.showsHorizontalScrollIndicator = false
        scroller.delegate = self
        scroller.delaysContentTouches = false
        scroller.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(itemTapped)))
        scroller.onTouchDown = { [weak self] point in self?.pressItem(at: point) }
        // The tap is handled as the finger lifts; the shading goes a moment later, so it is seen.
        scroller.onTouchUp = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.releaseItem() }
        }
        fixWidth = fix.widthAnchor.constraint(equalToConstant: 0)
        fixWidth.isActive = true
        // A plain 译 in a thin box, in the text's colour like the ▾ beside it: a blue icon stood out.
        quickTranslate.setImage(Self.yiGlyph(), for: .normal)
        quickTranslate.tintColor = .label
        quickTranslate.accessibilityLabel = "翻译"
        quickTranslate.addTarget(self, action: #selector(quickTranslateTapped), for: .touchUpInside)
        quickTranslate.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quickTranslate)
        quickTranslateWidth = quickTranslate.widthAnchor.constraint(equalToConstant: 0)
        quickTranslateWidth.isActive = true
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
        translate.setTitle("翻译", for: .normal)
        styleTool(translate)
        styleAI(translate, symbol: "translate")
        translate.backgroundColor = .clear
        translate.layer.cornerRadius = 0
        translate.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        translate.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 12 + SlantedButton.slant)
        translate.addTarget(self, action: #selector(translateTapped), for: .touchUpInside)
        // The lower layer: the language shows from under 翻译's slanted edge.
        translatePill.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.1)
        // A capsule: its end follows the keyboard's big top corner instead of fighting it.
        translatePill.layer.cornerRadius = 17
        translatePill.layer.cornerCurve = .continuous
        translatePill.clipsToBounds = true
        // Quieter than 翻译: it sets where translate goes, it doesn't translate.
        languageChip.titleLabel?.font = .systemFont(ofSize: 14)
        languageChip.setTitleColor(.systemBlue, for: .normal)
        languageChip.tintColor = .systemBlue
        languageChip.semanticContentAttribute = .forceRightToLeft
        languageChip.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 12)
        languageChip.imageEdgeInsets = UIEdgeInsets(top: 0, left: 3, bottom: 0, right: -3)
        languageChip.accessibilityHint = "选择翻译语言"
        languageChip.addTarget(self, action: #selector(languageTapped), for: .touchUpInside)
        // The chip first, so 翻译 and its shadow lie over it.
        for item in [languageChip, translate] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            translatePill.addSubview(item)
        }
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
        let icons = [(clipboardButton, Self.clipboardSymbol, #selector(clipboardTapped), "剪贴板"),
                     (phrasesButton, Self.phrasesSymbol, #selector(phrasesTapped), "常用语"),
                     (helpButton, Self.helpSymbol, #selector(helpTapped), "使用说明")]
        for (button, symbol, action, name) in icons {
            // Drawn to one height, so a tall clipboard and a wide bubble read as the same size.
            button.setImage(Self.icon(symbol), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = name
            button.addTarget(self, action: action, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }
        // The last icon reaches the bar's edge.
        helpButton.hitOutset.right = -8
        // A long language name gives way before the icons do.
        translate.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translate.titleLabel?.lineBreakMode = .byTruncatingTail
        languageChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        for item in [translatePill, offer, offerClose, spacer, clipboardButton, phrasesButton, helpButton] as [UIView] { tools.addArrangedSubview(item) }
        addSubview(tools)
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tools.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // The whole bar's height, so the icons' wider hit areas are inside the stack too.
            tools.topAnchor.constraint(equalTo: topAnchor),
            tools.bottomAnchor.constraint(equalTo: bottomAnchor),
            translatePill.heightAnchor.constraint(equalToConstant: 34),
            translate.leadingAnchor.constraint(equalTo: translatePill.leadingAnchor),
            translate.topAnchor.constraint(equalTo: translatePill.topAnchor),
            translate.bottomAnchor.constraint(equalTo: translatePill.bottomAnchor),
            languageChip.leadingAnchor.constraint(equalTo: translate.trailingAnchor),
            languageChip.trailingAnchor.constraint(equalTo: translatePill.trailingAnchor),
            languageChip.topAnchor.constraint(equalTo: translatePill.topAnchor),
            languageChip.bottomAnchor.constraint(equalTo: translatePill.bottomAnchor),
            // As wide as the longest name, so changing language doesn't move anything.
            languageChip.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.chipWidth),
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
            quickTranslate.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            quickTranslate.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            quickTranslate.heightAnchor.constraint(equalToConstant: 34),
            fix.trailingAnchor.constraint(equalTo: quickTranslate.leadingAnchor, constant: -2),
            fix.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),
            scroller.trailingAnchor.constraint(equalTo: fix.leadingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    /// [translatable]: the 文A shows beside the candidates.
    func show(label text: String, items: [String], fixTitle: String?, expanded: Bool, selected: Int? = nil, translatable: Bool = false) {
        selectedItem = selected
        quickTranslate.isHidden = !translatable
        let translateWidth: CGFloat = translatable ? 28 : 0
        if quickTranslateWidth.constant != translateWidth { quickTranslateWidth.constant = translateWidth }
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

    /// The small line over the candidates, only for a hint: the pinyin itself shows in the text.
    var showsLabel = true {
        didSet { labelHeight.isActive = !showsLabel }
    }
    private lazy var labelHeight = label.heightAnchor.constraint(equalToConstant: 0)

    /// Typing has begun: the tools give way at once; the candidates follow when the engine has them.
    func beginComposing() {
        tools.isHidden = true
        label.text = ""
    }

    /// The small hint line sits over the candidates' column: a tap there picks the one below.
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
            // At least a finger wide: a single character is no smaller a target than a key.
            let width = max(ceil((text as NSString).size(withAttributes: [.font: font]).width) + Self.itemPadding, Self.minItemWidth)
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
    /// [hasText]: something to translate is there; [selection]: only the selected text goes.
    func showTools(languageName: String, offering: Bool, saved: SavedTextPanelView.Tab? = nil, choosingLanguage: Bool = false,
                   hasText: Bool = true, selection: Bool = false) {
        // The icon of the open panel stands out; tapping it again closes the panel.
        for (button, tab) in [(clipboardButton, SavedTextPanelView.Tab.clipboard), (phrasesButton, .phrases), (helpButton, .help)] {
            button.backgroundColor = saved == tab ? KeyboardKeysView.letterKey : .clear
            button.layer.cornerRadius = 8
        }
        label.isHidden = true
        scroller.isHidden = true
        fix.isHidden = true
        setExpand(hidden: true, up: false)
        tools.isHidden = false
        quickTranslate.isHidden = true
        languageChip.setTitle(languageName, for: .normal)
        languageChip.setImage(UIImage(systemName: choosingLanguage ? "chevron.up" : "chevron.down",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)), for: .normal)
        translatePill.isHidden = offering
        translate.setTitle(selection ? "翻译选中" : "翻译", for: .normal)
        // Grey with nothing to translate; a tap still says why.
        translate.alpha = hasText ? 1 : 0.4
        translate.accessibilityLabel = (selection ? "翻译选中的文字成" : "翻译成") + languageName
        languageChip.accessibilityLabel = "更换翻译语言，当前\(languageName)"
        offer.isHidden = !offering
        offerClose.isHidden = !offering
        offer.setTitle("翻译刚复制的外文", for: .normal)
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

    @objc private func translateTapped() { onTranslate?() }
    @objc private func quickTranslateTapped() { onQuickTranslate?() }
    @objc private func languageTapped() { onLanguage?() }
    @objc private func offerTapped() { onOffer?() }
    @objc private func offerCloseTapped() { onDismissOffer?() }
    @objc private func clipboardTapped() { onClipboard?() }
    @objc private func phrasesTapped() { onPhrases?() }
    @objc private func helpTapped() { onHelp?() }

    /// The chip's width for the longest language name, chevron and padding included.
    private static let chipWidth: CGFloat = {
        let font = UIFont.systemFont(ofSize: 14)
        let widest = TranslateLanguage.all.map { ($0.chineseName as NSString).size(withAttributes: [.font: font]).width }.max() ?? 56
        return ceil(widest) + 10 + 12 + 13
    }()

    /// 「译」 in a thin rounded square, drawn as a template so it takes the label colour.
    static func yiGlyph() -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let box = UIBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 20, height: 20), cornerRadius: 5)
            box.lineWidth = 1.3
            UIColor.black.setStroke()
            box.stroke()
            let text = "译" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: UIColor.black]
            let t = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2), withAttributes: attrs)
        }.withRenderingMode(.alwaysTemplate)
    }

    static let clipboardSymbol = "doc.on.clipboard"
    static let phrasesSymbol = "text.bubble"
    static let helpSymbol = "questionmark.circle"
    private static let iconHeight: CGFloat = 20

    /// The symbol scaled to [iconHeight], its stroke kept the same weight as the others'.
    private static func icon(_ name: String) -> UIImage? {
        guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)) else { return nil }
        let size = CGSize(width: symbol.size.width * iconHeight / symbol.size.height, height: iconHeight)
        return UIGraphicsImageRenderer(size: size).image { _ in symbol.draw(in: CGRect(origin: .zero, size: size)) }
            .withRenderingMode(.alwaysTemplate)
    }
    /// The word under the finger as it came down. Candidates are worked out in the background and
    /// can change before the finger lifts; the word the user aimed at is the one they saw.
    private var pressedText: String?
    private var pressedButton: UIButton?

    private func itemIndex(at x: CGFloat) -> Int? {
        buttons.prefix(placed).firstIndex { $0.frame.minX <= x && x < $0.frame.maxX + 2 }
    }

    private func pressItem(at point: CGPoint) {
        releaseItem()
        guard let index = itemIndex(at: point.x), index < items.count else { return }
        pressedText = items[index]
        let button = buttons[index]
        if index != selectedItem {
            button.backgroundColor = KeyboardKeysView.pressedKey.withAlphaComponent(0.55)
            pressedButton = button
        }
    }

    private func releaseItem() {
        if let button = pressedButton, button.tag != selectedItem { button.backgroundColor = .clear }
        pressedButton = nil
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pressedText = nil
        releaseItem()
    }

    @objc private func itemTapped(_ tap: UITapGestureRecognizer) {
        let aimed = pressedText.flatMap { text in items.firstIndex(of: text) }
        pressedText = nil
        if let index = aimed ?? itemIndex(at: tap.location(in: scroller).x) { onTap?(index) }
    }

    @objc private func fixTapped() { onFix?() }
    @objc private func expandTapped() { onExpand?() }

    private static let maxShown = 40
    private static let selectedInset: CGFloat = 7
    private static let screensAhead: CGFloat = 2
    private static let itemPadding: CGFloat = 24
    private static let minItemWidth: CGFloat = 52
    private static let itemFont = UIFont.systemFont(ofSize: 20)
    private static let firstFont = UIFont.systemFont(ofSize: 20, weight: .semibold)
}

/// 翻译 as the top layer of the translate pill: a fill whose right edge slants like "/", with a
/// soft shadow on that edge, so the language beside it reads as the layer underneath.
final class SlantedButton: UIButton {
    static let slant: CGFloat = 10
    private let shape = CAShapeLayer()
    /// Opaque, so the shadow falls on the lower layer and not through this one.
    private static let fill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.14, green: 0.27, blue: 0.45, alpha: 1)
        : UIColor(red: 0.80, green: 0.89, blue: 1.0, alpha: 1) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOffset = CGSize(width: 2, height: 0)
        shape.shadowRadius = 3
        layer.insertSublayer(shape, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // UIButton adds its image view's layer at the bottom; the fill goes back under it.
        if layer.sublayers?.first !== shape { layer.insertSublayer(shape, at: 0) }
        let w = bounds.width, h = bounds.height
        let path = UIBezierPath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w - Self.slant, y: h))
        path.addLine(to: CGPoint(x: 0, y: h))
        path.close()
        shape.frame = bounds
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        shape.fillColor = Self.fill.resolvedColor(with: traitCollection).cgColor
        shape.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.5 : 0.25
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setNeedsLayout()
    }
}
