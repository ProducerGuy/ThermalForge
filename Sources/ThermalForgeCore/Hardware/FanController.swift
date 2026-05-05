import Foundation

public protocol FanController {
    func setMax() throws
    func setAllFans(rpm: Float) throws
    func resetAuto() throws
}

public protocol SensorProvider {
    func status() throws -> ThermalStatus
}
