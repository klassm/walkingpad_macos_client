import CoreBluetooth



open class WalkingPad: NSObject, CBPeripheralDelegate, ObservableObject {
    public var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var callback: TreadmillCallback
    public var status: DeviceState
    
    init(peripheral: CBPeripheral, callback: @escaping TreadmillCallback) {
        self.callback = callback
        self.peripheral = peripheral
        self.status = DeviceState(time: Date(), deviceName: peripheral.name ?? "unknown", statusType: .lastStatus)
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
        guard let characteristic = self.commandCharacteristic else { return }
    
        let data = Data(withChecksum)
        guard let peripheral = self.peripheral else { return }
        peripheral.delegate = self
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
    
    // Handles discovery event
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                print("Service UUID \(service.uuid)")
//                if BluetoothService.bleServiceUUIDs.contains(service.uuid) {
//                    peripheral.discoverCharacteristics(nil, for: service)
//                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        print("Service uuid=\(service.uuid) description=\(service.description)")
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                print ("> Characteristic uuid=\(characteristic.uuid) description=\(characteristic.description) \(characteristic.properties)")
                let asString = characteristic.uuid.uuidString
                if (asString.starts(with: "FE01")) {
                    peripheral.delegate = self
                    peripheral.setNotifyValue(true, for: characteristic)
                    self.notifyCharacteristic = characteristic
                }
                if (asString.starts(with: "FE02")) {
                    self.commandCharacteristic = characteristic
                }
            }
        }
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

            let oldStatus = self.status
            let speed = byteArray[3]
            let isManualMode = byteArray[4] == 1
            let distance = sumFrom(Array(byteArray[8...10])) * 10
            let steps = sumFrom(Array(byteArray[11...13]))
            let walkingTimeSeconds = sumFrom(Array(byteArray[5...7]))

            print("Update with status type \(statusType)")
            
            self.status = DeviceState(
                time: Date(),
                walkingTimeSeconds: walkingTimeSeconds,
                speed: Int(speed),
                steps: Int(steps),
                distance: Int(distance),
                walkingMode: isManualMode ? WalkingMode.manual : WalkingMode.automatic,
                deviceName: oldStatus.deviceName,
                statusType: statusType
            )
            self.callback(oldStatus, self.status)
            self.objectWillChange.send()
        }
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
    
    public func stop() {
        self.setSpeed(speed: 0)
    }
}
