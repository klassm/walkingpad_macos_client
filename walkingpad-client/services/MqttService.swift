import Foundation
import CocoaMQTT

struct MqttConfiguration: Codable {
    var username: String
    var password: String
    var host: String
    var port: UInt16
    var topic: String
}

struct MqttConnection {
    var mqtt: CocoaMQTT
    var config: MqttConfiguration
}

struct MqttData: Codable {
    var stepsWalkingpad: Int
    var stepsTotal: Int
    var distanceTotal: Int
    var speedKmh: Double
}

class MqttService {
    private var connection: MqttConnection?
    private var fileSystem: FileSystem
    private var lastMessageTime: Date?
    
    init(_ fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }
    
    func start() {
        guard let config = self.loadConfig() else { return }

        let clientID = "WalkingPadClient-" + String(ProcessInfo().processIdentifier)
        let mqtt = CocoaMQTT(clientID: clientID, host: config.host, port: config.port)
    
        mqtt.username = config.username
        mqtt.password = config.password
        mqtt.keepAlive = 60
        let result = mqtt.connect()
        
        print("MQTT connection result: \(result)")
        
        if (result) {
            self.connection = MqttConnection(mqtt: mqtt, config: config)
        }
    }
    
    func stop() {
        guard let connection = self.connection else { return }
        connection.mqtt.disconnect()
    }
    
    private func loadConfig() -> MqttConfiguration? {
        guard let mqttConfigRaw = self.loadConfigFile() else { return nil }
        
        do {
            let jsonDecoder = JSONDecoder()
            let decoded = try jsonDecoder.decode(MqttConfiguration.self, from: mqttConfigRaw)
            return decoded
        } catch {
            print("error while decoding data source json, \(error)")
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
    
    public func publish(oldState: DeviceState?, newState: DeviceState, workoutState: WorkoutState) {
        guard let connection = self.connection else { return }
        if (!shouldSend(oldState: oldState, newState: newState)) {
            return
        }
        
        let config = connection.config
        do {
            let jsonData = try JSONEncoder().encode(MqttData(stepsWalkingpad: newState.steps, stepsTotal: workoutState.steps, distanceTotal: workoutState.distance, speedKmh: newState.speedKmh()))
            let json = [UInt8](jsonData)
            connection.mqtt.publish(CocoaMQTTMessage(topic: "\(config.topic)", payload: json))
            self.lastMessageTime = Date()
        } catch {
            print("error while encoding mqtt data, \(error)")
        }
    }
    
    private func loadConfigFile() -> Data? {
        return self.fileSystem.load(filename: ".walkingpad-client-mqtt.json")
    }
}
