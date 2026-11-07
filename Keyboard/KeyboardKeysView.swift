import AudioToolbox
import PinyinCore
import QuartzCore
import UIKit

/// The keys, drawn as plain views; a touch goes to the nearest key, so there are no dead gaps.
final class KeyboardKeysView: UIView {
    enum Key {
        case text(String), literal(String), space, backspace, returnKey, language, nextKeyboard
        case digit(Character), punctuation, separator, nextSpelling, emoji
        /// An English 9-key key: taps in a row step through its letters.
        case letters(String)
    }

    private enum Action {
        case key(Key), shift, symbols, moreSymbols, globe, grid(GridPage)
    }

    /// The 9-key keyboard's own pages, so nothing falls back to the 26 keys.
    private enum GridPage {
        case main, numbers, marks(Int)
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
            case .key(.text), .key(.literal), .key(.space), .key(.digit), .key(.letters): return true
            default: return false
            }
        }

        var isSpace: Bool {
            if case .key(.space) = action { return true }
            return false
        }
    }

    /// A key of the 9-key keyboard, placed by column and row.
    private typealias GridKey = (cell: KeyCell, column: Int, row: Int, width: Int, height: Int)

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
    private static let caretHold: TimeInterval = 0.35
    private static let caretStep: CGFloat = 9
    private static let caretDim: CGFloat = 0.4
    private static let gridMarks = ["，。？！、：；…～“”—", "（）《》【】@#¥%&*", "+-=/\\|_<>[]{", "}^$€£.,?!:;'"]
    private static let gridSideMargin: CGFloat = 8
    private static let gridRowGap: CGFloat = 7
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
    /// Chinese is typed on the 9-key layout.
    var nineKey = false {
        didSet {
            guard nineKey != oldValue else { return }
            gridPage = .main
            symbols = false
            moreSymbols = false
            rebuild()
        }
    }
    /// Moves the caret by this many characters, for a held space bar.
    var onMoveCaret: ((Int) -> Void)?
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
    private var grid: [GridKey] = []
    private weak var separatorCell: KeyCell?
    private weak var spaceCell: KeyCell?
    private weak var returnCell: KeyCell?
    private var composing = false
    private var choosingMark = false
    private var gridPage = GridPage.main
    private var showsGrid: Bool { nineKey }
    private var spaceTouch: UITouch?
    private var spaceTimer: Timer?
    private var movingCaret = false
    private var caretX: CGFloat = 0

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
            gridPage = .main
            rebuild()
        }
    }

    /// While composing, three keys of the 9-key layout do something else.
    func setComposing(_ value: Bool, choosingMark: Bool) {
        guard composing != value || self.choosingMark != choosingMark else { return }
        composing = value
        self.choosingMark = choosingMark
        updateGridKeys()
    }

    private func updateGridKeys() {
        separatorCell?.text = composing ? "分隔" : "^^"
        let pending = composing || choosingMark
        spaceCell?.text = pending ? "选定" : (chinese ? "空格" : "space")
        returnCell?.text = pending ? "确认" : nil
        returnCell?.icon?.isHidden = pending
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
        grid = []
        rows = []
        if showsGrid {
            buildGrid()
            setNeedsLayout()
            return
        }
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
        rows = layout.map { row in
            row.map { title, action, weight in
                let cell = makeCell(title, action)
                if !symbols, let letter = Self.letterIndex(cell) { letterCells[letter] = cell }
                if case .key(.space) = action, chinese {
                    let corner = UILabel()
                    corner.text = "拼"
                    corner.font = .systemFont(ofSize: 13)
                    corner.textColor = .secondaryLabel
                    cell.addSubview(corner)
                    cell.corner = corner
                }
                return (cell, weight)
            }
        }
        setNeedsLayout()
    }

    private func makeCell(_ title: String, _ action: Action) -> KeyCell {
        let cell = KeyCell()
        cell.text = title
        cell.textAlignment = .center
        cell.font = font(for: title, action)
        cell.textColor = .label
        cell.isUserInteractionEnabled = false
        cell.layer.cornerRadius = Self.cornerRadius
        cell.layer.backgroundColor = Self.letterKey.resolvedColor(with: traitCollection).cgColor
        cell.action = action
        if let symbol = symbol(for: action) {
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Self.iconConfiguration))
            icon.tintColor = .label
            cell.addSubview(icon)
            cell.icon = icon
        }
        addSubview(cell)
        cells.append(cell)
        return cell
    }

    /// As on the system's 九宫格, so nothing needs learning again.
    private func buildGrid() {
        letterCells = [KeyCell?](repeating: nil, count: 26)
        geometry = nil
        @discardableResult
        func add(_ title: String, _ action: Action, _ column: Int, _ row: Int, width: Int = 1, height: Int = 1) -> KeyCell {
            let cell = makeCell(title, action)
            grid.append((cell, column, row, width, height))
            return cell
        }
        func mark(_ text: String, _ column: Int, _ row: Int, width: Int = 1) {
            add(text, .key(.literal(text)), column, row, width: width)
        }
        // A phone with a home button has no system globe, so this corner must switch keyboards.
        let corner: Action = showsGlobe ? .globe : .key(.emoji)
        let back = chinese ? "拼音" : "ABC"
        let language = chinese ? "英" : "中"
        separatorCell = nil
        switch gridPage {
        case .main:
            add("123", .grid(.numbers), 0, 0)
            add("，。?！", .key(.punctuation), 1, 0)
            add("", .key(.backspace), 4, 0)
            add("#@¥", .grid(.marks(0)), 0, 1)
            add(language, .key(.language), 0, 2)
            add("", corner, 0, 3)
            for (index, letters) in ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"].enumerated() {
                let upper = letters.uppercased()
                let shown = (chinese || shifted ? upper : letters).map(String.init).joined(separator: " ")
                let action: Action = chinese ? .key(.digit(Character(String(index + 2)))) : .key(.letters(shifted ? upper : letters))
                add(shown, action, (index + 1) % 3 + 1, (index + 1) / 3)
            }
            if chinese {
                separatorCell = add("", .key(.separator), 4, 1)
                add("选拼音", .key(.nextSpelling), 1, 3)
            } else {
                add("", .shift, 4, 1)
                mark(".", 1, 3)
            }
        case .numbers:
            add(back, .grid(.main), 0, 0)
            add("#@¥", .grid(.marks(0)), 0, 1)
            add(language, .key(.language), 0, 2)
            add("", corner, 0, 3)
            for (index, digit) in "123456789".enumerated() { mark(String(digit), index % 3 + 1, index / 3) }
            add("", .key(.backspace), 4, 0)
            mark("-", 4, 1)
            mark(".", 1, 3)
            mark("0", 2, 3)
        case let .marks(page):
            add(back, .grid(.main), 0, 0)
            add("123", .grid(.numbers), 0, 1)
            add(language, .key(.language), 0, 2)
            add("", .key(.emoji), 0, 3)
            for (index, text) in Self.gridMarks[page].enumerated() { mark(String(text), index % 3 + 1, index / 3) }
            add("", .key(.backspace), 4, 0)
            add(chinese ? "下一页" : "next", .grid(.marks((page + 1) % Self.gridMarks.count)), 4, 1)
        }
        returnCell = add("", .key(.returnKey), 4, 2, height: 2)
        if case .marks = gridPage {
            spaceCell = nil
        } else if case .numbers = gridPage {
            spaceCell = add("", .key(.space), 3, 3)
        } else {
            spaceCell = add("", .key(.space), 2, 3, width: 2)
        }
        updateGridKeys()
    }

    private func placeGrid() {
        let pitchX = (bounds.width - 2 * Self.gridSideMargin + Self.gap) / 5
        let pitchY = (bounds.height - Self.topInset - Self.bottomInset + Self.gridRowGap) / 4
        for key in grid {
            key.cell.frame = CGRect(
                x: Self.gridSideMargin + CGFloat(key.column) * pitchX,
                y: Self.topInset + CGFloat(key.row) * pitchY,
                width: CGFloat(key.width) * pitchX - Self.gap,
                height: CGFloat(key.height) * pitchY - Self.gridRowGap
            )
        }
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
        case .key(.emoji): return "face.smiling"
        default: return nil
        }
    }

    private func font(for title: String, _ action: Action) -> UIFont {
        if case .moreSymbols = action, title.count == 3, title != "123" { return .systemFont(ofSize: 15) }
        switch action {
        case .key(.text), .key(.literal): break
        case .key(.digit), .key(.letters): return .systemFont(ofSize: 17)
        default: return .systemFont(ofSize: showsGrid ? 16 : 18)
        }
        return .systemFont(ofSize: symbols ? 23 : 25)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if showsGrid {
            placeGrid()
            return
        }
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

    private func beginSpace(_ touch: UITouch) {
        spaceTouch = touch
        spaceTimer?.invalidate()
        guard !composing, !choosingMark else { return }
        spaceTimer = Timer.scheduledTimer(withTimeInterval: Self.caretHold, repeats: false) { [weak self] _ in
            self?.beginMovingCaret(touch)
        }
    }

    private func beginMovingCaret(_ touch: UITouch) {
        guard spaceTouch === touch else { return }
        movingCaret = true
        caretX = touch.location(in: self).x
        haptics?.impactOccurred()
        haptics?.prepare()
        cells.forEach { if !$0.isSpace { $0.alpha = Self.caretDim } }
    }

    private func endSpace() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        spaceTouch = nil
        guard movingCaret else { return }
        movingCaret = false
        cells.forEach { $0.alpha = 1 }
    }

    /// A key pressed while space is still down: the space came first, so it goes in first.
    private func flushSpace() {
        guard let touch = spaceTouch, !movingCaret, let at = presses.firstIndex(where: { $0.touch === touch }) else { return }
        let press = presses.remove(at: at)
        endSpace()
        press.cell.alpha = 1
        type(press.cell, nil, nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard movingCaret, let touch = spaceTouch, touches.contains(touch) else { return }
        let steps = Int((touch.location(in: self).x - caretX) / Self.caretStep)
        guard steps != 0 else { return }
        caretX += CGFloat(steps) * Self.caretStep
        onMoveCaret?(steps)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        keepDisplayFast()
        flushSpace()
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
            // Space waits: held down, it moves the caret instead.
            if cell.isSpace {
                beginSpace(touch)
            } else if cell.isLetterOrSpace {
                type(cell, tap, sample)
            }
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
        var typedLetter = false
        if case .text = key { typedLetter = true }
        if case .letters = key { typedLetter = true }
        if shifted, typedLetter {
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
        if cell.isSpace, press.touch === spaceTouch {
            let moved = movingCaret
            endSpace()
            if !moved { type(cell, nil, nil) }
            return
        }
        switch cell.action {
        case .key(.backspace):
            repeatTimer?.invalidate()
        case .key(.text), .key(.literal), .key(.space), .key(.digit), .key(.letters):
            break
        case .key(.language):
            gridPage = .main
            onKey?(.language)
        case let .grid(page):
            gridPage = page
            rebuild()
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
            if showsGrid { symbols = true }
            moreSymbols.toggle()
            rebuild()
        case .globe:
            if let event { onGlobe?(cell, event) }
            onKey?(.nextKeyboard)
        }
    }

    private func showPopup(over cell: KeyCell) {
        guard showsPopup, !showsGrid, cell.icon == nil, cell.isLetterOrSpace, let text = cell.text, !text.isEmpty, text != "space" else { return }
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
