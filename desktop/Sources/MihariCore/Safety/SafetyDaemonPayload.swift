import Foundation

/// bridge(デーモン)へ渡すセーフティートグルの契約。#50 と共有する。
///
/// JSON は `{"features": {"iphonePresence": false, "iphoneScreenshot": false, "discordExposure": false}}`。
/// キー名(camelCase)は bridge 側と合わせてあるので変えてはいけない。渡すのは
/// `isForwardedToDaemon == true` の 3 本だけ。あとの機能は Swift 側だけで完結する。
public struct SafetyDaemonPayload: Codable, Equatable, Sendable {

    /// デーモンに伝える機能ごとの ON/OFF。
    public struct Features: Codable, Equatable, Sendable {
        public var iphonePresence: Bool
        public var iphoneScreenshot: Bool
        public var discordExposure: Bool

        public init(iphonePresence: Bool, iphoneScreenshot: Bool, discordExposure: Bool) {
            self.iphonePresence = iphonePresence
            self.iphoneScreenshot = iphoneScreenshot
            self.discordExposure = discordExposure
        }
    }

    public var features: Features

    public init(settings: SafetySettings) {
        features = Features(
            iphonePresence: settings.isEnabled(.iphonePresence),
            iphoneScreenshot: settings.isEnabled(.iphoneScreenshot),
            discordExposure: settings.isEnabled(.discordExposure)
        )
    }
}

/// `POST /safety` の応答。サーバ側は #50 で実装される。
public struct SafetyUpdateResponse: Codable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}
