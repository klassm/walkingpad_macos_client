
import Foundation

class StepsUploader {
    private var googleFitFacade: GoogleFitFacade
    
    private var accumulatedSteps: Int = 0
    private var startTime: Date? = nil
    
    init(googleFitFacade: GoogleFitFacade) {
        self.googleFitFacade = googleFitFacade
    }
    
    func handleChange(_ change: Change) {
        let hasSpeedChange = change.newSpeed != change.oldSpeed
        accumulatedSteps += change.stepsDiff

        if (self.startTime == nil) {
            self.startTime = Date()
        }
        
        if (!hasSpeedChange || accumulatedSteps < 150 || change.oldSpeed == 0 || change.newSpeed != 0) {
            return
        }

        guard let startTime = self.startTime else { return }
        let now = Date()
        
        print("uploading \(startTime)-\(now) => \(self.accumulatedSteps)")
        self.googleFitFacade.uploadStepData(start: startTime, end: now, steps: self.accumulatedSteps)
        self.googleFitFacade.createWorkoutSession(start: startTime, end: now)
        
        self.startTime = nil
        self.accumulatedSteps = 0
    }
}
