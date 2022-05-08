import Foundation

class RepeatingTimer {
    private var interval: TimeInterval;
    private var eventHandler: () -> Void;
    private var timer: Timer? = nil
    
    init(interval: TimeInterval, eventHandler: @escaping ()-> Void) {
        self.interval = interval;
        self.eventHandler = eventHandler;
    }
    
    func start() {
        if (self.timer != nil) {
            NSLog("Timer is already running.")
            return;
        }
        
        NSLog("Starting timer");
        let newTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            self.eventHandler()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        self.timer = newTimer;
    }
    
    func stop() {
        guard let startedTimer = self.timer else {
            NSLog("Cannot stop timer, as it is not yet started")
            return;
        }
        
        NSLog("Stopping timer");
        startedTimer.invalidate();
        self.timer = nil;
    }
}
