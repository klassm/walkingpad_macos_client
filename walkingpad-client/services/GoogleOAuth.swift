import Foundation
import OAuth2

class GoogleOAuth: OAuth2DataLoader, ObservableObject {
    
    @Published
    var loggedIn: Bool = false;
    
    public init() {
        let oauth = OAuth2CodeGrant(settings: [
            "client_id": "1035108851517-r10k44vtl0outd5rn0h7derkrfctn2ra.apps.googleusercontent.com",
            "authorize_uri": "https://accounts.google.com/o/oauth2/auth",
            "token_uri": "https://www.googleapis.com/oauth2/v3/token",
            "scope": "profile https://www.googleapis.com/auth/fitness.activity.read https://www.googleapis.com/auth/fitness.activity.write",
            "redirect_uris": ["com.googleusercontent.apps.1035108851517-r10k44vtl0outd5rn0h7derkrfctn2ra:/oauth"],
        ])
        oauth.logger = OAuth2DebugLogger(.debug)
    
        super.init(oauth2: oauth, host: "https://www.googleapis.com")
        alsoIntercept403 = true
        self.loggedIn = self.isLoggedIn()
    }
    
    func googleApiRequest(path: String, method: String = "GET", data: Data? = nil, callback: @escaping ((_ callback: OAuth2Response) -> Void)) {
        let url = URL(string: "https://www.googleapis.com\(path)")!
        var req = oauth2.request(forURL: url)
        req.httpMethod = method
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let postData = data != nil ? String(decoding: data!, as: UTF8.self) : ""
        print("requesting \(url), method=\(method), postData=\(postData)")
        
        self.perform(request: req, callback: callback)
    }
    
    func auth() {
        self.attemptToAuthorize { authParameters, error in
            if let params = authParameters {
                print("Authorized! Access token is in `oauth2.accessToken`")
                print("Authorized! Additional parameters: \(params)")
                self.loggedIn = true
            }
            else {
                print("Authorization was canceled or went wrong: \(String(describing: error))")   // error will not be nil
            }
        }
    }
    
    func exchangeCodeForToken(_ code: String) {
        if let oa2 = self.oauth2 as? OAuth2CodeGrant {
            oa2.exchangeCodeForToken(code)
        }
    }
    
    func isLoggedIn() -> Bool {
        return self.oauth2.refreshToken != nil
    }
    
    func logout() {
        self.oauth2.forgetTokens()
        self.loggedIn = self.isLoggedIn()
    }
}
