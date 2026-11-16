import UIKit
import XCTest
@testable import LittleMoments

@MainActor private final class TestScreen: ScreenBrightnessControlling {
    var value: CGFloat? = 0.7
    var reads = 0
    var writes: [CGFloat] = []
    var starts = 0
    var stops = 0
    var onBrightnessChange: (() -> Void)?
    var brightness: CGFloat? {
        get { reads += 1; return value }
        set { value = newValue; if let newValue { writes.append(newValue) }; onBrightnessChange?() }
    }
    func startObserving() { starts += 1 }
    func stopObserving() { stops += 1 }
    func externalChange(_ value: CGFloat, notify: Bool = true) {
        self.value = value
        if notify { onBrightnessChange?() }
    }
}
@MainActor private final class TestBatteryMonitor: BatteryMonitoring {
    var reading: BatteryReading = .unknown
    var onChange: ((BatteryReading) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func publish(_ reading: BatteryReading) { self.reading = reading; onChange?(reading) }
}
@MainActor private final class TestBatteryDevice: NSObject, BatteryDevice {
    var batteryLevel: Float = -1
    var batteryState: UIDevice.BatteryState = .unknown
    var isBatteryMonitoringEnabled = false
}

@MainActor final class DimBatteryTests: XCTestCase {
    private func make(_ screen: TestScreen? = nil, _ battery: TestBatteryMonitor? = nil) -> DimScreenCoordinator {
        let coordinator = DimScreenCoordinator(screen: screen ?? TestScreen(), battery: battery ?? TestBatteryMonitor())
        coordinator.setUIActive(true)
        return coordinator
    }
    func testExplicitBufferingActivationSnapshotsOnceAndWakeIsIdempotent() {
        let screen = TestScreen(); let coordinator = make(screen)
        coordinator.dim(while: .stopped); coordinator.dim(while: .starting); coordinator.dim(while: .failed)
        XCTAssertFalse(coordinator.isDimmed); XCTAssertTrue(screen.writes.isEmpty)
        coordinator.dim(while: .buffering)
        let reads = screen.reads
        coordinator.dim(while: .buffering)
        XCTAssertEqual(screen.reads, reads)
        XCTAssertEqual(screen.starts, 1); XCTAssertEqual(screen.writes, [0.08])
        coordinator.wake(); coordinator.wake()
        XCTAssertFalse(coordinator.isDimmed)
        XCTAssertEqual(screen.writes, [0.08, 0.7]); XCTAssertEqual(screen.stops, 1)
    }
    func testEveryCaptureExitRestoresBrightness() {
        for phase in [CapturePhase.stopped, .starting, .paused, .denied, .failed] {
            let screen = TestScreen(); let coordinator = make(screen)
            coordinator.dim(while: .buffering)
            coordinator.capturePhaseChanged(phase)
            XCTAssertFalse(coordinator.isDimmed, "Exit \(phase)")
            XCTAssertEqual(screen.value, 0.7)
        }
    }
    func testSavingAndBufferingUpdatesDoNotWakeOrResnapshot() {
        let screen = TestScreen(); let coordinator = make(screen)
        coordinator.dim(while: .buffering)
        coordinator.capturePhaseChanged(.buffering)
        XCTAssertTrue(coordinator.isDimmed); XCTAssertEqual(screen.writes, [0.08])
        coordinator.wake(); XCTAssertEqual(screen.value, 0.7)
    }
    func testLibraryDisappearanceAndSceneInactivityShareCleanupAndNeverAutoDimOnReturn() {
        let screen = TestScreen(); let battery = TestBatteryMonitor(); let coordinator = make(screen, battery)
        coordinator.dim(while: .buffering)
        coordinator.setUIActive(false); coordinator.setUIActive(false)
        XCTAssertFalse(coordinator.isDimmed); XCTAssertEqual(screen.value, 0.7)
        XCTAssertEqual(battery.starts, 1); XCTAssertEqual(battery.stops, 1)
        coordinator.dim(while: .buffering); XCTAssertFalse(coordinator.isDimmed)
        coordinator.setUIActive(true); XCTAssertFalse(coordinator.isDimmed)
        XCTAssertEqual(battery.starts, 2)
    }
    func testExternalBrightnessChoiceIsPreservedEvenIfUserReturnsToDimValue() {
        let screen = TestScreen(); let coordinator = make(screen)
        coordinator.dim(while: .buffering)
        screen.externalChange(0.5); screen.externalChange(0.08)
        coordinator.wake()
        XCTAssertEqual(screen.value, 0.08)
        XCTAssertEqual(screen.writes, [0.08])
        // A new explicit dim session takes a fresh snapshot of the user's choice.
        screen.externalChange(0.4); coordinator.dim(while: .buffering); coordinator.wake()
        XCTAssertEqual(screen.value, 0.4)
    }
    func testExternalBrightnessWithoutNotificationStillWins() {
        let screen = TestScreen(); let coordinator = make(screen)
        coordinator.dim(while: .buffering); screen.externalChange(0.6, notify: false); coordinator.wake()
        XCTAssertEqual(screen.value, 0.6)
    }
    func testAlreadyDarkScreenIsNeverBrightenedAndMissingSceneCannotDim() {
        let screen = TestScreen(); screen.value = 0.02
        let coordinator = make(screen); coordinator.dim(while: .buffering)
        XCTAssertEqual(screen.value, 0.02); coordinator.wake(); XCTAssertEqual(screen.value, 0.02)
        screen.value = nil; coordinator.dim(while: .buffering); XCTAssertFalse(coordinator.isDimmed)
    }
    func testDeinitRestoresBrightnessAndStopsBatteryObservation() {
        let screen = TestScreen(); let battery = TestBatteryMonitor()
        var coordinator: DimScreenCoordinator? = make(screen, battery)
        coordinator?.dim(while: .buffering); coordinator = nil
        XCTAssertEqual(screen.value, 0.7); XCTAssertEqual(screen.stops, 1); XCTAssertEqual(battery.stops, 1)
    }
    func testUnknownBatteryAndChargingTransitions() {
        let battery = TestBatteryMonitor(); let coordinator = make(TestScreen(), battery)
        XCTAssertEqual(coordinator.battery, .unknown)
        XCTAssertTrue(coordinator.battery.text.contains("unknown"))
        for power in [BatteryReading.Power.unplugged, .charging, .full, .unknown] {
            battery.publish(BatteryReading(percent: 42, power: power))
            XCTAssertEqual(coordinator.battery, BatteryReading(percent: 42, power: power))
        }
    }
    func testDeviceBatteryAdapterNormalizesUnknownAndCleansUpNotifications() {
        let device = TestBatteryDevice(); let center = NotificationCenter()
        let monitor = DeviceBatteryMonitor(device: device, notifications: center)
        var readings: [BatteryReading] = []; monitor.onChange = { readings.append($0) }
        monitor.start(); monitor.start()
        XCTAssertTrue(device.isBatteryMonitoringEnabled); XCTAssertEqual(readings, [.unknown])
        device.batteryLevel = 0.426; device.batteryState = .charging
        center.post(name: UIDevice.batteryStateDidChangeNotification, object: device)
        XCTAssertEqual(readings.last, BatteryReading(percent: 43, power: .charging))
        device.batteryState = .full
        center.post(name: UIDevice.batteryLevelDidChangeNotification, object: device)
        XCTAssertEqual(readings.last?.power, .full)
        device.batteryLevel = .nan
        XCTAssertNil(monitor.reading.percent)
        device.batteryLevel = 2
        XCTAssertNil(monitor.reading.percent)
        monitor.stop(); monitor.stop()
        XCTAssertFalse(device.isBatteryMonitoringEnabled)
        let count = readings.count
        center.post(name: UIDevice.batteryLevelDidChangeNotification, object: device)
        XCTAssertEqual(readings.count, count)
    }
    func testBatteryMonitoringExistingOwnerAndDeinitCleanup() {
        let device = TestBatteryDevice(); device.isBatteryMonitoringEnabled = true
        let center = NotificationCenter()
        var callbacks = 0
        var monitor: DeviceBatteryMonitor? = DeviceBatteryMonitor(device: device, notifications: center)
        monitor?.onChange = { _ in callbacks += 1 }; monitor?.start(); monitor = nil
        XCTAssertTrue(device.isBatteryMonitoringEnabled)
        center.post(name: UIDevice.batteryStateDidChangeNotification, object: device)
        XCTAssertEqual(callbacks, 1)
        device.isBatteryMonitoringEnabled = false
        monitor = DeviceBatteryMonitor(device: device, notifications: center)
        monitor?.start(); monitor = nil
        XCTAssertFalse(device.isBatteryMonitoringEnabled)
    }
}
