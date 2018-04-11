#
# Automatic tests for urltitle.tcl.
#

# Dummy some irssi.tcl functions.
proc ::settings_add_str {a b} {}
proc ::signal_add {a b c} {}
proc ::irssi_print {a} {}

source idna.tcl
source urltitle.tcl

proc ::tests {} {
	puts "Running tests..."

	set success 1
	if {![::test_make_absolute_url]} {
		set success 0
	}

	if {$success} {
		puts "Tests completed. Success."
		return
	}
	puts "Tests completed. Failures found!"
}

proc ::test_make_absolute_url {} {
	set tests [list \
		[dict create \
			old_url https://leviathan.summercat.com/buttonup \
			location /buttonup/login \
			expected https://leviathan.summercat.com/buttonup/login \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/buttonup/ \
			location /buttonup/login \
			expected https://leviathan.summercat.com/buttonup/login \
			] \
		[dict create \
			old_url https://leviathan.summercat.com \
			location /buttonup \
			expected https://leviathan.summercat.com/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/ \
			location /buttonup \
			expected https://leviathan.summercat.com/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com \
			location buttonup \
			expected https://leviathan.summercat.com/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/ \
			location buttonup \
			expected https://leviathan.summercat.com/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/one \
			location buttonup \
			expected https://leviathan.summercat.com/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/one/ \
			location buttonup \
			expected https://leviathan.summercat.com/one/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/one/two \
			location buttonup \
			expected https://leviathan.summercat.com/one/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/one/two/ \
			location buttonup \
			expected https://leviathan.summercat.com/one/two/buttonup \
			] \
		[dict create \
			old_url https://leviathan.summercat.com \
			location / \
			expected https://leviathan.summercat.com/ \
			] \
		[dict create \
			old_url https://leviathan.summercat.com/hi \
			location / \
			expected https://leviathan.summercat.com/ \
			] \
	]

	set failed 0
	foreach test $tests {
		set new_url [::urltitle::make_absolute_url \
			[dict get $test old_url] \
			[dict get $test location] \
			]

		if {$new_url == [dict get $test expected]} {
			continue
		}

		puts [format "FAILURE: make_absolute_url(%s, %s) = %s, wanted %s" \
			[dict get $test old_url] \
			[dict get $test location] \
			$new_url \
			[dict get $test expected] \
			]
		incr failed
	}

	if {$failed != 0} {
		puts [format "make_absolute_url: %d/%d tests failed" $failed [llength $tests]]
	}

	return [expr $failed == 0]
}

::tests
