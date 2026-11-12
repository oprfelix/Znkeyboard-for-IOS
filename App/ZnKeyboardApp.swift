import Combine
import PinyinCore
import SwiftUI

@main
struct ZnKeyboardApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Brand.blue)
        }
    }
}

enum Brand {
    /// The blue of the app icon.
    static let blue = Color(red: 0.27, green: 0.52, blue: 1)
    /// Where the hero card's gradient ends: the blue leaning to violet.
    static let violet = Color(red: 0.45, green: 0.38, blue: 0.98)
}

/// A setting's icon: the tint on a pale tile of itself. One colour for every row, so the page
/// stays quiet and the language card is the only thing in colour.
struct TileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.blue)
                .frame(width: 29, height: 29)
                .background(Brand.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            configuration.title
        }
    }
}

extension LabelStyle where Self == TileLabelStyle {
    static var tile: TileLabelStyle { TileLabelStyle() }
}

/// The corner every card of ours shares, close to the list's own rows.
enum Card {
    static let radius: CGFloat = 24
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

extension View {
    /// Liquid Glass from iOS 26, frosted material before it. A tint colours the glass itself.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            let base = tint.map { Glass.regular.tint($0) } ?? .regular
            glassEffect(interactive ? base.interactive() : base, in: shape)
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// The pages' backdrop: the grouped grey with a faint wash of the brand colours at the top,
    /// for the glass to show.
    func ambientBackground() -> some View {
        scrollContentBackground(.hidden).background(AmbientBackground())
    }
}

struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let strength = scheme == .dark ? 0.32 : 0.22
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground)
            GeometryReader { geo in
                Circle().fill(Brand.blue).frame(width: geo.size.width * 0.9)
                    .blur(radius: 90).opacity(strength)
                    .offset(x: -geo.size.width * 0.3, y: -geo.size.width * 0.35)
                Circle().fill(Brand.violet).frame(width: geo.size.width * 0.8)
                    .blur(radius: 90).opacity(strength)
                    .offset(x: geo.size.width * 0.45, y: -geo.size.width * 0.15)
            }
        }
        .ignoresSafeArea()
    }
}

/// A light tick under the finger when a choice changes.
@MainActor func selectionTick() { UISelectionFeedbackGenerator().selectionChanged() }

