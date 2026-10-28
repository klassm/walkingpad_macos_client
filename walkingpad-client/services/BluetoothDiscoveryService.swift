import CoreBluetooth
import Foundation

final class BluetoothDiscoveryService: NSObject, @unchecked Sendable, CBCentralManagerDelegate, ObservableObject {
    private var centralManager: CBCentralManager! = nil
    public var peripheralBlacklist: Set<String> = []
    private var walkingPadService: WalkingPadService
    private var bluetoothPeripheral: BluetoothPeripheral? = nil
    private var isSleeping = false
    private var reconnectAttempts = 0
    private var pendingReconnectPeripheral: CBPeripheral? = nil
    private let maxReconnectAttempts = 5
    private var scanTimeoutTimer: Timer? = nil
    private let scanTimeoutInterval: TimeInterval = 30
    private var reconnectFallbackTimer: Timer? = nil
    private let reconnectFallbackInterval: TimeInterval = 30
    private var fallbackScanActive = false
    private let lastConnectedPeripheralKey = "lastConnectedPeripheralUUID"

    init(_ walkingPadService: WalkingPadService) {
        self.walkingPadService = walkingPadService
    }

    public func start() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
            NSLog("Central Manager State: %ld", self.centralManager.state.rawValue)
        } else if centralManager.state == .poweredOn {
            beginScan()
        }
    }

    public func restart() {
        cleanup()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        NSLog("Central Manager State: %ld", self.centralManager.state.rawValue)
    }

    private func cleanup() {
        cancelScanTimeout()
        cancelReconnectFallback()
        centralManager?.stopScan()
        bluetoothPeripheral = nil
    }

    func reconnectToKnownPeripheral() {
        guard centralManager.state == .poweredOn else { return }

        if let peripheral = walkingPadService.connectedPeripheral(), peripheral.state != .connected {
            NSLog("Reconnecting to known peripheral: %@", peripheral.identifier.uuidString)
            armReconnectFallback()
            centralManager.connect(peripheral, options: nil)
            return
        }

        if let uuidString = UserDefaults.standard.string(forKey: lastConnectedPeripheralKey),
           let uuid = UUID(uuidString: uuidString) {
            let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = peripherals.first, peripheral.state != .connected {
                NSLog("Reconnecting to persisted peripheral: %@", uuidString)
                pendingReconnectPeripheral = peripheral
                armReconnectFallback()
                centralManager.connect(peripheral, options: nil)
                return
            }
        }
    }

    /// A connect() to a known-but-unavailable peripheral stays pending
    /// indefinitely on macOS: no didConnect and no didFailToConnect, so the
    /// attempt-counter based scan fallback in scheduleReconnectOrScan() is
    /// unreachable. This timer guarantees the scan path (which provably
    /// finds the treadmill at app start) runs if the reconnect stays silent.
    private func armReconnectFallback() {
        cancelReconnectFallback()
        reconnectFallbackTimer = Timer.scheduledTimer(withTimeInterval: reconnectFallbackInterval, repeats: false) { [weak self] _ in
            self?.handleReconnectFallbackTimeout()
        }
    }

    private func cancelReconnectFallback() {
        reconnectFallbackTimer?.invalidate()
        reconnectFallbackTimer = nil
    }

    private func handleReconnectFallbackTimeout() {
        reconnectFallbackTimer = nil
        guard !isSleeping, walkingPadService.activeConnection == nil else { return }
        NSLog("Reconnect fallback timed out after %.0fs, falling back to full scan", reconnectFallbackInterval)
        fallbackScanActive = true
        if let pending = pendingReconnectPeripheral {
            pendingReconnectPeripheral = nil
            centralManager.cancelPeripheralConnection(pending)
        }
        beginScan()
    }

    func setSleeping(_ sleeping: Bool) {
        isSleeping = sleeping
        if sleeping {
            cancelScanTimeout()
            cancelReconnectFallback()
            centralManager?.stopScan()
        }
    }

    private func savePeripheralIdentifier(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastConnectedPeripheralKey)
    }

    private func beginScan() {
        cancelScanTimeout()
        NSLog("Scanning for devices")
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
        NSLog("Scan timeout, no device found. Will retry after delay.")
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
        NSLog("Connected to peripheral: %@", peripheral.identifier.uuidString)
        pendingReconnectPeripheral = nil
        cancelReconnectFallback()
        fallbackScanActive = false
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
        NSLog("Failed to connect to peripheral: %@, error: %@", peripheral.identifier.uuidString, String(describing: error))
        pendingReconnectPeripheral = nil
        bluetoothPeripheral = nil
        if fallbackScanActive {
            // The failure is the cancelled pending reconnect from the
            // fallback timeout; the fallback scan is already running.
            fallbackScanActive = false
            return
        }
        if !isSleeping {
            scheduleReconnectOrScan()
        }
    }

    private func handleDiscoveredDevice(_ peripheral: BluetoothPeripheral, _ isWalkingPad: Bool) {
        if isWalkingPad, let notifyCharacteristic = peripheral.notifyCharacteristic,
           let commandCharacteristic = peripheral.commandCharacteristic {
            savePeripheralIdentifier(peripheral.peripheral)
            walkingPadService.onConnect(WalkingPadConnection(
                peripheral: peripheral.peripheral,
                notifyCharacteristic: notifyCharacteristic,
                commandCharacteristic: commandCharacteristic
            ))
            centralManager.stopScan()
            cancelScanTimeout()
            bluetoothPeripheral = nil
        } else if isWalkingPad {
            NSLog("WalkingPad device %@ is missing required characteristics, skipping", peripheral.peripheral.identifier.uuidString)
            peripheralBlacklist.insert(peripheral.peripheral.identifier.uuidString)
            centralManager?.cancelPeripheralConnection(peripheral.peripheral)
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
        NSLog("Device is disconnected: %@, error: %@", peripheral.identifier.uuidString, String(describing: error))
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
            NSLog("Reconnect attempt %d/%d in %.0fs", reconnectAttempts, maxReconnectAttempts, delay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isSleeping else { return }
                self.reconnectToKnownPeripheral()
            }
        } else {
            NSLog("Max reconnect attempts reached, starting full scan")
            reconnectAttempts = 0
            beginScan()
        }
    }
}
