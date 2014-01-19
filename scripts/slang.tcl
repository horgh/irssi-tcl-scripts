#
# slang.tcl - June 24 2010
# by horgh
#
# Requires Tcl 8.5+ and tcllib
#
# Made with heavy inspiration from perpleXa's urbandict script!
#
# Must .chanset #channel +ud
#
# Uses is.gd to shorten long definition URL if isgd.tcl package present
#

package require htmlparse
package require http

namespace eval ud {
	# set this to !ud or whatever you want
	variable trigger "slang"

	# maximum lines to output
	variable max_lines 1

	# approximate characters per line
	variable line_length 400

	# show truncated message / url if more than one line
	variable show_truncate 1

	# bool. toggle debug output.
	variable debug 0

	variable client "Mozilla/5.0 (compatible; Y!J; for robot study; keyoshid)"
	variable url {http://www.urbandictionary.com/define.php}

	# regex to find all definition(s).
	variable list_regex {<div class='box'.*? data-defid='[0-9]+'>.*?<div class='footer'>}
	# regex to parse a single definition.
	variable def_regex {<div class='box'.*? data-defid='([0-9]+)'>.*?<div class='definition'>(.*?)</div>.*?<div class='example'>(.*?)</div>}

	settings_add_str "slang_enabled_channels" ""
	signal_add msg_pub $ud::trigger ud::handler

	# 0 if isgd package is present
	variable isgd_disabled [catch {package require isgd}]
}

proc ::ud::log {msg} {
	if {!$::ud::debug} {
		return
	}
	irssi_print "slang: $msg"
}

proc ud::handler {server nick uhost chan argv} {
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
		putchan $server $chan "Usage: $ud::trigger \[#\] <definition to look up>"
		return
	}

	ud::fetch $query $number $server $chan
}

proc ud::fetch {query number server channel} {
	::http::config -useragent $ud::client
	set page [expr {int(ceil($number / 7.0))}]
	set number [expr {$number - (($page - 1) * 7)}]

	set http_query [::http::formatQuery term $query page $page]

	set token [::http::geturl $ud::url -timeout 20000 -query $http_query \
		-command "::ud::fetch_cb $server $channel [list $query] $number"]
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
	set lines [::ud::split_line $ud::line_length [dict get $result example]]
	set line_count 0
	foreach line $lines {
		if {[incr output] > $ud::max_lines} {
			if {$ud::show_truncate} {
				putchan $server $channel "Output truncated. $def_url"
			}
			break
		}
		putchan $server $channel "$line"
	}
}

# Callback from HTTP get in ud::fetch
proc ::ud::fetch_cb {server channel query number token} {
	if {[string equal [::http::status $token] "error"]} {
		set msg [::http::error $token]
		putchan $server $channel "HTTP query error: $msg"
		::http::cleanup $token
		return
	}
	set data [::http::data $token]
	set ncode [::http::ncode $token]
	::http::cleanup $token

	if {$ncode != 200} {
		putchan $server $channel "HTTP fetch error. Response status code: $ncode."
		return
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

# 
proc ::ud::parse {query raw_definition} {
	if {![regexp $::ud::def_regex $raw_definition -> number definition example]} {
		error "Could not parse the definition."
	}
	set definition [::ud::sanitise_text $definition]
	set example [::ud::sanitise_text $example]

	set d [dict create]
	dict set d number $number
	dict set d definition "$query is $definition"
	dict set d example $example

	return $d
}

proc ud::def_url {query result} {
	set raw_url ${ud::url}?[::http::formatQuery term $query defid [dict get $result number]]
	if {$ud::isgd_disabled} {
		return $raw_url
	} else {
		if {[catch {isgd::shorten $raw_url} shortened]} {
			return "$raw_url (is.gd error)"
		} else {
			return $shortened
		}
	}
}

# by fedex
proc ud::split_line {max str} {
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
