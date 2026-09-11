import SwiftUI

struct AstraLoginView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var serverURL = UserDefaults.standard.string(forKey: "server.url") ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnected = false
    @State private var isWorking = false
    // コード取得前も待機中として扱い、認証方式の同時実行を防ぐ。
    @State private var isQuickConnecting = false
    @FocusState private var focusedField: AstraField?

    private enum AstraField {
        case server
        case username
        case password
    }

    private var isBusy: Bool { isWorking || auth.state == .connecting }
    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                hero
                VStack(alignment: .leading, spacing: 24) {
                    if isConnected {
                        authenticationStep
                            .transition(.opacity)
                    } else {
                        serverStep
                            .transition(.opacity)
                    }
                    if let error = auth.lastError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.12), Color(uiColor: .systemBackground)],
                startPoint: .topLeading, endPoint: .center
            )
            .ignoresSafeArea()
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isConnected)
        .onChange(of: auth.lastError) { _, error in
            if error != nil && isQuickConnecting { cancelQuickConnect() }
        }
        .onDisappear {
            cancelQuickConnect()
            password = ""
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                .accessibilityHidden(true)
            Text("Musicfin")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("あなたの音楽を、いつでも。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("音楽ライブラリに接続")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Jellyfin サーバーの URL を入力してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("サーバー URL").font(.subheadline.weight(.medium))
                TextField("https://jellyfin.example.com", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focusedField, equals: .server)
                    .padding(16)
                    .background(.background, in: .rect(cornerRadius: 14))
                    .accessibilityLabel("サーバー URL")
                    .disabled(isBusy)
                    .onSubmit { connect() }
            }
            Button(action: connect) {
                HStack {
                    if isBusy { ProgressView() }
                    Text(isBusy ? "接続中…" : "接続")
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .disabled(!canConnect)
        }
    }

    private var authenticationStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Label(auth.serverName ?? "Jellyfin サーバー", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text(auth.client?.serverURL.absoluteString ?? serverURL)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("サーバーを変更") {
                    cancelQuickConnect()
                    auth.lastError = nil
                    password = ""
                    isConnected = false
                    focusedField = .server
                }
                .buttonStyle(.glass)
                .disabled(isBusy)
            }
            credentials
                .disabled(isBusy || isQuickConnecting)
            Divider()
            quickConnect
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ログイン")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .padding(16)
                    .onSubmit { focusedField = .password }
                Divider().padding(.horizontal, 16)
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .padding(16)
                    .onSubmit { signIn() }
            }
            .background(.background, in: .rect(cornerRadius: 14))
            Button(action: signIn) {
                HStack {
                    if isBusy { ProgressView() }
                    Text(isBusy ? "ログイン中…" : "ログイン")
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .disabled(trimmedUsername.isEmpty)
        }
    }

    private var quickConnect: some View {
        VStack(spacing: 16) {
            if isQuickConnecting {
                if let code = auth.quickConnectCode {
                    Text(code)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .tracking(6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel("Quick Connect コード")
                        .accessibilityValue(code.map { String($0) }.joined(separator: " "))
                    Text("Jellyfin の Web 画面で Quick Connect を開いてこのコードを入力してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(auth.quickConnectCode == nil ? "コードを取得中…" : "承認を待っています…")
                Button("キャンセル", action: cancelQuickConnect)
                    .buttonStyle(.glass)
            } else {
                Text("パスワードを入力せずにログイン")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    guard !isBusy else { return }
                    focusedField = nil
                    isQuickConnecting = true
                    auth.startQuickConnect()
                } label: {
                    Label("Quick Connect を使う", systemImage: "number.square")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glass)
                .disabled(isBusy)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func connect() {
        guard canConnect else { return }
        isWorking = true
        focusedField = nil
        Task {
            defer { isWorking = false }
            isConnected = await auth.connect(to: serverURL)
            if isConnected { focusedField = .username }
        }
    }

    private func signIn() {
        guard !trimmedUsername.isEmpty, !isBusy, !isQuickConnecting else { return }
        isWorking = true
        focusedField = nil
        Task {
            defer {
                isWorking = false
                password = ""
            }
            await auth.signIn(username: trimmedUsername, password: password)
        }
    }

    private func cancelQuickConnect() {
        auth.cancelQuickConnect()
        isQuickConnecting = false
    }
}

#Preview {
    AstraLoginView()
        .environment(AuthStore())
}
