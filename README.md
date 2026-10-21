#  WalkingPad MacOS Client

A native MacOS Client (as status bar app) to watch your steps.


### Features

* Connect to your treadmill via Bluetooth - the app remembers the last device and reconnects automatically
* Watch your steps, the app will accumulate the steps
* You can change the speed directly in the app
* Statistics - the app will remember the times you walked before and give you some statistics on how much you have walked in the past
* Local HTTP API on port 4934 to read the state and control the treadmill (>= 0.0.14)
* [Alfred](https://www.alfredapp.com/) Workflow to control your treadmill by keystroke. You can download the workflow [here](https://github.com/klassm/walkingpad_alfred/releases)
* Publish the WalkingPad state as MQTT message (>= 0.0.3)
* Sync your steps into Android Health Connect using the companion app [android_health_connect_mqtt](https://github.com/klassm/android_health_connect_mqtt), which consumes the MQTT messages published by this app

### Installation

Download the latest release from the [releases section](https://github.com/klassm/walkingpad_macos_client/releases).

Please make sure to grant the app Bluetooth permissions, to ensure the app can communicate with the WalkingPad device.

![Bluetooth Permission](docs/bluetooth_connection.png)

#### MQTT Configuration

You can publish the current WalkingPad state as MQTT message. An example use case is to use the current state
for automations in your favorite home automation tool like Home Assistant.

To configure the app to use MQTT, you need to provide a config file containing the connection data. Please
place this file in `~/Library/Containers/klassm.walkingpad-client/Data/Library/Autosave Information/.walkingpad-client-mqtt.json`
(this is quite a complex path, however it does not require any additional permissions to read it).

```json
{
  "username": "myusername",
  "password": "mypassword",
  "host": "192.168.0.73",
  "port": 1883,
  "topic": "homeassistant/sensor/walkingpad"
}
```

The app will automatically read the config data and start to publish messages.

An example message looks like the following:
```
{
    "speedKmh":1.5,
    "stepsTotal":19202,
    "distanceTotal":4690,
    "stepsWalkingpad":510
}
```

Home Assistant can afterwards be configured to read the data.

```yaml
mqtt:
  sensor:
    - name: "WalkingPad Speed"
      object_id: "walkingpad_speed"
      state_topic: "homeassistant/sensor/walkingpad"
      value_template: "{{ value_json.speedKmh }}"
      unit_of_measurement: "km/h"
    - name: "WalkingPad Steps"
      object_id: "walkingpad_steps"
      state_topic: "homeassistant/sensor/walkingpad"
      value_template: "{{ value_json.stepsTotal }}"
      unit_of_measurement: "Steps"
```

#### Local HTTP API

Since 0.0.14 the app exposes a small HTTP API on `http://localhost:4934`, which can be used e.g. for a local
statistics dashboard (see [walkingpad_web_stats](https://github.com/klassm/walkingpad_web_stats)).

| Method | Path                       | Description                                                |
| ------ | -------------------------- | ---------------------------------------------------------- |
| GET    | `/treadmill`               | Current state (steps, distance, walking time, speed)       |
| GET    | `/treadmill/workouts`      | Recorded workouts (steps, distance, time, date)            |
| POST   | `/treadmill/start`         | Start the treadmill                                        |
| POST   | `/treadmill/stop`          | Stop the treadmill                                         |
| POST   | `/treadmill/faster`        | Increase speed                                             |
| POST   | `/treadmill/slower`        | Decrease speed                                             |
| POST   | `/treadmill/speed/{value}` | Set a fixed speed, value between 10 and 80 in steps of 10  |

The commands require a connected treadmill, otherwise the server responds with `428 Precondition Required`.

### Screenshots

![Tray App](docs/tray_app.png)
![Stats](docs/stats.png)


### Credits

The implementation is heavily inspired by [ph4r05/ph4-walkingpad](https://github.com/ph4r05/ph4-walkingpad).
