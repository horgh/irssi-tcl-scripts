#!/usr/bin/env tclsh

proc ::settings_add_str {a b} {}
proc ::signal_add {a b c} {}
proc ::irssi_print {a} {
	puts "irssi_print: $a"
}

source latoc.tcl

set html {<tr class="data-rowGC=F Bgc($extraLightBlue):h BdT Bdc($tableBorderGray) Bdc($tableBorderBlue):h H(33px) Whs(nw)" data-reactid="46"><td class="data-col0 Ta(start) Pstart(6px)" data-reactid="47"><a href="/quote/GC%3DF?p=GC%3DF" title="Gold" data-symbol="GC=F" class="Fw(b)" data-reactid="48">GC=F</a></td><td class="data-col1 Ta(start) Pend(10px)" data-reactid="49">Gold</td><td class="data-col2 Ta(end) Pstart(20px)" data-reactid="50">1,212.30</td><td class="data-col3 Ta(end) Pstart(20px)" data-reactid="51">4:59PM EDT</td><td class="data-col4 Ta(end) Pstart(20px)" data-reactid="52"><span class="Trsdu(0.3s)  C($dataGreen)" data-reactid="53">+18.30</span></td><td class="data-col5 Ta(end) Pstart(20px)" data-reactid="54"><span class="Trsdu(0.3s)  C($dataGreen)" data-reactid="55">+1.53%</span></td><td class="data-col6 Ta(end) Pstart(20px)" data-reactid="56">286,519</td><td class="data-col7 Ta(end) Pstart(20px) Pend(10px) W(120px)" data-reactid="57">366,253</td><td class="data-col8 Ta(start) Pstart(20px) Pend(6px) W(60px)" data-reactid="58"><a target="_blank" rel="noopener" href="/chart/GC%3DF?p=GC%3DF" data-symbol="GC=F" data-reactid="59"><!-- react-empty: 60 --></a></td></tr>}

set data [::latoc::parse $html]
puts $data
