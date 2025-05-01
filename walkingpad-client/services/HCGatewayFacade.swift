import Foundation

class HCGatewayAPI {
    let baseURL = URL(string: "https://api.hcgateway.shuchir.dev")!
    let session = URLSession(configuration: .default)
    
    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        decoder.dateDecodingStrategy = .custom { decoder -> Date in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            if let date = dateFormatter.date(from: dateString) {
                return date
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date string does not match format expected by formatter.")
            }
        }
        return decoder
    }()
    
    func performRequest(endpoint: String, method: String, parameters: [String: String] = [:]) async throws -> (Data, URLResponse) {
        guard var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }
        urlComponents.path = endpoint

        var request = URLRequest(url: urlComponents.url!, cachePolicy: .useProtocolCachePolicy)
        request.httpMethod = method

        if !parameters.isEmpty {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: [])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                throw error
            }
        }

        return try await session.data(for: request)
    }
    
    func login(username: String, password: String) async throws -> LoginResponse {
        let url = URL(string: "\(baseURL)/api/v2/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = [
            "username": username,
            "password": password
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: body, options: [])
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("Login failed with status code: \(statusCode)")
            throw URLError(.badServerResponse)
        }
        
        return try HCGatewayAPI.jsonDecoder.decode(LoginResponse.self, from: data)
    }

    func refreshToken(refreshToken: String) async throws -> LoginResponse {
        let url = URL(string: "\(baseURL)/api/v2/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: String] = [
            "refresh": refreshToken
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: body, options: [])
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("Token refresh failed with status code: \(statusCode)")
            throw URLError(.badServerResponse)
        }
        
        return try HCGatewayAPI.jsonDecoder.decode(LoginResponse.self, from: data)
    }


    func fetch(accessToken: String) async throws -> [FetchResponse] {
        let endpoint = "/api/v2/fetch/steps"
        let parameters: [String: Any] = ["queries": [String: String]()]

        guard var urlComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw NSError(domain: "Invalid URL", code: 0, userInfo: nil)
        }
        urlComponents.path = endpoint

        var request = URLRequest(url: urlComponents.url!, cachePolicy: .useProtocolCachePolicy)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: [])
        } catch {
            throw error
        }

        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([FetchResponse].self, from: data)
    }

    func push(accessToken: String, method: String, stepsRecord: StepsRecord) async throws -> PushResponse {
        let url = URL(string: "\(baseURL)/api/v2/push/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let body: [String: [StepsRecord]] = ["data": [stepsRecord]]
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateString = formatter.string(from: date)
            try container.encode(dateString)
        }
        
        let jsonData = try encoder.encode(body)
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        switch httpResponse.statusCode {
        case 200:
            return try JSONDecoder().decode(PushResponse.self, from: data)
        case 401, 403:
            // Pass through authentication errors with status code
            throw APIError.httpError(statusCode: httpResponse.statusCode, data: data)
        default:
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            print("Push failed with status code: \(httpResponse.statusCode), response: \(responseBody)")
            throw APIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }
    }
}

enum APIError: Error {
    case httpError(statusCode: Int, data: Data)
    case decodingError
}

struct LoginResponse: Codable {
    let token: String
    let refresh: String
    let expiry: Date
}


struct FetchResponse: Codable {
    let id: String
    let _id: String
    let data: [String: String]
    let start: Date
    let end: Date
    let app: String

    enum CodingKeys: String, CodingKey {
        case id
        case _id = "_id"
        case data
        case start
        case end
        case app
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        _id = try container.decode(String.self, forKey: ._id)
        data = try container.decode([String: String].self, forKey: .data)
        let startString = try container.decode(String.self, forKey: .start)
        guard let startDate = ISO8601DateFormatter().date(from: startString) else {
            throw DecodingError.dataCorruptedError(forKey: .start, in: container, debugDescription: "Invalid start date")
        }
        start = startDate
        let endString = try container.decode(String.self, forKey: .end)
        guard let endDate = ISO8601DateFormatter().date(from: endString) else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: container, debugDescription: "Invalid end date")
        }
        end = endDate
        app = try container.decode(String.self, forKey: .app)
    }
}

struct MetadataDevice: Codable {
    let manufacturer: String
    let model: String
    let type: Int
}

struct Metadata: Codable {
    let recordingMethod: Int
    let device: MetadataDevice
}

struct StepsRecord: Codable {
    let startTime: Date
    let startZoneOffset: Int?
    let endTime: Date
    let endZoneOffset: Int?
    let count: Int
    let metadata: Metadata?
}

struct PushResponse: Codable {
    let success: Bool
    let message: String

    enum CodingKeys: String, CodingKey {
        case success
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        message = try container.decode(String.self, forKey: .message)
    }
}
