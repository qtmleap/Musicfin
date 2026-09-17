import SwiftUI

/// Jellyfin のアカウント情報・音質・ログアウトをまとめた画面。`sheet` で表示する前提。
struct AccountView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// フルプレイヤーの開き方。**実機比較のための一時的な切り替え**なので、再生の設定とは器を分ける。
    @AppStorage(PlayerPresentationStyle.storageKey) private var playerStyle = PlayerPresentationStyle.slideUp
    @AppStorage(LyricsScrollAnimation.storageKey) private var lyricsAnimation = LyricsScrollAnimation.easeInOut
    @State private var confirmsSignOut = false

    private var userName: String {
        if case .signedIn(let user) = auth.state, !user.isEmpty { return user }
        return String(localized: "ユーザー")
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // 閉じるボタンの下端から最初のカードまでは 44 pt 空ける（Apple 実機の実測）。
                // 他のカード間の 24 pt は保ちたいので、差の 20 pt をこのカードだけに足す。
                accountSurface
                    .padding(.top, 20)
                qualitySurface(wifi: $settings.wifiQuality, cellular: $settings.cellularQuality)
                playerSurface
                signOutSurface
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .confirmationDialog("ログアウトしますか？", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("ログアウト", role: .destructive) {
                // サインアウトするとルートが切り替わるため、残った sheet がログイン画面を覆わないよう先に閉じる。
                dismiss()
                auth.signOut()
            }
        } message: {
            Text("\(userName) としてのセッションを終了します。")
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.square.stack")
                .font(.title2)
                .foregroundStyle(.tint)
            // 見出しは本文より一段だけ太く大きい程度に留める（Apple 実機の実測 17 pt）。
            Text("Jellyfin Account")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemBackground), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("閉じる")
        }
    }

    private var accountSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 円と名前の間は 8 pt（Apple 実機の実測）。他の利用箇所には及ぼさないので呼び出し側で指定する。
            HStack(spacing: 8) {
                AccountAvatar(name: userName, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    // 名前は節の見出しではないので太らせない（Apple 実機の実測も 17 pt・regular で、
                    // 一覧の行の文字と同じ太さ）。太らせると「音質」などの見出しと同じ重さに見えてしまう。
                    Text(userName).font(.body)
                    Text(auth.serverName ?? "Jellyfin")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider().padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 4) {
                Text("サーバー URL")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(auth.client?.serverURL.absoluteString ?? "—")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
    }

    private func qualitySurface(wifi: Binding<StreamQuality>, cellular: Binding<StreamQuality>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("音質").font(.title3.bold())
            VStack(spacing: 0) {
                QualityPicker(title: "Wi-Fi", systemImage: "wifi", selection: wifi)
                    .padding(16)
                Divider().padding(.horizontal, 16)
                QualityPicker(
                    title: "モバイル通信",
                    systemImage: "antenna.radiowaves.left.and.right",
                    selection: cellular
                )
                .padding(16)
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            Text("ロスレスは通信量が大きく、変更は次の曲から反映されます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                // カード内の行と左端を揃え、説明だけ外側へ張り付かないようにする。
                .padding(.horizontal, 16)
        }
    }

    /// プレイヤーの開き方と歌詞の行送り。**実機で見比べるための節**で、採る方式が決まったら消す
    /// （仕様 4.1.1 章・5.2 章）。カードの形は音質の節と同じにして、並んだときに別物に見えないようにする。
    private var playerSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プレイヤー").font(.title3.bold())
            VStack(spacing: 16) {
                PlayerStylePicker(selection: $playerStyle)
                Divider()
                LyricsAnimationPicker(selection: $lyricsAnimation)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            Text("実機比較用の一時的な切り替えです。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                // カード内の行と左端を揃え、説明だけ外側へ張り付かないようにする。
                .padding(.horizontal, 16)
        }
    }

    private var signOutSurface: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("ログアウト", role: .destructive) { confirmsSignOut = true }
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
            Text("ログアウトしてもサーバーの URL は保持されます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QualityPicker: View {
    let title: LocalizedStringResource
    let systemImage: String
    @Binding var selection: StreamQuality

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(StreamQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).foregroundStyle(.tint).frame(width: 24)
                Text(title)
                Spacer()
                Text(selection.title).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selection.title)
    }
}

/// 行送りの動き方の 4 択。行の形は `PlayerStylePicker` に合わせる（同じ画面に並ぶので形を変えない）。
private struct LyricsAnimationPicker: View {
    @Binding var selection: LyricsScrollAnimation

    var body: some View {
        Menu {
            Picker("歌詞の行送り", selection: $selection) {
                ForEach(LyricsScrollAnimation.allCases) { animation in
                    Text(animation.title).tag(animation)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "quote.bubble").foregroundStyle(.tint).frame(width: 24)
                Text("歌詞の行送り")
                Spacer()
                Text(selection.title).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selection.title)
    }
}

/// 開き方の 2 択。行の形は `QualityPicker` に合わせる（同じ画面に並ぶので形を変えない）。
private struct PlayerStylePicker: View {
    @Binding var selection: PlayerPresentationStyle

    var body: some View {
        Menu {
            Picker("開き方", selection: $selection) {
                ForEach(PlayerPresentationStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.expand.vertical").foregroundStyle(.tint).frame(width: 24)
                Text("開き方")
                Spacer()
                Text(selection.title).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selection.title)
    }
}

#Preview {
    AccountView()
        .environment(AuthStore())
        .environment(PlaybackSettings())
}
