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

/// Content scrolls into frosted glass under the status bar, blurred at the top and clear lower
/// down: iOS 26's own edge effect, or a masked material before it.
struct TopEdgeBlur: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content.overlay(alignment: .top) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        .frame(height: proxy.safeAreaInsets.top + 24)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
                .frame(height: 0)
            }
        }
    }
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
    @Binding var open: Bool
    @ViewBuilder let content: Content

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
    }
}

/// Three pages: translation comes first, as it is what the keyboard is for.
struct SetupView: View {
    @State private var kind = SharedSettings.providerKind
    @State private var baseURL = SharedSettings.customBaseURL
    @State private var model = SharedSettings.model
    @State private var apiKey = SharedSettings.apiKey
    @State private var showKey = false
    @State private var aiOpen = SharedSettings.apiKey.isEmpty
    @State private var askingForKey = false
    @AppStorage("fuzzyCardOpen") private var fuzzyOpen = false
    @AppStorage("touchCardOpen") private var touchOpen = true
    @FocusState private var editingKey: Bool
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
    @State private var nineKey = SharedSettings.nineKey
    @State private var adaptiveTouch = SharedSettings.adaptiveTouch
    @State private var models: [String] = []
    @State private var fullAccess = false
    @Environment(\.scenePhase) private var scenePhase

    private var isReady: Bool { fullAccess }

