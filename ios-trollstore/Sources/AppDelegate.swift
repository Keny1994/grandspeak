import UIKit
import AVFoundation

/// Điều khiển kênh âm thanh: .playback / .playAndRecord đều phát ra loa ngoài
/// kể cả khi công tắc Im lặng (Silent) của iPhone đang bật, đồng thời hỗ trợ tai nghe Bluetooth / AirPods.
enum AudioRouter {
    static var isRecordingActive = false

    static func activatePlayback() {
        isRecordingActive = false
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
            try session.setActive(true)
        } catch {
            // Bỏ qua: không làm sập ứng dụng nếu thiết bị từ chối kênh âm thanh.
        }
    }

    static func activateRecording() {
        isRecordingActive = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
            )
            try session.setActive(true)
        } catch {
            // Bỏ qua.
        }
    }

    static func resumeCurrentMode() {
        if isRecordingActive {
            activateRecording()
        } else {
            activatePlayback()
        }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AudioRouter.activatePlayback()

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard
                let info = notification.userInfo,
                let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            if type == .ended {
                AudioRouter.resumeCurrentMode()
            }
        }

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = UIColor(red: 0.094, green: 0.110, blue: 0.133, alpha: 1.0)
        win.rootViewController = WebViewController()
        win.makeKeyAndVisible()
        window = win
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        AudioRouter.resumeCurrentMode()
    }
}
