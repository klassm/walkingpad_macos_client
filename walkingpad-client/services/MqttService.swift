import Foundation
import CocoaMQTT

struct MqttConfiguration: Codable {
    var username: String
    var password: String
    var host: String
    var port: UInt16
    var topic: String;
}

struct MqttConnection {
    var mqtt: CocoaMQTT
    var config: MqttConfiguration
}

class MqttService {
    private var connection: MqttConnection?
    private var fileSystem: FileSystem
    
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
    
    public func publish(oldState: DeviceState?, newState: DeviceState) {
        guard let connection = self.connection else { return }
        let config = connection.config
        connection.mqtt.publish(CocoaMQTTMessage(topic: "\(config.topic)/speed", string: "\(newState.speedKmh())"))
        connection.mqtt.publish(CocoaMQTTMessage(topic: "\(config.topic)/steps", string: "\(newState.steps)"))
    }
    
    private func loadConfigFile() -> Data? {
        return self.fileSystem.load(filename: ".walkingpad-client-mqtt.json")
    }
}
