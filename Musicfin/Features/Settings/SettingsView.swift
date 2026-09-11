import SwiftUI

/// アカウント確認・音質の選択・ログアウトをまとめた設定画面。`sheet` で表示する前提。
/// ログイン画面と同じく、グループ化リストの上にピンクの淡いグラデーションを敷いて統一感を出す。
struct SettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false

    private var userName: String {
        if case .signedIn(let user) = auth.state, !user.isEmpty { return user }
        return "ユーザー"
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            List {
                accountSection
                Section {
                    QualityPicker(
                        title: "Wi-Fi",
                        systemImage: "wifi",
                        selection: $settings.wifiQuality
                    )
                    QualityPicker(
                        title: "モバイル通信",
                        systemImage: "antenna.radiowaves.left.and.right",
                        selection: $settings.cellularQuality
                    )
                } header: {
                    Text("音質")
                } footer: {
                    Text("ロスレスは通信量が大きく、再生開始まで時間がかかることがあります。変更は次の曲から反映されます。")
                }
                signOutSection
            }
            .scrollContentBackground(.hidden)
            .background(SettingsBackdrop())
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .confirmationDialog(
                "ログアウトしますか？",
                isPresented: $confirmsSignOut,
                titleVisibility: .visible
            ) {
                Button("ログアウト", role: .destructive) {
                    // サインアウトすると MusicfinApp がログイン画面へ切り替えるが、
                    // シート自体は残るので先に閉じておく。
                    dismiss()
                    auth.signOut()
                }
            } message: {
                Text("\(userName) としてのセッションを終了します。")
            }
        }
    }

    // MARK: - アカウント

    private var accountSection: some View {
        Section("アカウント") {
            HStack(spacing: 16) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.pink.gradient)
                VStack(alignment: .leading, spacing: 4) {
                    Text(userName)
                        .font(.title3.weight(.semibold))
                    Text(auth.serverName ?? "Jellyfin")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)

            // URL は控えるときに全文が要るので、省略せず折り返して見せる。
            VStack(alignment: .leading, spacing: 4) {
                Text("サーバー URL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(auth.client?.serverURL.absoluteString ?? "—")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - ログアウト

    private var signOutSection: some View {
        Section {
            Button("ログアウト", role: .destructive) { confirmsSignOut = true }
                .frame(maxWidth: .infinity)
        } footer: {
            Text("ログアウトしてもサーバーの URL は保持されます。")
        }
    }
}

// MARK: - 音質の選択

/// 接続種別ごとに 3 択を並べる。Picker の `navigationLink` だと「今どれか」が一覧で見えないので、
/// iPod の設定画面のように同じ画面内で切り替えられるようにした。
private struct QualityPicker: View {
    let title: String
    let systemImage: String
    @Binding var selection: StreamQuality

    var body: some View {
        DisclosureGroup {
            ForEach(StreamQuality.allCases) { quality in
                QualityRow(network: title, quality: quality, isSelected: quality == selection) {
                    selection = quality
                }
            }
        } label: {
            Label {
                LabeledContent(title, value: selection.title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.pink)
            }
        }
    }
}

private struct QualityRow: View {
    let network: String
    let quality: StreamQuality
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.title)
                        .foregroundStyle(.primary)
                    Text(quality.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.pink)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // 両グループを展開すると同じ 3 択が二度並ぶので、読み上げだけでも通信種別を区別できるようにする。
        .accessibilityLabel("\(network)、\(quality.title)")
        .accessibilityValue(quality.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 背景

private struct SettingsBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color.pink.opacity(0.14), Color(.systemGroupedBackground), Color(.systemGroupedBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

#Preview {
    SettingsView()
        .environment(AuthStore())
        .environment(PlaybackSettings())
}
