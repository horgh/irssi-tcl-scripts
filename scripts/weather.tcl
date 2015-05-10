#
# this script is to provide simple weather lookups.
#
# it's modeled on incith-weather. the data source for that script
# was dropped
#
# uses http://openweathermap.org/API
#
# you have to sign up for an API key.
# place it in the file ~/.irssi/weather.conf by itself.
#

package require http
package require json

namespace eval ::weather {
	# no https support it seems
	variable api_url http://api.openweathermap.org

	variable useragent "Lynx/2.8.8dev.2 libwww-FM/2.14 SSL-MM/1.4.1"

	# docs request we don't query more than once every 10 minutes
	variable cache_seconds [expr 60*15]

	# toggle debug output
	variable debug 1

	# api loaded at start
	variable api_key {}
	variable api_key_file [irssi_dir]/weather.conf

	# timeout on requests in seconds
	variable timeout [expr 30*1000]

	# file to save responses to if set.
	# blank to not use.
	variable save_response_file /tmp/weather.out

	# file to read response from if set (for testing it can be nice to cache
	# a response to avoid hitting API repeatedly).
	# blank to not use.
	variable read_response_file {}

	# cache of responses.
	# each is keyed by the query performed and associates
	# with a sub-dict.
	# sub-dict will have keys: request_time, and response.
	# the response is the result of the lookup.
	variable weather_cache [dict create]
	variable forecast_cache [dict create]

	signal_add msg_pub .wz ::weather::weather_pub
	signal_add msg_pub .weather ::weather::weather_pub
	signal_add msg_pub .wzf ::weather::forecast_pub
	signal_add msg_pub .forecast ::weather::forecast_pub

	settings_add_str "weather_enabled_channels" ""
}

# msg_pub signal handler: weather lookup
proc ::weather::weather_pub {server nick uhost chan argv} {
	if {![str_in_settings_str "weather_enabled_channels" $chan]} {
		return
	}

	set argv [string trim $argv]
	if {$argv == ""} {
		putchan $server $chan "Usage: .wz <location>"
		return
	}

	# I'm trying this method of making the request async as opposed to
	# my usual method of ::http::geturl -command
	after idle [list ::weather::weather_pub_async $server $nick $uhost $chan $argv]
}

proc ::weather::weather_pub_async {server nick uhost chan argv} {
	set weather [::weather::lookup_weather $argv]
	if {[dict get $weather status] != "ok"} {
		set msg [dict get $weather message]
		::weather::log "weather_pub: $msg"
		return
	}

	set data [dict get $weather data]

	set output ""
	append output [dict get $data city]
	append output ", "
	append output [dict get $data country]

	append output " ("
	append output [::weather::format_decimal [dict get $data latitude]]
	append output "°N/"
	append output [::weather::format_decimal [dict get $data longitude]]
	append output "°W)"

	append output " \002Conditions\002: "
	append output [dict get $data weather]
	append output " ("
	append output [dict get $data weather_description]
	append output ")"
	putchan $server $chan $output

	set output ""
	append output "\002Temperature\002: "
	append output [dict get $data temperature]
	append output "°C"

	append output " \002Humidity\002: "
	append output [dict get $data humidity]
	append output "%"

	append output " \002Pressure\002: "
	append output [dict get $data pressure]
	append output " hPa"
	putchan $server $chan $output

	set output ""
	append output "\002Wind\002: "
	append output [dict get $data windspeed]
	append output "m/s"

	append output " \002Clouds\002: "
	append output [dict get $data clouds]
	append output "%"

	putchan $server $chan $output
}

# msg_pub signal handler: forecast lookup
proc ::weather::forecast_pub {server nick uhost chan argv} {
	if {![str_in_settings_str "weather_enabled_channels" $chan]} {
		return
	}

	set argv [string trim $argv]
	if {$argv == ""} {
		putchan $server $chan "Usage: .wzf <location>"
		return
	}

	# I'm trying this method of making the request async as opposed to
	# my usual method of ::http::geturl -command
	after idle [list ::weather::forecast_pub_async $server $nick $uhost $chan $argv]
}

