import SwiftUI

/// アプリ全画面の実装候補。Fable 版と Astra 版を比較検討するために並存させている。
/// 採用が決まったら不要な方を削除し、この切り替えも取り除く。
enum DesignVariant {
    case fable
    case astra
    /// 比較前の共通実装。
    case legacy

    /// UI テストがビルドし直さずに実装を切り替えられるよう、環境変数 `MUSICFIN_VARIANT` を優先する。
    static var current: DesignVariant {
        switch ProcessInfo.processInfo.environment["MUSICFIN_VARIANT"] {
        case "astra": .astra
        case "legacy": .legacy
        default: .fable
        }
    }

    /// ログイン後の全画面（タブ、ミニ／フルプレイヤーを含む）。
    @ViewBuilder
    var rootView: some View {
        switch self {
        case .fable: FableRootView()
        case .astra: AstraRootView()
        case .legacy: RootView()
        }
    }

    @ViewBuilder
    var loginView: some View {
        switch self {
        case .fable: FableLoginView()
        case .astra: AstraLoginView()
        case .legacy: LoginView()
        }
    }

    /// `legacy` には設定画面がないので、Fable 版で代用する。
    @ViewBuilder
    var settingsView: some View {
        switch self {
        case .fable, .legacy: FableSettingsView()
        case .astra: AstraSettingsView()
        }
    }
}
