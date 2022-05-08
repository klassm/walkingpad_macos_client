import SwiftUI

struct FooterView: View {
    @EnvironmentObject var bleConnection: BLEConnection
    @EnvironmentObject var workout: Workout
    @Environment(\.openURL) var openURL
    
    var body: some View {
        HStack {
            Spacer()
            Button(action: {
                openURL(URL(string: "https://deskfit-macos-client-stats.netlify.app")!)
            }) {
                Text("Stats")
            }
            LoginLogoutButton()
            Button(action: {
                bleConnection.stop()
                workout.save()
                exit(0)
            }) {
                Text("Quit")
            }
        }
    }
}

struct FooterView_Previews: PreviewProvider {
    static var previews: some View {
        FooterView()
    }
}