/// Everything the pages show, saved as it changes; the keyboard reads the same settings.
@MainActor
final class Store: ObservableObject {
    @Published var kind = SharedSettings.providerKind {
        didSet {
            guard kind != oldValue else { return }
            SharedSettings.providerKind = kind
            model = SharedSettings.model
            apiKey = SharedSettings.apiKey
            status = nil
        }
    }
    @Published var baseURL = SharedSettings.customBaseURL { didSet { SharedSettings.customBaseURL = baseURL } }
    @Published var model = SharedSettings.model { didSet { SharedSettings.model = model } }
    @Published var apiKey = SharedSettings.apiKey {
        didSet { SharedSettings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    @Published var translate = SharedSettings.translateLanguage { didSet { SharedSettings.translateLanguage = translate } }
    @Published var reading = SharedSettings.readingLanguage { didSet { SharedSettings.readingLanguage = reading } }
    @Published var fuzzyRules = SharedSettings.fuzzyRules { didSet { SharedSettings.fuzzyRules = fuzzyRules } }
    @Published var haptics = SharedSettings.hapticsEnabled { didSet { SharedSettings.hapticsEnabled = haptics } }
    @Published var keySound = SharedSettings.keySoundEnabled { didSet { SharedSettings.keySoundEnabled = keySound } }
    @Published var keyPopup = SharedSettings.keyPopupEnabled { didSet { SharedSettings.keyPopupEnabled = keyPopup } }
    @Published var autoCapitalize = SharedSettings.autoCapitalize { didSet { SharedSettings.autoCapitalize = autoCapitalize } }
    @Published var doubleSpace = SharedSettings.doubleSpacePeriod { didSet { SharedSettings.doubleSpacePeriod = doubleSpace } }
    @Published var numberRow = SharedSettings.numberRow { didSet { SharedSettings.numberRow = numberRow } }
    @Published var nineKey = SharedSettings.nineKey { didSet { SharedSettings.nineKey = nineKey } }
    @Published var adaptiveTouch = SharedSettings.adaptiveTouch { didSet { SharedSettings.adaptiveTouch = adaptiveTouch } }
    @Published var aiRerank = SharedSettings.aiRerank { didSet { SharedSettings.aiRerank = aiRerank } }
    @Published var phrases = SavedTexts.phrases { didSet { SavedTexts.phrases = phrases } }
    @Published var fullAccess = SharedSettings.keyboardHasFullAccess
    /// nil when iOS doesn't say which keyboards are on.
    @Published var keyboardAdded = Store.keyboardIsAdded()
    /// The keyboard has translated copied text once: the guide's practice is done.
    @Published var readTried = SharedSettings.readTried
    @Published var models: [String] = []
    @Published var status: (ok: Bool, text: String)?
    @Published var testing = false

    var aiConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty && (kind != .openAICompatible || !baseURL.isEmpty)
    }

    /// The fixed list for DeepSeek and Gemini; a custom service lists what it reports.
    var modelChoices: [String] {
        if !kind.models.isEmpty { return kind.models }
        return models.contains(model) || model.isEmpty ? models : [model] + models
    }

    /// Added, or known to be added because it has run with full access.
    var keyboardReady: Bool { keyboardAdded == true || fullAccess }

    /// Setup steps still to do: add the keyboard, full access, AI.
    var setupStepsLeft: Int {
        [keyboardReady, fullAccess, aiConfigured].filter { !$0 }.count
    }

    /// The keyboards the user has turned on, as iOS keeps them for every app.
    static func keyboardIsAdded() -> Bool? {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String]
        else { return nil }
        return list.contains(id + ".keyboard")
    }

    /// The keyboard writes these with full access; nothing tells the app sooner.
    func refresh() {
        let added = Store.keyboardIsAdded()
        if keyboardAdded != added { keyboardAdded = added }
        // Without full access the keyboard can't clear its own flag; a removed keyboard has none.
        if added == false, SharedSettings.keyboardHasFullAccess { SharedSettings.keyboardHasFullAccess = false }
        if fullAccess != SharedSettings.keyboardHasFullAccess { fullAccess = SharedSettings.keyboardHasFullAccess }
        if readTried != SharedSettings.readTried { readTried = SharedSettings.readTried }
        if nineKey != SharedSettings.nineKey { nineKey = SharedSettings.nineKey }
        let saved = SavedTexts.phrases
        if phrases != saved { phrases = saved }
    }

    func loadModels() async {
        models = []
        guard kind == .openAICompatible, !apiKey.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled, let found = try? await AIClient().models(SharedSettings.provider), !Task.isCancelled else { return }
        models = found
    }

    @discardableResult
    func test() async -> Bool {
        testing = true
        status = nil
        defer { testing = false }
        do {
            _ = try await AIClient().polish("hello", with: SharedSettings.provider)
            status = (true, "连接成功")
            return true
        } catch {
            status = (false, AIClient.message(for: error, chinese: true))
            return false
        }
    }

    static func providerName(_ kind: AIProviderKind) -> String {
        switch kind {
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Google"
        case .openAICompatible: return "自定义"
        }
    }

