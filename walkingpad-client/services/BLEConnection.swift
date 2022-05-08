import Foundation
import SwiftUI
import CoreBluetooth

 
open class BLEConnection: NSObject, CBCentralManagerDelegate, ObservableObject {

    private var centralManager: CBCentralManager! = nil

    public static let bleServiceUUID = CBUUID.init(string: "fff0")

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
            print("Scanning for devices", BLEConnection.bleServiceUUID);
            self.centralManager.scanForPeripherals(withServices: [BLEConnection.bleServiceUUID], options: nil)
        } else {
            self.centralManager.stopScan()
        }
    }

    // Handles the result of the scan
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("Peripheral Name: \(String(describing: peripheral.name))  RSSI: \(String(RSSI.doubleValue))")
        
        if (peripheral.name?.contains("V-RUN1") == true) {
            print("found treadmill!")
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
            peripheral.discoverServices([BLEConnection.bleServiceUUID])
        }
    }
    
    public func stop() {
        self.centralManager.stopScan()
        if let device = self.device {
            if  let peripheral = device.peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            
            self.callback(device.status, DeviceState(time: Date(), speedLevel: 0, status: .Unknown, deviceName: device.status.deviceName))
            self.device = nil
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.device = nil
    }
}
