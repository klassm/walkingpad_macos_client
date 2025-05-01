import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walkingPadService: WalkingPadService
    @EnvironmentObject var workout: Workout
    
    
    var body: some View {
        
        VStack {
            if walkingPadService.isConnected() {
                DeviceView()
            } else {
                WaitingForTreadmillView()
            }
            
            Spacer()
        
  
            FooterView()
        }.padding(10)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
