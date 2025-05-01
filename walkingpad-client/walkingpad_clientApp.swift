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
        }
        
        self.mqttService.start()
        self.updateTimer?.start();
        self.bluetoothDiscoverService.start()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveSleepNotification), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveWakeNotification), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    @objc func receiveSleepNotification(sender: AnyObject){
        NSLog("Reveived sleep notification, stopping timer");
        self.updateTimer?.stop();
        self.mqttService.stop()
        self.stepsUploader.reset()
    }

    @objc func receiveWakeNotification(sender: AnyObject){
        NSLog("Reveived wake notification, starting timer");
        self.bluetoothDiscoverService.start()
        self.updateTimer?.start()
        self.mqttService.start()
        self.stepsUploader.reset()
    
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            startHttpServer(walkingPadService: self.walkingPadService, workout: self.workout)
        }
        
        let view = NSHostingView(rootView: ContentView()
                                    .environmentObject(workout)
                                    .environmentObject(walkingPadService)
                                    .environmentObject(hcGatewayService))
        let menuItem = NSMenuItem()
        menuItem.view = view
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 250)
        
        let menu = NSMenu()
        menu.addItem(menuItem)

        self.statusBarItem = NSStatusBar.system.statusItem(withLength: CGFloat(NSStatusItem.variableLength))
        self.statusBarItem.menu = menu
        if let button = self.statusBarItem.button {
            button.image = NSImage(named: "StatusIcon")
            button.image?.isTemplate = true
        }
        
        Task {
            await self.hcGatewayService.initialize()
        }
    }
    
    @objc func update() {
        self.walkingPadService.command()?.updateStatus()
    }
}