    /// Where to get a key, as on the Mac.
    static func keyGuide(_ kind: AIProviderKind) -> (title: String, url: URL)? {
        switch kind {
        case .deepSeek: return ("在 DeepSeek 开放平台获取", URL(string: "https://platform.deepseek.com/api_keys")!)
        case .gemini: return ("在 Google AI Studio 免费获取", URL(string: "https://aistudio.google.com/apikey")!)
        case .openAICompatible: return nil
        }
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Where this app's own page sits in Settings, which moved in iOS 18.
    static var appSettingsPath: [String] {
        if #available(iOS 18, *) { return ["设置", "App", "ZnKeyboard"] }
        return ["设置", "ZnKeyboard"]
    }
}

/// The three pages, and the guide on first launch.
struct RootView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var guiding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            TranslatePage(guiding: $guiding).tabItem { Label("翻译", systemImage: "bubble.left.and.text.bubble.right") }
            KeyboardPage().tabItem { Label("键盘", systemImage: "keyboard") }
            AboutPage().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .background(KeyboardDismisser())
        .onAppear {
            store.refresh()
            if !onboardingDone { guiding = true }
        }
        .onChange(of: scenePhase) { if $0 == .active { store.refresh() } }
        .task(id: "\(store.kind.rawValue)\(store.apiKey)\(store.baseURL)") { await store.loadModels() }
        .fullScreenCover(isPresented: $guiding) {
            OnboardingView { guiding = false; onboardingDone = true }
                .environmentObject(store)
                .tint(Brand.blue)
        }
    }
}

// MARK: Translate

/// Where the translate page leads: the AI service, and the key inside it.
enum TranslateRoute: Hashable { case ai, apiKey }

