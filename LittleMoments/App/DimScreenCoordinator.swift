import Combine
import UIKit

@MainActor protocol ScreenBrightnessControlling: AnyObject {
    var brightness: CGFloat? { get set }
    var onBrightnessChange: (() -> Void)? { get set }
    func startObserving()
    func stopObserving()
}

/// Bound to the camera view's own window scene, including on external displays.
@MainActor final class SceneScreenBrightnessController: ScreenBrightnessControlling {
    private weak var screen: UIScreen?
    private var observer: NSObjectProtocol?
    var onBrightnessChange: (() -> Void)?
    var brightness: CGFloat? {
        get { screen?.brightness }
        set { if let newValue { screen?.brightness = newValue } }
    }
    func attach(to scene: UIWindowScene?) { screen = scene?.screen }
    func startObserving() {
        guard observer == nil, let screen else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScreen.brightnessDidChangeNotification,
                                                          object: screen, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onBrightnessChange?() }
        }
    }
    func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

struct BatteryReading: Equatable {
    enum Power: Equatable { case unknown, unplugged, charging, full }
    let percent: Int?
    let power: Power
    var text: String {
        let level = percent.map { "\($0)% battery" } ?? "Battery level unknown"
        switch power {
        case .unknown: return "\(level) · charging status unknown"
        case .unplugged: return "\(level) · unplugged"
        case .charging: return "\(level) · charging"
        case .full: return "\(level) · fully charged"
        }
    }
    static let unknown = BatteryReading(percent: nil, power: .unknown)
}

@MainActor protocol BatteryMonitoring: AnyObject {
    var reading: BatteryReading { get }
    var onChange: ((BatteryReading) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor protocol BatteryDevice: AnyObject {
    var batteryLevel: Float { get }
    var batteryState: UIDevice.BatteryState { get }
    var isBatteryMonitoringEnabled: Bool { get set }
}
extension UIDevice: BatteryDevice { }

/// Event-driven; restores the device monitoring setting it found on activation.
@MainActor final class DeviceBatteryMonitor: BatteryMonitoring {
    private let device: BatteryDevice
    private let notifications: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var previousMonitoring: Bool?
    var onChange: ((BatteryReading) -> Void)?
    init(device: BatteryDevice? = nil, notifications: NotificationCenter = .default) {
        self.device = device ?? UIDevice.current
        self.notifications = notifications
    }
    var reading: BatteryReading {
        let level = device.batteryLevel
        let percent = level.isFinite && (0...1).contains(level) ? Int((level * 100).rounded()) : nil
        let power: BatteryReading.Power
        switch device.batteryState {
        case .unplugged: power = .unplugged
        case .charging: power = .charging
        case .full: power = .full
        default: power = .unknown
        }
        return BatteryReading(percent: percent, power: power)
    }
    func start() {
        guard previousMonitoring == nil else { return }
        previousMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        observers = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification].map { name in
            notifications.addObserver(forName: name, object: device, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onChange?(self.reading)
                }
            }
        }
        onChange?(reading)
    }
    func stop() {
        observers.forEach { notifications.removeObserver($0) }
        observers.removeAll()
        if let previousMonitoring { device.isBatteryMonitoringEnabled = previousMonitoring }
        previousMonitoring = nil
    }
    deinit {
        observers.forEach { notifications.removeObserver($0) }
        if let previousMonitoring {
            let device = device
            performOnMain { device.isBatteryMonitoringEnabled = previousMonitoring }
        }
    }
}

/// UIKit resources must be restored even if the last owner is released off-main.
private func performOnMain(_ action: @escaping @MainActor () -> Void) {
    if Thread.isMainThread { MainActor.assumeIsolated { action() } }
    else { Task { @MainActor in action() } }
}

@MainActor final class DimScreenCoordinator: ObservableObject {
    @Published private(set) var isDimmed = false
    @Published private(set) var battery: BatteryReading = .unknown
    private let screen: ScreenBrightnessControlling
    private let batteryMonitor: BatteryMonitoring
    private var active = false
    private var originalBrightness: CGFloat?
    private var appliedBrightness: CGFloat?
    private var ownsBrightness = false
    private static let tolerance: CGFloat = 0.005

    init(screen: ScreenBrightnessControlling? = nil, battery: BatteryMonitoring? = nil) {
        self.screen = screen ?? SceneScreenBrightnessController()
        self.batteryMonitor = battery ?? DeviceBatteryMonitor()
        self.screen.onBrightnessChange = { [weak self] in self?.brightnessChanged() }
        self.batteryMonitor.onChange = { [weak self] in self?.battery = $0 }
    }
    func attach(to scene: UIWindowScene?) {
        guard let adapter = screen as? SceneScreenBrightnessController else { return }
        // A moved/detached camera view must restore the old screen before rebinding.
        wake()
        adapter.attach(to: scene)
    }
    func setUIActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value { batteryMonitor.start(); battery = batteryMonitor.reading }
        else { wake(); batteryMonitor.stop() }
    }
    func dim(while phase: CapturePhase) {
        guard active, phase == .buffering, !isDimmed, let original = screen.brightness else { return }
        originalBrightness = original
        // Never brighten a screen that the user already set below our dim level.
        let target = min(original, 0.08)
        appliedBrightness = target
        ownsBrightness = true
        isDimmed = true
        screen.startObserving()
        screen.brightness = target
    }
    func capturePhaseChanged(_ phase: CapturePhase) {
        if phase != .buffering { wake() }
    }
    func wake() {
        guard isDimmed else { return }
        screen.stopObserving()
        if ownsBrightness, let originalBrightness, let appliedBrightness,
           let current = screen.brightness, abs(current - appliedBrightness) <= Self.tolerance {
            screen.brightness = originalBrightness
        }
        originalBrightness = nil
        appliedBrightness = nil
        ownsBrightness = false
        isDimmed = false
    }
    private func brightnessChanged() {
        guard isDimmed, let current = screen.brightness, let appliedBrightness else { return }
        // Once a different external value is observed, ownership stays relinquished,
        // even if the user subsequently returns to the dim value.
        if abs(current - appliedBrightness) > Self.tolerance { ownsBrightness = false }
    }
    deinit {
        let screen = screen, batteryMonitor = batteryMonitor
        let original = originalBrightness, applied = appliedBrightness
        // Ownership is acquired only by dim() and cleared by wake(); avoid the
        // actor-isolated @Published accessor from this nonisolated deinitializer.
        let restore = ownsBrightness
        performOnMain {
            screen.stopObserving()
            if restore, let original, let applied, let current = screen.brightness,
               abs(current - applied) <= 0.005 { screen.brightness = original }
            batteryMonitor.stop()
        }
    }
}
