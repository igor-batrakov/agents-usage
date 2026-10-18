import CoreGraphics
import IOKit.ps

/// Состояние машины для экономного опроса. Спрашивается в момент тика — без подписок и хранения.
enum SystemState {
    /// Экран заблокирован или основной дисплей спит — данные никто не увидит.
    static var screenIdle: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
