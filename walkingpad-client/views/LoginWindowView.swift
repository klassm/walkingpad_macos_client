import SwiftUI
import AppKit

struct LoginWindowView: View {
    let gatewayService: HCGatewayService
    let window: NSWindow
    
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    @FocusState private var usernameFieldFocused: Bool
    @State private var isLoginWindow = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Login via HCGateway")
                    .font(.title)
                    .padding(.top, 10)
                
                VStack(spacing: 10) {
                    Text("For syncing data to Google Fit you need to download a bridge app at ")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Link("HCGatewy in Github", destination: URL(string: "https://github.com/ShuchirJ/HCGateway")!)
                        .font(.subheadline)
                        .underline()
                        .foregroundColor(.blue)
                    
                    Text("Login on your device, then enter the same login credentials here.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
                
                Text("Login")
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Username")
                    
                    TextField("Enter username", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 250)
                        .focused($usernameFieldFocused)
                    
                    Text("Password")
                    
                    SecureField("Enter password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 250)
                }
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                }
                
                HStack(spacing: 20) {
                    Button("Cancel") {
                        window.close()
                    }
                    
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Login") {
                            Task {
                                await attemptLogin()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(username.isEmpty || password.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // Align the ScrollView content to the top
        .onAppear {
            usernameFieldFocused = true
        }
    }


    
    private func attemptLogin() async {
        if username.isEmpty || password.isEmpty {
            errorMessage = "Please enter username and password"
            return
        }
        
        isLoading = true
        errorMessage = ""
        
        let success = await gatewayService.login(username: username, password: password)
        
        if success {
            window.close()
        } else {
            errorMessage = "Invalid username or password"
        }
        
        isLoading = false
    }
}
