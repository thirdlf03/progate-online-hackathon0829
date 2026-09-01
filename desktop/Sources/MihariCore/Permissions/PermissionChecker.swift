import AVFoundation
import CoreGraphics
import CoreMotion
import Foundation

/// 各権限の現在の状態を OS に問い合わせる。
///
/// どの API もプロンプトを出さない照会専用のものだけを使う。要求は `PermissionRequester` 側。
public enum PermissionChecker {

    public static func check(_ kind: PermissionKind) -> PermissionState {
        switch kind {
        case .camera:
            return PermissionStateMapper.from(authorization: AVCaptureDevice.authorizationStatus(for: .video))
        case .screenRecording:
            return PermissionStateMapper.fromScreenRecording(preflight: CGPreflightScreenCaptureAccess())
        case .automation:
            return AutomationProbe.status()
        case .motion:
            return PermissionStateMapper.from(motion: CMHeadphoneMotionManager.authorizationStatus())
        }
    }

    public static func checkAll() -> [PermissionKind: PermissionState] {
        PermissionKind.allCases.reduce(into: [:]) { result, kind in
            result[kind] = check(kind)
        }
    }
}
