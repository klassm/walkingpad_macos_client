import Foundation

class StepsUploader {
    private var hcGatewayService: HCGatewayService
    
    private var accumulatedSteps: Int = 0
    private var startTime: Date? = nil
    
    init(hcGatewayService: HCGatewayService) {
        self.hcGatewayService = hcGatewayService
    }
    
    func handleChange(_ change: Change) {
        let hasSpeedChange = change.newSpeed != change.oldSpeed
        accumulatedSteps += change.stepsDiff

        if self.startTime == nil {
            self.startTime = Date()
        }
        
        if !hasSpeedChange || accumulatedSteps < 10 || change.oldSpeed == 0 || change.newSpeed != 0 {
            return
        }

        guard let startTime = self.startTime else { return }
        let now = Date()
        
        print("uploading \(startTime)-\(now) => \(self.accumulatedSteps)")
        
        Task {
            let success = await hcGatewayService.uploadSteps(startTime: startTime, endTime: now, steps: self.accumulatedSteps)
            if success {
                print("Steps uploaded successfully to HCGateway.")
                self.reset()
            } else {
                print("Failed to upload steps to HCGateway.")
            }
        }
        
    }
    
    func reset() {
        self.startTime = nil
        self.accumulatedSteps = 0
    }
}
