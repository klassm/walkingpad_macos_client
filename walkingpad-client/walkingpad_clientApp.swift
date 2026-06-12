import SwiftUI

@main
struct MenuBarPopoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var workout = Workout()
    private var walkingPadService: WalkingPadService
    private var bluetoothDiscoverService: BluetoothDiscoveryService
    private var stepsUploader: StepsUploader
    private var updateTimer: RepeatingTimer? = nil;
    private var mqttService: MqttService
    private var hcGatewayService: HCGatewayService

    var popover: NSPopover!
    var statusBarItem: NSStatusItem!
    override init() {
        self.walkingPadService = WalkingPadService()
        self.bluetoothDiscoverService = BluetoothDiscoveryService(walkingPadService)
        self.mqttService = MqttService(FileSystem())
        
        // Initialize HCGatewayService on the main actor
        self.hcGatewayService = HCGatewayService()
        self.stepsUploader = StepsUploader(hcGatewayService: self.hcGatewayService)
        
        super.init()
        
        self.updateTimer = RepeatingTimer(interval: 5, eventHandler: {
            self.workout.resetIfDateChanged()
            self.walkingPadService.command()?.updateStatus()
        })
        
        workout.onChangeCallback = {
            change in DispatchQueue.global(qos: .userInitiated).async {
                self.stepsUploader.handleChange(change)
            }
        }
        self.walkingPadService.callback = { oldState, newState in
            self.workout.update(oldState, newState)
            self.mqttService.publish(oldState: oldState, newState: newState, workoutState: self.workout.workoutState())
            DispatchQueue.main.async {
                self.updateStatusBarIcon(connected: self.walkingPadService.isConnected(), speed: newState.speed)
                if newState.speed > 0 {
                    self.statusBarItem?.button?.title = " \(self.workout.steps)"
                } else {
                    self.statusBarItem?.button?.title = ""
                }
            }
        }
        
        self.mqttService.start()
        self.updateTimer?.start();
        self.bluetoothDiscoverService.start()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(receiveSleepNotification), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(receiveWakeNotification), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(receiveScreenSleepNotification), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(receiveScreenWakeNotification), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(receiveSessionResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(receiveSessionBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }
    
    @objc func receiveSleepNotification(sender: AnyObject){
        NSLog("Received sleep notification, pausing services");
        bluetoothDiscoverService.setSleeping(true)
        self.updateTimer?.stop();
        self.mqttService.stop()
        self.stepsUploader.reset()
    }

    @objc func receiveWakeNotification(sender: AnyObject) {
        NSLog("Received wake notification, resuming services");
        resumeAfterSleepOrScreenOff()
    }

    @objc func receiveScreenSleepNotification(sender: AnyObject) {
        NSLog("Received screen sleep notification, pausing BLE scan");
        bluetoothDiscoverService.setSleeping(true)
    }

    @objc func receiveScreenWakeNotification(sender: AnyObject) {
        NSLog("Received screen wake notification, resuming BLE");
        resumeAfterSleepOrScreenOff()
    }

    @objc func receiveSessionResignActive(sender: AnyObject) {
        NSLog("Session resigned active (lock screen)");
        bluetoothDiscoverService.setSleeping(true)
    }

    @objc func receiveSessionBecomeActive(sender: AnyObject) {
        NSLog("Session became active (unlock)");
        resumeAfterSleepOrScreenOff()
    }

    private func resumeAfterSleepOrScreenOff() {
        self.updateTimer?.stop()
        self.mqttService.stop()

        bluetoothDiscoverService.setSleeping(false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            self.bluetoothDiscoverService.reconnectToKnownPeripheral()
            self.bluetoothDiscoverService.start()
        }

        self.mqttService.start()
        self.updateTimer?.start()

        self.stepsUploader.reset()
        self.workout.resetIfDateChanged()
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            startHttpServer(walkingPadService: self.walkingPadService, workout: self.workout)
        }
        
        let contentView = ContentView()
            .environmentObject(workout)
            .environmentObject(walkingPadService)
            .environmentObject(hcGatewayService)
        
        self.popover = NSPopover()
        self.popover.contentSize = NSSize(width: 200, height: 250)
        self.popover.behavior = .transient
        self.popover.contentViewController = NSHostingController(rootView: contentView)

        self.statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        if let button = self.statusBarItem.button {
            button.image = NSImage(named: "TreadmillEmpty")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        Task {
            await self.hcGatewayService.initialize()
        }
    }
    
    @objc func togglePopover() {
        if let button = self.statusBarItem.button {
            if self.popover.isShown {
                self.popover.performClose(button)
            } else {
                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    @objc func update() {
        self.walkingPadService.command()?.updateStatus()
    }
    
    private func updateStatusBarIcon(connected: Bool, speed: Int) {
        let iconName: String
        
        if !connected {
            iconName = "TreadmillEmpty"
        } else if speed > 0 {
            iconName = "TreadmillRunning"
        } else {
            iconName = "TreadmillStanding"
        }
        
        if let button = self.statusBarItem?.button,
           let icon = NSImage(named: iconName) {
            icon.isTemplate = true
            button.image = icon
        }
    }
}
