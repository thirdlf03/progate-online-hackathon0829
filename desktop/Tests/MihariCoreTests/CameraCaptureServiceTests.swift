import Foundation
import Testing

@testable import MihariCore

@Suite("カメラ撮影サービス(権限まわり)")
struct CameraCaptureServiceTests {

    /// 権限確認クロージャが呼ばれた回数を数える箱。テストのクロージャは @Sendable なので
    /// ロックで守って書き込む。
    private final class PermissionCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.withLock { count += 1 }
        }

        var callCount: Int {
            lock.withLock { count }
        }
    }

    @Test("権限が拒否されていれば AVCaptureSession に触れず理由付きで失敗する")
    func deniedPermissionFailsFast() async {
        let service = CameraCaptureService(checkPermission: {
            PermissionState(grant: .denied, detail: "denied (拒否)")
        })

        await #expect(throws: CaptureError.cameraPermissionNotGranted(detail: "denied (拒否)")) {
            _ = try await service.captureSinglePhoto()
        }
    }

    @Test("権限が未決定でも理由付きで失敗する(まだ聞いていないだけでは撮らない)")
    func undeterminedPermissionFailsFast() async {
        let service = CameraCaptureService(checkPermission: {
            PermissionState(grant: .undetermined, detail: "notDetermined (未決定)")
        })

        await #expect(throws: CaptureError.cameraPermissionNotGranted(detail: "notDetermined (未決定)")) {
            _ = try await service.captureSinglePhoto()
        }
    }

    @Test("gate が denyAll なら featureDisabled を投げ、権限確認も呼ばれない")
    func disabledGateFailsBeforeCheckingPermission() async {
        let recorder = PermissionCallRecorder()
        let service = CameraCaptureService(
            checkPermission: {
                recorder.record()
                return PermissionState(grant: .granted, detail: "granted")
            },
            gate: .denyAll
        )

        await #expect(throws: SafetyGateError.featureDisabled(.macCamera)) {
            _ = try await service.captureSinglePhoto()
        }
        // 権限の確認より先に弾く(OFF の間はカメラに触れない)ことの確認。
        #expect(recorder.callCount == 0)
    }

    @Test("gate が allowAll なら権限確認まで進む(従来の挙動)")
    func allowAllGateProceedsToPermissionCheck() async {
        let recorder = PermissionCallRecorder()
        let service = CameraCaptureService(
            checkPermission: {
                recorder.record()
                return PermissionState(grant: .denied, detail: "denied (拒否)")
            },
            gate: .allowAll
        )

        await #expect(throws: CaptureError.cameraPermissionNotGranted(detail: "denied (拒否)")) {
            _ = try await service.captureSinglePhoto()
        }
        #expect(recorder.callCount == 1)
    }
}
