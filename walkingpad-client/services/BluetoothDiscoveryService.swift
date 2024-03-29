import CoreBluetooth
import Foundation

open class BluetoothDiscoveryService: NSObject, CBCentralManagerDelegate, ObservableObject {
    private var centralManager: CBCentralManager! = nil
    public var peripheralBlacklist: Set<String> = []
    private var walkingPadService: WalkingPadService
    private var bluetoothPeripheral: BluetoothPeripheral? = nil

    init(_ walkingPadService: WalkingPadService) {
        self.walkingPadService = walkingPadService
    }
    
    public func start() {
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        self.bluetoothPeripheral = nil
        self.walkingPadService.onDisconnect()
        print("Central Manager State: \(self.centralManager.state)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.centralManagerDidUpdateState(self.centralManager)
        }
    }

    // Handles BT Turning On/Off
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if (central.state == .poweredOn) {
            print("Scanning for devices");
            self.centralManager.scanForPeripherals(withServices: BluetoothPeripheral.walkingPadServiceUUIDs, options: nil)
        } else {
            self.centralManager.stopScan()
        }
    }

    // Handles the result of the scan
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if (!self.peripheralBlacklist.contains(peripheral.identifier.uuidString)
            && self.bluetoothPeripheral == nil
        ) {
            self.bluetoothPeripheral = BluetoothPeripheral(peripheral: peripheral, callback: { bluetoothPeripheral, isWalkingPad in
                self.handleDiscoveredDevice(bluetoothPeripheral, isWalkingPad)
                
            })
            self.centralManager.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.bluetoothPeripheral?.discover()
    }
    
    private func handleDiscoveredDevice(_ peripheral: BluetoothPeripheral, _ isWalkingPad: Bool) {
        if (isWalkingPad) {
            self.walkingPadService.onConnect(WalkingPadConnection(
                peripheral: peripheral.peripheral,
                notifyCharacteristic: peripheral.notifyCharacteristic!,
                commandCharacteristic: peripheral.commandCharacteristic!
            ))
            self.centralManager.stopScan()
            self.bluetoothPeripheral = nil
        } else {
            self.peripheralBlacklist.insert(peripheral.peripheral.identifier.uuidString)
            self.centralManager?.cancelPeripheralConnection(peripheral.peripheral)
            self.bluetoothPeripheral = nil
        }
    }
    
    public func stop() {
        self.centralManager.stopScan()
        self.bluetoothPeripheral = nil
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Device is disconnected, starting scan again.")
        if (self.walkingPadService.isCurrentDevice(peripheral: peripheral)) {
            self.walkingPadService.onDisconnect()
        }
        self.start()
    }
}
