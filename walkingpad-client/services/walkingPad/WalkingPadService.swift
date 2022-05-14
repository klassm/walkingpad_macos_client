import Foundation
import CoreBluetooth

public typealias TreadmillCallback = (_ oldState: DeviceState?, _ newState: DeviceState) -> Void

public struct WalkingPadConnection {
    var peripheral: CBPeripheral
    var notifyCharacteristic: CBCharacteristic
    var commandCharacteristic: CBCharacteristic
}

open class WalkingPadService: NSObject, CBPeripheralDelegate, ObservableObject {

    private var connection: WalkingPadConnection?
    @Published
    private var lastState: DeviceState? = nil
    
    public var callback: TreadmillCallback?
    
    public func onConnect(_ connection: WalkingPadConnection) {
        self.connection = connection
        self.connection?.peripheral.delegate = self
    }
    
    public func onDisconnect() {
        self.lastState = nil
    }
    
    public func isCurrentDevice(peripheral: CBPeripheral) -> Bool {
        return peripheral == self.connection?.peripheral
    }
    
    public func command() -> WalkingPadCommand? {
        guard let connection = self.connection else { return nil }
        return WalkingPadCommand(connection)
    }
    
    private func sumFrom(_ values: [UInt8]) -> Int {
        return values.reduce(0, { acc, value in acc * 256 + Int(value) })
    }
    
    private func statusTypeFrom(_ bits: [UInt8]) -> StatusType? {
        if (bits[0] == 248 && bits[1] == 162) {
            return .currentStatus
        }
        if (bits[0] == 248 && bits[1] == 167) {
            return .lastStatus
        }
        return nil
    }
    
    // Handling updates
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value {
            
            let byteArray = [UInt8](value)
            guard let statusType = statusTypeFrom(Array(byteArray[0...2])) else { return }
            guard let connection = self.connection else { return }
            
            let speed = byteArray[3]
            let isManualMode = byteArray[4] == 1
            let distance = sumFrom(Array(byteArray[8...10])) * 10
            let steps = sumFrom(Array(byteArray[11...13]))
            let walkingTimeSeconds = sumFrom(Array(byteArray[5...7]))

            print("Update with status type \(statusType)")
            
            let status = DeviceState(
                time: Date(),
                walkingTimeSeconds: walkingTimeSeconds,
                speed: Int(speed),
                steps: Int(steps),
                distance: Int(distance),
                walkingMode: isManualMode ? WalkingMode.manual : WalkingMode.automatic,
                deviceName: connection.peripheral.name ?? "unknown",
                statusType: statusType
            )
            
            self.callback?(self.lastState, status)
            self.lastState = status
        }
    }
    
    public func lastStatus() -> DeviceState? {
        return self.lastState
    }
    
    public func isConnected() -> Bool {
        return self.connection != nil
    }
}
