import SwiftUI

@main
struct ZnKeyboardApp: App {
    var body: some Scene {
        WindowGroup { SetupView() }
    }
}

/// Turning the keyboard on, and a box to try it in.
struct SetupView: View {
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("启用键盘") {
                    Text("1. 打开「设置 → 通用 → 键盘 → 键盘 → 添加新键盘」，选择 ZnKeyboard。")
                    Text("2. 点 ZnKeyboard，打开「允许完全访问」，翻译和润色需要联网。")
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("试一试") {
                    TextField("在这里打字", text: $text, axis: .vertical)
                }
            }
            .navigationTitle("ZnKeyboard")
        }
    }
}
