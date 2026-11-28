import AVFoundation
import MediaPlayer
import UIKit

/// 春风原车把手按键 → CarPlay 控制。
///
/// 实测结论（Android 侧 6 个版本验证）：仪表通过蓝牙 HID 键盘下发按键，车上 4 个物理键只有 3 个能到手机：
/// ▲ → 音量加，▼ → 音量减，SET → 播放/暂停；BACK 由仪表内部消化。
///
/// iOS 上这两类键都拿不到 UIKey 事件，只能：
/// 1. 音量键：观察 `AVAudioSession.outputVolume`（KVO），需要音频会话活跃（CarPlay 音频在跑时满足）；
/// 2. 播放/暂停键：交给 Now Playing，用 `MPRemoteCommandCenter` 的 play/pause 回调接。
/// 因为是"变化量"而非"按下/抬起"，按住时会连续触发，长按按"连发"处理，SET 的长按无法识别。
final class HandlebarController: NSObject {

    enum Action {
        case knobPrevious(Int)
        case knobNext(Int)
        case select
        case back
        case home
        case siri
    }

    private enum Key {
        case up, down, set

        var handlebarKey: HandlebarKey {
            switch self {
            case .up: return .up
            case .down: return .down
            case .set: return .set
            }
        }
    }

    var onAction: ((Action) -> Void)?
    /// 每个「按键 + 手势」的实际去向，由设置页里的映射表决定。
    var binding: ((HandlebarKey, HandlebarTrigger) -> HandlebarBinding)?
    /// 映射到某条 CarPlay 控制指令时回调。
    var onControl: ((CarPlayControl) -> Void)?
    var onLog: ((String) -> Void)?

    // 与 Android 版保持一致的手势参数
    private let doubleGapMS = 420.0
    private let longPressMS = 700.0
    private let edgeBurstGapMS = 900.0
    private let edgeDedupeMS = 160.0
    private let burstCount = 3
    private let volumeEpsilon: Float = 0.02

    private struct Gesture {
        var pendingSingle: DispatchWorkItem?
        var pendingLong: DispatchWorkItem?
        var longFired = false
        var isDown = false
        var lastEdge: TimeInterval = 0
        var edgeRun = 0
    }

    private var gestures: [Key: Gesture] = [:]
    private var running = false
    private var observingVolume = false
    private var pinnedVolume: Float = 0.5
    private var volumeView: MPVolumeView?
    private var remoteHandlers: [(command: MPRemoteCommand, token: Any)] = []
    private var volumeRestoreWork: [DispatchWorkItem] = []

    private var now: TimeInterval { Date().timeIntervalSince1970 * 1000 }

    deinit {
        stop()
    }

    // MARK: - 生命周期

    func start() {
        guard !running else { return }
        running = true
        gestures.removeAll()
        let session = AVAudioSession.sharedInstance()
        var current = session.outputVolume
        // 贴边时把"锚点"挪到中间，否则只能朝一个方向识别
        if current <= 0.1 || current >= 0.9 {
            current = 0.5
            setSystemVolume(0.5)
        }
        pinnedVolume = current
        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        observingVolume = true
        registerRemoteCommands()
        onLog?("把手按键已就绪（▲ / ▼ / SET）")
    }

    func stop() {
        guard running else { return }
        running = false
        if observingVolume {
            observingVolume = false
            AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
        }
        for entry in remoteHandlers {
            entry.command.removeTarget(entry.token)
        }
        remoteHandlers.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        gestures.values.forEach {
            $0.pendingSingle?.cancel()
            $0.pendingLong?.cancel()
        }
        gestures.removeAll()
        volumeRestoreWork.forEach { $0.cancel() }
        volumeRestoreWork.removeAll()
        volumeView?.removeFromSuperview()
        volumeView = nil
        onLog?("把手按键已停止")
    }

    // MARK: - 音量键（▲ / ▼）

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard running, keyPath == "outputVolume" else { return }
        let volume = AVAudioSession.sharedInstance().outputVolume
        // 我们自己复位造成的回调
        if abs(volume - pinnedVolume) < volumeEpsilon { return }
        let isUp = volume > pinnedVolume
        let key: Key = isUp ? .up : .down
        let stamp = now
        var gesture = gestures[key] ?? Gesture()
        let gap = stamp - gesture.lastEdge
        if gap < edgeDedupeMS { return }
        // 按住不放时音量会连续变化，间隔很短就按"连发"处理
        gesture.edgeRun = (gap < edgeBurstGapMS && gesture.edgeRun > 0) ? gesture.edgeRun + 1 : 1
        gesture.lastEdge = stamp
        gestures[key] = gesture

