import Foundation

enum ThermalLevel: CaseIterable, Equatable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}

/// Capture has no automatic thermal quality mode. Critical pressure requires a pause.
struct ThermalPolicy: Equatable {
    let blocksCapture: Bool
    let warning: String?
    init(state: ThermalLevel) {
        blocksCapture = state == .critical
        switch state {
        case .nominal, .fair: warning = nil
        case .serious:
            warning = "This iPhone is getting warm. Capture continues at the selected resolution. Let the device cool if needed."
        case .critical:
            warning = "This iPhone is too hot to buffer. Let it cool, then tap Start Buffer."
        }
    }
}

@MainActor protocol ThermalMonitoring: AnyObject {
    var state: ThermalLevel { get }
    // No event payload: consumers sample the current state when a notification is delivered.
    var onChange: (() -> Void)? { get set }
}

@MainActor final class ProcessThermalMonitor: ThermalMonitoring {
    private let center: NotificationCenter
    private let readState: () -> ThermalLevel
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?
    var state: ThermalLevel { readState() }

    init(center: NotificationCenter = .default,
         readState: @escaping () -> ThermalLevel = { ThermalLevel(ProcessInfo.processInfo.thermalState) }) {
        self.center = center
        self.readState = readState
        observer = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                      object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }
    deinit { if let observer { center.removeObserver(observer) } }
}

/// Explicit injection for deterministic model tests and DEBUG UI-test launches.
@MainActor final class MutableThermalMonitor: ThermalMonitoring {
    var state: ThermalLevel
    var onChange: (() -> Void)?
    init(state: ThermalLevel = .nominal) { self.state = state }
    func setState(_ state: ThermalLevel) { self.state = state; onChange?() }
}
