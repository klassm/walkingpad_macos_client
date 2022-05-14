import SwiftUI
import CoreBluetooth


struct RunningView: View {
    @EnvironmentObject
    var device: WalkingPad

    var body: some View {
        let speedLevel = self.device.status.speed
        
        let renderButton = { (speed: Int) in
            Button(action: {
                device.setSpeed(speed: UInt8(speed))
            }) {
                Text(String(format: "%.1f", Float(speed) / 10.0))
            }
            .background(speedLevel == speed ? Color.blue : Color.secondary)
            .foregroundColor(speedLevel == speed ? Color.white : Color.black)
            .cornerRadius(5)
        }
        
        let renderWalkingModeButton = {(mode: WalkingMode) in
            Button(action: { device.setWalkingMode(mode: mode)}) {
                Text(mode == .manual ? "Manual" : "Automatic")
            }
            .background(mode == device.status.walkingMode ? Color.blue : Color.secondary)
            .foregroundColor(mode == device.status.walkingMode ? Color.white : Color.black)
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
            
            if (self.device.status.walkingMode == .manual) {
                renderSpeedRows()
            }
            
            HStack {
                renderWalkingModeButton(.manual)
                renderWalkingModeButton(.automatic)
            }
            
            HStack {
                Button(action: {
                    self.device.stop()
                }) {
                    Text("Stop")
                }
            }
        }
    }
}
