#!/bin/bash
#
# pws-data-uploader v1.0
# https://github.com/lrswss/weather-station-uploader
#
# Copyright (c) 2021 Lars Wessels <software@bytebox.org>
#
# This software is licensed under the terms of the MIT license.  
# For a copy, see <https://opensource.org/licenses/MIT>.
#
# Shell script to periodically publish sensor data from a private
# weather station (PWS),# which sends its readings (in metric format)
# via LoRaWAN to TTN and to Weather Undergroud, Windy and OpenWeather.
# Requires 'mosquitto_sub' to connect to TTN's MQTT server, 'jq' to
# parse JSON messages and 'bc' to convert or calculate sensor readings.
#
# Before you can upload weather data to one of the online services mentioned
# above you need to register your private weather station (PWS) to receive
# a station id, login, password, api keys, etc. Please read the following
# documentation about the APIs for more details:
#
# https://community.windy.com/topic/8168/report-your-weather-station-data-to-windy
# https://openweathermap.org/stations
# https://support.weather.com/s/article/PWS-Upload-Protocol?language=en_US
#
# Your weather station or better your decoder function in the TTN
# console should provide the following (metric) readings/variables as
# part of the 'decoded_payload' in the JSON uplink message: temperature,
# humitidy, pressure, dewpoint, heatindex, windspeed, winddirection,
# rain1h, rain24h, rainTotal and globalradiation. If values for rain1h or
# rain24h are missing, a zero reading is uploaded. If you're brave, you
# can also# adjust the JSON and URL templates to your needs (lines 90-140).
#
# SECURITY NOTICE: You should not use this script on a shared multi-user
# system since 'mosquitto_sub' requires the password for an authenticated
# MQTT connection to be stated with '-P' on the command line. It will show
# up in the process list and is visible to other users on a shared system.
#

# choose a name for your PWS and set its gps location (required)
STATION_NAME="my private weather station"
STATION_LAT="XX.XXXXXX"
STATION_LON="Y.YYYYYY"

# elevation of your location, height of the temperature and
# wind sensor above ground (integer value in meters, interger)
STATION_ALTITUDE_M=2
STATION_TEMPSENSOR_HEIGHT_M=2
STATION_WINDSENSOR_HEIGHT_M=3

# settings to inform you if the station doesn't send new data for
# given number of seconds (leave email address blank to disable)
ADMIN_MAIL="you@provider.com"
OFFLINE_WARNING_SECS=3600
EMAIL_WARNING_CYCLE_SECS=10800

# credentials (user and api key) and topic to connect to TTN's
# MQTT server to receive sensor data (required)
MQTT_USER="ttn-app-name"
MQTT_PASS="api-key-for-ttn-app-name"
MQTT_TOPIC="v3/ttn-app-name/devices/+/up"

# create an account on windy.com to receive an API key to
# upload data from your PWS or leave blank to disable
# https://account.windy.com/login 
# leave blank to disable
WINDY_KEY=""

# register your PWS on openwaethermap.org to receive
# station-id and key or leave blank to disable
# https://openweathermap.org/stations
OPENWEATHER_STATIONID=""
OPENWEATHER_KEY=""

# credentials for your PWS at weather underground (leave blank to disable)
# https://www.wunderground.com/member/devices/new 
WUNDERGROUND_ID=""
WUNDERGROUND_PASS=""

# the following settings should not be changed
WINDY_URL="https://stations.windy.com/pws/update/$WINDY_KEY"
OPENWEATHER_URL="https://api.openweathermap.org/data/3.0"
WUNDERGROUND_URL="https://weatherstation.wunderground.com/weatherstation/updateweatherstation.php"

MQTT_SERVER=eu1.cloud.thethings.network
MQTT_CAFILE=/etc/ssl/certs/ca-certificates.crt
EMAIL_WARNING_CYCLE_SECS=10800
LOCK=/tmp/.pws-data-uploader.$$

#
# no more changes below this line unless you know what you are doing...
#

JSON_STA_WINDY='{
	"stations": [
		{	"station": 0,
			"name": "__STATION_NAME",
			"lat": __STATION_LAT,
			"lon": __STATION_LON,
			"elevation": __STATION_ALT,
			"tempheight": __STATION_T_HEIGHT,
			"windheight": __STATION_W_HEIGHT
		}
	]
}'

JSON_OBS_WINDY='{
	"observations": [
		{	"station": 0,
			"dateutc": "__DATEUTC",
			"temp": __TEMP,
			"mbar": __PRES,
			"humidity": __HUM,
			"dewpoint": __DEWPT,
			"wind": __WSPEED,
			"winddir": __WDIR,
			"precip": __RAIN1H
		}
	]
}'

