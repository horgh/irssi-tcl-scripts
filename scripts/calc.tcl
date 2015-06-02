#
# created by fedex
# updated by horgh
#

# Part of tcllib
package require math

namespace eval calc {
	signal_add msg_pub !calc calc::safe_calc
	signal_add msg_pub .calc calc::safe_calc

	settings_add_str "calc_enabled_channels" ""
}

proc ::tcl::mathfunc::factorial {n} {
	#return [math::factorial [expr {int($n)}]]
	return [math::factorial $n]
}

proc calc::is_op {str} {
	return [expr [lsearch {{ } . + - * / ( ) %} $str] != -1]
}

proc calc::safe_calc {server nick uhost chan str} {
	if {![str_in_settings_str "calc_enabled_channels" $chan]} {
		return
	}

	# treat ^ as exponentiation
	regsub -all -- {\^} $str "**" str

	foreach char [split $str {}] {
		# allow characters so as to be able to call mathfuncs
		if {![is_op $char] && ![regexp -- {^[a-z0-9]$} $char]} {
			putchan $server $chan "${nick}: Invalid expression. (${str})"
			return
		}
	}

	# make all values floating point
	set str [regsub -all -- {((?:\d+)?\.?\d+)} $str {[expr {\1*1.0}]}]
	set str [subst $str]

	if {[catch {expr $str} out]} {
		putchan $server $chan "${nick}: Invalid equation. (${str})"
		return
	} else {
		set out [::calc::format_double_thousands $out]
		putchan $server $chan "$str = $out"
	}
}

#proc ::calc::format_double {v} {
#	if {$v == "null" || $v == ""} {
#		set v 0
#	}
#	set v [format %.2f $v]
#	return $v
#}

proc ::calc::format_double_thousands {v} {
	if {$v == "null" || $v == ""} {
		set v 0
	}
	#set v [::bitcoincharts::format_double $v]
	# break the string on the '.'.
	set number_parts [split $v .]
	set whole_part [lindex $number_parts 0]
	set fractional_part [lindex $number_parts 1]

	# break the whole part into separate digits.
	set whole_part_digits [split $whole_part {}]
	# reverse the digits.
	set whole_part_digits [lreverse $whole_part_digits]

	# take up to 3 digits each time from this reversed list and
	# put these groupings into another list.
	# this is so we can deal with the case of not having full
	# groups of 3.
	set digit_groups [list]
	while {[llength $whole_part_digits]} {
		if {[expr [llength $whole_part_digits] >= 3]} {
			set digit_group [lrange $whole_part_digits 0 2]
			set whole_part_digits [lreplace $whole_part_digits 0 2]
		} else {
			set digit_group [lrange $whole_part_digits 0 end]
			set whole_part_digits [lreplace $whole_part_digits 0 end]
		}
		# reverse the digit group digits as first part of reverting
		# our original reverse.
		set digit_group [lreverse $digit_group]
		# make the digits a string instead of a list
		set digit_group [join $digit_group {}]
		lappend digit_groups $digit_group
	}
	# rebuild the whole part string. we also have to reverse
	# the digit groups as the second step in undoing our reverse.
	set whole_part [join [lreverse $digit_groups] ,]
	# rebuild the full number.
	set full [join [list $whole_part $fractional_part] .]
	return $full
}

irssi_print "calc.tcl loaded"
