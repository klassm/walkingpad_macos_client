import Foundation

public struct DeviceState {
    var time: Date
    var speedLevel: Int = 0
    var status: Status = .Unknown
    var deviceName: String
    
    func speedKmh() -> Double {
        switch speedLevel {
        case 10:
            return 0.7
        case 20:
            return 1.5
        case 30:
            return 2.4
        case 40:
            return 3.3
        case 50:
            return 4.3
        case 60:
            return 5.2
        case 70:
            return 6.1
        case 80:
            return 7.1
        default:
            return 0
        }
    }
}

public enum Status {
    case Stopped
    case Starting
    case Running
    case Paused
    case Unknown
}
