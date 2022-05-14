import Foundation
import SwiftUI
import CoreBluetooth

 
open class BLEConnection: NSObject, CBCentralManagerDelegate, ObservableObject {

    private var centralManager: CBCentralManager! = nil

    public static let bleServiceUUIDs = [
        CBUUID.init(string: "0000180a-0000-1000-8000-00805f9b34fb"),
        CBUUID.init(string: "00010203-0405-0607-0809-0a0b0c0d1912"),
        CBUUID.init(string: "0000fe00-0000-1000-8000-00805f9b34fb")
    ]

    @Published
    var device: WalkingPad? = nil
    
    public var callback: TreadmillCallback = {_, _ in }

    override init() {
        super.init();
        self.start()
    }
    
    public func start() {
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        print("Central Manager State: \(self.centralManager.state)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.centralManagerDidUpdateState(self.centralManager)
        }
    }

    // Handles BT Turning On/Off
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if (central.state == .poweredOn) {
            print("Scanning for devices");
            self.centralManager.scanForPeripherals(withServices: BLEConnection.bleServiceUUIDs, options: nil)
        } else {
            self.centralManager.stopScan()
        }
    }

    // Handles the result of the scan
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if (peripheral.name?.starts(with: "KS-") == true) {
            print("Found treadmill: \(String(describing: peripheral.name))  RSSI: \(String(RSSI.doubleValue))")
            
            self.centralManager.stopScan()
            
            let device = WalkingPad(peripheral: peripheral, callback: self.callback)
            self.device = device
            peripheral.delegate = device
            self.centralManager.connect(peripheral, options: nil)
        }
    }


    // The handler if we do connect successfully
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral == self.device?.peripheral {
            print("Connected to your BLE Board")
            peripheral.discoverServices(BLEConnection.bleServiceUUIDs)
        }
    }
    
    public func stop() {
        self.centralManager.stopScan()
        if let device = self.device {
            if  let peripheral = device.peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            
            self.callback(device.status, DeviceState(
                time: Date(),
                speed: 0,
                deviceName: device.status.deviceName,
                statusType: .lastStatus)
            )
            self.device = nil
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.device = nil
    }
}
