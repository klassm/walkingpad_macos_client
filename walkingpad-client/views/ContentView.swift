import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleConnection: BLEConnection
    @EnvironmentObject var workout: Workout
    @EnvironmentObject var googleOAuth: GoogleOAuth
    
    
    var body: some View {
        
        VStack {
            if let device = bleConnection.device {
                DeviceView()
                    .environmentObject(device)
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
