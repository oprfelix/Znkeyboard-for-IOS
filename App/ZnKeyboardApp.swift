import PinyinCore
import SwiftUI

@main
struct ZnKeyboardApp: App {
    var body: some Scene {
        WindowGroup {
            SetupView().tint(Brand.blue)
        }
    }
}

enum Brand {
    static let blue = Color(red: 0.16, green: 0.42, blue: 1)
    static let soft = Color(red: 0.16, green: 0.42, blue: 1).opacity(0.1)
}

/// A rounded white card with a small title.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.blue)
                    .frame(width: 28, height: 28)
                    .background(Brand.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct InputBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Brand.blue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Closes the keyboard on a tap anywhere but a text field. It watches the window rather than
/// the page, so buttons, pickers and toggles still get their taps.
struct KeyboardDismisser: UIViewRepresentable {
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {}

    final class Host: UIView, UIGestureRecognizerDelegate {
        private weak var tap: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, tap == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.tap = tap
        }

        @objc private func tapped() { window?.endEditing(true) }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextView || current is UITextField { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// A card that opens from its title; closed, the title shows [summary].
struct FoldingCard<Content: View>: View {
    let title: String
    let symbol: String
    let summary: String
    @ViewBuilder let content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.blue)
                        .frame(width: 28, height: 28)
                        .background(Brand.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A plain UIKit text view: an ordinary field for every keyboard the user has, ZnKeyboard included.
struct TryField: UIViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = UILabel()
        label.text = placeholder
        label.font = view.font
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ])
        context.coordinator.placeholder = label
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: TryField
        weak var placeholder: UILabel?
        init(_ parent: TryField) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            placeholder?.isHidden = !view.text.isEmpty
        }
        func textViewDidBeginEditing(_ view: UITextView) { parent.editing = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.editing = false }
    }
}

/// Turning the keyboard on, the AI settings, and a box to try it in.
struct SetupView: View {
    @State private var kind = SharedSettings.providerKind
    @State private var baseURL = SharedSettings.customBaseURL
    @State private var model = SharedSettings.model
    @State private var apiKey = SharedSettings.apiKey
    @State private var showKey = false
    @State private var translate = SharedSettings.translateLanguage
    @State private var reading = SharedSettings.readingLanguage
    @State private var text = ""
    @State private var status: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var fuzzyRules = SharedSettings.fuzzyRules
    @State private var haptics = SharedSettings.hapticsEnabled
    @State private var keySound = SharedSettings.keySoundEnabled
    @State private var keyPopup = SharedSettings.keyPopupEnabled
    @State private var autoCapitalize = SharedSettings.autoCapitalize
    @State private var doubleSpace = SharedSettings.doubleSpacePeriod
    @State private var numberRow = SharedSettings.numberRow
    @State private var adaptiveTouch = SharedSettings.adaptiveTouch
    @State private var models: [String] = []
    @State private var fullAccess = false
    @State private var trying = false
    @Environment(\.scenePhase) private var scenePhase

    private var isReady: Bool { fullAccess }

    /// The saved model stays listed even when the provider didn't name it.
    private var modelChoices: [String] {
        let known = models.isEmpty ? [kind.defaultModel] : models
        return known.contains(model) || model.isEmpty ? known : [model] + known
    }

