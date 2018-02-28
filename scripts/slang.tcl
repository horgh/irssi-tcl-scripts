# Look up definitions on urbandictionary.com.

package require htmlparse
package require http

namespace eval ::ud {
	# set this to !ud or whatever you want to trigger lookups.
	variable trigger "slang"

	# maximum lines to output from a definition.
	variable max_lines 1

	# approximate maximum characters per line.
	variable line_length 400

	# show truncated message / url if more than one line.
	variable show_truncate 1

	# bool. toggle logging.
	variable log 1

	# http user-agent to claim.
	variable client "Mozilla/5.0 (compatible; Y!J; for robot study; keyoshid)"

	# url to send look up requests to.
	variable url {https://www.urbandictionary.com/define.php}

	# regex to find all definition(s).
	variable list_regex {<div class='def-panel' data-defid='[0-9]+?'>.*?<div class='def-footer'>}
	# regex to parse a single definition.
	variable def_regex  {<div class='def-panel' data-defid='([0-9]+?)'>.*?<div class='meaning'>(.*?)</div>.*?<div class='example'>(.*?)</div>}

	# the number of definitions per page.
	variable definitions_per_page 7

	# the maximum number of HTTP requests to make during one one lookup.
	variable max_requests 3

	# http request timeout.
	variable request_timeout_seconds 10

	# Whether to enable debug mode or not.
	variable debug 1

	settings_add_str "slang_enabled_channels" ""

	signal_add msg_pub $::ud::trigger ::ud::handler
}

proc ::ud::log {msg} {
	if {!$::ud::log} {
		return
	}
	irssi_print "slang: $msg"
}

proc ::ud::handler {server nick uhost chan argv} {
	if {![str_in_settings_str "slang_enabled_channels" $chan]} {
		return
	}

	set argv [string trim $argv]
	set argv [split $argv]
	if {[string is digit [lindex $argv 0]]} {
		set number [lindex $argv 0]
		set query [join [lrange $argv 1 end]]
	} else {
		set query [join $argv]
		set number 1
	}
	set query [string trim $query]

	if {$query == ""} {
		putchan $server $chan "Usage: $::ud::trigger \[#\] <definition to look up>"
		return
	}

	lassign [::ud::find_term_by_page $number] page
	set http_query [::http::formatQuery term $query page $page]
	set url ${::ud::url}?${http_query}

	set request_count 0
	::ud::fetch $server $chan $url $query $number $request_count
}

# we want to find what page a requested definition number is on, and where
# on that page it is. this is because we might have asked for definition 10
# which may not be on page 1.
proc ::ud::find_term_by_page {number} {
	# get floating point number per page - we need that for the page calculation.
	set definitions_per_page [expr 1.0 * $::ud::definitions_per_page]

	# the page it's on.
	set page [expr {int(ceil($number / $definitions_per_page))}]

	# where on that page it is. 1 based.
	set number_on_page [expr {$number - (($page - 1) * $::ud::definitions_per_page)}]
	return [list $page $number_on_page]
}

# initiate a new http request.
#
# parameters:
# server: the irssi server identifier (to output to)
# channel: the irc channel to output to
# url: the url to fetch.
# query: the term to query
# number: the definition number we want
# request_count: the number of requests made already for this lookup.
proc ::ud::fetch {server channel url query number request_count} {
	# we only make a defined number of requests (following redirects).
	if {$request_count >= $::ud::max_requests} {
		::ud::log "fetch: maximum requests made"
		putchan $server $channel "Too many redirects! Not requesting $url"
		return
	}

	# set our user-agent. this could have been set by a different script, so we
	# want to do it for every request.
	::http::config -useragent $::ud::client

	set timeout [expr $::ud::request_timeout_seconds * 1000]
	incr request_count

	if {$::ud::debug} {
		::ud::log "fetch: Retrieving $url"
		set token [::http::geturl $url -timeout $timeout]
		::ud::fetch_cb $server $channel [list $query] $number $request_count $token
		return
	}

	::http::geturl $url \
		-timeout $timeout \
		-command "::ud::fetch_cb $server $channel [list $query] $number $request_count"
}

# take the raw query response data and output it to the channel as necessary.
# first we parse it.
#
# one reason to keep this as a separate proc from fetch_cb is so that we can
# catch errors in fetch_cb for easier reporting due to fetch_cb being
# an async callback from ::http::geturl which has various gotchas.
proc ::ud::output {server channel query number data} {
	# parse out the definitions & examples.
	set definitions [regexp -all -inline -- $::ud::list_regex $data]
	set definition_count [llength $definitions]
	# the definition number requested may be on a page beyond the first, so
	# we want to know what number on the page it is that we want.
	lassign [::ud::find_term_by_page $number] -> number
	if {[expr $definition_count < $number]} {
		putchan $server $channel "Error: $definition_count definition(s) found."
		return
	}

	# find the definition we want.
	set definition [lindex $definitions [expr {$number - 1}]]
	# parse it out.
	set result [::ud::parse $query $definition]

	# build the url to the definition.
	set def_url [::ud::def_url $query $result]

	# build and output the definition lines.
	set lines [::ud::split_line $::ud::line_length [dict get $result definition]]
	set line_count 0
	foreach line $lines {
		if {[incr line_count] > $::ud::max_lines} {
			if {$::ud::show_truncate} {
				putchan $server $channel "Output truncated. $def_url"
			}
			break
		}
		putchan $server $channel "$line"
	}
	# build and output the example lines.
	set lines [::ud::split_line $::ud::line_length [dict get $result example]]
	set line_count 0
	foreach line $lines {
		if {[incr output] > $::ud::max_lines} {
			if {$::ud::show_truncate} {
				putchan $server $channel "Output truncated. $def_url"
			}
			break
		}
		putchan $server $channel "$line"
	}
}

# an HTTP request generated a 30x response. follow it.
#
# parameters:
# server: the irssi server identifier to output to
# channel: the channel to output to
# query: the term to look up
# number: the requested definition number
# request_count: the number of http requests made so far in the lookup
# meta: this is the meta list from an ::http request
proc ::ud::http_follow_redirect {server channel query number request_count meta} {
	set location ""
	# find the location header value.
	foreach {key value} $meta {
		if {![string equal -nocase $key location]} {
			continue
		}
		set location $value
		break
	}
	if {$location == ""} {
		::ud::log "http_follow_redirect: No Location header found to redirect"
		return
	}
	# at this time we only follow absolute location headers.
	# happily this is what urbandictionary is currently sending.
	if {![regexp -- {^https?://} $location]} {
		::ud::log "http_follow_redirect: Location is not absolute: $location"
		return
	}
	::ud::fetch $server $channel $location $query $number $request_count
}

# Callback from HTTP get in ud::fetch
#
# parameters:
# server: the irssi server identifier to output to
# channel: the channel to output to
# query: the term to look up
# number: the requested definition number
# request_count: the number of http requests made so far
proc ::ud::fetch_cb {server channel query number request_count token} {
	if {[string equal [::http::status $token] "error"]} {
		set msg [::http::error $token]
		putchan $server $channel "HTTP query error: $msg"
		::http::cleanup $token
		return
	}
	set data [::http::data $token]
	set ncode [::http::ncode $token]
	set meta [http::meta $token]
	::http::cleanup $token

	# we can receive redirects.
	if {[regexp -- {30[01237]} $ncode]} {
		::ud::http_follow_redirect $server $channel $query $number $request_count \
			$meta
		return
	}

	if {$ncode != 200} {
		putchan $server $channel "HTTP request problem. HTTP code: $ncode."
		return
	}

	if {$::ud::debug} {
		set fh [open /tmp/ud.txt w]
		puts -nonewline $fh $data
		close $fh
	}

	if {[catch {::ud::output $server $channel $query $number $data} msg]} {
		putchan $server $channel "Output failure: $msg"
		return
	}
}

# take a string, s, from the raw html of a query, and sanitise it for output.
# this should be run on both the definition and the example text.
proc ::ud::sanitise_text {s} {
	set s [htmlparse::mapEscapes $s]
	set s [regsub -all -- {<.*?>} $s ""]
	set s [regsub -all -- {\s+} $s " "]
	set s [string tolower $s]
	set s [string trim $s]
	return $s
}

proc ::ud::parse {query raw_definition} {
	if {![regexp $::ud::def_regex $raw_definition -> id definition example]} {
		error "Could not parse the definition."
	}
	set definition [::ud::sanitise_text $definition]
	set example [::ud::sanitise_text $example]

	set d [dict create]
	dict set d id $id
	dict set d definition "$query is $definition"
	dict set d example $example

	return $d
}

proc ::ud::def_url {query result} {
	set raw_url ${::ud::url}?[::http::formatQuery term $query defid [dict get $result id]]
	return $raw_url
}

proc ::ud::split_line {max str} {
	set last [expr {[string length $str] -1}]
	set start 0
	set end [expr {$max -1}]

	set lines []

	while {$start <= $last} {
		if {$last >= $end} {
			set end [string last { } $str $end]
		}

		lappend lines [string trim [string range $str $start $end]]
		set start $end
		set end [expr {$start + $max}]
	}

	return $lines
}

irssi_print "slang.tcl loaded"
