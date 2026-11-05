// l10n: zh-Hans (scripts/check-strings.sh)
import AppKit
import Observation
import Security
import ServiceManagement
import TalkTalkCore

/// The login item seam: SMAppService.mainApp in the app, a fake in a test.
@MainActor
protocol LoginItemService {
    var status: LaunchAtLoginPolicy.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct MainAppLoginItem: LoginItemService {
    var status: LaunchAtLoginPolicy.Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Settings › 通用 › 登录启动 (ARCHITECTURE.md §11) through SMAppService.mainApp. Registration
/// needs a signed bundle (ad hoc counts as signed; a bare `swift run` binary does not).
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: LaunchAtLoginPolicy.Status
    private(set) var lastError: String?
    let bundleSigned: Bool
    @ObservationIgnored private let service: any LoginItemService

    init(service: any LoginItemService = MainAppLoginItem(), bundleSigned: Bool = LaunchAtLogin.mainBundleIsSigned()) {
        self.service = service
        self.bundleSigned = bundleSigned
        status = bundleSigned ? service.status : .notFound
    }

    func presentation(stronglyRecommended: Bool) -> LaunchAtLoginPolicy.Presentation {
        LaunchAtLoginPolicy.present(status, bundleSigned: bundleSigned, stronglyRecommended: stronglyRecommended)
    }

    func refresh() {
        if bundleSigned { status = service.status }
    }

    func set(_ on: Bool) {
        lastError = nil
        do {
            switch LaunchAtLoginPolicy.action(wantOn: on, current: status) {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .none: break
            }
        } catch {
            lastError = String(localized: "登录启动没有改成：\(error.localizedDescription)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The app bundle carries a valid code signature (ad hoc included).
    nonisolated static func mainBundleIsSigned(_ url: URL = Bundle.main.bundleURL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    }
}