JSON_STA_OPENWEATHER='{
	"external_id": "__EXTERNAL_ID",
	"name": "__STATION_NAME",
	"latitude": __STATION_LAT,
	"longitude": __STATION_LON,
	"altitude": __STATION_ALT
}'

JSON_OBS_OPENWEATHER='[
	{	"station_id": "__STATIONID",
		"dt": __DATETIME,
		"temperature": __TEMP,
		"humidity": __HUM,
		"dew_point": __DEWPT,
		"heat_index": __HEATIDX,
		"pressure": __PRES,
		"wind_speed": __WSPEED,
		"wind_deg": __WDIR,
		"rain_1h": __RAIN1H,
		"rain_24h": __RAIN24H
	}
]'

# still wondering why wunderground.com doesn't offer a JSON API like others services
URL_ARGS_WUNDERGROUND='ID=__WID&PASSWORD=__WPASS&dateutc=__DATEUTC&tempf=__TEMPF&humidity=__HUM&baromin=__PRESIN&winddir=__WDIR&windspeedmph=__WSPEEDMPH&solarradiation=__RADIATION&rainin=__RAININ&dewptf=__DEWPTF&dailyrainin=__DAILYRAININ&action=updateraw'


# remove lock file when script exits
cleanup() {
	rm -f $LOCK
	exit 0
}

# optional background process to send an email if station
# has gone offline (no more MQTT messages coming from TTN)
checkstate() {
	if [ -z "$ADMIN_MAIL" ]; then
		exit 0
	fi

	NODATA=0 
	while (true)
	do
		if [ -f $LOCK ]; then
			LAST_UPDATE=$(stat -t -c %Z $LOCK)
			NOW=$(date +%s)
			if [ $((NOW-LAST_UPDATE)) -gt $OFFLINE_WARNING_SECS ]; then
				LAST_WARNING=$(cat $LOCK)
				LAST_UPDATE=$(stat -t -c %y $LOCK | cut -f1 -d'.')
				if [ "$LAST_WARNING" == "0" -a "$NODATA" == "1" ]; then
					echo "Last Update on $MQTT_SERVER:$MQTT_TOPIC: $LAST_UPDATE" | \
						mail -s "[$(hostname -s)] weather station $STATION_NAME recovered" \
						$ADMIN_MAIL >/dev/null
					NODATA=0
				elif [ -z "$LAST_WARNING" -o $((NOW-LAST_WARNING)) -gt $EMAIL_WARNING_CYCLE_SECS ]; then
					LAST_UPDATE=$(stat -t -c %y $LOCK | cut -f1 -d'.')
					echo "Last Update on $MQTT_SERVER:$MQTT_TOPIC: $LAST_UPDATE" | \
						mail -s "[$(hostname -s)] no data from weather station $STATION_NAME " \
						$ADMIN_MAIL >/dev/null
					echo $NOW > $LOCK
					NODATA=1
				fi
			fi
		fi
		if [ ! -f $LOCK ]; then
			exit 0
		fi
		sleep 60
	done
}

trap cleanup TERM INT
touch $LOCK
checkstate &

# update/set station meta data on windy.com 
if [ -n "$WINDY_KEY" ]; then
	JSON_STA_WINDY=$(echo $JSON_STA_WINDY | sed -e "s/__STATION_NAME/$STATION_NAME/")
	JSON_STA_WINDY=$(echo $JSON_STA_WINDY | sed -e "s/__STATION_LAT/$STATION_LAT/")
	JSON_STA_WINDY=$(echo $JSON_STA_WINDY | sed -e "s/__STATION_LON/$STATION_LON/")
	JSON_STA_WINDY=$(echo $JSON_STA_WINDY | sed -e "s/__STATION_ALT/$STATION_ALTITUDE_M/")
	JSON_STA_WINDY=$(echo $JSON_STA_WINDY | sed -e "s/__STATION_T_HEIGHT/$STATION_TEMPSENSOR_HEIGHT_M/")
	JSON_STA_WINDY=$(echo $JSON_STA_WINDY | sed -e "s/__STATION_W_HEIGHT/$STATION_WINDSENSOR_HEIGHT_M/")
	echo "Sending PWS meta data to windy.com..."
	echo $JSON_STA_WINDY
	curl -s -X POST $WINDY_URL -H 'Content-Type: application/json' -d "$JSON_STA_WINDY"
	echo
	echo
fi

