import Foundation
import Embassy

struct WorkoutApiData: Codable {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
    var date: String
}

struct TreadmillState : Codable {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
}

func startHttpServer(walkingPadService: WalkingPadService, workout: Workout) {
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
            guard let command = walkingPadService.command() else {
                sendStatus(428, "Treadmill not connected")
                return
            }

            if (path == "/treadmill/stop") {
                command.setSpeed(speed: 0)
                sendSuccess()
                return
            }

            if (path == "/treadmill/start") {
                command.start()
                sendSuccess()
                return
            }

            
            if (path == "/treadmill/faster") {
                let speed = walkingPadService.lastStatus()?.speed
                if (speed == nil) {
                    command.start()
                } else {
                    command.setSpeed(speed: UInt8((speed ?? 0) + 5))
                }
                sendSuccess()
                return
            }

            
            if (path == "/treadmill/slower") {
                let speed = walkingPadService.lastStatus()?.speed
                if (speed == nil) {
                    command.setSpeed(speed: 0)
                } else {
                    command.setSpeed(speed: UInt8((speed ?? 0) - 5))
                }
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
                command.setSpeed(speed: speed)

                sendSuccess()
                return
            }

            sendStatus(404, "Not found")
        }
        
        
        let handleGet = { () in
            do {
                if (path == "/treadmill/workouts") {
                    let jsonEncoder = JSONEncoder()

                        let workouts = workout.loadAll()
                        let toEncode = workouts.map{WorkoutApiData(
                            steps: $0.steps,
                            distance: $0.distance,
                            walkingSeconds: $0.walkingSeconds,
                            date: dateFormatter.string(from: $0.date)
                        )}
                        let json = try jsonEncoder.encode(toEncode)
                        startResponse("200 OK", [("content-type", "application/json"), ("access-control-allow-origin", "*")])
                        sendBody(json)
                        sendBody(Data())

                    return
                } else if (path == "/treadmill") {
                    let jsonEncoder = JSONEncoder()
                    let toEncode = TreadmillState(
                        steps: workout.steps,
                        distance: workout.distance,
                        walkingSeconds: workout.walkingSeconds
                    )
                    let json = try jsonEncoder.encode(toEncode)
                    startResponse("200 OK", [("content-type", "application/json"), ("access-control-allow-origin", "*")])
                    sendBody(json)
                    sendBody(Data())
                } else {
                    sendStatus(404, "Not found")
                }
            } catch {
                sendStatus(500, "Error")
            }
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
