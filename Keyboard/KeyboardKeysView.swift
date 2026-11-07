import AudioToolbox
import PinyinCore
import QuartzCore
import UIKit

/// The keys, drawn as plain views; a touch goes to the nearest key, so there are no dead gaps.
final class KeyboardKeysView: UIView {
    enum Key {
        case text(String), literal(String), space, backspace, returnKey, language, nextKeyboard
    }

    private enum Action {
        case key(Key), shift, symbols, moreSymbols, globe
    }

    private final class KeyCell: UILabel {
        var action: Action = .key(.space)
        var icon: UIImageView?
        var corner: UILabel?

        override func layoutSubviews() {
            super.layoutSubviews()
            icon?.center = CGPoint(x: bounds.midX, y: bounds.midY)
            if let corner {
                corner.sizeToFit()
                corner.frame.origin = CGPoint(x: bounds.maxX - corner.bounds.width - 8, y: bounds.maxY - corner.bounds.height - 4)
            }
        }

        var isLetterOrSpace: Bool {
            switch action {
            case .key(.text), .key(.literal), .key(.space): return true
            default: return false
            }
        }
    }

    private typealias Press = (touch: UITouch, cell: KeyCell)

    // A row of letters measures what the system keyboard's does; the number row is shorter.
    private static let rowHeight: CGFloat = 54
    private static let numberRowHeight: CGFloat = 44
    private static let rowGap: CGFloat = 11
    private static let hitOverhang: CGFloat = 4
    private static let fastDisplaySeconds: CFTimeInterval = 3
    private static let topInset: CGFloat = 4
    private static let bottomInset: CGFloat = 2
    private static let gap: CGFloat = 6
    private static let sideMargin: CGFloat = 6.5
    private static let cornerRadius: CGFloat = 9
    // In widths of a letter key, measured on the system keyboard.
    private static let sideKey: CGFloat = 1.35
    private static let bottomKey: CGFloat = 1.3
    private static let returnKey: CGFloat = 2.8
    private static let fills: CGFloat = 0
    private static let symbolKey: CGFloat = 1.22
    private static let wideSymbolKey: CGFloat = 1.47
    /// Sampled from the system keyboard, which fills every key alike in both appearances.
    static let letterKey = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 61.0 / 255, alpha: 1) : .white }

    var onKey: ((Key) -> Void)?
    var onGlobe: ((UIView, UIEvent) -> Void)?
    /// Haptics need full access; without it the generator does nothing.
    var haptics: UIImpactFeedbackGenerator?
    var showsGlobe = true { didSet { if showsGlobe != oldValue { rebuild() } } }
    var showsNumberRow = false { didSet { if showsNumberRow != oldValue { rebuild() } } }
    var showsPopup = true
    /// A letter typed: its text, how the touch fitted each key, and the learner's record of it.
    var onLetter: ((String, [Float]?, TypingLearner.Sample?) -> Void)?
    var typing: AdaptiveTyping?
    var playsSound = false
    /// How many rows of keys there are now.
    var preferredHeight: CGFloat {
        4 * Self.rowHeight + (showsNumberRow ? Self.numberRowHeight : 0) + Self.topInset + Self.bottomInset - Self.rowGap
    }

    private let popup = UILabel()
    private var cells: [KeyCell] = []
    private var rows: [[(cell: KeyCell, weight: CGFloat)]] = []
    private var shifted = false
    private var symbols = false
    private var moreSymbols = false
    private var chinese = true
    private var repeatTimer: Timer?
    private var presses: [Press] = []
    private var fastUntil: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var letterCells = [KeyCell?](repeating: nil, count: 26)
    private var geometry: KeyGeometry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        popup.textAlignment = .center
        popup.font = .systemFont(ofSize: 30)
        popup.layer.cornerRadius = 8
        popup.layer.masksToBounds = true
        popup.isHidden = true
        addSubview(popup)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { rebuild() }
    }

    /// One-shot capitals, for the start of an English sentence.
    func setShifted(_ value: Bool) {
        if shifted != value {
            shifted = value
            rebuild()
        }
    }

    func setChinese(_ value: Bool) {
        typing?.chinese = value
        if chinese != value {
            chinese = value
            rebuild()
        }
    }

    private func letters(_ text: String) -> [(String, Action, CGFloat)] {
        text.map { character in
            let shown = shifted ? String(character).uppercased() : String(character)
            return (shown, .key(.text(shown)), 1)
        }
    }

    private func rebuild() {
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        var layout: [[(String, Action, CGFloat)]]
        if symbols {
            layout = symbolRows()
        } else {
            layout = showsNumberRow ? ["1234567890".map { (String($0), .key(.text(String($0))), 1) }] : []
            layout += [
                letters("qwertyuiop"),
                letters("asdfghjkl"),
                [("", .shift, Self.sideKey)] + letters("zxcvbnm") + [("", .key(.backspace), Self.sideKey)],
            ]
        }
        var bottom: [(String, Action, CGFloat)] = symbols
            ? [(chinese ? "拼音" : "ABC", .symbols, Self.returnKey)]
            : [("123", .symbols, Self.bottomKey), (chinese ? "中" : "英", .key(.language), Self.bottomKey)]
        if showsGlobe { bottom.append(("", .globe, Self.bottomKey)) }
        bottom += [(chinese ? "" : "space", .key(.space), Self.fills), ("", .key(.returnKey), Self.returnKey)]
        layout.append(bottom)
        letterCells = [KeyCell?](repeating: nil, count: 26)
        geometry = nil
        let background = Self.letterKey.resolvedColor(with: traitCollection).cgColor
        rows = layout.map { row in
            row.map { title, action, weight in
                let cell = KeyCell()
                cell.text = title
                cell.textAlignment = .center
                cell.font = font(for: title, action)
                cell.textColor = .label
                cell.isUserInteractionEnabled = false
                cell.layer.cornerRadius = Self.cornerRadius
                cell.layer.backgroundColor = background
                cell.action = action
                if !symbols, let letter = Self.letterIndex(cell) { letterCells[letter] = cell }
                if let symbol = symbol(for: action) {
                    let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Self.iconConfiguration))
                    icon.tintColor = .label
                    cell.addSubview(icon)
                    cell.icon = icon
                }
                if case .key(.space) = action, chinese {
                    let corner = UILabel()
                    corner.text = "拼"
                    corner.font = .systemFont(ofSize: 13)
                    corner.textColor = .secondaryLabel
                    cell.addSubview(corner)
                    cell.corner = corner
                }
                addSubview(cell)
                cells.append(cell)
                return (cell, weight)
            }
        }
        setNeedsLayout()
    }

    private func keys(_ text: String, weight: CGFloat = 1) -> [(String, Action, CGFloat)] {
        text.map { (String($0), .key(.text(String($0))), weight) }
    }

    /// Laid out as on the system keyboard, whose Chinese and English pages differ.
    private func symbolRows() -> [[(String, Action, CGFloat)]] {
        let backspace: (String, Action, CGFloat) = ("", .key(.backspace), Self.sideKey)
        if moreSymbols {
            return [
                keys("【】{}#%^*+="),
                keys(chinese ? "_—\\|~《》$&·" : "_\\|~<>€£¥•"),
                [("123", .moreSymbols, Self.sideKey)] + keys("…，?!'\"", weight: Self.symbolKey) + [backspace],
            ]
        }
        guard chinese else {
            return [
                keys("1234567890"),
                keys("-/:;()$&@\""),
                [("#+=", .moreSymbols, Self.sideKey), (".", .key(.literal(".")), Self.wideSymbolKey)]
                    + keys(",?!'", weight: Self.wideSymbolKey) + [backspace],
            ]
        }
        return [
            keys("1234567890"),
            keys("-/:;()¥@“”"),
            [("#+=", .moreSymbols, Self.sideKey)] + keys("。，、?!", weight: Self.symbolKey)
                + [(".", .key(.literal(".")), Self.symbolKey), backspace],
        ]
    }

    private static let iconConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)

    private func symbol(for action: Action) -> String? {
        switch action {
        case .shift: return shifted ? "shift.fill" : "shift"
        case .key(.backspace): return "delete.left"
        case .key(.returnKey): return "return"
        case .globe: return "globe"
        default: return nil
        }
    }

    private func font(for title: String, _ action: Action) -> UIFont {
        if case .moreSymbols = action, title.count == 3, title != "123" { return .systemFont(ofSize: 15) }
        switch action {
        case .key(.text), .key(.literal): break
        default: return .systemFont(ofSize: 18)
        }
        return .systemFont(ofSize: symbols ? 23 : 25)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only the letter keyboard has the fifth row; the others share its full height.
        let numberRow = rows.count == 5 ? Self.numberRowHeight : 0
        let fullRows = CGFloat(max(rows.count - (numberRow > 0 ? 1 : 0), 1))
        let rowHeight = (bounds.height - Self.topInset - Self.bottomInset + Self.rowGap - numberRow) / fullRows
        var y = Self.topInset
        let unit = (bounds.width - 2 * Self.sideMargin - 9 * Self.gap) / 10
        for (r, row) in rows.enumerated() {
            let height = r == 0 && numberRow > 0 ? numberRow : rowHeight
            place(row, y: y, height: height - Self.rowGap, unit: unit, isBottom: r == rows.count - 1)
            y += height
        }
        updateGeometry(pitchX: unit + Self.gap, pitchY: rowHeight)
    }

    /// The bottom row fills the width around the space bar; another row with wider keys at its
    /// ends pins them to the sides; the rest is centred.
    private func place(_ row: [(cell: KeyCell, weight: CGFloat)], y: CGFloat, height: CGFloat, unit: CGFloat, isBottom: Bool) {
        func put(_ cell: KeyCell, _ x: CGFloat, _ width: CGFloat) {
            cell.frame = CGRect(x: x, y: y, width: width, height: height)
        }
        let span = bounds.width - 2 * Self.sideMargin
        let gaps = CGFloat(row.count - 1) * Self.gap
        var x = Self.sideMargin
        if isBottom {
            let fixed = row.reduce(CGFloat(0)) { $0 + $1.weight * unit }
            for (cell, weight) in row {
                let width = weight == Self.fills ? span - fixed - gaps : weight * unit
                put(cell, x, width)
                x += width + Self.gap
            }
            return
        }
        var middle = row[...]
        if let first = row.first, let last = row.last, first.weight == Self.sideKey {
            put(first.cell, x, first.weight * unit)
            put(last.cell, bounds.width - Self.sideMargin - last.weight * unit, last.weight * unit)
            middle = row[1..<(row.count - 1)]
        }
        let width = middle.reduce(CGFloat(0)) { $0 + $1.weight * unit } + CGFloat(middle.count - 1) * Self.gap
        x = (bounds.width - width) / 2
        for (cell, weight) in middle {
            put(cell, x, weight * unit)
            x += weight * unit + Self.gap
        }
    }

    /// Only a letter key, so the digits of the number row and "space" don't count.
    private static func letterIndex(_ cell: KeyCell) -> Int? {
        guard case .key(.text) = cell.action, let scalar = cell.text?.lowercased().utf8.first,
              cell.text?.count == 1, scalar >= 97, scalar <= 122 else { return nil }
        return Int(scalar) - 97
    }

    private func updateGeometry(pitchX: CGFloat, pitchY: CGFloat) {
        var centersX = [Float](repeating: 0, count: 26)
        var centersY = [Float](repeating: 0, count: 26)
        for (letter, cell) in letterCells.enumerated() {
            guard let cell else {
                geometry = nil
                return
            }
            centersX[letter] = Float(cell.frame.midX)
            centersY[letter] = Float(cell.frame.midY)
        }
        geometry = KeyGeometry(centersX: centersX, centersY: centersY, pitchX: Float(pitchX), pitchY: Float(pitchY))
    }

    /// The key a touch on [cell] meant, and what the pinyin and the learner need to know of it.
    private func resolve(_ cell: KeyCell, _ point: CGPoint) -> (cell: KeyCell, tap: [Float]?, sample: TypingLearner.Sample?) {
        guard let typing, let geometry, let geometric = Self.letterIndex(cell) else { return (cell, nil, nil) }
        let x = Float(point.x), y = Float(point.y)
        let tap = typing.decoder.letterCosts(x: x, y: y, keys: geometry)
        guard typing.adaptiveEnabled else { return (cell, tap, nil) }
        let letter = typing.decoder.decode(x: x, y: y, geometricLetter: geometric, keys: geometry, previous2: typing.learner.previous2, previous1: typing.learner.previous1, useLanguageModel: true)
        return (letterCells[letter] ?? cell, tap, TypingLearner.Sample(letter: letter, x: x, y: y, keys: geometry))
    }

    private func cell(at point: CGPoint) -> KeyCell? {
        cells.min { distance($0, point) < distance($1, point) }
    }

    private func distance(_ cell: KeyCell, _ point: CGPoint) -> CGFloat {
        let dx = max(cell.frame.minX - point.x, 0, point.x - cell.frame.maxX)
        let dy = max(cell.frame.minY - point.y, 0, point.y - cell.frame.maxY)
        return dx * dx + dy * dy
    }

    /// ProMotion rests at a low rate on a still screen, and touches and drawing wait for its next
    /// frame. A running link holds it at full speed while typing, and stops soon after.
    private func keepDisplayFast() {
        fastUntil = CACurrentMediaTime() + Self.fastDisplaySeconds
        displayLink?.isPaused = false
    }

    @objc private func displayTick() {
        if CACurrentMediaTime() > fastUntil { displayLink?.isPaused = true }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        keepDisplayFast()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        keepDisplayFast()
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            layoutIfNeeded()
            let point = touch.location(in: self)
            guard let nearest = cell(at: point) else { continue }
            let (cell, tap, sample) = resolve(nearest, point)
            presses.append((touch, cell))
            UIView.performWithoutAnimation { cell.alpha = 0.55 }
            haptics?.impactOccurred()
            haptics?.prepare()
            if playsSound { AudioServicesPlaySystemSound(1104) }
            showPopup(over: cell)
            // The key is settled as the finger lands, so the letter need not wait for it to lift.
            if cell.isLetterOrSpace { type(cell, tap, sample) }
            if case .key(.backspace) = cell.action {
                onKey?(.backspace)
                repeatTimer?.invalidate()
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in self?.onKey?(.backspace) }
                }
            }
        }
    }

    /// A symbol or a space goes back to the letters; digits stay, as they often come in a run.
    private func endsSymbols(_ key: Key) -> Bool {
        switch key {
        case let .text(text): return !text.allSatisfy(\.isNumber)
        case .literal, .space: return true
        default: return false
        }
    }

    private func type(_ cell: KeyCell, _ tap: [Float]?, _ sample: TypingLearner.Sample?) {
        guard case let .key(key) = cell.action else { return }
        if case let .text(text) = key { onLetter?(text, tap, sample) } else { onKey?(key) }
        if shifted, case .text = key {
            shifted = false
            rebuild()
        }
        if symbols, endsSymbols(key) {
            symbols = false
            moreSymbols = false
            rebuild()
        }
    }

    /// The key is the one the finger came down on, so rolling off it does not change it.
    private func release(_ press: Press, _ event: UIEvent?) {
        let cell = press.cell
        cell.alpha = 1
        switch cell.action {
        case .key(.backspace):
            repeatTimer?.invalidate()
        case .key(.text), .key(.literal), .key(.space):
            break
        case let .key(key):
            onKey?(key)
        case .shift:
            shifted.toggle()
            rebuild()
        case .symbols:
            symbols.toggle()
            moreSymbols = false
            rebuild()
        case .moreSymbols:
            moreSymbols.toggle()
            rebuild()
        case .globe:
            if let event { onGlobe?(cell, event) }
            onKey?(.nextKeyboard)
        }
    }

    private func showPopup(over cell: KeyCell) {
        guard showsPopup, cell.icon == nil, cell.isLetterOrSpace, let text = cell.text, !text.isEmpty, text != "space" else { return }
        popup.text = text
        popup.backgroundColor = Self.letterKey
        popup.frame = CGRect(x: cell.frame.minX - 4, y: cell.frame.minY - cell.frame.height - 8, width: cell.frame.width + 8, height: cell.frame.height + 4)
        popup.isHidden = false
        bringSubviewToFront(popup)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event)
    }

    /// iOS cancels a touch when a system gesture claims it; the key was still pressed.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event)
    }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent?) {
        let done = presses.filter { touches.contains($0.touch) }
        presses.removeAll { touches.contains($0.touch) }
        done.forEach { release($0, event) }
        if presses.isEmpty { popup.isHidden = true }
    }

    /// A little above the top row counts as the top row, not as the candidate above it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        point.y >= -Self.hitOverhang && point.y < bounds.height && point.x >= 0 && point.x < bounds.width
    }
}
