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
	variable save_response_file {}

	# file to read response from if set (for testing it can be nice to cache
	# a response to avoid hitting API repeatedly).
	# blank to not use.
	#variable read_response_file /tmp/weather.out
	variable read_response_file {}

	# dict of query to dicts about responses
	# response dict will have keys: request_time, and response.
	variable cache [dict create]

	signal_add msg_pub .wz ::weather::weather_pub
	signal_add msg_pub .wzf ::weather::forecast_pub

	settings_add_str "weather_enabled_channels" ""
}

# msg_pub signal handler: weather lookup
proc ::weather::weather_pub {server nick uhost chan argv} {
	if {![str_in_settings_str "weather_enabled_channels" $chan]} {
		return
	}

	set argv [string trim $argv]
	if {$argv == ""} {
		putchan $server $chan $output "Usage: .wz <location>"
		return
	}

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
	append output [dict get $data latitude]
	append output "°N/"
	append output [dict get $data longitude]
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
}

# query weather API for current weather
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
	if {$::weather::read_response_file != ""} {
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
	if {[dict exists $::weather::cache $query]} {
		set request_time [dict get $::weather::cache $query request_time]
		set current_time [clock seconds]
		set cached_until [expr $request_time+$::weather::cache_seconds]
		if {[expr $current_time < $cached_until]} {
			::weather::log "lookup_weather: using cache"
			return [dict get $::weather::cache $query response]
		}
		::weather::log "lookup_weather: cache expired"
		dict remove $::weather::cache $query
	}

	# need to make an API request.
	set cache [dict create request_time [clock seconds]]

	set response [::weather::api_lookup_weather $query]
	dict set cache response $response

	dict set ::weather::cache $query $cache

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
	::weather::log "lookup_weather: making request: $full_url"
	set token [::http::geturl $full_url \
		-timeout $::weather::timeout \
	]

	set status [::http::status $token]
	if {$status != "ok"} {
		::weather::log "lookup_weather: status is $status"
		set http_error [::http::error $token]
		::http::cleanup $token
		return [dict create status error message $http_error]
	}

	set ncode [::http::ncode $token]
	set data [::http::data $token]
	::http::cleanup $token

	if {$::weather::save_response_file != ""} {
		::weather::log "lookup_weather: saved response to file"
		set f [open $::weather::save_response_file w]
		puts -nonewline $f $data
		close $f
	}

	if {$ncode != 200} {
		::weather::log "lookup_weather: code is $ncode"
		return [dict create status error message "HTTP $ncode"]
	}

	set weather [::weather::parse_weather $data]
	if {$weather == ""} {
		::weather::log "lookup_weather: parse failure"
		return [dict create status error message "Parse failure"]
	}

	::weather::log "lookup_weather: parse success"
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
