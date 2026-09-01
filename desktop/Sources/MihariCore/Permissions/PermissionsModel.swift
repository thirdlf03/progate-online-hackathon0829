import Foundation
import SwiftUI

/// オンボーディング画面の状態。
@MainActor
public final class PermissionsModel: ObservableObject {

    /// 初回起動でまとめ要求を済ませたかを覚えておくキー。
    /// 2 回目以降は勝手にプロンプトを出さず、ユーザーがボタンを押したときだけ要求する。
    static let didRequestOnLaunchKey = "com.thirdlf03.mihari.didRequestOnLaunch"

    @Published public private(set) var states: [PermissionKind: PermissionState]
    @Published public private(set) var lastCheckedAt: Date?
    @Published public private(set) var lastMessage: String?
    @Published public private(set) var isRequesting = false
    /// いまのセーフティー設定。#51 以降、見せる権限と必須権限はここから導出する。
    @Published public private(set) var settings: SafetySettings = .default

    private let defaults: UserDefaults
    private let requestPermission: @Sendable (PermissionKind) async -> String
    private let checkPermissions: @Sendable () -> [PermissionKind: PermissionState]

    /// - Parameters:
    ///   - requestPermission: 実際にプロンプトを出す処理。テストでは差し替えて、
    ///     テスト実行だけで TCC のダイアログが出ないようにする。
    ///   - checkPermissions: 現在の状態を照会する処理。テストでは差し替えて、
    ///     実機の TCC の状態に左右されずに起動フローの判定を確かめる。
    public init(
        defaults: UserDefaults = .standard,
        requestPermission: @escaping @Sendable (PermissionKind) async -> String = PermissionRequester.request,
        checkPermissions: @escaping @Sendable () -> [PermissionKind: PermissionState] = PermissionChecker.checkAll
    ) {
        self.defaults = defaults
        self.requestPermission = requestPermission
        self.checkPermissions = checkPermissions
        self.states = PermissionKind.allCases.reduce(into: [:]) { $0[$1] = .unchecked }
    }

    public func apply(settings: SafetySettings) {
        self.settings = settings
    }

    public func state(for kind: PermissionKind) -> PermissionState {
        states[kind] ?? .unchecked
    }

    /// 未許可のまま残っている権限。オンボーディングを閉じてよいかの判断に使う。
    public var pending: [PermissionKind] {
        PermissionKind.allCases.filter { state(for: $0).grant != .granted }
    }

    /// いまの設定で意味を持つ(画面に出す)権限。オンボーディングの行の一覧に使う。
    public var relevantKinds: [PermissionKind] {
        PermissionKind.relevant(for: settings)
    }

    /// 未許可のまま残っている必須権限。ここが空になるまで見張りを始めない。
    public var missingRequired: [PermissionKind] {
        PermissionKind.required(for: settings).filter { state(for: $0).grant != .granted }
    }

    /// 必須権限がすべて許可されているか。
    public var isRequiredSatisfied: Bool {
        missingRequired.isEmpty
    }

    /// 初回起動のまとめ要求を済ませたか。初回だけ権限画面を出すための判定に使う。
    public var hasCompletedFirstLaunch: Bool {
        defaults.bool(forKey: Self.didRequestOnLaunchKey)
    }

    public func refresh() {
        states = checkPermissions()
        lastCheckedAt = Date()
    }

    public func request(_ kind: PermissionKind) async {
        lastMessage = await requestPermission(kind)
        refresh()
    }

    /// 要求できる権限を順にプロンプトする。対象は現在の設定から導出する。
    public func requestAll() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        var messages: [String] = []
        for kind in PermissionKind.requestableOnLaunch(for: settings) {
            guard state(for: kind).grant != .granted else { continue }
            messages.append(await requestPermission(kind))
        }
        lastMessage = messages.isEmpty ? "要求が必要な権限はありませんでした" : messages.joined(separator: " / ")
        refresh()
    }

    /// トグルを ON にした瞬間に呼ぶ。そのトグルが必要とする権限(#54 の設定画面が使う)が
    /// あり、未許可なら要求する。
    public func request(for feature: SafetyFeature) async {
        guard let kind = PermissionKind.allCases.first(where: { $0.feature == feature }) else { return }
        guard state(for: kind).grant != .granted else { return }
        await request(kind)
    }

    /// 初回起動のときだけ、まとめ要求を一度走らせる。
    public func requestOnFirstLaunchIfNeeded() async {
        guard !defaults.bool(forKey: Self.didRequestOnLaunchKey) else { return }
        defaults.set(true, forKey: Self.didRequestOnLaunchKey)
        await requestAll()
    }

    public func openSettings(for kind: PermissionKind) {
        if !kind.pane.open() {
            lastMessage = "システム設定を開けませんでした: \(kind.pane.rawValue)"
        }
    }
}
