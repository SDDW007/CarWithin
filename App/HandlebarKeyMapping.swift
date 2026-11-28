import Foundation

/// 春风仪表能传到手机的三个把手键（BACK 被仪表自己消化，永远收不到）。
enum HandlebarKey: String, CaseIterable {
    case up, down, set

    var name: String {
        switch self {
        case .up: return "▲ 上"
        case .down: return "▼ 下"
        case .set: return "SET"
        }
    }
}

/// 同一次按键能识别出的三种手势。
enum HandlebarTrigger: String, CaseIterable {
    case single, double, long

    var name: String {
        switch self {
        case .single: return "单击"
        case .double: return "双击"
        case .long: return "长按"
        }
    }
}

/// 一个「按键 + 手势」可以绑定的目标。
enum HandlebarBinding: Equatable {
    /// 不修改，沿用 App 内置默认行为。
    case followDefault
    /// 什么都不发。
    case none
    /// 映射到某条 CarPlay 控制指令（焦点上/下、选择、返回……）。
    case control(CarPlayControl)

    var title: String {
        switch self {
        case .followDefault: return "默认"
        case .none: return "无动作"
        case .control(let control): return control.title
        }
    }

    var storedValue: String {
        switch self {
        case .followDefault: return "default"
        case .none: return "none"
        case .control(let control): return control.rawValue
        }
    }

    init(storedValue: String) {
        if storedValue == "none" { self = .none; return }
        if let control = CarPlayControl(rawValue: storedValue) { self = .control(control); return }
        self = .followDefault
    }

    /// 菜单里的全部选项，顺序固定，便于下拉选择。
    static let all: [HandlebarBinding] = [.followDefault, .none] + CarPlayControl.allCases.map { .control($0) }

    var menuIndex: Int { Self.all.firstIndex(of: self) ?? 0 }
}

/// 九个「按键 + 手势」组合的映射表，存 UserDefaults，重启不丢。
final class HandlebarKeyMappingStore {
    static let shared = HandlebarKeyMappingStore()
    static let didChange = Notification.Name("HandlebarKeyMappingDidChange")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func storageKey(_ key: HandlebarKey, _ trigger: HandlebarTrigger) -> String {
        "handlebarMapping.\(key.rawValue).\(trigger.rawValue)"
    }

    func binding(_ key: HandlebarKey, _ trigger: HandlebarTrigger) -> HandlebarBinding {
        let value = defaults.string(forKey: storageKey(key, trigger)) ?? "default"
        return HandlebarBinding(storedValue: value)
    }

    func setBinding(_ binding: HandlebarBinding, _ key: HandlebarKey, _ trigger: HandlebarTrigger) {
        if binding == .followDefault {
            defaults.removeObject(forKey: storageKey(key, trigger))
        } else {
            defaults.set(binding.storedValue, forKey: storageKey(key, trigger))
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func resetAll() {
        for key in HandlebarKey.allCases {
            for trigger in HandlebarTrigger.allCases {
                defaults.removeObject(forKey: storageKey(key, trigger))
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 有多少个组合被改成了非默认（用于设置页显示摘要）。
    var customizedCount: Int {
        HandlebarKey.allCases.reduce(0) { total, key in
            total + HandlebarTrigger.allCases.filter { binding(key, $0) != .followDefault }.count
        }
    }
}

/// 内置默认行为，和之前版本完全一致。
extension HandlebarController {
    static func defaultAction(_ key: HandlebarKey, _ trigger: HandlebarTrigger) -> Action {
        switch (key, trigger) {
        case (.up, .single): return .knobPrevious(1)
        case (.up, .double): return .home
        case (.up, .long): return .knobPrevious(3)
        case (.down, .single): return .knobNext(1)
        case (.down, .double): return .back
        case (.down, .long): return .knobNext(3)
        case (.set, .single): return .select
        case (.set, .double): return .back
        case (.set, .long): return .siri
        }
    }
}
