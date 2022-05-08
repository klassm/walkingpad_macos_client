
import Foundation

class StepsUploader {
    private var googleFitFacade: GoogleFitFacade
    
    private var accumulatedSteps: Int = 0
    private var intervalStartTime: Date? = nil
    private var workoutStartTime: Date? = nil
    
    init(googleFitFacade: GoogleFitFacade) {
        self.googleFitFacade = googleFitFacade
    }
    
    func handleChange(_ change: Change) {
        let hasSpeedChange = change.newSpeedLevel != change.oldSpeedLevel
        accumulatedSteps += change.steps

        if (intervalStartTime == nil) {
            intervalStartTime = Date()
        }
        if (workoutStartTime == nil) {
            workoutStartTime = intervalStartTime
        }
        
        if (!hasSpeedChange) {
            return
        }
        
        let now = Date()
        self.submitIfRequired(start: intervalStartTime!, end: now, steps: accumulatedSteps)
        
        if (change.newSpeedLevel < 10) {
            self.googleFitFacade.createWorkoutSession(start: workoutStartTime!, end: now)
            workoutStartTime = nil
        }
        
        intervalStartTime = now
        accumulatedSteps = 0
    }
    
    private func submitIfRequired(start: Date, end: Date, steps: Int) {
        if (steps == 0) {
            return
        }
        
        print("uploading \(start)-\(end) => \(steps)")
        self.googleFitFacade.uploadStepData(start: start, end: end, steps: steps)
    }
}