        if gesture.edgeRun >= burstCount {
            // 连发：立刻滚动，不再参与单击/双击判定
            cancelPendingSingle(key)
            dispatch(.long, key)
        } else {
            tap(key)
        }
        lockVolume()
    }

    // MARK: - Now Playing（SET）

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let info = MPNowPlayingInfoCenter.default()
        var info3: [String: Any] = [:]
        info3[MPMediaItemPropertyTitle] = "CarWithin"
        info3[MPMediaItemPropertyArtist] = "原车把手按键"
        info3[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info.nowPlayingInfo = info3

        let play = center.playCommand
        play.isEnabled = true
        remoteHandlers.append((play, play.addTarget { [weak self] _ in
            self?.setKeyDown(); return .success
        }))
        let pause = center.pauseCommand
        pause.isEnabled = true
        remoteHandlers.append((pause, pause.addTarget { [weak self] _ in
            self?.setKeyDown(); return .success
        }))
        let toggle = center.togglePlayPauseCommand
        toggle.isEnabled = true
        remoteHandlers.append((toggle, toggle.addTarget { [weak self] _ in
            self?.setKeyDown(); return .success
        }))
    }

    /// 播放/暂停回调只给"一次"，没有按下状态，合成一次极短的按下+抬起。
    private func setKeyDown() {
        let stamp = now
        var gesture = gestures[.set] ?? Gesture()
        if stamp - gesture.lastEdge < 120 { return }
        gesture.lastEdge = stamp
        gestures[.set] = gesture
        tap(.set)
    }

    // MARK: - 手势引擎

    private func tap(_ key: Key) {
        var gesture = gestures[key] ?? Gesture()
        if let pending = gesture.pendingSingle {
            // 第二击：升级成双击
            pending.cancel()
            gesture.pendingSingle = nil
            gesture.longFired = false
            gesture.edgeRun = 0
            gestures[key] = gesture
            dispatch(.double, key)
            return
        }
        let isVolumeKey = (key == .up || key == .down)
        let item = DispatchWorkItem { [weak self] in self?.singleFire(key) }
        gesture.pendingSingle = item
        let longItem = DispatchWorkItem { [weak self] in self?.longFire(key) }
        gesture.pendingLong = longItem
        gesture.isDown = true
        gesture.longFired = false
        gestures[key] = gesture
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleGapMS / 1000, execute: item)
        // 长按只在持续按住（音量键连续触发）时由 edgeRun 走连发，这里保留计时器做兜底
        if !isVolumeKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressMS / 1000, execute: longItem)
        }
    }

    private func singleFire(_ key: Key) {
        var gesture = gestures[key] ?? Gesture()
        gesture.pendingSingle = nil
        gesture.pendingLong?.cancel()
        gesture.pendingLong = nil
        gestures[key] = gesture
        if gesture.longFired { return }
        dispatch(.single, key)
    }

    private func longFire(_ key: Key) {
        var gesture = gestures[key] ?? Gesture()
        guard gesture.isDown, gesture.pendingSingle != nil else { return }
        gesture.longFired = true
        gesture.pendingSingle?.cancel()
        gesture.pendingSingle = nil
        gestures[key] = gesture
        dispatch(.long, key)
    }

    private func cancelPendingSingle(_ key: Key) {
        var gesture = gestures[key] ?? Gesture()
        gesture.pendingSingle?.cancel()
        gesture.pendingSingle = nil
        gesture.pendingLong?.cancel()
        gesture.pendingLong = nil
        gestures[key] = gesture
    }

    private func fire(_ action: Action) {
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }

    /// 收到一次手势后，先查映射表：默认就按内置行为，指定了指令就走 CarPlay 控制，指定「无动作」就丢掉。
    private func dispatch(_ trigger: HandlebarTrigger, _ key: Key) {
        let handlebarKey = key.handlebarKey
        let resolved = binding?(handlebarKey, trigger) ?? .followDefault
        switch resolved {
        case .followDefault:
            fire(HandlebarController.defaultAction(handlebarKey, trigger))
        case .none:
            onLog?("把手键 \(handlebarKey.name) \(trigger.name) → 无动作，已丢弃")
        case .control(let control):
            onLog?("把手键 \(handlebarKey.name) \(trigger.name) → \(control.title)")
            DispatchQueue.main.async { [weak self] in
                self?.onControl?(control)
            }
        }
    }

    // MARK: - 音量锁定

    /// 音量键被当成旋钮用：每次变化立刻把音量压回锚点，并在随后几百毫秒里连续补压，
    /// 把系统的「原车音量 +1 / -1」彻底吃掉，避免边导航边被调音量。
    private func lockVolume() {
        applyVolume(pinnedVolume)
        for delay in [0.05, 0.18, 0.4] {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                self.applyVolume(self.pinnedVolume)
            }
            volumeRestoreWork.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// 同步改音量：KVO 回调本身在主线程，直接动 slider 才来得及盖住系统那次步进。
    private func applyVolume(_ value: Float) {
        volumeSlider()?.setValue(min(max(value, 0), 1), animated: false)
    }

    private func setSystemVolume(_ value: Float) {
        DispatchQueue.main.async { [weak self] in
            guard let slider = self?.volumeSlider() else { return }
            slider.setValue(min(max(value, 0), 1), animated: false)
        }
    }

    private func volumeSlider() -> UISlider? {
        if let view = volumeView {
            return view.subviews.compactMap { $0 as? UISlider }.first
        }
        let view = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 40, height: 40))
        view.showsRouteButton = false
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            window.addSubview(view)
        } else {
            return nil
        }
        volumeView = view
        view.layoutIfNeeded()
        return view.subviews.compactMap { $0 as? UISlider }.first
    }
}
