import Foundation
import CoreBluetooth


public protocol WalkingPadCommanding {
    func start()
    func setSpeed(speed: UInt8)
    func setWalkingMode(mode: WalkingMode)
    func updateStatus()
}

public class WalkingPadCommand: WalkingPadCommanding {
    private var connection: WalkingPadConnection
    
    init(_ connection: WalkingPadConnection) {
        self.connection = connection
    }
    
    private func fixChecksum(values: [UInt8]) -> [UInt8] {
        let elements: [UInt8] = values.dropFirst().dropLast(2)
        let checksum: UInt8 = elements.reduce(0, {a, b in a.addingReportingOverflow(UInt8(b)).partialValue});
        var copy = Array(values)
        copy[copy.endIndex - 2] = checksum
        return copy
    }
    
    public func executeCommand(command: [UInt8]) {
        let withChecksum = self.fixChecksum(values: command)
        let data = Data(withChecksum)
        
        let characteristic = self.connection.commandCharacteristic
        NSLog("BLE command write: %d bytes to %@ (withoutResponse)", data.count, characteristic.uuid.uuidString)
        // The treadmill advertises the .write property on FE02, but its ATT
        // permission table only accepts write-without-response (Write
        // Command): a .withResponse Write Request is rejected with ATT error
        // 0x03 "Writing is not permitted". Verified 2026-10-27 on KS-HCR1AA.
        self.connection.peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    
    public func setSpeed(speed: UInt8) {
        self.executeCommand(command: [247, 162, 1, speed, 0xff, 253])
    }
    
    public func updateStatus() {
        self.executeCommand(command: [247, 162, 0, 0, 162, 253])
    }
    
    public func start() {
        self.executeCommand(command: [247, 162, 4, 1, 0xff, 253])
    }
    
    public func setWalkingMode(mode: WalkingMode) {
        let mode: UInt8 = mode == .automatic ? 0 : 1
        self.executeCommand(command: [247, 162, 2, mode, 0xff, 253])
    }
    
}
