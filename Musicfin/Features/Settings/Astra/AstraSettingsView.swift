import SwiftUI

/// Astra 版ログインと揃え、装飾を抑えて設定値と説明を読み取りやすくする。
struct AstraSettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackSettings.self) private var playbackSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showsSignOutConfirmation = false

    private var username: String {
        if case .signedIn(let user) = auth.state, !user.isEmpty { return user }
        return "ユーザー名なし"
    }

    var body: some View {
        // Environment の共有ストアを複製せず、音質の選択に必要な Binding を得るために取り直す。
        @Bindable var settings = playbackSettings

        NavigationStack {
            Form {
                Section("アカウント") {
                    accountDetail("ユーザー名", value: username)
                    accountDetail("サーバー名", value: auth.serverName ?? "Jellyfin")
                    accountDetail("サーバー URL", value: auth.client?.serverURL.absoluteString ?? "未接続")
                }

                Section {
                    AstraQualityOptions(network: "Wi-Fi", selection: $settings.wifiQuality)
                    AstraQualityOptions(network: "モバイル通信", selection: $settings.cellularQuality)
                } header: {
                    Text("音質")
                } footer: {
                    Text("ロスレスは通信量が大きく、再生開始まで時間がかかることがあります。変更は次の曲から反映されます。")
                }

                Section {
                    Button("ログアウト", role: .destructive) {
                        showsSignOutConfirmation = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        // システムの表示言語に依存せず、UI テストでも同じ名前で閉じる操作を識別できるようにする。
                        .accessibilityLabel("閉じる")
                }
            }
            .confirmationDialog("ログアウトしますか？", isPresented: $showsSignOutConfirmation, titleVisibility: .visible) {
                Button("ログアウト", role: .destructive) {
                    // サインアウトで表示元が切り替わる前に、設定シートを閉じる。
                    dismiss()
                    auth.signOut()
                }
            } message: {
                Text("音楽を聴くには、もう一度ログインする必要があります。")
            }
        }
    }

    private func accountDetail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

/// 現在値と三つの音質の説明を一度に比較できるよう、インライン表示を維持する。
/// 通信種別は見出しと読み上げで区切り、装飾カードを重ねずフラットな構成に揃える。
private struct AstraQualityOptions: View {
    let network: String
    @Binding var selection: StreamQuality

    var body: some View {
        Text(network)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)

        ForEach(StreamQuality.allCases) { quality in
            Button {
                selection = quality
            } label: {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(quality.title)
                            .foregroundStyle(.primary)
                        Text(quality.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(selection == quality ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // 同じ選択肢が二度並ぶため、読み上げだけでも通信種別を識別できるようにする。
            .accessibilityLabel("\(network)、\(quality.title)")
            .accessibilityValue(quality.detail)
            .accessibilityAddTraits(selection == quality ? .isSelected : [])
        }
    }
}

#Preview {
    AstraSettingsView()
        .environment(AuthStore())
        .environment(PlaybackSettings())
}
