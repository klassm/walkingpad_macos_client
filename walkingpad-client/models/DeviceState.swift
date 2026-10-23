import Foundation


public enum WalkingMode {
    case manual, automatic
}

public enum StatusType {
    case lastStatus, currentStatus
}

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

// The treadmill's coarse availability state, shared by the HTTP API
// (/treadmill/connection) and MQTT so both report the same semantics.
public enum TreadmillConnectionState: String, Codable {
    case disconnected, idle, running
    
    init(isConnected: Bool, speed: Int) {
        if !isConnected {
            self = .disconnected
        } else if speed > 0 {
            self = .running
        } else {
            self = .idle
        }
    }
}
