#
# vim: tabstop=2:shiftwidth=2:noexpandtab
#
# Fetch title of URLs in channels
#
# /set urltitle_enabled_channels #channel1 #channel2 ..
# to enable in those channels
#
# /set urltitle_ignored_nicks nick1 nick2 nick2 ..
# to not fetch titles of urls by these nicks
#

package require http
package require tls
package require htmlparse
package require idna

namespace eval ::urltitle {
	variable useragent "Tcl http client package 2.7"

	# 2 MiB.
	# If we hit this (or near it), then we cannot retrieve a title.
	variable max_bytes [expr 2*1024*1024]

	variable max_redirects 3

	settings_add_str "urltitle_enabled_channels" ""
	settings_add_str "urltitle_ignored_nicks" ""

	signal_add msg_pub "*" ::urltitle::urltitle

	variable debug 0
}

proc ::urltitle::log {msg} {
	if {!$::urltitle::debug} {
		return
	}
	irssi_print "urltitle: $msg"
}

proc ::urltitle::urltitle {server nick uhost chan msg} {
	if {![str_in_settings_str urltitle_enabled_channels $chan]} {
		return
	}

	if {[str_in_settings_str urltitle_ignored_nicks $nick]} {
		return
	}

	set url [::urltitle::recognise_url $msg]
	if {$url == ""} {
		return
	}

	::urltitle::geturl $url $server $chan 0

	# geturl changes the https protocol for SNI. Reset it back for other scripts
	# in this interpreter.
	::http::register https 443 [list ::tls::socket -ssl2 0 -ssl3 0 -tls1 1]
}

