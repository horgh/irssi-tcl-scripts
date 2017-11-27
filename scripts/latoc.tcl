# Provides binds to read Yahoo.com futures
#
# If you update this, update the one in
# https://github.com/horgh/eggdrop-scripts.
package require http

namespace eval ::latoc {
	variable user_agent "Lynx/2.8.5rel.1 libwww-FM/2.14 SSL-MM/1.4.1 OpenSSL/0.9.7e"

	variable list_regexp {<tr class="data-row.*?".*?</a></td></tr>}
	variable stock_regexp {<td class="data-col0.*>(.*)</a></td><td class="data-col1.*>(.*)</td><td class="data-col2.*>(.*)</td><td class="data-col3.*>(.*)</td><td class="data-col4.*>(.*)<!-- /react-text --></span></td><td class="data-col5.*>(.*)<!-- /react-text --></span></td><td class="data-col6.*>(.*)</td><td class="data-col7.*>(.*)</td><td class="data-col8.*"}

	variable url "https://finance.yahoo.com/commodities?ltr=1"

	signal_add msg_pub "!oil"    ::latoc::oil_handler
	signal_add msg_pub "!gold"   ::latoc::gold_handler
	signal_add msg_pub "!silver" ::latoc::silver_handler

	settings_add_str "latoc_enabled_channels" ""
}

proc ::latoc::fetch {server chan} {
	::http::config -useragent $::latoc::user_agent
	set token [::http::geturl $::latoc::url -timeout 20000]

	set status [::http::status $token]
	if {$status != "ok"} {
		set http_error [::http::error $token]
		putchan $server $chan "HTTP error: $status: $http_error"
		::http::cleanup $token
		return
	}

	set ncode [::http::ncode $token]
	if {$ncode != 200} {
		set code [::http::code $token]
		putchan $server $chan "HTTP error: $ncode: $code"
		::http::cleanup $token
		return
	}

	set data [::http::data $token]
	::http::cleanup $token

	return $data
}

proc ::latoc::parse {data} {
	set lines []
	foreach stock [regexp -all -inline -- $::latoc::list_regexp $data] {
		regexp $::latoc::stock_regexp $stock -> symbol name price last change percent volume interest
		set direction none
		if {$change < 0} {
			set direction Down
		}
		if {$change > 0} {
			set direction Up
		}
		lappend lines [::latoc::format $name $price $last $direction $change $percent]
	}

	return $lines
}

proc ::latoc::output {server chan lines symbol_pattern} {
	foreach line $lines {
		if {![regexp -- $symbol_pattern $line]} {
			continue
		}
		putchan $server $chan "$line"
	}
}

proc ::latoc::oil_handler {server nick uhost chan argv} {
	if {![str_in_settings_str "latoc_enabled_channels" $chan]} { return }

	set data [::latoc::fetch $server $chan]
	set lines [::latoc::parse $data]
	::latoc::output $server $chan $lines {Crude Oil}
}

proc ::latoc::gold_handler {server nick uhost chan argv} {
	if {![str_in_settings_str "latoc_enabled_channels" $chan]} { return }

	set data [::latoc::fetch $server $chan]
	set lines [::latoc::parse $data]
	::latoc::output $server $chan $lines {Gold}
}

proc ::latoc::silver_handler {server nick uhost chan argv} {
	if {![str_in_settings_str "latoc_enabled_channels" $chan]} { return }

	set data [::latoc::fetch $server $chan]
	set lines [::latoc::parse $data]
	::latoc::output $server $chan $lines {Silver}
}

proc ::latoc::format {name price last direction change percent} {
	return "$name: \00310$price [::latoc::colour $direction $change] [::latoc::colour $direction $percent]\003 $last"
}

proc ::latoc::colour {direction value} {
	if {[string match "Down" $direction]} {
		return \00304$value\017
	}
	if {[string match "Up" $direction]} {
		return \00309$value\017
	}
	return $value
}

irssi_print "latoc.tcl loaded"
