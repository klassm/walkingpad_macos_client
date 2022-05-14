import SwiftUI
import OAuth2

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
    private var googleOAuth = GoogleOAuth()
    private var stepsUploader: StepsUploader
    private var updateTimer: RepeatingTimer? = nil;

    var popover: NSPopover!
    var statusBarItem: NSStatusItem!
    
    
    override init() {
        self.walkingPadService = WalkingPadService()
        self.bluetoothDiscoverService = BluetoothDiscoveryService(walkingPadService)
        self.stepsUploader = StepsUploader(googleFitFacade: GoogleFitFacade(self.googleOAuth))
        
        super.init()
        
        self.updateTimer = RepeatingTimer(interval: 5, eventHandler: {
            self.walkingPadService.command()?.updateStatus()
        })
        
        workout.onChangeCallback = {
            change in DispatchQueue.global(qos: .userInitiated).async {
                self.stepsUploader.handleChange(change)
            }
        }
        self.walkingPadService.callback = { oldState, newState in
            self.workout.update(oldState, newState)
        }
        
        self.updateTimer?.start();
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveSleepNotification), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(receiveWakeNotification), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    @objc func receiveSleepNotification(sender: AnyObject){
        NSLog("Reveived sleep notification, stopping timer");
        self.updateTimer?.stop();
    }

    @objc func receiveWakeNotification(sender: AnyObject){
        NSLog("Reveived wake notification, starting timer");
        self.bluetoothDiscoverService.start()
        self.updateTimer?.start()
    
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        DispatchQueue.global(qos: .userInitiated).async {
            startHttpServer(walkingPadService: self.walkingPadService, workout: self.workout)
        }
        
        let view = NSHostingView(rootView: ContentView()
                                    .environmentObject(workout)
                                    .environmentObject(walkingPadService)
                                    .environmentObject(googleOAuth))
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
    }
    
    @objc func update() {
        self.walkingPadService.command()?.updateStatus()
    }
    
    // register our app to get notified when launched via URL
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(AppDelegate.handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    /** Gets called when the App launches/opens via URL. */
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue {
            if let url = URLComponents(string: urlString), urlString.contains("/oauth") && urlString.contains("code=") {
                if let code = url.queryItems?.first(where: { $0.name == "code" })?.value {
                    googleOAuth.exchangeCodeForToken(code)
                    print("received calback with \(code)")
                }
            }
        }
        else {
            NSLog("No valid URL to handle")
        }
    }
}
