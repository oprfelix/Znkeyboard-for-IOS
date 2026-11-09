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
}

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
    @Published var phrases = SavedTexts.phrases { didSet { SavedTexts.phrases = phrases } }
    @Published var fullAccess = SharedSettings.keyboardHasFullAccess
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

    /// The keyboard writes these with full access; nothing tells the app sooner.
    func refresh() {
        if fullAccess != SharedSettings.keyboardHasFullAccess { fullAccess = SharedSettings.keyboardHasFullAccess }
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
        case .gemini: return "Google Gemini"
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
            TranslatePage(guiding: $guiding).tabItem { Label("翻译", systemImage: "translate") }
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

struct TranslatePage: View {
    @EnvironmentObject private var store: Store
    @Binding var guiding: Bool
    @AppStorage("pasteConfirmed") private var pasteConfirmed = false
    @State private var path: [Route] = []
    @State private var askingForKey = false

    enum Route: Hashable { case apiKey }

    private var stepsLeft: Int {
        [store.fullAccess, store.fullAccess, pasteConfirmed, store.aiConfigured].filter { !$0 }.count
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    statusLine
                    if stepsLeft > 0 {
                        Button { guiding = true } label: {
                            HStack {
                                Label("继续完成设置", systemImage: "list.bullet.circle").foregroundStyle(Brand.blue)
                                Spacer()
                                Text("还差 \(stepsLeft) 步").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    languageRow("我的回复", "中文 → ", $store.translate)
                    languageRow("收到的外文", "外文 → ", $store.reading)
                } footer: {
                    Text("键盘上显示「翻译为\(store.translate.chineseName)」；复制外文后点「翻译复制的内容」。")
                }
                Section {
                    Picker(selection: $store.kind) {
                        ForEach(AIProviderKind.allCases, id: \.self) { Text(Store.providerName($0)).tag($0) }
                    } label: {
                        Label("服务商", systemImage: "sparkles")
                    }
                    if store.kind == .openAICompatible {
                        HStack {
                            Label("接口地址", systemImage: "link")
                            TextField("https://", text: $store.baseURL)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    NavigationLink(value: Route.apiKey) {
                        HStack {
                            Label("API Key", systemImage: "key")
                            Spacer()
                            Text(store.apiKey.isEmpty ? "未填写" : "已保存").foregroundStyle(store.apiKey.isEmpty ? .orange : .secondary)
                        }
                    }
                    modelRow
                } header: {
                    Text("AI 服务")
                } footer: {
                    Label("文字从手机直接发给你选的服务商，不经过我们的服务器。", systemImage: "lock.shield")
                }
            }
            .navigationTitle("翻译")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { _ in ApiKeyPage() }
            .alert("请先配置 API", isPresented: $askingForKey) {
                Button("稍后", role: .cancel) {}
                Button("去配置") { path = [.apiKey] }
            } message: {
                Text("翻译使用你自己的 AI 服务，填好 API Key 后就能选择语言。")
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(store.fullAccess ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(store.fullAccess ? "键盘已就绪" : "键盘还没启用").font(.subheadline)
            Spacer()
            if store.aiConfigured {
                Text(Store.providerName(store.kind)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func languageRow(_ title: String, _ from: String, _ value: Binding<TranslateLanguage>) -> some View {
        let row = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).foregroundStyle(.secondary)
                Text(from + value.wrappedValue.chineseName).font(.body.weight(.semibold)).foregroundStyle(.primary)
            }
            Spacer()
            Text("更改").font(.subheadline).foregroundStyle(.secondary)
        }
        if store.aiConfigured {
            Menu {
                Picker(title, selection: value) {
                    ForEach(TranslateLanguage.all, id: \.self) { Text($0.chineseName).tag($0) }
                }
            } label: { row.contentShape(Rectangle()) }
            .buttonStyle(.plain)
        } else {
            Button { askingForKey = true } label: { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        if store.kind == .openAICompatible && store.models.isEmpty {
            HStack {
                Label("模型", systemImage: "cpu")
                TextField("模型名称", text: $store.model)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } else {
            Picker(selection: $store.model) {
                ForEach(store.modelChoices, id: \.self) { Text($0).tag($0) }
            } label: {
                Label("模型", systemImage: "cpu")
            }
        }
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
                    Picker("中文键盘", selection: $store.nineKey) {
                        Text("全键盘").tag(false)
                        Text("九宫格").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("布局")
                } footer: {
                    Text("也可以在键盘上长按「中」切换。")
                }
                Section("输入") {
                    NavigationLink {
                        FuzzyPage()
                    } label: {
                        HStack {
                            Label("模糊音", systemImage: "waveform")
                            Spacer()
                            Text("\(FuzzyRules.labelled.filter { store.fuzzyRules.contains($0.rule) }.count) 组").foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        PhrasesPage()
                    } label: {
                        HStack {
                            Label("常用语", systemImage: "text.bubble")
                            Spacer()
                            Text("\(store.phrases.count) 条").foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $store.numberRow) { Label("数字行", systemImage: "number") }
                    Toggle(isOn: $store.autoCapitalize) { Label("英文句首大写", systemImage: "capslock") }
                    Toggle(isOn: $store.doubleSpace) { Label("双击空格输入句号", systemImage: "space") }
                }
                Section {
                    Toggle(isOn: $store.haptics) { Label("按键振动", systemImage: "iphone.radiowaves.left.and.right") }
                    Toggle(isOn: $store.keySound) { Label("按键声音", systemImage: "speaker.wave.2") }
                    Toggle(isOn: $store.keyPopup) { Label("按键气泡", systemImage: "bubble.middle.bottom") }
                    Toggle(isOn: $store.adaptiveTouch) { Label("按键学习", systemImage: "hand.point.up.left") }
                } header: {
                    Text("触控与手感")
                } footer: {
                    Text("振动和声音需要打开完全访问。按键学习会记住你的落点，按偏时自动纠正。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("键盘")
            .navigationBarTitleDisplayMode(.inline)
        }
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
                Section {
                    HStack(spacing: 12) {
                        AppIcon(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ZnKeyboard").font(.headline)
                            Text("版本 \(Self.version)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    HStack {
                        Label { Text("键盘状态") } icon: { Image(systemName: "keyboard").foregroundStyle(Brand.blue) }
                        Spacer()
                        Text(store.fullAccess ? "已就绪" : "未启用").foregroundStyle(store.fullAccess ? Color.secondary : Color.orange)
                    }
                    Button { Store.openSettings() } label: {
                        HStack {
                            Label { Text("系统设置").foregroundStyle(.primary) } icon: { Image(systemName: "gear").foregroundStyle(Brand.blue) }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    link("隐私政策", "hand.raised", "https://znkeyboard.2amz.com/privacy")
                    link("官网", "globe", "https://zn.2amz.com")
                }
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func link(_ title: String, _ symbol: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Label { Text(title).foregroundStyle(.primary) } icon: { Image(systemName: symbol).foregroundStyle(Brand.blue) }
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

/// Four steps for a new user; each can wait, and the translate page offers the rest later.
struct OnboardingView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("keyboardAddedConfirmed") private var addedConfirmed = false
    @AppStorage("pasteConfirmed") private var pasteConfirmed = false
    @State private var text = ""
    let done: () -> Void

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var added: Bool { addedConfirmed || store.fullAccess }
    private var allDone: Bool { added && store.fullAccess && pasteConfirmed && store.aiConfigured }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        AppIcon(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("欢迎使用 ZnKeyboard").font(.headline)
                            Text("四步就能开始，大约 3 分钟").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    step(1, "添加键盘", done: added,
                         detail: "打开「\(Store.appSettingsPath.joined(separator: " › ")) › 键盘」，打开 ZnKeyboard。")
                    if !added {
                        Button("打开设置页") { Store.openSettings() }
                        Button("我已添加") { addedConfirmed = true }
                    }
                    step(2, "打开完全访问", done: store.fullAccess,
                         detail: "在同一页打开「允许完全访问」。润色和翻译需要联网；普通打字不需要，也不会上传你输入的内容。")
                    if added && !store.fullAccess {
                        Button("打开设置页") { Store.openSettings() }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("打开后，在下面切到 ZnKeyboard 打一个字，这一步就会自动打勾。").font(.footnote).foregroundStyle(.secondary)
                            TryField(text: $text, placeholder: "切到 ZnKeyboard 打一个字")
                        }
                        .padding(.vertical, 4)
                    }
                    NavigationLink {
                        PasteGuidePage()
                    } label: {
                        step(3, "允许读取复制的内容", done: pasteConfirmed,
                             detail: "复制外文后一键翻译、剪贴板记录都要用到，不然每次都会弹窗问你。")
                    }
                    NavigationLink {
                        ConnectAIPage()
                    } label: {
                        step(4, "连接 AI 服务", done: store.aiConfigured,
                             detail: "选 DeepSeek 或 Google Gemini，粘贴你的 API Key。")
                    }
                }
                Section {
                    Button(action: done) {
                        Text(allDone ? "开始使用" : "稍后再说")
                            .font(.body.weight(allDone ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(allDone ? Brand.blue : .secondary)
                } footer: {
                    if !allDone { Text("没完成的步骤，之后在「翻译」页顶部可以继续。") }
                }
            }
            .navigationTitle("设置向导")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .onReceive(poll) { _ in store.refresh() }
        }
        .background(KeyboardDismisser())
    }

    private func step(_ number: Int, _ title: String, done: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Brand.blue)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if !done { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Step 3: where "Paste from Other Apps" is, drawn as Settings shows it.
struct PasteGuidePage: View {
    @AppStorage("pasteConfirmed") private var pasteConfirmed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在系统设置里这样找：").font(.subheadline.weight(.medium))
                    HStack(spacing: 4) {
                        ForEach(Array(Store.appSettingsPath.enumerated()), id: \.offset) { index, part in
                            if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Text(part).font(.footnote)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    Text("找到「从其他 App 粘贴」，改成「允许」：").font(.subheadline)
                    VStack(spacing: 0) {
                        HStack { Text("键盘"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            .padding(.horizontal, 12).frame(height: 40)
                        Divider().padding(.leading, 12)
                        HStack {
                            Text("从其他 App 粘贴")
                            Spacer()
                            Text("允许").foregroundStyle(Brand.blue)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(Brand.blue.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.blue, lineWidth: 1.5))
                    }
                    .font(.subheadline)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                }
                .padding(.vertical, 6)
                .listRowBackground(Color(.systemGroupedBackground))
            }
            Section {
                Button("直接打开设置页") { Store.openSettings() }
                Button("我已设置好") {
                    pasteConfirmed = true
                    dismiss()
                }
                .font(.body.weight(.semibold))
            } footer: {
                Text("看不到这一项？先在任意 App 里复制一段文字，切到 ZnKeyboard 点「翻译复制的内容」，系统弹出询问时点「允许粘贴」，这一项就会出现。")
            }
        }
        .navigationTitle("允许读取复制的内容")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Step 4: a provider, a key, and a test that ends the step.
struct ConnectAIPage: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Picker("服务商", selection: $store.kind) {
                    Text("DeepSeek").tag(AIProviderKind.deepSeek)
                    Text("Google Gemini").tag(AIProviderKind.gemini)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                KeyField(key: $store.apiKey)
            } footer: {
                if let guide = Store.keyGuide(store.kind) {
                    HStack(spacing: 4) {
                        Text("还没有 Key？")
                        Link(guide.title + " ↗", destination: guide.url)
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