# Breaks an absolute URL into 3 pieces:
# prefix/protocol: e.g. http://, https//
# domain: e.g. everything up to the first /, if it exists
# rest: everything after the first /, if exists
proc ::urltitle::split_url {absolute_url} {
	if {![regexp -- {(https?://)([^/]*)/?(.*)} $absolute_url -> prefix domain rest]} {
		error "urltitle error: parse problem: $absolute_url"
	}
	set domain [idna::domain_toascii $domain]

	# from http-title.tcl by Pixelz. Avoids urls that will be treated as
	# a flag
	if {[string index $domain 0] eq "-"} {
		error "urltitle error: Invalid URL: domain looks like a flag"
	}
	return [list $prefix $domain $rest]
}

# Attempt to recognise potential_url as an actual url in form of http[s]://...
# Returns blank if unsuccessful
proc ::urltitle::recognise_url {potential_url} {
	set full_url []
	if {[regexp -nocase -- {(https?://\S+)} $potential_url -> url]} {
		set full_url $url
	} elseif {[regexp -nocase -- {(www\.\S+)} $potential_url -> url]} {
		set full_url "http://${url}"
	}

	if {$full_url == ""} {
		return ""
	}

	lassign [::urltitle::split_url $full_url] prefix domain rest

	return "${prefix}${domain}/${rest}"
}

# @param string $data The body of the page
#
# @return mixed the title (html decoded), or "" if not found
#
# pull the title out of the html body of a page
proc ::urltitle::extract_title {data} {
	# Upper bound for {,x} is 255.
	if {[regexp -nocase -- {<title(?:\s{1,100}[^>]{0,200})?>([^<]{1,255}?[^<]{1,255}?)</title>} $data -> title]} {
		set title [regsub -all -- {\s+} $title " "]
		::urltitle::log "extract_title: found raw title $title"
		# mapEscapes decodes html encoded characters
		return [htmlparse::mapEscapes $title]
	}
	return ""
}

proc ::urltitle::geturl {url server chan redirect_count} {
	::urltitle::log "geturl: Trying to get URL: $url"
	if {$redirect_count > $::urltitle::max_redirects} {
		irssi_print "urltitle: Too many redirects ($redirect_count). Not fetching $url"
		return
	}

	# Use TLS SNI (-servername). We need the hostname.
	# For this we need tcl-tls 1.6.4+
	lassign [::urltitle::split_url $url] prefix hostname rest
	::http::register https 443 [list ::tls::socket -ssl2 0 -ssl3 0 -tls1 1 -servername $hostname]

	::http::config -useragent $::urltitle::useragent

	# Provide an Accept text/html header as we are expecting to pull the HTML
	# title tag out for printing.
	# I use -headers rather than http::config -accept as the latter is global and
	# I would rather avoid changing global options.

	irssi_print "urltitle: Fetching $url"

	if {[catch {::http::geturl \
		$url \
		-binary 1 \
		-blocksize $::urltitle::max_bytes \
		-timeout 10000 \
		-headers [list Accept text/html] \
		-progress ::urltitle::http_progress \
		} token]} {
		irssi_print "urltitle: Unable to make HTTP request to \[$url\]: $token"
		return
	}

	::urltitle::http_done $server $chan $redirect_count $token
}

# This function will cause us to stop the request after max_bytes.
# We are apparently not able to use the portion of data we've retrieved. The
# data is garbage in my testing. The documentation is unclear.
proc ::urltitle::http_progress {token total current} {
	if {$current >= $::urltitle::max_bytes} {
		::urltitle::log "http_progress: resetting, too large"

		# Don't clean up the token here. We will in http_done.

		::http::reset $token
	}
}

proc ::urltitle::http_done {server chan redirect_count token} {
	# Get state array out of token
	upvar #0 $token state

	# Ensure we have a sane state.
	if {$state(status) != "ok"} {
		set status $state(status)
		::urltitle::log "http_done: request status is $status, not ok"
		# It appears that status reset is not okay to use the result after all.
		::http::cleanup $token
		return
	}

	if {$::urltitle::debug} {
		set url $state(url)
		set data [::http::data $token]
		set code [::http::ncode $token]
		set meta [::http::meta $token]
		::urltitle::log "http_done: trying to get charset"
		set charset [::urltitle::get_charset $token]
		set fh [open /tmp/urltitle.out w]
		puts -nonewline $fh $data
		close $fh
		irssi_print "http_done: code ${code}"
		irssi_print "http_done: meta ${meta}"
		irssi_print "http_done: got charset: $charset"
	}

	# Follow redirects for some 30* codes
	set code [::http::ncode $token]
	if {[regexp -- {30[01237]} $code]} {
		# We need a Location: header to follow.
		set meta [::http::meta $token]
		set location [::urltitle::dict_get_insensitive $meta Location]
		if {$location == ""} {
			irssi_print "http_done: redirect code $code found, but no location header"
			::http::cleanup $token
			return
		}

		# The location may not be an absolute URL. Make it one.

		# Get the URL out of the state array. We could pass it via the callback but
		# issues with variable substitution if URL contains what appears to be
		# variables?
		set url $state(url)

		set new_url [::urltitle::make_absolute_url $url $location]

		::http::cleanup $token
		::urltitle::geturl $new_url $server $chan [incr redirect_count]
		return
	}

	::urltitle::parse_and_show_title $server $chan $token
	::http::cleanup $token
}

# Take a completed request token and try to extract a title from it.
# No more HTTP requests will be made.
# If we find a title, we write it to the channel.
proc ::urltitle::parse_and_show_title {server chan token} {
	set data [::http::data $token]
	set charset [::urltitle::get_charset $token]
	::http::cleanup $token

	# convert the data to unicode (internal) from its encoding.
	set data [encoding convertfrom $charset $data]

	# strip invalid unicode chars. see twitlib.tcl fix_status proc.
	set filtered_data ""
	for {set i 0} {$i < [string length $data]} {incr i} {
		set char [string index $data $i]
		# any unicode printing char including space.
		if {![string is print -strict $char]} {
			continue
		}
		append filtered_data $char
	}

	set title [::urltitle::extract_title $filtered_data]
	if {$title != ""} {
		::urltitle::log "http_done: title after extracting/decoding: $title"
		set output [string trim $title]

		# we do not need to encode to utf-8 - that gets taken care of
		# by functions other than us. in particular when we call Tcl_GetString()
		# in putchan_raw().

		putchan $server $chan "\002$output"
	} else {
		irssi_print "urltitle: No title found."
	}
}

# We've been redirected. Figure out where to go.
#
# Take the current URL and the Location header, and determine the full URL to
# go to next.
#
# Ensure we return an absolute URL
#
# new_target is the Location given by a redirect. This may be an absolute
# URL including protocol and host, or it may be relative to the host.
#
# If it's relative, we use old_url to create an absolute URL.
proc ::urltitle::make_absolute_url {old_url new_target} {
	# First check if we've been given an absolute URL (including host) as the
	# target.
	set absolute_url [::urltitle::recognise_url $new_target]
	if {$absolute_url != ""} {
		return $absolute_url
	}

	# The target is relative to the host. We need to create an absolute URL.

	if {[string length $new_target] == 0} {
		error "make_absolute_url: Location is blank"
	}

	# Break up the old URL into useful pieces.
	lassign [::urltitle::split_url $old_url] prefix domain old_path

	# If the first character of the target is /, then append it to the
	# domain/host, and we're done.
	if {[string index $new_target 0] == "/"} {
		return [format "%s%s%s" $prefix $domain $new_target]
	}

	# It's relative to the current "directory" on the host.

	# Find what that directory is.

	# If old URL was https://url, then return https://url/new_target
	if {$old_path == ""} {
		return [format "%s%s/%s" $prefix $domain $new_target]
	}

	# If old URL was https://url/blah/, then return https://url/blah/new_target
	if {[regexp -- {(\S+)/} $old_path -> old_dir]} {
		return [format "%s%s/%s/%s" $prefix $domain $old_dir $new_target]
	}

	# No / in the old path.

	# If old URL was https://url/blah, then return https://url/new_target
	return [format "%s%s/%s" $prefix $domain $new_target]
}

# @param dict $d A dict which from ::http::meta
# @param string $key The key to look for.
#
# @return mixed value from the dict, or "" if not found
#
# retrieve a key from a dict where we do not care about the
# case of the key.
proc ::urltitle::dict_get_insensitive {d key} {
	set key [string tolower $key]

	# retrieve all keys from the dict.
	set keys [dict keys $d]
	foreach found_key $keys {
		if {[string equal -nocase $found_key $key]} {
			return [dict get $d $found_key]
		}
	}
	return ""
}

# @param ::http token
#
# @return string charset. "" if not found.
#
# look for a charset in the Content-Type header.
proc ::urltitle::get_charset_from_headers {token} {
	::urltitle::log "get_charset_from_headers: trying to get charset"
	set meta [::http::meta $token]

	# get the Content-Type value if it exists.
	set content_type [::urltitle::dict_get_insensitive $meta Content-Type]
	if {$content_type == ""} {
		::urltitle::log "get_charset_from_headers: no content-type header"
		return ""
	}

	# try to retrieve charset
	set re {charset="?(.*?)"?;?}
	set res [regexp -nocase -- $re $content_type m charset]
	if {!$res} {
		::urltitle::log "get_charset_from_headers: no charset found"
		return ""
	}
	::urltitle::log "get_charset_from_headers: found charset: $charset"
	return $charset
}

# @param ::http token
#
# @return string charset. "" if not found.
#
# look for a charset in the html <meta/> tag.
proc ::urltitle::get_charset_from_body {token} {
	::urltitle::log "get_charset_from_body: trying to get charset"
	set data [::http::data $token]
	#::urltitle::log "get_charset_from_body: body: $data"

	set re {<meta[^>]+?charset=['\"]?([a-zA-Z\-_0-9]+)['\"]?.*?>}
	set res [regexp -nocase -- $re $data m charset]
	if {!$res} {
		::urltitle::log "get_charset_from_body: no charset found"
		return ""
	}

	::urltitle::log "get_charset_from_body: found charset: $charset"
	return $charset
}

# @param string charset   charset found from examining result
#
# @return string charset
#
# try translate the charset so as to be recognized as a tcl charset.
# some may be specified by the result/document that are not an
# exact match to tcl charset names.
proc ::urltitle::translate_charset {charset} {
	::urltitle::log "translate_charset: got charset $charset"
	set charset [string tolower $charset]
	# iso-8859-1 must be changed to iso8859-1
	regsub -- {iso-} $charset iso charset
	# shift_jis -> shiftjis
	regsub -- {shift_} $charset shift charset
	# windows-1252 -> cp1252
	regsub -- {windows-1252} $charset cp1252 charset
	# utf8 -> utf-8
	regsub -- {utf8} $charset utf-8 charset
	# known issue:
	# http://item.taobao.com/item.htm?spm=a1z10.1.w5003-1534844088.9.jxzqSB&id=25873632122&scene=taobao_shop
	# ! Tcl: Error: unknown encoding "gbk"
	# I think this encoding is not supported in Tcl at this time from what
	# I can tell...
	::urltitle::log "translate_charset: have charset $charset after translate"
	return $charset
}

# @param ::http token
#
# @return string charset
#
# try to get the charset of the requested document.
# first try http headers, then meta in body.
# fall back to iso8859-1 if we don't find one.
proc ::urltitle::get_charset {token} {
	# the charset from the Content-Type meta-data value.
	set charset [::urltitle::get_charset_from_headers $token]
	if {$charset != ""} {
		::urltitle::log "get_charset: charset from headers: $charset. translating"
		return [::urltitle::translate_charset $charset]
	}

	# no charset given in http header. try to get from the meta tag in the body.
	set charset [::urltitle::get_charset_from_body $token]
	if {$charset != ""} {
		::urltitle::log "get_charset: charset from body: $charset. translating"
		return [::urltitle::translate_charset $charset]
	}

	# default to iso8859-1.
	set charset iso8859-1
	::urltitle::log "get_charset: default charset $charset. translating."
	return [::urltitle::translate_charset $charset]
}

irssi_print "urltitle.tcl loaded"
