import Foundation
import SwiftUI
import CoreBluetooth


public typealias WalkingPadFoundCallback = (_ peripheral: BluetoothPeripheral, _ isWalkingPad: Bool) -> Void
 
open class BluetoothPeripheral: NSObject, CBPeripheralDelegate {
    public static let walkingPadServiceUUIDs = [
        CBUUID.init(string: "0000180a-0000-1000-8000-00805f9b34fb"),
        CBUUID.init(string: "00010203-0405-0607-0809-0a0b0c0d1912"),
        CBUUID.init(string: "0000fe00-0000-1000-8000-00805f9b34fb")
    ]

    
    public var peripheral: CBPeripheral
    public var notifyCharacteristic: CBCharacteristic?
    public var commandCharacteristic: CBCharacteristic?
    private var nonDiscoveredServices: [CBService] = []
    private var callback: WalkingPadFoundCallback
    
    init(peripheral: CBPeripheral, callback: @escaping WalkingPadFoundCallback) {
        self.peripheral = peripheral
        self.callback = callback
    }
    
    public func discover() {
        print("discovering \(self.peripheral.name ?? "unknown")")
        self.peripheral.delegate = self
        self.peripheral.discoverServices(BluetoothPeripheral.walkingPadServiceUUIDs)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            let relevantServices = services.filter({ service in BluetoothPeripheral.walkingPadServiceUUIDs.contains(service.uuid)})
            self.nonDiscoveredServices = relevantServices
            for service in relevantServices {
                peripheral.discoverCharacteristics(nil, for: service)
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
                    self.notifyCharacteristic = characteristic
                }
                if (asString.starts(with: "FE02")) {
                    self.commandCharacteristic = characteristic
                }
            }
        }
        self.nonDiscoveredServices = self.nonDiscoveredServices.filter({ nonDiscoveredService in nonDiscoveredService != service })
        self.notifyIfWalkingPad()
    }
    
    
    private func notifyIfWalkingPad() {
        if (!self.nonDiscoveredServices.isEmpty) {
            return
        }
        let isWalkingPad = self.commandCharacteristic != nil && self.notifyCharacteristic != nil
        self.callback(self, isWalkingPad)
    }
}
