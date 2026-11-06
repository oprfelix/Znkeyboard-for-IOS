import AudioToolbox
import UIKit

/// The keys, drawn as plain views; a touch goes to the nearest key, so there are no dead gaps.
final class KeyboardKeysView: UIView {
    enum Key {
        case text(String), space, backspace, returnKey, language, nextKeyboard
    }

    private enum Action {
        case key(Key), shift, symbols, globe
    }

    private final class KeyCell: UILabel {
        var action: Action = .key(.space)
    }

    // A row of letters measures what the system keyboard's does; the number row is shorter.
    private static let rowHeight: CGFloat = 54
    private static let numberRowHeight: CGFloat = 44
    private static let rowGap: CGFloat = 11
    private static let topInset: CGFloat = 4
    private static let bottomInset: CGFloat = 2
    private static let gap: CGFloat = 6
    private static let letterKey = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    private static let functionKey = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    }

    var onKey: ((Key) -> Void)?
    var onGlobe: ((UIView, UIEvent) -> Void)?
    /// Haptics need full access; without it the generator does nothing.
    var haptics: UIImpactFeedbackGenerator?
    var showsGlobe = true { didSet { if showsGlobe != oldValue { rebuild() } } }
    var showsNumberRow = false { didSet { if showsNumberRow != oldValue { rebuild() } } }
    var showsPopup = true
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
    private var chinese = true
    private var repeatTimer: Timer?

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
            layout = [
                "1234567890".map { (String($0), .key(.text(String($0))), 1) },
                "-/:;()$&@\"".map { (String($0), .key(.text(String($0))), 1) },
                [("返回", .symbols, 1.5)] + ".,?!'".map { (String($0), .key(.text(String($0))), 1.2) } + [("⌫", .key(.backspace), 1.5)],
            ]
        } else {
            layout = showsNumberRow ? ["1234567890".map { (String($0), .key(.text(String($0))), 1) }] : []
            layout += [
                letters("qwertyuiop"),
                letters("asdfghjkl"),
                [("⇧", .shift, 1.4)] + letters("zxcvbnm") + [("⌫", .key(.backspace), 1.4)],
            ]
        }
        var bottom: [(String, Action, CGFloat)] = [("123", .symbols, 1.2), (chinese ? "中" : "英", .key(.language), 1.1)]
        if showsGlobe { bottom.append(("🌐", .globe, 1.1)) }
        bottom += [(chinese ? "拼音" : "space", .key(.space), 4.2), (chinese ? "，" : ",", .key(.text(",")), 1), ("换行", .key(.returnKey), 1.6)]
        layout.append(bottom)
        rows = layout.map { row in
            row.map { title, action, weight in
                let cell = KeyCell()
                cell.text = title
                cell.textAlignment = .center
                cell.font = .systemFont(ofSize: title.count == 1 && title.first?.isASCII == true ? 25 : 16)
                cell.textColor = .label
                cell.layer.cornerRadius = 8
                // A thin shadow under each key, as on the system keyboard.
                cell.layer.shadowColor = UIColor.black.cgColor
                cell.layer.shadowOpacity = 0.3
                cell.layer.shadowRadius = 0
                cell.layer.shadowOffset = CGSize(width: 0, height: 1)
                switch action {
                case .key(.text), .key(.space):
                    cell.layer.backgroundColor = Self.letterKey.resolvedColor(with: traitCollection).cgColor
                default:
                    cell.layer.backgroundColor = Self.functionKey.resolvedColor(with: traitCollection).cgColor
                }
                cell.action = action
                addSubview(cell)
                cells.append(cell)
                return (cell, weight)
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only the letter keyboard has the fifth row; the others share its full height.
        let numberRow = rows.count == 5 ? Self.numberRowHeight : 0
        let fullRows = CGFloat(max(rows.count - (numberRow > 0 ? 1 : 0), 1))
        let rowHeight = (bounds.height - Self.topInset - Self.bottomInset + Self.rowGap - numberRow) / fullRows
        var y = Self.topInset
        for (r, row) in rows.enumerated() {
            let height = r == 0 && numberRow > 0 ? numberRow : rowHeight
            let total = row.reduce(CGFloat(0)) { $0 + $1.weight }
            // The second row is narrower on the letter keyboard, centred under the first.
            let unit = (bounds.width - Self.gap) / (rows.first.map { $0.reduce(CGFloat(0)) { $0 + $1.weight } } ?? total)
            let width = r == rows.count - 1 ? (bounds.width - Self.gap) / total : unit
            var x = (bounds.width - width * total) / 2
            if r == rows.count - 1 || total * unit > bounds.width { x = Self.gap / 2 }
            let scale = total * width > bounds.width ? (bounds.width - Self.gap) / (total * width) : 1
            for (cell, weight) in row {
                let w = weight * width * scale
                cell.frame = CGRect(x: x + Self.gap / 2, y: y, width: w - Self.gap, height: height - Self.rowGap)
                x += w
            }
            y += height
        }
    }

    private func cell(at point: CGPoint) -> KeyCell? {
        cells.min { distance($0, point) < distance($1, point) }
    }

    private func distance(_ cell: KeyCell, _ point: CGPoint) -> CGFloat {
        let dx = max(cell.frame.minX - point.x, 0, point.x - cell.frame.maxX)
        let dy = max(cell.frame.minY - point.y, 0, point.y - cell.frame.maxY)
        return dx * dx + dy * dy
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cell = cell(at: touch.location(in: self)) else { continue }
            UIView.performWithoutAnimation { cell.alpha = 0.55 }
            haptics?.impactOccurred()
            haptics?.prepare()
            if playsSound { AudioServicesPlaySystemSound(1104) }
            showPopup(over: cell)
            if case .key(.backspace) = cell.action {
                onKey?(.backspace)
                repeatTimer?.invalidate()
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in self?.onKey?(.backspace) }
                }
            }
        }
    }

    private func showPopup(over cell: KeyCell) {
        guard showsPopup, case .key(.text) = cell.action, let text = cell.text else { return }
        popup.text = text
        popup.backgroundColor = Self.letterKey
        popup.frame = CGRect(x: cell.frame.minX - 4, y: cell.frame.minY - cell.frame.height - 8, width: cell.frame.width + 8, height: cell.frame.height + 4)
        popup.isHidden = false
        bringSubviewToFront(popup)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        popup.isHidden = true
        repeatTimer?.invalidate()
        cells.forEach { $0.alpha = 1 }
        for touch in touches {
            guard let cell = cell(at: touch.location(in: self)) else { continue }
            switch cell.action {
            case .key(.backspace): break
            case let .key(key):
                onKey?(key)
                if shifted, case .text = key {
                    shifted = false
                    rebuild()
                }
            case .shift:
                shifted.toggle()
                rebuild()
            case .symbols:
                symbols.toggle()
                rebuild()
            case .globe:
                if let event { onGlobe?(cell, event) }
                onKey?(.nextKeyboard)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        popup.isHidden = true
        repeatTimer?.invalidate()
        cells.forEach { $0.alpha = 1 }
    }
}