proc ::weather::forecast_pub_async {server nick uhost chan argv} {
	set forecast [::weather::lookup_forecast $argv]
	if {[dict get $forecast status] != "ok"} {
		set msg [dict get $forecast message]
		::weather::log "forecast_pub: $msg"
		return
	}
	set data [dict get $forecast data]

	set output ""
	append output [dict get $data city]
	append output ", "
	append output [dict get $data country]

	append output " ("
	append output [::weather::format_decimal [dict get $data latitude]]
	append output "°N/"
	append output [::weather::format_decimal [dict get $data longitude]]
	append output "°W) "
	putchan $server $chan $output

	set output ""
	foreach forecast [dict get $data forecasts] {
		if {$output != ""} {
			append output " "
		}
		set day [clock format [dict get $forecast when] -format "%A"]
		append output "\002$day\002: "
		append output [dict get $forecast weather]
		append output ", "

		append output [dict get $forecast temperature_max]
		append output "/"
		append output [dict get $forecast temperature_min]
		append output "°C"
	}
	putchan $server $chan $output
}

# retrieve current weather
#
# parameters:
# query: a search query string to find current weather at the location
#
# returns a dict with keys:
# status: ok or error
# data: dict with lookup data if present
# message: response message if error
proc ::weather::lookup_weather {query} {
	# may not need to make a new request.
	if {$::weather::read_response_file != "" && \
			[file exists $::weather::read_response_file]} {
		::weather::log "lookup_weather: reading response from file"
		set f [open $::weather::read_response_file]
		set data [read -nonewline $f]
		close $f

		set weather [::weather::parse_weather $data]
		if {$weather == ""} {
			::weather::log "lookup_weather: parse failure"
			return [dict create status error message "Parse failure"]
		}

		::weather::log "lookup_weather: parse success"
		return [dict create status ok data $weather]
	}

	# may be cached
	set query [string tolower $query]
	set query [string trim $query]
	if {[dict exists $::weather::weather_cache $query]} {
		set request_time [dict get $::weather::weather_cache $query request_time]
		set current_time [clock seconds]
		set cached_until [expr $request_time+$::weather::cache_seconds]
		if {[expr $current_time < $cached_until]} {
			::weather::log "lookup_weather: using cache"
			return [dict get $::weather::weather_cache $query response]
		}
		::weather::log "lookup_weather: cache expired"
		dict remove $::weather::weather_cache $query
	}

	# need to make an API request.
	set cache [dict create request_time [clock seconds]]
	set response [::weather::api_lookup_weather $query]
	dict set cache response $response
	dict set ::weather::weather_cache $query $cache
	return $response
}

# retrieve current forecast
#
# parameters:
# query: a search query string to find current weather at the location
#
# returns a dict with keys:
# status: ok or error
# data: dict with lookup data if present
# message: response message if error
proc ::weather::lookup_forecast {query} {
	# may not need to make a new request.
	if {$::weather::read_response_file != "" && \
			[file exists $::weather::read_response_file]} {
		::weather::log "lookup_forecast: reading response from file"
		set f [open $::weather::read_response_file]
		set data [read -nonewline $f]
		close $f

		set weather [::weather::parse_forecast $data]
		if {$weather == ""} {
			::weather::log "lookup_forecast: parse failure"
			return [dict create status error message "Parse failure"]
		}

		::weather::log "lookup_forecast: parse success"
		return [dict create status ok data $weather]
	}

	# may be cached
	set query [string tolower $query]
	set query [string trim $query]
	if {[dict exists $::weather::forecast_cache $query]} {
		set request_time [dict get $::weather::forecast_cache $query request_time]
		set current_time [clock seconds]
		set cached_until [expr $request_time+$::weather::cache_seconds]
		if {[expr $current_time < $cached_until]} {
			::weather::log "lookup_forecast: using cache"
			return [dict get $::weather::forecast_cache $query response]
		}
		::weather::log "lookup_forecast: cache expired"
		dict remove $::weather::forecast_cache $query
	}

	# need to make an API request.
	set cache [dict create request_time [clock seconds]]
	set response [::weather::api_lookup_forecast $query]
	dict set cache response $response
	dict set ::weather::forecast_cache $query $cache
	return $response
}

proc ::weather::api_lookup_weather {query} {
	::http::config -useragent $::weather::useragent
	::http::register https 443 [list ::tls::socket -ssl2 0 -ssl3 0 -tls1 1]

	set url $::weather::api_url/data/2.5/weather

	set query [::http::formatQuery \
		APPID $::weather::api_key \
		q $query \
		units metric \
	]

	set full_url $url?$query
	::weather::log "api_lookup_weather: making request: $full_url"
	set token [::http::geturl $full_url \
		-timeout $::weather::timeout \
		-binary 1 \
	]

	set status [::http::status $token]
	if {$status != "ok"} {
		::weather::log "api_lookup_weather: status is $status"
		set http_error [::http::error $token]
		::http::cleanup $token
		return [dict create status error message $http_error]
	}

	set ncode [::http::ncode $token]
	set data [::http::data $token]
	set data [encoding convertfrom "utf-8" $data]
	::http::cleanup $token

	if {$::weather::save_response_file != ""} {
		::weather::log "api_lookup_weather: saved response to file"
		set f [open $::weather::save_response_file w]
		puts -nonewline $f $data
		close $f
	}

	if {$ncode != 200} {
		::weather::log "api_lookup_weather: code is $ncode"
		return [dict create status error message "HTTP $ncode"]
	}

	set weather [::weather::parse_weather $data]
	if {$weather == ""} {
		::weather::log "api_lookup_weather: parse failure"
		return [dict create status error message "Parse failure"]
	}

	::weather::log "api_lookup_weather: parse success"
	return [dict create status ok data $weather]
}