    private var aiConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty && (kind != .openAICompatible || !baseURL.isEmpty)
    }

    /// The saved model stays listed even when the provider didn't name it.
    private var modelChoices: [String] {
        let known = models.isEmpty ? [kind.defaultModel] : models
        return known.contains(model) || model.isEmpty ? known : [model] + known
    }

    var body: some View {
        TabView {
            translatePage.tabItem { Label("翻译", systemImage: "translate") }
            keyboardPage.tabItem { Label("键盘", systemImage: "keyboard") }
            aboutPage.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .background(KeyboardDismisser())
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { if $0 == .active { refresh() } }
        .task(id: "\(kind.rawValue)\(apiKey)\(baseURL)") { await loadModels() }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 16, content: content)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .modifier(TopEdgeBlur())
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 16)
    }

    private var translatePage: some View {
        ScrollViewReader { reader in
            page {
                header
                if !isReady { enable }
                translation
                ai.id("ai")
                Label("文字从手机直接发给你选的服务商，不经过我们的服务器", systemImage: "lock.shield")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            .alert("请先配置 API", isPresented: $askingForKey) {
                Button("稍后", role: .cancel) {}
                Button("去配置") {
                    withAnimation(.snappy) {
                        aiOpen = true
                        reader.scrollTo("ai", anchor: .top)
                    }
                    if apiKey.isEmpty { editingKey = true }
                }
            } message: {
                Text("翻译使用你自己的 AI 服务，填好 API Key 后就能选择语言。")
            }
        }
    }

    private var keyboardPage: some View {
        page {
            pageTitle("键盘")
            tryIt
            layout
            fuzzy
            feel
        }
    }

    private var aboutPage: some View {
        page {
            pageTitle("关于")
            keyboardStatus
            VStack(spacing: 0) {
                linkRow("隐私政策", "https://znkeyboard.2amz.com/privacy", "arrow.up.right")
                Divider()
                linkRow("反馈问题", "mailto:oprfelix@gmail.com", "envelope")
                Divider()
                HStack {
                    Text("版本")
                    Spacer()
                    Text(version).foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            }
            .font(.subheadline)
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func linkRow(_ title: String, _ url: String, _ symbol: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
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
            Text("用中文打字，用对方的语言沟通").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var keyboardStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? .green : .orange)
            Text(isReady ? "键盘已就绪" : "键盘未启用").font(.subheadline.weight(.medium))
            Spacer()
            Button("系统设置", action: openSettings).font(.footnote)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var enable: some View {
        Card(title: "启用键盘", symbol: "keyboard") {
            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "添加键盘", detail: "打开「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」，选择 ZnKeyboard")
                Step(number: 2, title: "打开完全访问", detail: "润色和翻译需要联网，翻译复制的内容需要读取剪贴板。打开后切到 ZnKeyboard 打一个字，就完成了")
            }
            Button(action: openSettings) {
                Text("打开系统设置").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private var translation: some View {
        Card(title: "翻译语言", symbol: "translate") {
            languageRow("我的回复译成", "键盘按钮显示为「翻译为\(translate.chineseName)」", $translate) { SharedSettings.translateLanguage = $0 }
            languageRow("收到的外文译成", "复制外文后，在键盘上点「翻译复制的内容」", $reading) { SharedSettings.readingLanguage = $0 }
        }
    }

    /// Where to get a key, as on the Mac.
    private var keyGuide: (title: String, url: URL)? {
        switch kind {
        case .deepSeek: return ("在 DeepSeek 开放平台获取", URL(string: "https://platform.deepseek.com/api_keys")!)
        case .gemini: return ("在 Google AI Studio 免费获取", URL(string: "https://aistudio.google.com/apikey")!)
        case .openAICompatible: return nil
        }
    }

    private func providerName(_ kind: AIProviderKind) -> String {
        switch kind {
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Google Gemini"
        case .openAICompatible: return "自定义"
        }
    }

    /// A closed dropdown: the choice can only change on purpose, through its menu.
    private func dropdown(_ title: String, _ value: String) -> some View {
        InputBox {
            HStack(spacing: 10) {
                Text(title).foregroundStyle(.secondary).fixedSize()
                Text(value)
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

    private var ai: some View {
        FoldingCard(title: "API 配置", symbol: "key", summary: aiConfigured ? "\(providerName(kind)) 已配置" : "未配置", open: $aiOpen) {
            Menu {
                Picker("服务商", selection: $kind) {
                    ForEach(AIProviderKind.allCases, id: \.self) { Text(providerName($0)).tag($0) }
                }
            } label: {
                dropdown("服务商", providerName(kind))
            }
            .buttonStyle(.plain)
            .onChange(of: kind) { newValue in
                SharedSettings.providerKind = newValue
                model = SharedSettings.model
                apiKey = SharedSettings.apiKey
                showKey = false
                status = nil
            }
            if kind == .openAICompatible {
                InputBox {
                    TextField("接口地址（https 开头）", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: baseURL) { SharedSettings.customBaseURL = $0 }
                }
            }
            InputBox {
                HStack {
                    // No SecureField: iOS would take the page for a login form and hide every
                    // third-party keyboard, ZnKeyboard included, in the fields around it.
                    if showKey || editingKey || apiKey.isEmpty {
                        TextField("API Key", text: $apiKey)
                            .textContentType(nil)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($editingKey)
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
                // Here, not on the field: the field leaves the page once the key is hidden.
                .onChange(of: apiKey) { SharedSettings.apiKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if apiKey.isEmpty, let guide = keyGuide {
                HStack(spacing: 4) {
                    Text("还没有 Key？").foregroundStyle(.secondary)
                    Link(guide.title + " ↗", destination: guide.url)
                }
                .font(.footnote)
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
                    dropdown("模型", model)
                }
                .buttonStyle(.plain)
                .onChange(of: model) { SharedSettings.model = $0 }
            }
            Button(action: test) {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    Text(testing ? "正在测试…" : "测试连接").font(.subheadline.weight(.semibold))
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
        }
    }

    private var layout: some View {
        Card(title: "中文键盘", symbol: "square.grid.3x3") {
            Menu {
                Picker("键盘布局", selection: $nineKey) {
                    Text("全键盘").tag(false)
                    Text("九宫格").tag(true)
                }
            } label: {
                dropdown("键盘布局", nineKey ? "九宫格" : "全键盘")
            }
            .buttonStyle(.plain)
            .onChange(of: nineKey) { SharedSettings.nineKey = $0 }
        }
    }

    private var fuzzy: some View {
        FoldingCard(title: "模糊音", symbol: "waveform", summary: "已开 \(FuzzyRules.labelled.filter { fuzzyRules.contains($0.rule) }.count) 组", open: $fuzzyOpen) {
            Text("平翘舌、前后鼻音分不清时打开，打哪个音都能出字。").font(.footnote).foregroundStyle(.secondary)
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
        FoldingCard(title: "触控与手感", symbol: "hand.tap", summary: "振动、声音、按键学习", open: $touchOpen) {
            VStack(spacing: 0) {
                setting("按键振动", "需要打开完全访问", $haptics) { SharedSettings.hapticsEnabled = $0 }
                setting("按键声音", "需要打开完全访问", $keySound) { SharedSettings.keySoundEnabled = $0 }
                setting("按键气泡", "按下时在上方放大显示字母", $keyPopup) { SharedSettings.keyPopupEnabled = $0 }
                setting("数字行", "在字母上方多显示一排数字", $numberRow) { SharedSettings.numberRow = $0 }
                setting("按键学习", "记住你的按键习惯，按偏时自动纠正", $adaptiveTouch) { SharedSettings.adaptiveTouch = $0 }
                setting("英文句首大写", "英文输入时自动大写句首字母", $autoCapitalize) { SharedSettings.autoCapitalize = $0 }
                setting("双击空格输入句号", "连按两下空格，输入句号", $doubleSpace) { SharedSettings.doubleSpacePeriod = $0 }
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
            if aiConfigured {
                Picker(title, selection: value) {
                    ForEach(TranslateLanguage.all, id: \.self) { Text($0.chineseName).tag($0) }
                }
                .labelsHidden()
            } else {
                Button { askingForKey = true } label: {
                    HStack(spacing: 4) {
                        Text(value.wrappedValue.chineseName)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                }
            }
        }
        .onChange(of: value.wrappedValue) { save($0) }
    }

    private var tryIt: some View {
        Card(title: "试一试", symbol: "text.cursor") {
            InputBox {
                TryField(text: $text, placeholder: "切到 ZnKeyboard，打几个字试试")
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
