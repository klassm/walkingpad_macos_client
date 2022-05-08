import SwiftUI
import CoreBluetooth


struct RunningView: View {
    @EnvironmentObject
    var device: WalkingPad

    var body: some View {
        let speedLevel = self.device.status.speedLevel
        
        let renderButton = { (speed: Int) in
            Button(action: {
                device.setSpeed(speed: UInt8(speed))
            }) {
                Text("\(speed)")
            }
            .background(speedLevel == speed ? Color.blue : Color.secondary)
            .foregroundColor(speedLevel == speed ? Color.white : Color.black)
            .cornerRadius(5)
        }
        
        VStack {
            WorkoutStateView()
            
            HStack {
                ForEach(1..<5) { index in
                    renderButton(index * 10)
                }
            }
            HStack {
                ForEach(5..<9) { index in
                    renderButton(index * 10)
                }
            }
            HStack {
                Button(action: {
                    self.device.stop()
                }) {
                    Text("Stop")
                }
                
                Button(action: {
                    self.device.pause()
                }) {
                    Text("Pause")
                }
            }
        }
    }
}
