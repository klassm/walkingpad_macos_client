import Foundation
import MQTTNIO
import NIO

struct MqttConfiguration: Codable {
    var username: String
    var password: String
    var host: String
    var port: UInt16
    var topic: String
}

struct MqttData: Codable {
    var stepsWalkingpad: Int
    var stepsTotal: Int
    var distanceTotal: Int
    var speedKmh: Double
    var state: TreadmillConnectionState
}

class MqttService {
    private var client: MQTTClient?
    private var fileSystem: FileSystem
    private var lastMessageTime: Date?
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var config: MqttConfiguration?
    
    init(_ fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }
    
    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
    
    func start() {
        guard let config = self.loadConfig() else { return }
        self.config = config
        
        let client = MQTTClient(
            configuration: .init(
                target: .host(config.host, port: Int(config.port)),
                clientId: "WalkingPadClient-\(ProcessInfo().processIdentifier)",
                credentials: config.username.isEmpty ? nil : .init(username: config.username, password: config.password)
            ),
            eventLoopGroupProvider: .shared(eventLoopGroup)
        )
        
        client.connect().flatMap { _ -> EventLoopFuture<Void> in
            NSLog("MQTT connected successfully")
            self.client = client
            _ = self.subscribeToTopics(config: config)
            return self.eventLoopGroup.next().makeSucceededFuture(())
        }.whenComplete { result in
            switch result {
            case .success:
                NSLog("MQTT connected successfully")
                self.client = client
                self.subscribeToTopics(config: config)
            case .failure(let error):
                NSLog("MQTT connection failed: %@", String(describing: error))
            }
        }
    }
    
    @discardableResult
    private func subscribeToTopics(config: MqttConfiguration) -> EventLoopFuture<Void> {
        guard let client = client else {
            return eventLoopGroup.next().makeFailedFuture(NSError(domain: "MQTT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not connected"]))
        }
        return client.subscribe(to: [.init(topicFilter: config.topic, qos: .atMostOnce)]).map { _ in }
    }
    
    func stop() {
        try? client?.disconnect().wait()
    }
    
    private func loadConfig() -> MqttConfiguration? {
        guard let mqttConfigRaw = self.loadConfigFile() else { return nil }
        
        do {
            let jsonDecoder = JSONDecoder()
            let decoded = try jsonDecoder.decode(MqttConfiguration.self, from: mqttConfigRaw)
            return decoded
        } catch {
            NSLog("error while decoding mqtt config json: %@", String(describing: error))
            return nil
        }
    }
    
    private func shouldSend(oldState: DeviceState?, newState: DeviceState) -> Bool {
        let oldSpeed = oldState?.speed;
        let newSpeed = newState.speed
        guard let lastMessageTime = self.lastMessageTime else { return true }
        
        if (oldSpeed != newSpeed) {
            return true
        }
        
        let now = Date()
        let passedSeconds = now.timeIntervalSince(lastMessageTime)
        return passedSeconds > 30
    }
    
    public func publish(oldState: DeviceState?, newState: DeviceState, workoutState: WorkoutState, connectionState: TreadmillConnectionState) {
        guard let client = self.client else { return }
        if (!shouldSend(oldState: oldState, newState: newState)) {
            return
        }
        
        do {
            let jsonData = try JSONEncoder().encode(MqttData(
                stepsWalkingpad: newState.steps,
                stepsTotal: workoutState.steps,
                distanceTotal: workoutState.distance,
                speedKmh: newState.speedKmh(),
                state: connectionState
            ))
            
            let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
            NSLog("Publishing MQTT data: %@", jsonString)
            
            client.publish(
                .string(jsonString),
                to: self.config?.topic ?? "walkingpad/stats",
                qos: .atMostOnce
            )
            
            self.lastMessageTime = Date()
        } catch {
            NSLog("error while encoding mqtt data: %@", String(describing: error))
        }
    }
    
    private func loadConfigFile() -> Data? {
        return self.fileSystem.load(filename: ".walkingpad-client-mqtt.json")
    }
}
