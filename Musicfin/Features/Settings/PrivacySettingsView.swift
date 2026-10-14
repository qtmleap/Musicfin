import SwiftUI

/// 計測への同意の説明と切り替え。アカウント画面とログイン前の画面で同じ内容を使う。
struct PrivacySettingsSection: View {
    @Environment(TelemetryConsent.self) private var consent

    static let policyURL = URL(string: "https://qleap.jp/term/privacy_policy")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プライバシー").font(.title3.bold())
            VStack(alignment: .leading, spacing: 16) {
                Toggle(
                    "利用状況と不具合情報を共有",
                    isOn: Binding(
                        get: { consent.isSharingEnabled },
                        set: { consent.setSharingEnabled($0) }
                    )
                )
                // 開発ビルドでは保存値があっても収集しないため、切り替えを無効にして理由を示す。
                .disabled(!consent.isAvailable)
                .accessibilityIdentifier("telemetry-sharing-toggle")
                Text(
                    "使いやすさと安定性の改善のため、オンにすると、Google の Firebase を使って、アプリの利用状況、インストールごとの識別子、おおよその地域や端末の情報、クラッシュ・動作速度・診断情報を開発者が受け取ります。Jellyfin の認証情報や再生内容を独自の計測情報として送信しません。オフのままでもすべての機能を使えます。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if !consent.isAvailable {
                    Text("このビルドでは開発用のため、設定にかかわらず情報を収集しません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("プライバシーポリシー", destination: Self.policyURL)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("privacy-policy-link")
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            Text(
                "オフにすると、解析の収集を無効にします。クラッシュ情報の停止は次回の起動から完全に反映されます。送信中の情報は届く場合があり、送信済みの情報は削除されません。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            // カード内の行と左端を揃え、説明だけ外側へ張り付かないようにする。
            .padding(.horizontal, 16)
        }
    }
}

/// ログイン前でも開けるプライバシー設定。サーバーに接続しなくても選択と方針の確認ができるようにする。
struct PrivacySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PrivacySettingsSection()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
            }
            .navigationTitle("プライバシー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
        }
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    PrivacySettingsView()
        .environment(TelemetryConsent.live)
}
