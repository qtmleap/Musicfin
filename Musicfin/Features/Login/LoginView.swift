import SwiftUI

/// サーバー URL の入力 → ユーザー名とパスワード（または Quick Connect）の 2 段構成。
struct LoginView: View {
    @Environment(AuthStore.self) private var auth

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnected = false
    @State private var isWorking = false
    @FocusState private var focusedField: Field?

    private enum Field { case server, username, password }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                if isConnected {
                    credentialsSection
                    quickConnectSection
                }
                if let error = auth.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Musicfin")
            .disabled(isWorking)
            .onAppear { serverURL = UserDefaults.standard.string(forKey: "server.url") ?? "" }
            .onDisappear { auth.cancelQuickConnect() }
        }
    }

    // MARK: - サーバー

    private var serverSection: some View {
        Section {
            TextField("jellyfin.example.com", text: $serverURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .server)
                .onSubmit { Task { await connect() } }

            if isConnected, let name = auth.serverName {
                LabeledContent("接続先", value: name)
            } else {
                Button("接続") { Task { await connect() } }
                    .disabled(serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("サーバー")
        } footer: {
            Text("`https://` を省略した場合は自動で補われます。ローカルの `http://` も利用できます。")
        }
    }

    // MARK: - 認証

    private var credentialsSection: some View {
        Section("ログイン") {
            TextField("ユーザー名", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .username)

            SecureField("パスワード", text: $password)
                .textContentType(.password)
                .focused($focusedField, equals: .password)
                .onSubmit { Task { await signIn() } }

            Button("ログイン") { Task { await signIn() } }
                .disabled(username.isEmpty)
        }
    }

    private var quickConnectSection: some View {
        Section {
            if let code = auth.quickConnectCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(code)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .kerning(6)
                        .frame(maxWidth: .infinity)
                    Text("Jellyfin の Web 画面で［Quick Connect］を開き、このコードを入力してください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button("キャンセル", role: .destructive) { auth.cancelQuickConnect() }
            } else {
                Button("Quick Connect を使う") { auth.startQuickConnect() }
            }
        } header: {
            Text("パスワードを入力せずにログイン")
        }
    }

    // MARK: - 動作

    private func connect() async {
        isWorking = true
        defer { isWorking = false }
        focusedField = nil
        isConnected = await auth.connect(to: serverURL)
        if isConnected { focusedField = .username }
    }

    private func signIn() async {
        isWorking = true
        defer { isWorking = false }
        focusedField = nil
        await auth.signIn(username: username, password: password)
        password = ""
    }
}
