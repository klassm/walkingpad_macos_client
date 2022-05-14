import Foundation
import CoreBluetooth


public class WalkingPadCommand {
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
        let mode: UInt8 = mode == .automatic ? 1 : 0
        self.executeCommand(command: [247, 162, 2, mode, 0xff, 253])
    }
    
}
