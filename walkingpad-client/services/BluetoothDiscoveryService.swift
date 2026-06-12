import CoreBluetooth
import Foundation

open class BluetoothDiscoveryService: NSObject, CBCentralManagerDelegate, ObservableObject {
    private var centralManager: CBCentralManager! = nil
    public var peripheralBlacklist: Set<String> = []
    private var walkingPadService: WalkingPadService
    private var bluetoothPeripheral: BluetoothPeripheral? = nil
    private var isSleeping = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var scanTimeoutTimer: Timer? = nil
    private let scanTimeoutInterval: TimeInterval = 30
    private let lastConnectedPeripheralKey = "lastConnectedPeripheralUUID"

    init(_ walkingPadService: WalkingPadService) {
        self.walkingPadService = walkingPadService
    }

    public func start() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
            print("Central Manager State: \(self.centralManager.state)")
        } else if centralManager.state == .poweredOn {
            beginScan()
        }
    }

    public func restart() {
        cleanup()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("Central Manager State: \(self.centralManager.state)")
    }

    private func cleanup() {
        cancelScanTimeout()
        centralManager?.stopScan()
        bluetoothPeripheral = nil
    }

    func reconnectToKnownPeripheral() {
        guard centralManager.state == .poweredOn else { return }

        if let peripheral = walkingPadService.connectedPeripheral(), peripheral.state != .connected {
            print("Reconnecting to known peripheral: \(peripheral.identifier.uuidString)")
            centralManager.connect(peripheral, options: nil)
            return
        }

        if let uuidString = UserDefaults.standard.string(forKey: lastConnectedPeripheralKey),
           let uuid = UUID(uuidString: uuidString) {
            let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = peripherals.first, peripheral.state != .connected {
                print("Reconnecting to persisted peripheral: \(uuidString)")
                centralManager.connect(peripheral, options: nil)
                return
            }
        }
    }

    func setSleeping(_ sleeping: Bool) {
        isSleeping = sleeping
        if sleeping {
            cancelScanTimeout()
            centralManager?.stopScan()
        }
    }

    private func savePeripheralIdentifier(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastConnectedPeripheralKey)
    }

    private func beginScan() {
        cancelScanTimeout()
        print("Scanning for devices")
        centralManager.scanForPeripherals(withServices: BluetoothPeripheral.walkingPadServiceUUIDs, options: nil)
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: scanTimeoutInterval, repeats: false) { [weak self] _ in
            self?.handleScanTimeout()
        }
    }

    private func cancelScanTimeout() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
    }

    private func handleScanTimeout() {
        print("Scan timeout, no device found. Will retry after delay.")
        centralManager?.stopScan()
        let delay = min(5.0 * Double(reconnectAttempts + 1), 60.0)
        reconnectAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isSleeping else { return }
            self.beginScan()
        }
    }

    private func resetReconnectAttempts() {
        reconnectAttempts = 0
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if !isSleeping {
                reconnectToKnownPeripheral()
                beginScan()
            }
        } else {
            centralManager.stopScan()
            cancelScanTimeout()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !peripheralBlacklist.contains(peripheral.identifier.uuidString)
            && bluetoothPeripheral == nil
        {
            bluetoothPeripheral = BluetoothPeripheral(peripheral: peripheral, callback: { bluetoothPeripheral, isWalkingPad in
                self.handleDiscoveredDevice(bluetoothPeripheral, isWalkingPad)
            })
            centralManager.connect(peripheral, options: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resetReconnectAttempts()
        centralManager.stopScan()
        cancelScanTimeout()
        if walkingPadService.isCurrentDevice(peripheral: peripheral), walkingPadService.activeConnection != nil {
            walkingPadService.restoreConnection(peripheral)
        } else {
            bluetoothPeripheral = BluetoothPeripheral(peripheral: peripheral, callback: { [weak self] bluetoothPeripheral, isWalkingPad in
                self?.handleDiscoveredDevice(bluetoothPeripheral, isWalkingPad)
            })
            bluetoothPeripheral?.discover()
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect to peripheral: \(peripheral.identifier.uuidString), error: \(String(describing: error))")
        bluetoothPeripheral = nil
        if !isSleeping {
            scheduleReconnectOrScan()
        }
    }

    private func handleDiscoveredDevice(_ peripheral: BluetoothPeripheral, _ isWalkingPad: Bool) {
        if isWalkingPad {
            savePeripheralIdentifier(peripheral.peripheral)
            walkingPadService.onConnect(WalkingPadConnection(
                peripheral: peripheral.peripheral,
                notifyCharacteristic: peripheral.notifyCharacteristic!,
                commandCharacteristic: peripheral.commandCharacteristic!
            ))
            centralManager.stopScan()
            cancelScanTimeout()
            bluetoothPeripheral = nil
        } else {
            peripheralBlacklist.insert(peripheral.peripheral.identifier.uuidString)
            centralManager?.cancelPeripheralConnection(peripheral.peripheral)
            bluetoothPeripheral = nil
        }
    }

    public func stop() {
        centralManager.stopScan()
        cancelScanTimeout()
        bluetoothPeripheral = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Device is disconnected: \(peripheral.identifier.uuidString), error: \(String(describing: error))")
        if walkingPadService.isCurrentDevice(peripheral: peripheral) {
            walkingPadService.onDisconnect()
        }
        if !isSleeping {
            scheduleReconnectOrScan()
        }
    }

    private func scheduleReconnectOrScan() {
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = min(2.0 * Double(reconnectAttempts), 30.0)
            print("Reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isSleeping else { return }
                self.reconnectToKnownPeripheral()
            }
        } else {
            print("Max reconnect attempts reached, starting full scan")
            reconnectAttempts = 0
            beginScan()
        }
    }
}
