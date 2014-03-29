#
# Created Feb 28 2010
#
# Requires Tcl 8.5+
# Requires tcllib for json
#

package require htmlparse
package require http
package require json
package require tls

namespace eval ::google {
	variable useragent_api "Lynx/2.8.8dev.2 libwww-FM/2.14 SSL-MM/1.4.1"
	variable useragent_convert "Mozilla/5.0 (X11; Linux i686; rv:8.0) Gecko/20100101 Firefox/8.0"

	variable convert_url "https://www.google.ca/search"
	variable convert_regexp {<table class=std>.*?<b>(.*?)</b>.*?</table>}

	variable api_url "http://ajax.googleapis.com/ajax/services/search/"

	variable api_referer "http://www.egghelp.org"

	# debug mode on or off.
	variable debug 0

	signal_add msg_pub "!g"       ::google::search
	signal_add msg_pub "!google"  ::google::search
	signal_add msg_pub "!g1"      ::google::search1
	signal_add msg_pub "!news"    ::google::news
	signal_add msg_pub "!images"  ::google::images
	signal_add msg_pub "!convert" ::google::convert

	settings_add_str "google_enabled_channels" ""
}

# print a debug message.
proc ::google::log {msg} {
	if {!$::google::debug} {
		return
	}
	irssi_print "google: $msg"
}

# Query normal html for conversions
proc ::google::convert {server nick uhost chan argv} {
	if {![str_in_settings_str google_enabled_channels $chan]} { return }

	if {[string length $argv] == 0} {
		putchan $server $chan "Please provide a query."
		return
	}

	::http::config -useragent $::google::useragent_convert
	::http::register https 443 ::tls::socket
	set query [::http::formatQuery q $argv]
	set token [::http::geturl ${::google::convert_url}?${query} \
		-command "::google::convert_callback $server $chan"]
}

proc ::google::convert_callback {server chan token} {
	set status [::http::status $token]
	if {$status != "ok"} {
		set http_error [::http::error $token]
		::google::log "convert_callback: failure: status is: $status: $http_error"
		::http::cleanup $token
		return
	}
	set data [::http::data $token]
	set ncode [::http::ncode $token]
	::http::cleanup $token

	# debug
	#set fid [open "g-debug.txt" w]
	#puts $fid $data
	#close $fid

	if {$ncode != 200} {
		putchan $server $chan "HTTP query failed: $ncode"
		::google::log "convert_callback: data: $data"
		return
	}

	if {[catch {::google::convert_parse $data} result]} {
		putchan $server $chan "Error: $result."
		return
	}

	putchan $server $chan "\002$result\002"
}

proc ::google::convert_parse {html} {
	if {![regexp -- $::google::convert_regexp $html -> result]} {
		#set fid [open /tmp/g-debug.txt w]
		#puts $fid $html
		#close $fid
		error "Parse error or no result"
	}

	# it seems that since I wrote this script the plain text result output
	# for the unit converter has gone away. it's now a widget that you can
	# toggle units and type of conversion. so it's trickier to pull out what
	# we want and may vary in form quite a lot.
	# if there's an API that would be the much better approach... but I'm not
	# sure there is one.

	set result [::htmlparse::mapEscapes $result]
	# change <sup>num</sup> to ^num (exponent)
	set result [regsub -all -- {<sup>(.*?)</sup>} $result {^\1}]
	# strip rest of html code
	return [regsub -all -- {<.*?>} $result ""]
}

# Output for results from api query
proc ::google::output {server chan url title content} {
	regsub -all -- {(?:<b>|</b>)} $title "\002" title
	regsub -all -- {<.*?>} $title "" title
	set output "$title @ $url"
	putchan $server $chan "[::htmlparse::mapEscapes $output]"
}

# Query api
proc ::google::api_handler {server chan argv url {num {}}} {
	if {[string length $argv] == 0} {
		putchan $server $chan "Error: Please supply search terms."
		return
	}
	set query [::http::formatQuery v "1.0" q $argv safe off]
	set headers [list Referer $::google::api_referer]
	if {$num == ""} {
		set num 4
	}

	::http::config -useragent $::google::useragent_api
	::http::register https 443 ::tls::socket
	set token [::http::geturl ${url}?${query} -headers $headers -method GET \
		-command "::google::api_callback $server $chan $num"]
}

proc ::google::api_callback {server chan num token} {
	set status [::http::status $token]
	if {$status != "ok"} {
		set http_error [::http::error $token]
		::google::log "api_callback: failure: status is: $status: $http_error"
		::http::cleanup $token
		return
	}
	set data [::http::data $token]
	set ncode [::http::ncode $token]
	::http::cleanup $token

	# debug
	#set fid [open "g-debug.txt" w]
	#fconfigure $fid -translation binary -encoding binary
	#puts $fid $data
	#close $fid

	if {$ncode != 200} {
		putchan $server $chan "HTTP query failed: $ncode"
		return
	}

	set data [::json::json2dict $data]
	set response [dict get $data responseData]
	set results [dict get $response results]

	if {[llength $results] == 0} {
		putchan $server $chan "No results."
		return
	}

	foreach result $results {
		if {$num != "" && [incr count] > $num} {
			return
		}
		dict with result {
			# $language holds lang in news results, doesn't exist in web results
			if {![info exists language] || $language == "en"} {
				::google::output $server $chan $unescapedUrl $title $content
			}
		}
	}
}

# Regular API search
proc ::google::search {server nick uhost chan argv} {
	if {![str_in_settings_str "google_enabled_channels" $chan]} {
		return
	}

	::google::api_handler $server $chan $argv ${::google::api_url}web
}

# Regular API search, 1 result
proc ::google::search1 {server nick uhost chan argv} {
	if {![str_in_settings_str "google_enabled_channels" $chan]} {
		return
	}

	::google::api_handler $server $chan $argv ${google::api_url}web 1
}

# News from API
proc ::google::news {server nick uhost chan argv} {
	if {![str_in_settings_str "google_enabled_channels" $chan]} {
		return
	}

	::google::api_handler $server $chan $argv ${::google::api_url}news
}

# Images from API
proc ::google::images {server nick uhost chan argv} {
	if {![str_in_settings_str "google_enabled_channels" $chan]} {
		return
	}

	::google::api_handler $server $chan $argv ${google::api_url}images
}

irssi_print "google.tcl loaded"