proc ::weather::api_lookup_forecast {query} {
	::http::config -useragent $::weather::useragent
	::http::register https 443 [list ::tls::socket -ssl2 0 -ssl3 0 -tls1 1]

	set url $::weather::api_url/data/2.5/forecast/daily

	# cnt means how many days of forecast to retrieve
	set query [::http::formatQuery \
		APPID $::weather::api_key \
		q $query \
		units metric \
		cnt 4 \
	]

	set full_url $url?$query
	::weather::log "api_lookup_forecast: making request: $full_url"
	set token [::http::geturl $full_url \
		-timeout $::weather::timeout \
		-binary 1 \
	]

	set status [::http::status $token]
	if {$status != "ok"} {
		::weather::log "api_lookup_forecast: status is $status"
		set http_error [::http::error $token]
		::http::cleanup $token
		return [dict create status error message $http_error]
	}

	set ncode [::http::ncode $token]
	set data [::http::data $token]
	set data [encoding convertfrom "utf-8" $data]
	::http::cleanup $token

	if {$::weather::save_response_file != ""} {
		::weather::log "api_lookup_forecast: saved response to file"
		set f [open $::weather::save_response_file w]
		puts -nonewline $f $data
		close $f
	}

	if {$ncode != 200} {
		::weather::log "api_lookup_forecast: code is $ncode"
		return [dict create status error message "HTTP $ncode"]
	}

	set weather [::weather::parse_forecast $data]
	if {$weather == ""} {
		::weather::log "api_lookup_forecast: parse failure"
		return [dict create status error message "Parse failure"]
	}

	::weather::log "api_lookup_forecast: parse success"
	return [dict create status ok data $weather]
}

# take json and parse into a dict
#
# returns blank string if there is a problem
proc ::weather::parse_weather {data} {
	set decoded [::json::json2dict $data]

	# make a dict using expected keys from the response
	set parsed [dict create]

	# country
	if {![dict exists $decoded sys]} {
		::weather::log "parse_weather: missing sys"
		return ""
	}
	if {![dict exists $decoded sys country]} {
		::weather::log "parse_weather: missing sys country"
		return ""
	}
	dict set parsed country [dict get $decoded sys country]

	# city
	if {![dict exists $decoded name]} {
		::weather::log "parse_weather: missing name"
		return ""
	}
	dict set parsed city [dict get $decoded name]

	# pressure hPa
	if {![dict exists $decoded main]} {
		::weather::log "parse_weather: missing main"
		return ""
	}
	if {![dict exists $decoded main pressure]} {
		::weather::log "parse_weather: missing pressure"
		return ""
	}
	dict set parsed pressure [dict get $decoded main pressure]

	# temp
	if {![dict exists $decoded main temp]} {
		::weather::log "parse_weather: missing temp"
		return ""
	}
	dict set parsed temperature [dict get $decoded main temp]

	# humidity %
	if {![dict exists $decoded main humidity]} {
		::weather::log "parse_weather: missing humidity"
		return ""
	}
	dict set parsed humidity [dict get $decoded main humidity]

	# wind speed (m/s)
	if {![dict exists $decoded wind]} {
		::weather::log "parse_weather: missing wind"
		return ""
	}
	if {![dict exists $decoded wind speed]} {
		::weather::log "parse_weather: missing wind speed"
		return ""
	}
	dict set parsed windspeed [dict get $decoded wind speed]

	# weather description
	if {![dict exists $decoded weather]} {
		::weather::log "parse_weather: missing weather"
		return ""
	}

	# weather is a list of objects?
	if {[llength [dict get $decoded weather]] == 0} {
		::weather::log "parse_weather: missing weather object"
		return
	}
	set weather [lindex [dict get $decoded weather] 0]
	if {![dict exists $weather main]} {
		::weather::log "parse_weather: missing weather main"
		return ""
	}
	if {![dict exists $weather description]} {
		::weather::log "parse_weather: missing weather description"
		return ""
	}
	dict set parsed weather [dict get $weather main]
	dict set parsed weather_description [dict get $weather description]

	# coords
	if {![dict exists $decoded coord]} {
		::weather::log "parse_weather: missing coord"
		return ""
	}
	if {![dict exists $decoded coord lat]} {
		::weather::log "parse_weather: missing coord lat"
		return ""
	}
	if {![dict exists $decoded coord lon]} {
		::weather::log "parse_weather: missing coord lon"
		return ""
	}
	dict set parsed latitude [dict get $decoded coord lat]
	dict set parsed longitude [dict get $decoded coord lon]

	# clouds %
	if {![dict exists $decoded clouds]} {
		::weather::log "parse_weather: missing clouds"
		return ""
	}
	if {![dict exists $decoded clouds all]} {
		::weather::log "parse_weather: missing clouds all"
		return ""
	}
	dict set parsed clouds [dict get $decoded clouds all]

	return $parsed
}

