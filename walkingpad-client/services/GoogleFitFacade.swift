import Foundation

struct WorkoutSessionPutData: Codable {
    var id: String
    var name: String
    var description: String
    var startTimeMillis: Int
    var endTimeMillis: Int
    var version: Int
    var modifiedTimeMillis: Int
    var application: Application
    var activityType: Int
    var activeTimeMillis: Int
}

struct Device: Codable {
    var manufacturer: String
    var model: String
    var type: String
    var uid: String;
    var version: String
}

struct DataType: Codable {
    struct Field: Codable {
        var format: String
        var name: String
    }
    var field: [Field]
    var name: String
}


struct Application: Codable {
    var name: String
}


struct DataSourcePostData: Codable {
    var application: Application
    var dataType: DataType
    var device: Device
    var type: String
}

struct DataSourcePatchData: Codable {
    struct Value: Codable {
        var intVal: Int
    }
    
    struct Point: Codable {
        var dataTypeName: String
        var endTimeNanos: UInt64
        var originDataSourceId: String
        var startTimeNanos: UInt64
        var value: [Value]
    }
    
    var dataSourceId: String
    var maxEndTimeNs: UInt64
    var minStartTimeNs: UInt64
    var point: [Point]
}

struct DataSource: Decodable {
    var dataStreamId: String
}

struct DataSourceListResponse: Decodable {
    var dataSource: [DataSource]
}

class GoogleFitFacade {
    let googleOAuth: GoogleOAuth

    init(_ googleOAuth: GoogleOAuth) {
        self.googleOAuth = googleOAuth
    }
    
    private func getOrCreateDataSource(callback: @escaping ((String) -> Void)) {
        self.listDevices(callback: { ids in
            if (ids.isEmpty) {
                self.createDevice(callback: callback)
                return
            }
            callback(ids.first!)
        })
    }
    
    private func listDevices(callback: @escaping (([String]) -> Void)) {
        self.googleOAuth.googleApiRequest(path: "/fitness/v1/users/me/dataSources", callback: {result in
        
            if let error = result.error {
                print("could not post, \(error)")
            } else {
                let decoder = JSONDecoder()
                do {
                    let data = try decoder.decode(DataSourceListResponse.self, from: result.data!)
                    let ids = data.dataSource
                        .filter({stream in stream.dataStreamId.contains("deskfit") })
                        .map({stream in stream.dataStreamId })
                    callback(ids)
                } catch {
                    print("could not list devices, json parse error: \(error)")
                }
            }
        })
    }
    
    private func application() -> Application {
        return Application(name: "WalkingPad MacOS Client")
    }
    
    private func createDevice(callback: @escaping ((String) -> Void)) {
        let postData = DataSourcePostData(
            application: application(),
            dataType: DataType(
                field: [DataType.Field(format: "integer", name: "steps")],
                name: "com.google.step_count.delta"
            ),
            device: Device(
                manufacturer: "Kingsmith",
                model: "WalkingPad",
                type: "unknown",
                uid: "walkingpad",
                version: "1"
            ), type: "raw")
        
        let jsonEncoder = JSONEncoder()
        let jsonDecoder = JSONDecoder()
        let json = try? jsonEncoder.encode(postData)
        self.googleOAuth.googleApiRequest(path: "/fitness/v1/users/me/dataSources", method: "POST", data: json, callback: {result in
            if let error = result.error {
                print("could not post, \(error)")
            }
   
            do {
                let response = try jsonDecoder.decode(DataSource.self, from: result.data!)
                callback(response.dataStreamId)
                print("DataSource created")
            } catch {
                print("error while decoding data source json, \(error)")
            }
        })
    }
    
    
    func uploadStepData(start: Date, end: Date, steps: Int) {
        if (!googleOAuth.isLoggedIn()) {
            print("skipping upload, I am not logged in")
            return
        }
        if (start.formatted(date: .complete, time: .omitted) != end.formatted(date: .complete, time: .omitted)) {
            print("start date does not match end date")
            return
        }
        
        let startTimeNanos = UInt64(start.timeIntervalSince1970 * 1000 * 1000 * 1000) + 1
        let endTimeNanos = UInt64(end.timeIntervalSince1970 * 1000 * 1000 * 1000) - 1
        let dataSetId = "\(startTimeNanos)-\(endTimeNanos)"
        let jsonEncoder = JSONEncoder()
        
        self.getOrCreateDataSource(callback: { dataSourceId in
            let json = try? jsonEncoder.encode(DataSourcePatchData(
                dataSourceId: dataSourceId,
                maxEndTimeNs: endTimeNanos,
                minStartTimeNs: startTimeNanos,
                point: [DataSourcePatchData.Point(dataTypeName: "com.google.step_count.delta", endTimeNanos: endTimeNanos, originDataSourceId: dataSourceId, startTimeNanos: startTimeNanos, value: [DataSourcePatchData.Value(intVal: steps)])]
            ))
            self.googleOAuth.googleApiRequest(path: "/fitness/v1/users/me/dataSources/\(dataSourceId)/datasets/\(dataSetId)", method: "PATCH", data: json, callback: { response in
                if let error = response.error {
                    print("could not patch, \(error)")
                }
                print("Patch resulted in status \(response.response.statusString)")
            })
        })
    }
    
    func createWorkoutSession(start: Date, end: Date) {
        let startTimeMillis = Int(start.timeIntervalSince1970 * 1000)
        let endTimeMillis = Int(end.timeIntervalSince1970 * 1000)
        let id = "walkingpad_session_\(startTimeMillis)-\(endTimeMillis)"
        let jsonEncoder = JSONEncoder()
        
        let session = WorkoutSessionPutData(id: id, name: "Kingsmith", description: "WalkingPad", startTimeMillis: startTimeMillis, endTimeMillis: endTimeMillis, version: 1, modifiedTimeMillis: endTimeMillis, application: application(), activityType: 58, activeTimeMillis: endTimeMillis - startTimeMillis)
        
        let json = try? jsonEncoder.encode(session)
        self.googleOAuth.googleApiRequest(path: "/fitness/v1/users/me/sessions/\(id)", method: "PUT", data: json, callback: { response in
            if let error = response.error {
                print("could not put session, \(error)")
            }
            print("Put session resulted in status \(response.response.statusString)")
        })
    }
}
