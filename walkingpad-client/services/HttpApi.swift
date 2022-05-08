import Foundation
import Embassy

struct WorkoutApiData: Codable {
    var steps: Double
    var meters: Double
    var date: String
}



func startHttpServer(bleConnection: BLEConnection, workout: Workout) {
    let loop = try! SelectorEventLoop(selector: try! KqueueSelector())
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let server = DefaultHTTPServer(eventLoop: loop, port: 4934) {
        (
            environ: [String: Any],
            startResponse: @escaping ((String, [(String, String)]) -> Void),
            sendBody: @escaping ((Data) -> Void)
        ) in
        let path = environ["PATH_INFO"] as! String
        
        let sendStatus = { (status: Int, statusText: String) in
            startResponse("\(status) \(statusText)", [])
            sendBody(Data())
        }
        
        let sendSuccess = { () in
            sendStatus(200, "OK")
        }
        
        
        let handlePost = { () in
            guard let treadmill = bleConnection.device else {
                sendStatus(428, "Treadmill not connected")
                return
            }
            
            if (path == "/treadmill/stop") {
                treadmill.stop()
                sendSuccess()
                return
            }
            
            if (path == "/treadmill/start") {
                treadmill.start()
                sendSuccess()
                return
            }
            
            if (path == "/treadmill/pause") {
                treadmill.pause()
                sendSuccess()
                return
            }
            
            if (path.hasPrefix("/treadmill/speed/")) {
                let speedRegex = try! NSRegularExpression(pattern: "/treadmill/speed/([1-8]0)")
                guard let match = speedRegex.firstMatch(in: path, options: [], range: NSRange(path.startIndex..., in: path)) else {
                    sendStatus(404, "Not found")
                    return
                }
                
                let range = Range(match.range(at: 1), in: path)!
                let speedMatch = path[range]
                let speed = UInt8(speedMatch)!
                treadmill.setSpeed(speed: speed)

                sendSuccess()
                return
            }
            
            sendStatus(404, "Not found")
        }
        
        
        let handleGet = { () in
            
            if (path == "/treadmill/workouts") {
                let jsonEncoder = JSONEncoder()
                do {
                    let workouts = workout.loadAll()
                    let toEncode = workouts.map{WorkoutApiData(steps: $0.steps, meters: $0.meters, date: dateFormatter.string(from: $0.date))}
                    let json = try jsonEncoder.encode(toEncode)
                    startResponse("200 OK", [("content-type", "application/json"), ("access-control-allow-origin", "*")])
                    sendBody(json)
                    sendBody(Data())
                } catch {
                    sendStatus(500, "Error")
                }
                return
            }
          
            sendStatus(404, "Not found")
        }
        
        let method = environ["REQUEST_METHOD"] as? String
        if method == "POST"  {
            handlePost()
        } else if method == "GET" {
            handleGet()
        } else {
            sendStatus(404, "Not found")
        }
    }

    // Start HTTP server to listen on the port
    try! server.start()

    // Run event loop
    loop.runForever()
}