    var body: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(spacing: 16) {
                header
                setup
                tryIt.id("try")
                fuzzy
                feel
                ai
                VStack(spacing: 8) {
                    Label("文字从手机直接发给你选的服务商，没有中转服务器", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Link("隐私政策", destination: URL(string: "https://znkeyboard.2amz.com/privacy")!)
                }
                .font(.footnote)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
            // Room to lift the box above the keyboard, whatever height it has.
            .padding(.bottom, trying ? 360 : 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(KeyboardDismisser())
        .background(background.ignoresSafeArea())
        // Content scrolls under the status bar, not through it.
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                Rectangle().fill(.ultraThinMaterial)
                    .frame(height: proxy.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
            }
            .frame(height: 0)
        }
        .onChange(of: trying) { focused in
            guard focused else { return }
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                withAnimation { reader.scrollTo("try", anchor: .top) }
            }
        }
        }
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { if $0 == .active { refresh() } }
        .task(id: "\(kind.rawValue)\(apiKey)\(baseURL)") { await loadModels() }
    }

    /// The keyboard reports full access once it has it; iOS lets no app ask whether it is added.
    private func refresh() {
        fullAccess = SharedSettings.keyboardHasFullAccess
    }

    private func loadModels() async {
        models = []
        guard !apiKey.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled, let found = try? await AIClient().models(SharedSettings.provider), !Task.isCancelled else { return }
        models = found
    }

    private var background: some View {
        LinearGradient(colors: [Brand.blue.opacity(0.14), Color(.systemGroupedBackground)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
            .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if let icon = UIImage(named: "AppIcon60x60") {
                    Image(uiImage: icon).resizable()
                } else {
                    Brand.blue
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Brand.blue.opacity(0.2), radius: 12, y: 6)
            Text("ZnKeyboard").font(.title2.weight(.bold))
            Text("和海外客户沟通，不再卡在语言上").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var setup: some View {
        if isReady {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("键盘已就绪").font(.subheadline.weight(.medium))
                Spacer()
                Button("系统设置", action: openSettings).font(.footnote)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            Card(title: "启用键盘", symbol: "keyboard") {
                VStack(alignment: .leading, spacing: 14) {
                    Step(number: 1, title: "添加键盘", detail: "设置 → 通用 → 键盘 → 键盘 → 添加新键盘，只选 ZnKeyboard")
                    Step(number: 2, title: "允许完全访问", detail: "润色和翻译要联网，复制翻译要读取剪贴板。打开后，切到 ZnKeyboard 打一个字")
                }
                Button(action: openSettings) {
                    Text("打开系统设置").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private var ai: some View {
        Card(title: "AI 润色与翻译", symbol: "sparkles") {
            Picker("服务商", selection: $kind) {
                Text("DeepSeek").tag(AIProviderKind.deepSeek)
                Text("Gemini").tag(AIProviderKind.gemini)
                Text("自定义").tag(AIProviderKind.openAICompatible)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { newValue in
                SharedSettings.providerKind = newValue
                model = newValue.defaultModel
                SharedSettings.model = model
                status = nil
            }
            if kind == .openAICompatible {
                InputBox {
                    TextField("接口地址，以 https 开头", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: baseURL) { SharedSettings.customBaseURL = $0 }
                }
            }
            InputBox {
                HStack {
                    // No SecureField: iOS would take the page for a login form and hide every
                    // third-party keyboard, ZnKeyboard included, in the fields around it.
                    if showKey || apiKey.isEmpty {
                        TextField("API Key", text: $apiKey)
                            .textContentType(nil)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: apiKey) { SharedSettings.apiKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } else {
                        Text(String(repeating: "•", count: min(apiKey.count, 24)))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { showKey = true }
                    }
                    if !apiKey.isEmpty {
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if kind == .openAICompatible && models.isEmpty {
                InputBox {
                    HStack {
                        Text("模型").foregroundStyle(.secondary)
                        TextField("模型名称", text: $model)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: model) { SharedSettings.model = $0 }
                    }
                }
            } else {
                Menu {
                    Picker("模型", selection: $model) {
                        ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    InputBox {
                        HStack(spacing: 10) {
                            Text("模型").foregroundStyle(.secondary).fixedSize()
                            Text(model)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: model) { SharedSettings.model = $0 }
            }
            Button(action: test) {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "正在测试" : "测试连接").font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(testing || apiKey.isEmpty)
            if let status {
                Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(status.ok ? .green : .red)
            }
            Divider()
            languageRow("回复翻译成", "键盘上显示为「翻译为\(translate.chineseName)」", $translate) { SharedSettings.translateLanguage = $0 }
            languageRow("外文消息翻译成", "复制外文消息后使用", $reading) { SharedSettings.readingLanguage = $0 }
        }
    }

    private var fuzzy: some View {
        FoldingCard(title: "模糊音", symbol: "waveform", summary: "已开 \(FuzzyRules.labelled.filter { fuzzyRules.contains($0.rule) }.count) 组") {
            Text("分不清的读音可以打开，打哪个音都能出字。").font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(FuzzyRules.labelled, id: \.rule) { item in
                    let on = fuzzyRules.contains(item.rule)
                    Button {
                        if on { fuzzyRules.remove(item.rule) } else { fuzzyRules.insert(item.rule) }
                        SharedSettings.fuzzyRules = fuzzyRules
                    } label: {
                        HStack {
                            Text(item.label).font(.subheadline.monospaced())
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(on ? Brand.blue : Color.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(on ? Brand.soft : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var feel: some View {
        FoldingCard(title: "手感", symbol: "hand.tap", summary: "振动、声音、气泡") {
            VStack(spacing: 0) {
                setting("按键振动", "需要完全访问", $haptics) { SharedSettings.hapticsEnabled = $0 }
                setting("按键声音", "需要完全访问", $keySound) { SharedSettings.keySoundEnabled = $0 }
                setting("按键气泡", "按下时放大显示字母", $keyPopup) { SharedSettings.keyPopupEnabled = $0 }
                setting("数字行", "在字母上方显示数字键", $numberRow) { SharedSettings.numberRow = $0 }
                setting("按键学习", "记住你的落点习惯，按偏时自动纠正", $adaptiveTouch) { SharedSettings.adaptiveTouch = $0 }
                setting("英文句首大写", "英文模式下自动大写", $autoCapitalize) { SharedSettings.autoCapitalize = $0 }
                setting("双击空格输入句号", nil, $doubleSpace) { SharedSettings.doubleSpacePeriod = $0 }
            }
        }
    }

    private func setting(_ title: String, _ detail: String?, _ value: Binding<Bool>, save: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 7)
        .onChange(of: value.wrappedValue) { save($0) }
    }

    private func languageRow(_ title: String, _ detail: String, _ value: Binding<TranslateLanguage>, save: @escaping (TranslateLanguage) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(title, selection: value) {
                ForEach(TranslateLanguage.all, id: \.self) { Text($0.chineseName).tag($0) }
            }
            .labelsHidden()
            .onChange(of: value.wrappedValue) { save($0) }
        }
    }

    private var tryIt: some View {
        Card(title: "试一试", symbol: "text.cursor") {
            InputBox {
                TryField(text: $text, editing: $trying, placeholder: "切换到 ZnKeyboard，打几个字试试")
                    .padding(.vertical, 6)
            }
        }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            do {
                _ = try await AIClient().polish("hello", with: SharedSettings.provider)
                status = (true, "连接成功")
            } catch {
                status = (false, AIClient.message(for: error, chinese: true))
            }
            testing = false
        }
    }
}
