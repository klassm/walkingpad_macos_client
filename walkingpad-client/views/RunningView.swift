import SwiftUI
import CoreBluetooth


struct RunningView: View {
    @EnvironmentObject
    var walkingPadService: WalkingPadService

    var body: some View {
        let state = self.walkingPadService.lastStatus()
        let speedLevel = state?.speed ?? 0

        let renderButton = { (speed: Int) in
            Button(action: {
                self.walkingPadService.command()?.setSpeed(speed: UInt8(speed))
            }) {
                Text(String(format: "%.1f", Float(speed) / 10.0))
            }
            .background(speedLevel == speed ? Color.accentColor : Color.clear)
            .foregroundColor(speedLevel == speed ? Color.white : Color.black)
            .cornerRadius(5)
        }
        
        let renderWalkingModeButton = {(mode: WalkingMode) in
            Button(action: { self.walkingPadService.command()?.setWalkingMode(mode: mode)}) {
                Text(mode == .manual ? "Manual" : "Automatic")
            }
            .background(mode == state?.walkingMode ? Color.accentColor : Color.clear)
            .foregroundColor(mode == state?.walkingMode ? Color.white : Color.black)
            .cornerRadius(5)
        }
        
        let renderRow = { (start: Int, end: Int) in
            HStack {
                ForEach(start..<end, id: \.self) { index in
                    let targetSpeed = (index * 10) / 2 + 10
                    renderButton(targetSpeed)
                }
            }
        }
        
        let renderSpeedRows = {
            ForEach(0..<4) { index in
                let start = index * 4
                renderRow(start, start + 4)
            }
        }
        
        VStack {
            WorkoutStateView()
            
            if (state?.walkingMode == .manual) {
                renderSpeedRows()
            } else {
                Text("Speed: \(String(format: "%.00f km/h", Double(speedLevel) / 10))")
            }
            
            HStack {
                renderWalkingModeButton(.manual)
                renderWalkingModeButton(.automatic)
            }
            
            HStack {
                Button(action: {
                    self.walkingPadService.command()?.setSpeed(speed: 0)
                }) {
                    Text("Stop")
                }
            }
        }
    }
}
