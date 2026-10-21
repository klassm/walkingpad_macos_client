import Foundation

// Timer callbacks fire on the main run loop and the timer is only ever
// started/stopped from the main thread, so shared state is main-thread bound.
final class RepeatingTimer: @unchecked Sendable {
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
        let newTimer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { _ in
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
