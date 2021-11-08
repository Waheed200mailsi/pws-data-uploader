# Private weather station (PWS) data uploader

## Description

Shell script to periodically publish sensor data from a PWS, which sends its
readings (in metric format) via [LoRaWAN](https://www.thethingsnetwork.org/docs/lorawan/)
to [The Things Network (TTN)](https://www.thethingsnetwork.org), to 
[Weather Undergroud](https://www.wunderground.com), [Windy](https://www.windy.com)
and [OpenWeather](https://openweathermap.org).

## System requirements

The skript is written for `bash`. Furthermore you need `mosquitto_sub` to
connect to TTN's MQTT server, `jq` to parse JSON messages and `bc` to convert
or calculate sensor readings.

## Register your PWS

Before you can upload weather data to one of the online services mentioned above you
need to register your private weather station (PWS) to receive a station id, login,
password, api-keys, etc. Please read the following documentation about the APIs
for more details:

* [Windy](https://community.windy.com/topic/8168/report-your-weather-station-data-to-windy)
* [OpenWeather](https://openweathermap.org/stations)
* [Weather Underground](https://support.weather.com/s/article/PWS-Upload-Protocol?language=en_US)

## Configuration

At the beginning of the script you'll find quite a few variables that need to be set once
according to your setup. All `STATION_` and `MQTT_` settings are required. If you don't
set a `WINDY_KEY`, `OPENWEATHER_KEY` or `WUNDERGROUND_PASS` the upload to the corresponding
service will be omitted.

## TTN Payload from PWS as input

Your weather station or better the decoder function of your receiving application
in your [TTN console](https://console.cloud.thethings.network/) should provide
the following (metric) readings/variables as part of the `decoded_payload` in
the MQTT/JSON uplink message: `temperature`, `humitidy`, `pressure`, `dewpoint`,
`heatindex`, `windspeed`, `winddirection`, `rain1h`, `rain24h`, `rainTotal`
and `globalradiation`. If values for `rain1h` or `rain24h` are missing, a zero
reading is uploaded. If you're brave, you can also adjust the JSON and URL templates
to your needs (lines 90-140).

## Run as a service at system startup

To run the script automatically as a non-privileged service (as user `nobody`) in the
background (on a Linux system with [systemd](https://en.wikipedia.org/wiki/Systemd)) copy
it (as root) to `/usr/local/bin` and `pws-data-uploader.service` to `/etc/systemd/system`.
Update systemd with `systemctl daemon-reload`, enabled the newly created service
with `systemctl enable pws-data-uploader` and finally start it with
`systemctl start pws-data-uploader`.

## Security considerations

You should not use this script on a shared multi-user system since `mosquitto_sub`
requires the password for an authenticated MQTT connection to be stated with `-P`
on the command line. It will show up in the process list and is visible to other
users on a shared system.

## Contributing

Pull requests are welcome! For major changes, please open an issue first to
discuss what you would like to change.

## License

Copyright (c) 2021 Lars Wessels  
This software was published under the MIT license.  
Please check the [license file](LICENSE).
