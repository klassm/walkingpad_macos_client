import Foundation
import Combine
import Security

class HCGatewayService: ObservableObject {
    private let api = HCGatewayAPI()
    @Published private(set) var accessToken: String?
    @Published private(set) var refreshToken: String?
    private var expiryDate: Date?
      
    private let accessTokenKey = "accessToken"
    private let refreshTokenKey = "refreshToken"
    private let expiryDateKey = "expiryDate"
    
    init() {
        accessToken = loadToken(key: accessTokenKey)
        refreshToken = loadToken(key: refreshTokenKey)
        expiryDate = UserDefaults.standard.object(forKey: expiryDateKey) as? Date
    }
    
    func initialize() async {
        let tokenIsValid = await ensureValidAccessToken()
        guard tokenIsValid else {
            print("Failed to obtain a valid access token.")
            return
        }
    }
    
    func login(username: String, password: String) async -> Bool {
        do {
            let response = try await api.login(username: username, password: password)
            await MainActor.run {
                self.accessToken = response.token
                self.refreshToken = response.refresh
                self.expiryDate = response.expiry // Assuming response includes an `expiry` field of type Date
                self.saveTokens()
                self.saveExpiryDate()
            }
            return true
        } catch {
            print("Login error:", error)
            return false
        }
    }

    func refreshAccessToken() async -> Bool {
        guard let refreshToken = refreshToken else { return false }
        
        do {
            let response = try await api.refreshToken(refreshToken: refreshToken)
            await MainActor.run {
                self.accessToken = response.token
                self.refreshToken = response.refresh
                self.expiryDate = response.expiry
                self.saveTokens()
                self.saveExpiryDate()
            }
            return true
        } catch {
            print("Token refresh error:", error)
            // Logout if token refresh fails
            await MainActor.run {
                self.logout()
            }
            return false
        }
    }
    
    private func saveTokens() {
        if let accessToken = accessToken {
            saveToken(token: accessToken, key: accessTokenKey)
        }
        if let refreshToken = refreshToken {
            saveToken(token: refreshToken, key: refreshTokenKey)
        }
    }
    
    private func saveExpiryDate() {
        UserDefaults.standard.set(expiryDate, forKey: expiryDateKey)
    }
    
    func logout() {
        accessToken = nil
        refreshToken = nil
        expiryDate = nil
        deleteToken(key: accessTokenKey)
        deleteToken(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: expiryDateKey)
    }
    
    func isLoggedIn() -> Bool {
        return refreshToken != nil
    }
    

    private func isAccessTokenExpired() -> Bool {
        guard let expiryDate = expiryDate else {
            return true
        }
        return expiryDate < Date()
    }
    
    private func ensureValidAccessToken() async -> Bool {
        if isAccessTokenExpired() {
            return await refreshAccessToken()
        }
        return true
    }
    
    func uploadSteps(startTime: Date, endTime: Date, steps: Int) async -> Bool {
        guard isLoggedIn() else {
            print("Not logged in, cannot upload steps.")
            return false
        }
        
        let tokenIsValid = await ensureValidAccessToken()
        guard tokenIsValid, let accessToken = accessToken else {
            print("Failed to obtain a valid access token.")
            return false
        }
        
        let metadata = Metadata(
            recordingMethod: 0,
            device: MetadataDevice(
                manufacturer: "Walkingpad Macos",
                model: "Walkingpad",
                type: 0
            )
        )
        
        let stepsRecord = StepsRecord(
            startTime: startTime,
            startZoneOffset: nil,
            endTime: endTime,
            endZoneOffset: nil,
            count: steps,
            metadata: metadata
        )
        
        do {
            return try await performPushRequest(accessToken: accessToken, stepsRecord: stepsRecord)
        } catch {
            print("Error uploading steps:", error)
            return false
        }
    }
    
    
    private func performPushRequest(accessToken: String, stepsRecord: StepsRecord) async throws -> Bool {
        do {
            let response = try await api.push(
                accessToken: accessToken,
                method: "steps",
                stepsRecord: stepsRecord
            )
            return response.success
        } catch let error as APIError {
            switch error {
            case .httpError(let statusCode, _):
                if [401, 403].contains(statusCode) {
                    print("Auth error \(statusCode), attempting token refresh...")
                    if await refreshAccessToken(), let newAccessToken = self.accessToken {
                        print("Token refresh successful, retrying...")
                        return try await performPushRequest(
                            accessToken: newAccessToken,
                            stepsRecord: stepsRecord
                        )
                    } else {
                        print("Token refresh failed")
                        throw HCGatewayError.tokenRefreshFailed
                    }
                }
                throw error
            default:
                throw error
            }
        } catch {
            // Handle other error types
            print("Push request failed with error: \(error)")
            throw error
        }
    }
    
    // MARK: - Keychain Operations
    
    private func saveToken(token: String, key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: token.data(using: .utf8)!
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadToken(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
    
    private func deleteToken(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

enum HCGatewayError: Error {
    case tokenRefreshFailed
    case unauthorized
}
