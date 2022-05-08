import SwiftUI

struct LoginLogoutButton: View {
    @EnvironmentObject var googleOAuth: GoogleOAuth
    
    
    var body: some View {
        

            if (!googleOAuth.isLoggedIn()) {
                Button(action: {
                    googleOAuth.auth()
                }) {
                    Text("Login")
                }
                
            } else {
                Button(action: {
                    googleOAuth.logout()
                }) {
                    Text("Logout")
                }
            }
  
    }
}