# update/set station meta data on openweathermap.org
if [ -n "$OPENWEATHER_KEY" ]; then
	JSON_STA_OPENWEATHER=$(echo $JSON_STA_OPENWEATHER | sed -e "s/__STATION_NAME/$STATION_NAME/")
	if [ -n "$WUNDERGROUND_ID" ]; then
		JSON_STA_OPENWEATHER=$(echo $JSON_STA_OPENWEATHER | sed -e "s/__EXTERNAL_ID/$WUNDERGROUND_ID/")
	fi
	JSON_STA_OPENWEATHER=$(echo $JSON_STA_OPENWEATHER | sed -e "s/__STATION_LAT/$STATION_LAT/")
	JSON_STA_OPENWEATHER=$(echo $JSON_STA_OPENWEATHER | sed -e "s/__STATION_LON/$STATION_LON/")
	JSON_STA_OPENWEATHER=$(echo $JSON_STA_OPENWEATHER | sed -e "s/__STATION_ALT/$STATION_ALTITUDE_M/")
	echo "Sending PWS meta data to openweathermap.org..."
	echo $JSON_STA_OPENWEATHER
	curl -s -X PUT "$OPENWEATHER_URL/stations/$OPENWEATHER_STATIONID?appid=$OPENWEATHER_KEY" \
		-H 'Content-Type: application/json' -d "$JSON_STA_OPENWEATHER"
	echo
	echo
fi

HOUR_PREV=0
RAINTOTAL_PREV_DAY=0
RAINTOTAL_PREV_UPDATE=0
RAINRATE1H=0
LAST=0

