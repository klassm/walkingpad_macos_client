
import SwiftUI

struct WaitingForTreadmillView: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                ProgressView("Waiting for treadmill...")
            }
            Spacer()
        }
    }
}

struct SearchingForDeviceView_Previews: PreviewProvider {
    static var previews: some View {
        WaitingForTreadmillView()
    }
}
