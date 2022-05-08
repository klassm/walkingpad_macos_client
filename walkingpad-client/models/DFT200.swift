import CoreBluetooth

public typealias TreadmillCallback = (_ oldState: DeviceState, _ newState: DeviceState) -> Void

open class WalkingPad: NSObject, CBPeripheralDelegate, ObservableObject {
    public var peripheral: CBPeripheral?
    private var characteristics: [CBCharacteristic] = []
    private var callback: TreadmillCallback
    public var status: DeviceState
    
    init(peripheral: CBPeripheral, callback: @escaping TreadmillCallback) {
        self.callback = callback
        self.peripheral = peripheral
        self.status = DeviceState(time: Date(), deviceName: peripheral.name ?? "unknown")
    }
    
    private func calculateChecksum(values: [UInt8]) -> UInt8 {
        return values.reduce(0, {a, b in a.addingReportingOverflow(b).partialValue});
    }
    
    private func getCharacteristic() -> CBCharacteristic? {
        for characteristic in self.characteristics {
            if characteristic.uuid.uuidString == "FFF2" {
                return characteristic
            } else {
                print("no match for \(characteristic)")
            }
        }
        return nil
    }
    
    public func executeCommand(command: UInt8, arg: UInt8 = 0) {
        print ("execute \(command)")
        let values: [UInt8] = [0xf0, 0xc3, 0x03, command, arg, 0];
        let checksum = self.calculateChecksum(values: values)
        guard let characteristic = self.getCharacteristic() else { return }
    
        let data = Data(values + [checksum])
        print ("sending \(data)")
        self.peripheral?.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    // Handles discovery event
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                print("Service UUID \(service.uuid)")
                if service.uuid == BLEConnection.bleServiceUUID {
                    peripheral.delegate = self
                    peripheral.discoverCharacteristics(nil, for: service)
                    return
                }
            }
        }
    }

    // Handling discovery of characteristics
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let characteristics = service.characteristics {
            self.characteristics = characteristics + self.characteristics
            for characteristic in characteristics {
                self.peripheral?.setNotifyValue(true, for: characteristic)
            }
        }
    }
    
    private func statusFrom(byteValue: UInt8) -> Status {
        switch byteValue {
        case 0x1:
            return .Stopped
        case 0x2:
            return .Starting
        case 0x3:
            return .Running
        case 0x4:
            return .Paused
        default:
            return .Unknown
        }
    }
    
    
    // Handling updates
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let value = characteristic.value {
            let oldStatus = self.status
            let statusByte = value[14]
            let status = self.statusFrom(byteValue: statusByte)
            let speed = status == .Paused || status == .Stopped ? 0 : Int(value[10])
            print("Speed \(speed)")
            self.status = DeviceState(time: Date(), speedLevel: speed, status: status, deviceName: oldStatus.deviceName)
            self.callback(oldStatus, self.status)
            self.objectWillChange.send()
        }
    }
    
    public func setSpeed(speed: UInt8) {
        self.executeCommand(command: 0x03, arg: speed)
    }
    
    public func updateStatus() {
        NSLog("Updating device status");
        self.executeCommand(command: 0x00)
    }
    
    public func start() {
        self.executeCommand(command: 0x01)
    }
    
    public func stop() {
        self.executeCommand(command: 0x02)
    }
    
    public func pause() {
        self.executeCommand(command: 0x04)
    }
}