struct TranslatePage: View {
    @EnvironmentObject private var store: Store
    @Binding var guiding: Bool
    @State private var path: [TranslateRoute] = []
    @State private var askingForKey = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    status
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    languageCard
                        .padding(1)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    NavigationLink(value: TranslateRoute.ai) {
                        HStack {
                            Label("AI 服务", systemImage: "sparkles").labelStyle(.tile)
                            Spacer()
                            Text(store.aiConfigured ? Store.providerName(store.kind) : "未配置")
                                .foregroundStyle(store.aiConfigured ? Color.secondary : Color.orange)
                        }
                    }
                }
            }
            .ambientBackground()
            .navigationTitle("翻译")
            .navigationDestination(for: TranslateRoute.self) { route in
                switch route {
                case .ai: AIServicePage()
                case .apiKey: ApiKeyPage()
                }
            }
            .onChange(of: store.translate) { _ in selectionTick() }
            .onChange(of: store.reading) { _ in selectionTick() }
            .alert("请先配置 API", isPresented: $askingForKey) {
                Button("稍后", role: .cancel) {}
                Button("去配置") { path = [.ai, .apiKey] }
            } message: {
                Text("翻译使用你自己的 AI 服务，填好 API Key 后就能选择语言。")
            }
        }
    }

    /// A quiet line when all is ready; a card with the next step when something is missing.
    @ViewBuilder
    private var status: some View {
        if !store.fullAccess {
            Button { guiding = true } label: {
                notice("键盘还没启用", "完成设置后才能用 ZnKeyboard 打字", action: "去设置")
            }
            .buttonStyle(.plain)
        } else if !store.aiConfigured {
            Button { path = [.ai, .apiKey] } label: {
                notice("还没配置 API Key", "翻译要连接 AI 服务", action: "去配置")
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("已就绪").font(.subheadline.weight(.medium))
                Text("完全访问 · AI 已配置").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    private func notice(_ title: String, _ detail: String, action: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").font(.title3).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(action).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .glass(Capsule(), tint: .orange, interactive: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glass(Card.shape)
        .padding(1)
        .contentShape(Rectangle())
    }

    /// The two directions the app translates, on glass; a tap on a language changes it. Only the
    /// target is chosen: the AI reads whatever language the user writes or receives.
    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            languageLine("我的回复", $store.translate)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
            languageLine("收到的消息", $store.reading)
        }
        .padding(20)
        .glass(Card.shape)
    }

    private func languageLine(_ title: String, _ value: Binding<TranslateLanguage>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("翻译成").font(.title3.weight(.semibold))
                languagePicker(title, value)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func languagePicker(_ title: String, _ value: Binding<TranslateLanguage>) -> some View {
        let pill = HStack(spacing: 6) {
            Text(value.wrappedValue.chineseName).font(.title3.weight(.semibold))
            Image(systemName: "chevron.down").font(.caption.weight(.bold)).opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .glass(Capsule(), tint: Brand.blue, interactive: true)
        if store.aiConfigured {
            Menu {
                Picker(title, selection: value) {
                    ForEach(TranslateLanguage.all, id: \.self) { Text($0.chineseName).tag($0) }
                }
            } label: { pill }
            .buttonStyle(.plain)
        } else {
            Button { askingForKey = true } label: { pill }.buttonStyle(.plain)
        }
    }
}

/// The service, its key and model: set once, so they live a level down from the languages.
struct AIServicePage: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        List {
            Section {
                choiceRow("服务商", "sparkles", value: Store.providerName(store.kind), selection: $store.kind,
                          options: AIProviderKind.allCases.map { ($0, Store.providerName($0)) })
                if store.kind == .openAICompatible {
                    HStack {
                        Label("接口地址", systemImage: "link").labelStyle(.tile)
                        TextField("https://", text: $store.baseURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                NavigationLink(value: TranslateRoute.apiKey) {
                    HStack {
                        Label("API Key", systemImage: "key.fill").labelStyle(.tile)
                        Spacer()
                        Text(store.apiKey.isEmpty ? "未填写" : "已保存").foregroundStyle(store.apiKey.isEmpty ? .orange : .secondary)
                    }
                }
                modelRow
            } footer: {
                Label("文字从手机直接发给服务商，不经过我们的服务器。", systemImage: "lock.shield")
            }
        }
        .ambientBackground()
        .navigationTitle("AI 服务")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var modelRow: some View {
        if store.kind == .openAICompatible && store.models.isEmpty {
            HStack {
                Label("模型", systemImage: "cpu").labelStyle(.tile)
                TextField("模型名称", text: $store.model)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } else {
            choiceRow("模型", "cpu", value: store.model, selection: $store.model,
                      options: store.modelChoices.map { ($0, $0) })
        }
    }

    /// A choice that reads like the rows around it: the value in grey, not the tint, with a small
    /// mark that it opens a menu.
    private func choiceRow<Value: Hashable>(_ title: String, _ symbol: String, value: String,
                                            selection: Binding<Value>, options: [(Value, String)]) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
        } label: {
            HStack {
                Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: symbol) }.labelStyle(.tile)
                Spacer()
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.medium)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The key, where to get one, and a test of it.
struct ApiKeyPage: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        List {
            Section {
                KeyField(key: $store.apiKey)
            } header: {
                Text(Store.providerName(store.kind))
            } footer: {
                if store.apiKey.isEmpty, let guide = Store.keyGuide(store.kind) {
                    HStack(spacing: 4) {
                        Text("还没有 Key？")
                        Link(guide.title + " ↗", destination: guide.url)
                    }
                }
            }
            Section {
                Button {
                    Task { await store.test() }
                } label: {
                    HStack {
                        Text(store.testing ? "正在测试…" : "测试连接")
                        Spacer()
                        if store.testing { ProgressView() }
                    }
                }
                .disabled(store.testing || store.apiKey.isEmpty)
            } footer: {
                if let status = store.status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(status.ok ? .green : .red)
                }
            }
        }
        .ambientBackground()
        .navigationTitle("API Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// No SecureField: iOS would take the page for a login form and hide every third-party keyboard,
/// ZnKeyboard included, in the fields around it. The key shows as dots until tapped.
struct KeyField: View {
    @Binding var key: String
    @State private var showing = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack {
            if showing || editing || key.isEmpty {
                TextField("粘贴 API Key", text: $key)
                    .textContentType(nil)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editing)
            } else {
                Text(String(repeating: "•", count: min(key.count, 24)))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showing = true }
            }
            if !key.isEmpty {
                Button { showing.toggle() } label: {
                    Image(systemName: showing ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: Keyboard

struct KeyboardPage: View {
    @EnvironmentObject private var store: Store
    @State private var text = ""

    /// What AI 整句排序 does, or once on, how long the keyboard took per keystroke.
    private var aiRerankNote: String {
        let stats = SharedSettings.aiRerankStats
        if store.aiRerank, stats.calls > 0 {
            return String(format: "AI 整句排序：已排序 %d 次按键，平均每次 %.1f 毫秒。", stats.calls, stats.millis / Double(stats.calls))
        }
        return "AI 整句排序用手机上的语言模型给整句候选重新排序，不联网。"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TryField(text: $text, placeholder: "切到 ZnKeyboard，打几个字试试")
                        .padding(.vertical, 4)
                } header: {
                    Text("试一试")
                }
                Section {
                    HStack(spacing: 12) {
                        LayoutCard(title: "全键盘", nineKey: false, selected: !store.nineKey) { store.nineKey = false }
                        LayoutCard(title: "九宫格", nineKey: true, selected: store.nineKey) { store.nineKey = true }
                    }
                    .padding(1)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    Text("布局")
                }
                Section {
                    NavigationLink {
                        FuzzyPage()
                    } label: {
                        HStack {
                            Label("模糊音", systemImage: "waveform").labelStyle(.tile)
                            Spacer()
                            Text("\(FuzzyRules.labelled.filter { store.fuzzyRules.contains($0.rule) }.count) 组").foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        PhrasesPage()
                    } label: {
                        HStack {
                            Label("常用语", systemImage: "text.bubble.fill").labelStyle(.tile)
                            Spacer()
                            Text("\(store.phrases.count) 条").foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $store.aiRerank) { Label("AI 整句排序（实验）", systemImage: "sparkles").labelStyle(.tile) }
                    Toggle(isOn: $store.numberRow) { Label("数字行", systemImage: "number").labelStyle(.tile) }
                    Toggle(isOn: $store.autoCapitalize) { Label("英文句首大写", systemImage: "shift.fill").labelStyle(.tile) }
                    Toggle(isOn: $store.doubleSpace) { Label("双击空格输入句号", systemImage: "space").labelStyle(.tile) }
                } header: {
                    Text("输入")
                } footer: {
                    Text(aiRerankNote)
                }
                Section {
                    Toggle(isOn: $store.haptics) { Label("按键振动", systemImage: "iphone.radiowaves.left.and.right").labelStyle(.tile) }
                    Toggle(isOn: $store.keySound) { Label("按键声音", systemImage: "speaker.wave.2.fill").labelStyle(.tile) }
                    Toggle(isOn: $store.keyPopup) { Label("按键气泡", systemImage: "bubble.middle.bottom.fill").labelStyle(.tile) }
                    Toggle(isOn: $store.adaptiveTouch) { Label("按键学习", systemImage: "hand.point.up.left.fill").labelStyle(.tile) }
                } header: {
                    Text("触控与手感")
                } footer: {
                    Text("振动和声音需要完全访问。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .ambientBackground()
            .navigationTitle("键盘")
        }
    }
}

/// One of the two layouts, drawn as a small keyboard; the chosen one is outlined in the tint.
struct LayoutCard: View {
    let title: String
    let nineKey: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button { if !selected { selectionTick() }; action() } label: {
            VStack(spacing: 10) {
                preview
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 78)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Brand.blue : Color.secondary.opacity(0.5))
                    Text(title).font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(.primary)
                }
            }
            .padding(12)
            .glass(Card.shape)
            .overlay(Card.shape.strokeBorder(selected ? Brand.blue : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    /// Rows of keys for the full layout, a 3 x 3 grid for nine keys; under both, the row with the
    /// wide space bar, so it reads as a keyboard at a glance.
    private var preview: some View {
        let rows = nineKey ? [3, 3, 3] : [10, 9, 7]
        return VStack(spacing: 3.5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, count in
                HStack(spacing: nineKey ? 4 : 2.5) {
                    ForEach(0..<count, id: \.self) { _ in key.frame(width: nineKey ? 22 : nil) }
                }
                .frame(maxWidth: nineKey ? nil : .infinity)
                .padding(.horizontal, nineKey ? 0 : CGFloat(10 - count) * 3)
            }
            HStack(spacing: nineKey ? 4 : 2.5) {
                key.frame(width: nineKey ? 12 : 16)
                if !nineKey { key.frame(width: 16) }
                key.frame(maxWidth: .infinity)
                key.frame(width: nineKey ? 12 : 22)
            }
            .frame(width: nineKey ? 74 : nil)
        }
    }

    private var key: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(selected ? Brand.blue.opacity(0.55) : Color.secondary.opacity(0.35))
    }
}

struct FuzzyPage: View {
    @EnvironmentObject private var store: Store

    private static let hints = [
        "z = zh": "打 zi 也能出「知」",
        "c = ch": "打 ci 也能出「吃」",
        "s = sh": "打 si 也能出「是」",
        "n = l": "打 nan 也能出「蓝」",
        "an = ang": "打 fan 也能出「方」",
        "en = eng": "打 chen 也能出「成」",
        "in = ing": "打 xin 也能出「星」",
    ]

    var body: some View {
        List {
            Section {
                ForEach(FuzzyRules.labelled, id: \.rule) { item in
                    Toggle(isOn: Binding(
                        get: { store.fuzzyRules.contains(item.rule) },
                        set: { on in
                            var next = store.fuzzyRules
                            if on { next.insert(item.rule) } else { next.remove(item.rule) }
                            store.fuzzyRules = next
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                            if let hint = Self.hints[item.label] { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            } footer: {
                Text("平翘舌、前后鼻音分不清时打开，打哪个音都能出字。")
            }
        }
        .ambientBackground()
        .navigationTitle("模糊音")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Typed from the keyboard's phrases panel; the keyboard can add copies to it too.
struct PhrasesPage: View {
    @EnvironmentObject private var store: Store
    @State private var newPhrase = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("新的常用语", text: $newPhrase, axis: .vertical).lineLimit(1...4)
                    Button("添加") {
                        if SavedTexts.addPhrase(newPhrase) { store.phrases = SavedTexts.phrases }
                        newPhrase = ""
                    }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("地址、收款信息、固定回复，在键盘上点 \(Image(systemName: "text.bubble")) 就能输入。也可以在键盘的剪贴板里长按一条，存为常用语。")
            }
            if !store.phrases.isEmpty {
                Section {
                    ForEach(store.phrases, id: \.self) { Text($0) }
                        .onDelete { store.phrases.remove(atOffsets: $0) }
                        .onMove { store.phrases.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("左滑删除，点右上角「编辑」可以调整顺序。")
                }
            }
        }
        .toolbar { if !store.phrases.isEmpty { EditButton() } }
        .ambientBackground()
        .navigationTitle("常用语")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: About

struct AboutPage: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        NavigationStack {
            List {
                // The app's own face: a large icon, its name, and the version under it.
                Section {
                    VStack(spacing: 10) {
                        AppIcon(size: 96)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                        Text("ZnKeyboard").font(.title2.weight(.semibold))
                        Text("版本 \(Self.version)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Button { Store.openSettings() } label: {
                        HStack {
                            Label { Text("系统设置").foregroundStyle(.primary) } icon: { Image(systemName: "gearshape.fill") }.labelStyle(.tile)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    link("隐私政策", "hand.raised.fill", "https://znkeyboard.2amz.com/privacy")
                    link("官网", "globe", "https://zn.2amz.com")
                }
            }
            .ambientBackground()
            .navigationTitle("关于")
        }
    }

    private func link(_ title: String, _ symbol: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: symbol) }.labelStyle(.tile)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}

struct AppIcon: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = UIImage(named: "AppIcon60x60") {
                Image(uiImage: icon).resizable()
            } else {
                Brand.blue
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// MARK: Onboarding

/// Three steps for a new user. Each one ticks itself when iOS shows it is done; none asks the
/// user to say so. Every step can wait, and the translate page offers the rest later.
struct OnboardingView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var focusTry = 0
    /// Typed a while ago and still no tick: only then is it worth saying what may be wrong.
    @State private var stillWaiting = false
    @State private var practiceText = ""
    @State private var practiceFocus = 0
    @State private var copiedSample = false
    /// Set on the way to Settings, so coming back can bring up the keyboard to try.
    @State private var wentToSettings = false
    let done: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private enum Step: Int { case add = 1, access, ai, practice, finished }

    /// What the practice has the user copy: a message as a friend abroad might send it.
    private static let sample = "Are you free this weekend?"

    /// The first step not done. When iOS doesn't say whether the keyboard is added, typing with
    /// it in step 2 shows both at once, so step 2 leads.
    private var current: Step {
        if !store.keyboardReady && store.keyboardAdded != nil { return .add }
        if !store.fullAccess { return .access }
        if !store.aiConfigured { return .ai }
        if !store.readTried { return .practice }
        return .finished
    }

    private var keyboardPath: String {
        (Store.appSettingsPath + ["键盘"]).joined(separator: " › ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        AppIcon(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("欢迎使用 ZnKeyboard").font(.headline)
                            Text(current == .finished ? "全部设置好了" : "跟着做，每一步完成后会自动打勾")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    addStep
                    accessStep
                    aiStep
                    practiceStep
                }
                Section {
                    Button(action: done) {
                        Text(current == .finished ? "开始使用" : "先用起来，稍后再设置")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(Brand.blue)
                } footer: {
                    if current != .finished { Text("没完成的步骤，之后在「翻译」页顶部可以继续。") }
                }
            }
            .navigationTitle("设置向导")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .animation(.default, value: current)
            .onReceive(poll) { _ in store.refresh() }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, wentToSettings else { return }
                wentToSettings = false
                store.refresh()
                // Back from Settings with full access to show: bring up the keyboard to try.
                if current == .access { focusTry += 1 }
            }
        }
        .background(KeyboardDismisser())
    }

    private func openSettings() {
        wentToSettings = true
        Store.openSettings()
    }

    // MARK: Steps

    @ViewBuilder
    private var addStep: some View {
        let isCurrent = current == .add || (current == .access && !store.keyboardReady)
        step(1, "添加键盘", done: store.keyboardReady, current: isCurrent,
             detail: "点下面的按钮，在设置里依次点「\(keyboardPath)」，打开 ZnKeyboard。如果打开的是设置首页，往下滑找到「App」。")
        if current == .add {
            Button("去设置添加") { openSettings() }
                .font(.body.weight(.semibold))
        }
    }

    @ViewBuilder
    private var accessStep: some View {
        step(2, "打开完全访问", done: store.fullAccess, current: current == .access,
             detail: "在同一页打开「允许完全访问」，系统会弹出一段提示，点「允许」。翻译需要联网；普通打字不需要，也不会上传你输入的内容。")
        if current == .access {
            Button("去设置打开") { openSettings() }
                .font(.body.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                (Text("打开后回到这里，点一下下面的输入框，再点键盘左下角的 ") + Text(Image(systemName: "globe")) + Text("，切到 ZnKeyboard，这一步就会自动打勾。"))
                    .font(.footnote).foregroundStyle(.secondary)
                TryField(text: $text, placeholder: "点这里，切到 ZnKeyboard", focus: focusTry)
                if stillWaiting {
                    Text("还没打勾？看看「允许完全访问」是不是打开了，以及现在用的是不是 ZnKeyboard（键盘上方有「翻译为」按钮）。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
            .task(id: text.isEmpty) {
                stillWaiting = false
                guard !text.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { stillWaiting = true }
            }
        }
    }

    @ViewBuilder
    private var aiStep: some View {
        let row = step(3, "连接 AI 服务", done: store.aiConfigured, current: current == .ai,
                       detail: "选 DeepSeek 或 Google，粘贴你的 API Key。只打字可以先跳过。")
        if store.aiConfigured {
            row
        } else {
            NavigationLink { ConnectAIPage() } label: { row }
        }
    }

    /// Copy a foreign message, translate it on the keyboard: done once, the feature is found.
    @ViewBuilder
    private var practiceStep: some View {
        step(4, "试一次：翻译对方发来的外文", done: store.readTried, current: current == .practice,
             detail: store.aiConfigured
                ? "以后在微信等聊天 App 里：长按对方的消息 → 拷贝 → 回到输入框，点键盘上的「翻译刚复制的外文」。现在先在这里试一次。"
                : "连接 AI 服务后就能试。")
        if current == .practice {
            VStack(alignment: .leading, spacing: 10) {
                Text("假设对方发来这句话：").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Text(Self.sample).font(.body)
                    Spacer()
                    Button(copiedSample ? "已复制" : "复制") {
                        UIPasteboard.general.string = Self.sample
                        copiedSample = true
                        practiceFocus += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.blue)
                }
                .padding(10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(copiedSample
                     ? "在弹出的键盘上点「翻译刚复制的外文」。第一次用会先问是否同意发送，点「同意」；系统问是否允许粘贴时，点「允许粘贴」。看到中文译文，这一步就会打勾。"
                     : "点「复制」，就像在聊天里长按消息后点「拷贝」。")
                    .font(.footnote).foregroundStyle(.secondary)
                TryField(text: $practiceText, placeholder: "键盘会在这里弹出", focus: practiceFocus)
            }
            .padding(.vertical, 4)
        }
    }

    private func step(_ number: Int, _ title: String, done: Bool, current: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : (current ? Brand.blue : Color(.systemGray3)))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                    .foregroundStyle(done || current ? .primary : .secondary)
                if current { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Step 3: a provider, a key, and a test that ends the step.
struct ConnectAIPage: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Picker("服务商", selection: $store.kind) {
                    Text("DeepSeek").tag(AIProviderKind.deepSeek)
                    Text("Google").tag(AIProviderKind.gemini)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                KeyField(key: $store.apiKey)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key 是一串密钥，相当于你在 AI 服务商那里的账号凭证。注册后在网站上点「创建」，复制下来粘贴到这里。")
                    if let guide = Store.keyGuide(store.kind) {
                        HStack(spacing: 4) {
                            Text("还没有 Key？")
                            Link(guide.title + " ↗", destination: guide.url)
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { if await store.test() { dismiss() } }
                } label: {
                    HStack {
                        Text(store.testing ? "正在测试…" : "测试并完成").font(.body.weight(.semibold))
                        Spacer()
                        if store.testing { ProgressView() }
                    }
                }
                .disabled(store.testing || store.apiKey.isEmpty)
                Button("跳过，先只用打字") { dismiss() }.foregroundStyle(.secondary)
            } footer: {
                if let status = store.status, !status.ok {
                    Label(status.text, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("连接 AI 服务")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if store.kind == .openAICompatible { store.kind = .deepSeek } }
    }
}

// MARK: Shared pieces

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

/// A plain UIKit text view: an ordinary field for every keyboard the user has, ZnKeyboard included.
struct TryField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Raising it brings up the keyboard in the field.
    var focus = 0

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
        if focus != context.coordinator.focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: TryField
        weak var placeholder: UILabel?
        var focus: Int
        init(_ parent: TryField) {
            self.parent = parent
            focus = parent.focus
        }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            placeholder?.isHidden = !view.text.isEmpty
        }
    }
}