# take json and parse into a dict
#
# returns blank string if there is a problem
proc ::weather::parse_forecast {data} {
	set decoded [::json::json2dict $data]

	# make a dict using expected keys from the response
	set parsed [dict create]

	# country
	if {![dict exists $decoded city]} {
		::weather::log "parse_forecast: missing city"
		return ""
	}
	if {![dict exists $decoded city country]} {
		::weather::log "parse_forecast: missing city country"
		return ""
	}
	dict set parsed country [dict get $decoded city country]

	# city
	if {![dict exists $decoded city name]} {
		::weather::log "parse_forecast: missing city name"
		return ""
	}
	dict set parsed city [dict get $decoded city name]

	# coords
	if {![dict exists $decoded city coord]} {
		::weather::log "parse_forecast: missing city coord"
		return ""
	}
	if {![dict exists $decoded city coord lat]} {
		::weather::log "parse_forecast: missing city coord lat"
		return ""
	}
	if {![dict exists $decoded city coord lon]} {
		::weather::log "parse_forecast: missing city coord lon"
		return ""
	}
	dict set parsed latitude [dict get $decoded city coord lat]
	dict set parsed longitude [dict get $decoded city coord lon]

	# get each forecast
	dict set parsed forecasts [list]
	if {![dict exists $decoded list]} {
		::weather::log "parse_forecast: missing list"
		return ""
	}
	foreach weather [dict get $decoded list] {
		set weather_parsed [dict create]
		# there is more data available here but I'm only pulling out what I
		# intend to show right now

		# temps: min, max
		if {![dict exists $weather temp]} {
			::weather::log "parse_forecast: missing list temp"
			return ""
		}
		if {![dict exists $weather temp min]} {
			::weather::log "parse_forecast: missing list temp min"
			return ""
		}
		if {![dict exists $weather temp max]} {
			::weather::log "parse_forecast: missing list temp max"
			return ""
		}
		dict set weather_parsed temperature_min [dict get $weather temp min]
		dict set weather_parsed temperature_max [dict get $weather temp max]

		# weather main
		if {![dict exists $weather weather]} {
			::weather::log "parse_forecast: missing list weather"
			return ""
		}
		# this is a list... let's just take the first...
		if {[llength [dict get $weather weather]] == 0} {
			::weather::log "parse_forecast: missing list weather list"
			return ""
		}
		set weather_desc [lindex [dict get $weather weather] 0]
		if {![dict exists $weather_desc main]} {
			::weather::log "parse_forecast: missing list weather main"
			return ""
		}
		dict set weather_parsed weather [dict get $weather_desc main]

		# when, unixtime
		if {![dict exists $weather dt]} {
			::weather::log "parse_forecast: missing list dt"
			return ""
		}
		dict set weather_parsed when [dict get $weather dt]

		dict lappend parsed forecasts $weather_parsed
	}

	return $parsed
}

proc ::weather::format_decimal {number} {
	return [format "%.2f" $number]
}

proc ::weather::load_key {} {
	if {[catch {open $::weather::api_key_file} f]} {
		irssi_print "weather: cannot open API key file: $::weather::api_key_file: $f"
		return
	}
	set contents [read -nonewline $f]
	close $f
	set ::weather::api_key $contents
}

proc ::weather::log {msg} {
	if {!$::weather::debug} {
		return
	}
	irssi_print "weather: $msg"
}

irssi_print "weather.tcl loaded"
::weather::load_key
