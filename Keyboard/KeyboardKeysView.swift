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

    static let rowHeight: CGFloat = 52
    private static let gap: CGFloat = 6

    var onKey: ((Key) -> Void)?
    var onGlobe: ((UIView, UIEvent) -> Void)?
    var showsGlobe = true { didSet { if showsGlobe != oldValue { rebuild() } } }

    private var cells: [KeyCell] = []
    private var rows: [[(cell: KeyCell, weight: CGFloat)]] = []
    private var shifted = false
    private var symbols = false
    private var chinese = true
    private var repeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no storyboards") }

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
            layout = [
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
                cell.font = .systemFont(ofSize: title.count == 1 ? 21 : 15)
                cell.textColor = .label
                cell.layer.cornerRadius = 7
                cell.layer.masksToBounds = true
                if case .key(.text) = action {
                    cell.backgroundColor = .tertiarySystemFill
                } else if case .key(.space) = action {
                    cell.backgroundColor = .tertiarySystemFill
                } else {
                    cell.backgroundColor = .quaternarySystemFill
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
        let rowHeight = (bounds.height - 8) / CGFloat(max(rows.count, 1))
        for (r, row) in rows.enumerated() {
            let total = row.reduce(CGFloat(0)) { $0 + $1.weight }
            // The second row is narrower on the letter keyboard, centred under the first.
            let unit = (bounds.width - Self.gap) / (rows.first.map { $0.reduce(CGFloat(0)) { $0 + $1.weight } } ?? total)
            let width = r == rows.count - 1 ? (bounds.width - Self.gap) / total : unit
            var x = (bounds.width - width * total) / 2
            if r == rows.count - 1 || total * unit > bounds.width { x = Self.gap / 2 }
            let scale = total * width > bounds.width ? (bounds.width - Self.gap) / (total * width) : 1
            for (cell, weight) in row {
                let w = weight * width * scale
                cell.frame = CGRect(x: x + Self.gap / 2, y: CGFloat(r) * rowHeight + 5, width: w - Self.gap, height: rowHeight - 8)
                x += w
            }
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
            if case .key(.backspace) = cell.action {
                onKey?(.backspace)
                repeatTimer?.invalidate()
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in self?.onKey?(.backspace) }
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
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
        repeatTimer?.invalidate()
        cells.forEach { $0.alpha = 1 }
    }
}
