import SwiftUI

/// サーバー URL の入力 → 認証（パスワードまたは Quick Connect）の 2 段構成。
/// `Form` ではなく Liquid Glass のカードを積むレイアウトにして、Apple Music の初回画面に寄せている。
struct FableLoginView: View {
    @Environment(AuthStore.self) private var auth

    private enum Step: Equatable {
        case server
        case credentials
    }

    private enum Field: Hashable {
        case server
        case username
        case password
    }

    @State private var step: Step = .server
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private var isConnecting: Bool { auth.state == .connecting }
    private var isWaitingQuickConnect: Bool { auth.quickConnectCode != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                FableLoginHero()
                    .padding(.top, 48)

                Group {
                    switch step {
                    case .server:
                        serverCard
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    case .credentials:
                        credentialsCard
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // iPad ではフォームが画面幅いっぱいに伸びると間延びするので上限を設ける。
                .frame(maxWidth: 440)

                errorMessage
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .animation(.snappy, value: step)
            .animation(.snappy, value: auth.quickConnectCode)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FableLoginBackdrop())
        .onAppear { serverURL = UserDefaults.standard.string(forKey: "server.url") ?? "" }
        .onDisappear { auth.cancelQuickConnect() }
    }

    // MARK: - ステップ 1: サーバー

    private var serverCard: some View {
        FableGlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Jellyfin サーバー")
                    .font(.headline)

                FableInputField(systemImage: "server.rack") {
                    TextField("jellyfin.example.com", text: $serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .server)
                        .onSubmit { Task { await connect() } }
                }

                Text("https:// を省略すると自動で補います。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                FablePrimaryButton(title: "接続", isBusy: isConnecting) {
                    Task { await connect() }
                }
                .disabled(serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(isConnecting)
    }

    // MARK: - ステップ 2: 認証

    private var credentialsCard: some View {
        FableGlassCard {
            VStack(alignment: .leading, spacing: 16) {
                serverSummary

                if let code = auth.quickConnectCode {
                    quickConnectPanel(code: code)
                } else {
                    passwordForm
                    Divider()
                    Button {
                        focusedField = nil
                        auth.startQuickConnect()
                    } label: {
                        Label("Quick Connect でログイン", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
        }
        .disabled(isConnecting)
    }

    private var serverSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(auth.serverName ?? "Jellyfin")
                    .font(.headline)
                if let url = auth.client?.serverURL {
                    Text(url.absoluteString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            Button("サーバーを変更") {
                auth.cancelQuickConnect()
                focusedField = nil
                step = .server
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 12) {
            FableInputField(systemImage: "person") {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
            }
            FableInputField(systemImage: "key") {
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { Task { await signIn() } }
            }
            FablePrimaryButton(title: "ログイン", isBusy: isConnecting) {
                Task { await signIn() }
            }
            .disabled(username.isEmpty)
        }
    }

    private func quickConnectPanel(code: String) -> some View {
        VStack(spacing: 16) {
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .kerning(8)
                // kerning は末尾にも余白を付けるので、中央に見えるよう同じ量だけ左へ寄せる。
                .padding(.leading, 8)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)

            Text("Jellyfin の Web 画面で Quick Connect を開き、このコードを入力してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ProgressView()
                Text("承認を待っています…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("キャンセル", role: .cancel) { auth.cancelQuickConnect() }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - エラー

    @ViewBuilder
    private var errorMessage: some View {
        if let error = auth.lastError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 440, alignment: .leading)
                .transition(.opacity)
        }
    }

    // MARK: - 動作

    private func connect() async {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isConnecting else { return }
        focusedField = nil
        if await auth.connect(to: trimmed) {
            step = .credentials
            focusedField = .username
        }
    }

    private func signIn() async {
        guard !username.isEmpty, !isConnecting else { return }
        focusedField = nil
        await auth.signIn(username: username, password: password)
        // 失敗しても平文のパスワードを画面に残さない。
        password = ""
    }
}

// MARK: - 部品

/// アプリ名とアイコン風のマーク。ログイン画面の上部に置く。
private struct FableLoginHero: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(
                    LinearGradient(colors: [.pink, .red], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 24, style: .continuous)
                )
                .shadow(color: .red.opacity(0.3), radius: 16, y: 8)

            Text("Musicfin")
                .font(.largeTitle.weight(.bold))
            Text("Jellyfin の音楽を、どこでも。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// 画面全体の背景。無地だとガラスの質感が出ないので、淡いグラデーションを敷く。
private struct FableLoginBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color.pink.opacity(0.18), Color(.systemBackground), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// 内容をひとまとめにするガラスのカード。
private struct FableGlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
    }
}

/// アイコン付きの入力欄。`Form` の行と同じ高さ感に揃える。
private struct FableInputField<Content: View>: View {
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.fill.tertiary, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// 主要操作のボタン。処理中はラベルの代わりに `ProgressView` を出す。
private struct FablePrimaryButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .fontWeight(.semibold)
                    .opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        // glassProminent は tint によって文字色が変わるので、白で固定して読みやすさを保つ。
        .foregroundStyle(.white)
        .controlSize(.large)
    }
}

#Preview("サーバー入力") {
    FableLoginView()
        .environment(AuthStore())
}