# main loop reading MQTT messages from TTN
while read TOPIC
do
	if [ -n "$(echo $TOPIC | grep temperature)" ]; then
		NOW=$(date +%s)

		# parse sensor readings from TTN's JSON uplink message
		TEMP=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.temperature)
		HUM=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.humidity)
		PRES=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.pressure)
		DEWPT=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.dewpoint)
		HEATIDX=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.heatindex)
		WSPEED=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.windspeed)
		WDIR=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.winddirection)
		RAIN1H=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.rain1h)
		RAIN24H=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.rain24h)
		RAINTOTAL=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.rainTotal)
		RADI=$(echo $TOPIC | awk '{ print $2 }' | jq .uplink_message.decoded_payload.globalradiation)

		# for wunderground.com: calculate total precipitation for
		# today (starting at 00:00h) and hourly rain rate
		if [ -n "$WUNDERGROUND_PASS" -a "$RAINTOTAL" != "null" ]; then 
			HOUR=$(date +%H)
			if [ "$HOUR" == "00" -a "$HOUR_PREV" == "23" ]; then
				RAINTOTAL_PREV_DAY=$RAINTOTAL
			fi
			if [ "$RAINTOTAL_PREV_DAY" != "0" -a "$RAINTOTAL" != "null" ]; then
				RAINTOTAL_TODAY=$(echo "$RAINTOTAL-$RAINTOTAL_PREV_DAY" | bc)
			else
				RAINTOTAL_TODAY=0
			fi
			PREV_HOUR=$HOUR

			# hourly rain rate
			if [ "$RAINTOTAL_PREV_UPDATE" != "0" ]; then
				SECS_ELAPSED=$((NOW-LAST))
				RAIN_DIFF=$(echo "($RAINTOTAL-$RAINTOTAL_PREV_UPDATE)" | bc)
				RAINRATE1H=$(echo "scale=4;(($RAIN_DIFF/$SECS_ELAPSED)*3600)" | bc)
			fi
			RAINTOTAL_PREV_UPDATE=$RAINTOTAL
			LAST=$NOW
		fi

		# update JSON for windy.com upload
		if [ -n "$WINDY_KEY" ]; then
			_JSON_OBS_WINDY=$JSON_OBS_WINDY
			DATEUTC=$(date -u --rfc-3339=seconds | cut -f1 -d'+')
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__DATEUTC/$DATEUTC/")
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__TEMP/$TEMP/")
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__HUM/$HUM/")
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__DEWPT/$DEWPT/")
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__PRES/$PRES/")
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__WSPEED/$WSPEED/")
			_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__WDIR/$WDIR/")
			if [ "$RAIN1H" != "null" ]; then
				_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__RAIN1H/$RAIN1H/")
			else
				_JSON_OBS_WINDY=$(echo $_JSON_OBS_WINDY | sed -e "s/__RAIN1H/0/")
			fi
		fi

		# JSON for openweathermap.org
		if [ -n "$OPENWEATHER_KEY" ]; then
			_JSON_OBS_OPENWEATHER=$JSON_OBS_OPENWEATHER
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__STATIONID/$OPENWEATHER_STATIONID/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__DATETIME/$NOW/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__TEMP/$TEMP/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__HUM/$HUM/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__DEWPT/$DEWPT/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__HEATIDX/$HEATIDX/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__PRES/$PRES/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__WSPEED/$WSPEED/")
			_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__WDIR/$WDIR/")
			if [ "$RAIN1H" != "null" ]; then
				_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__RAIN1H/$RAIN1H/")
			else
				_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__RAIN1H/0/")
			fi
			if [ "$RAIN24H" != "null" ]; then
				_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__RAIN24H/$RAIN24H/")
			else
				_JSON_OBS_OPENWEATHER=$(echo $_JSON_OBS_OPENWEATHER | sed -e "s/__RAIN24H/0/")
			fi
		fi

		# convert all sensor readings to imperial format
		# for wunderground (other services accept both...)
		if [ -n "$WUNDERGROUND_PASS" ]; then	
			if [ "$TEMP" != "null" ]; then
				TEMPF=$(echo "scale=2;($TEMP*9/5)+32" | bc)
			fi
			if [ "$PRES" != "null" ]; then
				PRESIN=$(echo "scale=2;($PRES*0.029531)" | bc)
			fi
			if [ "$DEWPT" != "null" ]; then
				DEWPTF=$(echo "scale=2;($DEWPT*9/5)+32" | bc)
			fi
			if [ "$WSPEED" != "null" ]; then
				WSPEEDMPH=$(echo "scale=2;($WSPEED*2.237)" | bc)
			fi
			if [ -n "$RAINRATE1H" ]; then
				RAININ=$(echo "scale=4;($RAINRATE1H/25.4)" | bc)
				unset RAINRATE1H
			fi
			if [ -n "$RAINTOTAL_TODAY" ]; then
				DAILYRAININ=$(echo "scale=4;($RAINTOTAL_TODAY/25.4)" | bc)
				unset RAINTOTAL_TODAY
			fi

			# replace template vars in wunderground URL with sensor data
			_URL_ARGS_WUNDERGROUND=$URL_ARGS_WUNDERGROUND
			DATEUTC=$(echo -n "$DATEUTC" | jq -sRr @uri)
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__DATEUTC/$DATEUTC/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__WID/$WUNDERGROUND_ID/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__WPASS/$WUNDERGROUND_PASS/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__TEMPF/$TEMPF/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__HUM/$HUM/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__PRESIN/$PRESIN/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__DEWPTF/$DEWPTF/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__WDIR/$WDIR/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__RADIATION/$RADI/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__WSPEEDMPH/$WSPEEDMPH/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__RAININ/$RAININ/")
			_URL_ARGS_WUNDERGROUND=$(echo $_URL_ARGS_WUNDERGROUND | sed -e "s/__DAILYRAININ/$DAILYRAININ/")
		fi

		# update lock file for 'checkstate()'
        echo 0 > $LOCK

		if [ "$TEMP" != "null" -a "$HUM" != "null" ]; then
			if [ -n "$WINDY_KEY" ]; then
				echo "Sending PWS sensor readings to windy.com..."
				echo $_JSON_OBS_WINDY
				curl -s -X POST $WINDY_URL -H 'Content-Type: application/json' \
					-d "$_JSON_OBS_WINDY"
				echo
				echo
			fi
			if [ -n "$OPENWEATHER_KEY" ]; then
				echo "Sending PWS sensor readings to openweathermap.org..."
				echo $_JSON_OBS_OPENWEATHER
				curl -s -X POST "$OPENWEATHER_URL/measurements?appid=$OPENWEATHER_KEY" \
					-H 'Content-Type: application/json' -d "$_JSON_OBS_OPENWEATHER"
				echo
				echo
			fi
			if [ -n "$WUNDERGROUND_PASS" ]; then
				echo "Sending PWS sensor readings to wunderground.com..."
				echo "$WUNDERGROUND_URL?$_URL_ARGS_WUNDERGROUND"
				curl -s -X GET "$WUNDERGROUND_URL?$_URL_ARGS_WUNDERGROUND"
			fi
		fi

        unset DATEUTC
        unset TEMP
        unset TEMPF
        unset HUM
        unset DEWPT
        unset DEWPTF
        unset HEATIDX
        unset PRES
        unset PRESIN
        unset WSPEED
        unset WSPEEDMPH
        unset WDIR
        unset RAIN1H
        unset RAIN24H
        unset RAININ
        unset RAINTOTAL
		unset DAILYRAININ
        unset RADI
    fi

done < <(mosquitto_sub -u $MQTT_USER -P $MQTT_PASS -h $MQTT_SERVER --cafile $MQTT_CAFILE -v -t "$MQTT_TOPIC") 

exit 0
