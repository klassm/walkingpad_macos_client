import Foundation

public struct DeviceState {
    var time: Date
    var walkingTimeSeconds: Int = 0
    var speed: Int = 0
    var steps: Int = 0
    var distance: Int = 0
    var walkingMode: WalkingMode = WalkingMode.manual
    var deviceName: String
    var statusType: StatusType
    
    func speedKmh() -> Double {
        return Double(speed) / 10
    }
}
