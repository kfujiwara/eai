# $Id: MIME.pm,v 1.17 2008/08/26 09:19:51 fujiwara Exp $
#
# MIME, header field manipulation package
# for UTF8SMTP Downgrading:
#
#    draft-ietf-eai-downgrade-06.txt
#    draft-fujiwara-eai-downgraded-display-00.txt
#
# Author: Kazunori Fujiwara
# Contact: <fujiwara@jprs.co.jp>, <fujiwara@wide.ad.jp>
#
# Copyright and License are at the end of this file. 
# Documentation is avaiable by "perldoc"

require 5.8.8;
package UTF8SMTP::MIME;
use strict;
use warnings;
use utf8;
use MIME::Base64 ();
use Exporter;
use POSIX;
our @ISA = qw(Exporter);
our @EXPORT      = qw(set_mime_encoding non_ascii unfolding folding rfc2047_bq decode_unstructured rfc2047comments decode_rfc2047comments xtext_decode xtext_encode rfc2231_encode mime_rfc2231_decode generate_mailbox rfc2047q_unstructured rfc2047q_comment rfc2047q_display get_CFWS get_word rfc2047incomments generate_envelope datetime_string set_datetime_tz cat_headerfields);

my $mime_debug = 1;
my $encoding = 'A';

sub logmsg
{
	print STDERR shift,"\n";
}

sub set_mime_encoding
{
	($encoding) = @_;
}
###############################################################################
#
# non_ascii($string): Non ASCII check
#
###############################################################################
sub non_ascii($)
{
	my ($str) = @_;
	return ($str =~ /[^\000-\177]/);
}
###############################################################################
#
# utf8len variable
#
###############################################################################
my @utf8len;
foreach (0..127) { $utf8len[$_] = 1; };
foreach (128..193) { $utf8len[$_] = 0; }; # broken
foreach (194..223) { $utf8len[$_] = 2; };
foreach (224..239) { $utf8len[$_] = 3; };
foreach (240..247) { $utf8len[$_] = 4; };
foreach (248..255) { $utf8len[$_] = 1; };
###############################################################################
#
# constants
#
###############################################################################

use constant {
	MIME_LINE_LIMIT => 78,
	ENCODED_WORD_LIMIT => 75,
	ENCODED_WORD_HEAD => '=?UTF-8?B?',
	ENCODED_WORD_QHEAD => '=?UTF-8?Q?',
	ENCODED_WORD_TAIL => '?='
};

###############################################################################
#
# unfolding($string)
#
###############################################################################
sub unfolding($)
{
	my ($input) = @_;
	chomp($input);
	$input =~ tr/\r//d;
	$input =~ s/[ \t]*\n[ \t]*/ /g;
	return $input;
}
###############################################################################
#
# folding($string)
#
###############################################################################
sub folding
{
	my ($h) = @_;
	my ($out, $line, $s);

	$out = ''; $line = ''; $s = '';
	$h =~ s/\n/ /g;
	if (length($h) <= MIME_LINE_LIMIT) {
		return $h;
	}
	if ($h =~ /^Received:[ \t]([^ \t].*)$/i) {
		return &received_folding($1);
	}
	while($h ne '') {
		if ($h =~ /^([ \t]*[^ \t]+)([ \t]+[^ \t].*)$/) {
			$s = $1;
			$h = $2;
		} else {
			$s = $h;
			$h = '';
		}
		if (length($line) + length($s) > MIME_LINE_LIMIT) {
			$out .= $line . "\n";
			if ($s =~ /^[ \t]*([^ \t].*)$/) {
				$s = $1;
			}
			$line = ' ' . $s;
		} else {
			$line .= $s;
		}
	}
	$out .= $line;
	return $out;
}
sub received_folding
{
	my $l = shift;
	$l =~ s/;[ \t]*/;\n\t/g;
	$l =~ s/[ \t]from[ \t]/\n\tfrom /g;
	$l =~ s/[ \t]for[ \t]/\n\tfor /g;
	$l =~ s/[ \t]by[ \t]/\n\tby /g;
	return 'Received: '.$l;
}
##########################################################
#
# rfc2047_bq($name, $value, $mode)
#
###############################################################################
sub rfc2047_bq
{
	my ($name, $value, $mode) = @_;
	my ($str) = $value;
	if ($encoding eq 'B') {
		return &rfc2047_b_encode($name, $value);
	}
	if ($encoding eq 'Q') {
		return &rfc2047_q_encode($name, $value, $mode);
	}
	utf8::decode($str);
	if ($str =~ /[^\x{0000}-\x{017f}]/) {
		return &rfc2047_b_encode($name, $value);
	}
	return &rfc2047_q_encode($name, $value, $mode);
}

##########################################################
# rfc2047 Q encoding ... for 0x21-0x7e characters,
#   _=? are not allowed, others are OK in encoded-words as is.
#   ()" are not allowed inside comments.
#   Only A-Za-z0-9!*+-/ are allowed in display name
# sub rfc2047_q_encode
##########################################################
my @rfc2047q_allowed;
use constant {
	rfc2047q_unstructured => 1,
	rfc2047q_comment => 2,
	rfc2047q_display => 4,
};
&init_rfc2047q;
sub init_rfc2047q
{
	my $i;
	foreach $i (0..0x20,0x7f..0xff) {
		$rfc2047q_allowed[$i] = 0;
	}
	foreach $i (0x21..0x7e) {
		$rfc2047q_allowed[$i] = rfc2047q_unstructured | rfc2047q_comment;
	}
	foreach $i (split(//, '_=?')) {
		$rfc2047q_allowed[ord($i)] = 0;
	}
	foreach $i (split(//, '()"')) {
		$rfc2047q_allowed[ord($i)] &= rfc2047q_unstructured;
	}
	foreach $i ('0'..'9','a'..'z','A'..'Z',split(//, '!*+-/')) {
		$rfc2047q_allowed[ord($i)] |= rfc2047q_display;
	}
}
sub rfc2047_q_encode
{
	my ($name, $value, $mode);
	($name, $value, $mode) = @_;

	if (!defined($mode)) {
		$mode = rfc2047q_display;
	}
	my ($output, $l, $lim, $rest, $c, $t, $limit_first, $limit);
	$rest = $value;
	$output = '';
	$t = $name . (($name ne '') ? ': ' : '') . ENCODED_WORD_QHEAD;
	$limit = ENCODED_WORD_LIMIT - length(ENCODED_WORD_TAIL);
	while($rest ne '') {
		# get first character of UTF-8
		$c = substr($rest, 0, 1); substr($rest, 0, 1) = '';
		$l = $utf8len[ord($c)];
		if ($l == 0) {
			&logmsg("utf-8 character 0x".hex(ord($c))." is invalid") if ($mime_debug);
			$l = 1;
		}
		if ($l > 1) {
			$c = $c . substr($rest, 0, $l-1);
			if (length($c) ne $l) {
				&logmsg("utf-8 string is broken: $value") if ($mime_debug);
			}
			substr($rest, 0, $l-1) = '';
			$l = '';
			foreach my $cc (split(//, $c)) {
				$l .= sprintf("=%02x", ord($cc));
			}
			$c = $l;
		} else {
			if ($c eq ' ') {
				$c = '_';
			} elsif (!($rfc2047q_allowed[ord($c)] & $mode)) {
				$c = sprintf("=%02x", ord($c));
			}
		}
		if (length($t.$c) > $limit) {
			$output .= $t . ENCODED_WORD_TAIL . ' ';
			$t = ENCODED_WORD_QHEAD . $c;
		} else {
			$t .= $c;
		}
	}
	if ($t ne '') {
		$output .= $t . ENCODED_WORD_TAIL;
	}
	return ($output);
}

##########################################################
#
# rfc2047_b_encode($headername, $headervalue)
#
###############################################################################
sub rfc2047_b_encode
{
	my ($name, $value);
	($name, $value) = @_;

	my ($output, $l, $lim, $rest, $c, $t, $limit_first, $limit);
	$rest = $value;
	$output = '';
	if ($name eq '') {
		$limit_first = 0;
	} else {
		$output = $name.': ';
		$limit_first = MIME_LINE_LIMIT - length($output);
		$limit_first = 0 if ($limit_first > ENCODED_WORD_LIMIT);
	}
	$t = '';
	while($rest ne '') {
		$limit = int(((($limit_first > 0) ? $limit_first : ENCODED_WORD_LIMIT)
			- length(ENCODED_WORD_HEAD.ENCODED_WORD_TAIL)) / 4) * 3;
		# get first character of UTF-8
		while($rest ne '') {
			$c = substr($rest, 0, 1); substr($rest, 0, 1) = '';
			$l = $utf8len[ord($c)];
			if ($l > 1) {
				$c = $c . substr($rest, 0, $l-1);
				if (length($c) ne $l) {
					&logmsg("utf-8 string is broken: $value") if ($mime_debug);
				}
				substr($rest, 0, $l-1) = '';
			}
			if (length($t.$c) > $limit) {
				my $a = MIME::Base64::encode($t, '');
				chomp($a);
				$a =~ s/ $//;
				$output .= ENCODED_WORD_HEAD . $a . ENCODED_WORD_TAIL . ' ';
				$t = $c;
				last;
			} else {
				$t .= $c;
			}
		}
	}
	if ($t ne '') {
		my $a = MIME::Base64::encode($t, '');
		$a =~ s/ $//;
		$output .= ENCODED_WORD_HEAD . $a . ENCODED_WORD_TAIL;
	}
	return $output;
}
##############################################################################

# Only support UTF-8 encoding
sub rfc2047_decode
{
	my $value = shift;

	if ($value =~ /^\"([^"]*)\"$/) {
		$value = &rfc2047_decode($1);
		return '"'.$value.'"';
	}
	return $value unless ($value =~ /^=\?([^?]+)\?([bqBQ])\?(.+)\?=$/);
	my ($charset, $encoding, $encoded) = ($1, $2, $3);
	$charset =~ y/a-z/A-Z/;
	$encoding =~ y/a-z/A-Z/;
	my @charset = split(/\*/, $charset);
	return $value if ($charset[0] ne 'UTF-8');
	my $output = '';
	if ($encoding eq 'B') {
		return MIME::Base64::decode($encoded);
	} elsif ($encoding eq 'Q') {
		while ($encoded ne '') {
			my $c = substr $encoded, 0, 1, '';
			if ($c eq '_') {
				$output .= ' ';
			} elsif ($c eq '=') {
				$c = substr $encoded, 0, 2, '';
				return $value unless ($c =~ /[0-9a-fA-F][0-9a-fA-F]/);
				$output .= chr(hex($c));
			} else {
				$output .= $c;
			}
		}
	}
	return $output;
}

sub decode_unstructured
{
	my ($value);
	($value) = @_;

	my ($output, $rest, $after_encoded, $space, $word, $decoded);
	$rest = $value;
	$output = '';
	$after_encoded = 0;
	while($rest ne '') {
		if ($rest =~ /^([ \t]*)([^ \t]+)(|[ \t]+.*)$/) {
			($space, $word, $rest) = ($1, $2, $3);
			$decoded = &rfc2047_decode($word);
			if ($decoded ne $word) {
				$output .= ($after_encoded?'':$space) . $decoded;
				$after_encoded = 1;
			} else {
				$output .= $space . $word;
				$after_encoded = 0;
			}
		} else {
			$output .= $rest;
			$rest = '';
		}
	}
	return $output;
}

sub rfc2047incomments
{
	my ($head, $rest, $value);
	($rest) = @_;
	$head = '';

	while($rest ne '') {
		if ($rest =~ /^([ \t()]+)([^ \t()].*|)$/) {
			$head .= $1; $rest = $2;
		}
		if ($rest =~ /^([^ \t()]+)([ \t()].*|)$/) {
			$value = $1; $rest = $2;
			if (&non_ascii($value)) {
				$value = &rfc2047_bq('', $value, rfc2047q_comment);
			}
			$head .= $value;
		}
	}
	return $head;
}
sub decode_rfc2047incomments
{
	my ($head, $rest, $value, $decoded);
	($rest) = @_;
	$head = '';

	while($rest ne '') {
		if ($rest =~ /^([^()]*)([()]+)([^()]+.*|)$/) {
			$rest = $3;
			$head .= &decode_unstructured($1) . $2;
		} else {
			$head .= &decode_unstructured($rest);
			last;
		}
	}
	return $head;
}

################################################################
# get_CFWS($input, $mode) returns ($cfws, $rest)
#    $mode = 0: $cfws is not changed
#    $mode = 1: $cfws is encoded by RFC 2047
#    $mode = 2: $cfws is decoded by RFC 2047
################################################################
sub get_CFWS
{
	my ($cfws, $comment, $nest, $p, $q);
	my ($rest, $flag) = @_;
	$cfws = '';
	$nest = 0;

	if ($rest =~ /^([ \t]+)([^ \t].*|)$/) {
		$cfws = $1;
		$rest = $2;
	}
	while (substr($rest, 0, 1) eq '(') {
		substr($rest, 0, 1) = '';
		$comment = '(';
		$nest = 1;
		while ($nest > 0) {
			$p = index $rest, '(';
			$q = index $rest, ')';
			if ($q < 0 || $rest eq '') {
				&logmsg("parensis nesting error: ($rest") if ($mime_debug);
				return ($rest,'');
			}
			if ($p < 0 || $q < $p) {
				$comment .= substr($rest, 0, $q+1).' ';
				$rest = substr($rest, $q + 1);
				$nest--;
			} else {
				$comment .= substr($rest, 0, $p). ' (';
				$rest = substr($rest, $p + 1);
				$nest++;
			}
		}
		if ($flag == 1) {
			$cfws .= &rfc2047incomments($comment);
		} elsif ($flag == 2) {
			$cfws .= &decode_rfc2047incomments($comment);
		} else {
			$cfws .= $comment;
		}
		if ($rest =~ /^([ \t]+)([^ \t].*|)$/) {
			$cfws .= $1;
			$rest = $2;
		}
	}
	return ($cfws, $rest);
}
sub get_word
{
	my ($p, $word);
	my ($rest) = @_;

	$word = '';
	if ($rest =~ /^[^ \t(]/) {
		if (substr($rest, 0, 1) eq '"') {
			$p = index $rest, '"', 1;
			if ($p < 0) {
				&logmsg("$rest: Quote nesting error") if ($mime_debug);
				return ($rest,'');
			}
			$word = substr($rest, 0, $p+1);
			$rest = substr($rest, $p+1);
		} else {
			if ($rest =~ /^([^ \t]+)([ \t].*|)$/) {
				$word = $1;
				$rest = $2;
			} else {
				$word = $rest;
				$rest = '';
			}
		}
	}
	return ($word, $rest);
}
sub rfc2047comments
{
	my ($rest) = @_;
	my ($output, $p, $q);

	while($rest ne '') {
		($p, $rest) = &get_CFWS($rest, 1);
		$output .= $p;
		($p, $rest) = &get_word($rest);
		$output .= $p;
	}
	return $output;
}
sub decode_rfc2047comments
{
	my ($rest) = @_;
	my ($output, $p, $q);

	$output = ''; $p = ''; $q = '';
	while($rest ne '') {
		($p, $rest) = &get_CFWS($rest, 2);
		$output .= $p;
		($p, $rest) = &get_word($rest);
		$q = rfc2047_decode($p);
		$output .= $q;
	}
	return $output;
}


###############################################################################
# xtext encoding
# xtext decode($string)  returns  decoded string.
###############################################################################
sub xtext_decode
{
	my ($head, $rest, $value);
	($rest) = @_;
	$head = '';

	while($rest ne '') {
		if ($rest =~ /^([^+]+)\+([0-9A-F][0-9A-F])(.*)$/) {
			$head .= $1; $value = $2; $rest = $3;
			$head .= chr(hex($value));
		} elsif ($rest =~ /^([^+]+)\+(.*)$/) {
			$head .= $head . '+';
			$rest = $2;
		} else {
			$head .= $rest;
			$rest = '';
		}
	}
	return $head;
}

sub xtext_encode
{
	my ($head, $rest, $value);
	($rest) = @_;
	$head = '';

	while($rest ne '') {
		if ($rest =~ /^([!-*,-<>-~]+)([\x00-\x20+=\x7f-\xff])(.*)$/) {
			$head .= $1; $value = $2; $rest = $3;
			$head .= sprintf("+%02x", ord($value));
		} else {
			$head .= $rest;
			$rest = '';
		}
	}
	return $head;
}


##########################################################
# rfc2231 encoding
# &rfc2231_encode($name, $value)
###############################################################################
my $attribute_except_chars = '()<>@,;:\\"/[]?=*%\' ';
my @attr_char;
for (my $i = 33; $i < 127; $i++) {
	$attr_char[$i] = 1;
}
foreach my $i (split(//, $attribute_except_chars)) {
	$attr_char[ord($i)] = 0;
}

sub rfc2231_encode_sub
{
	my ($c, $x) = @_;
	my ($w);
	$w = sprintf("%%%02X", ord($c));
	foreach $c (split(//, $x)) {
		return '' if (ord($c) < 128 || ord($c) >= 192); #broken UTF8
		$w .= sprintf("%%%02X", ord($c));
	}
	return $w;
}
sub rfc2231_encode
{
	my ($name, $value);
	($name, $value) = @_;

	if (substr($value, 0, 1) eq '"' && substr($value, -1, 1) eq '"') {
		$value = substr($value, 1, length($value)-2);
	}
	my ($count, $l, $lim, $rest, $e1, $e2, $e2t, $w, $x, $c, $t);

	$rest = $value;
	$count = 0;
	$e1 = $name . '*=UTF-8\'\'';
	$e2 = '';
	$e2t = 'UTF-8\'\'';
	while($rest ne '') {
		# get first character of UTF-8
		$c = substr($rest, 0, 1); substr($rest, 0, 1) = '';
		$l = $utf8len[ord($c)];
		if ($l > 1) {
			$x = substr($rest, 0, $l-1);
			$w = &rfc2231_encode_sub($c,$x);
			if (length($x) ne $l-1 || $w eq '') {
				&logmsg("utf-8 string is broken: $value") if ($mime_debug);
			}
			substr($rest, 0, $l-1) = '';
		} else {
			$x = '';
			$w = ($attr_char[ord($c)])?$c:sprintf("%02X", ord($c));
		}
		$e1 .= $w;
		$t = $name.'*'.sprintf("%d", $count).'*='.$e2t;
		if (length($t.$w) > ENCODED_WORD_LIMIT) {
			$e2 .= $t . "; ";
			$e2t = $w;
			$count++;
		} else {
			$e2t .= $w;
		}
	}
	return $e1 if (length($e1) <= ENCODED_WORD_LIMIT);
	$e2 .= $t . $w;
	return $e2;
}

sub mine_rfc2231_decode_str
{
	my ($name, $v) = @_;
	my @v = split(/\'/, $v);
	$v[0] =~ y/a-z/A-Z/;
	if ($v[0] ne 'UTF-8') {
		return "$name*=$v";
	} else {
		$v[2] =~ s/%([0-9a-fA-F][0-9a-fA-F])/pack("C",hex($1))/eg;
		return $name.'="'.$v[2].'"';
	}
}

sub mime_rfc2231_decode
{
	my @value = @_;
	my ($i, $j, @data, $name, $section, $v);

	for ($i = 0; $i <= $#value; $i++) {
		next unless ($value[$i] =~ /^[ \t]*([^= *\t]+)(\*\d+|)\*=([^ \t]+)([ \t]+|)$/);
		$name = $1;
		$section = $2;
		$v = $3;
		if ($section eq '') {
			$value[$i] = &mine_rfc2231_decode_str($name, $v);
			next;
		}
		for ($j = $i; $j <= $#value; $j++) {
			next unless ($value[$j] =~ /^[ \t]*([^= *\t]+)\*(\d+)\*=([^ \t]+)([ \t]+|)$/);
			next if ($1 ne $name);
			$data[$2] = $3;
			$value[$j] = '';
		}
		$v = join('', @data);
		$value[$i] = &mine_rfc2231_decode_str($name, $v);
	}
	for ($i = 0; $i <= $#value; $i++) {
		if ($value[$i] eq '') {
			splice @value, $i, 1;
			$i--;
		}
	}
	return @value;
}

#############################################################################
sub generate_mailbox
{
	my $mailfrom = shift;

	if ($mailfrom->{altaddr} eq '') {
		return '<'.$mailfrom->{addr}.'>';
	}
	return '<'.$mailfrom->{addr}.' <'.$mailfrom->{altaddr}.'>>';
}
sub generate_envelope
{
	my $mailfrom = shift;

	if ($mailfrom->{altaddr} eq '') {
		return '<'.$mailfrom->{addr}.'>';
	}
	return '<'.$mailfrom->{addr}.'> ALT-ADDRESS='.$mailfrom->{altaddr};
}

##############################################################################
my $datetime_tzstr = '+0000';
my $datetime_offset = 0;

sub set_datetime_tz
{
	$datetime_tzstr = shift;
	$datetime_offset = shift;
}
sub datetime_string
{
	my $now = shift;
	if ($now eq "") { $now = time; }
	return (strftime "%a, %d %b %Y %H:%M:%S", gmtime($now+$datetime_offset)).' '.$datetime_tzstr;
}

##############################################################################
sub cat_headerfields
{
	my $l = '';
	foreach my $i (@_) {
		$l .= $i . "\n" if ($i ne '');
	}
	return $l;
}

1;

=head1 NAME

UTF8SMTP::MIME - MIME and header field manipulation package for UTF8SMTP

=head1 DESCRIPTION

MIME and header field manipulation package for UTF8SMTP Downgrading.

This is an implementation of draft-ietf-eai-downgrade-06 and
 draft-fujiwara-eai-downgraded-display-00.

=head1 USAGE

 TBD

=head1 Bugs

 This program may have many problems.
 If you find any problem, please contact to the author.

 Non-ASCII check is achived by /[^000-177]/.

=head1 Author

  Kazunori Fujiwara <fujiwara@jprs.co.jp> <fujiwara@wide.ad.jp>

=head1 Copyright and License

Copyright(c) 2007,2008 Japan Registry Services Co., Ltd.
All rights reserved. By using this file, you agree to the
terms and conditions set forth bellow.

             LICENSE TERMS AND CONDITIONS 

The following License Terms and Conditions apply, unless a different
license is obtained from Japan Registry Service Co., Ltd. ("JPRS"),
a Japanese corporation, Chiyoda First Bldg. East 13F,
3-8-1 Nishi-Kanda, Chiyoda-ku, Tokyo 101-0065, Japan.

1. Use, Modification and Redistribution (including distribution
   of any modified or derived work) in source and/or binary forms
   is permitted under this License Terms and Conditions.

2. Redistribution of source code must retain the copyright notices
   as they appear in each source code file, this License Terms and
   Conditions.

3. Redistribution in binary form must reproduce the Copyright
   Notice, this License Terms and Conditions, in the documentation
   and/or other materials provided with the distribution.
   For the purposes of binary distribution the "Copyright Notice"
   refers to the following language:
   "Copyright(c) 2007,2008  Japan Registry Service Co., Ltd.
    All rights reserved."

4. The name of JPRS may not be used to endorse or promote products
   derived from this Software without specific prior written
   approval of JPRS.

5. Disclaimer/Limitation of Liability: THIS SOFTWARE IS PROVIDED
   BY JPRS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
   INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
   DISCLAIMED.  IN NO EVENT SHALL JPRS BE LIABLE FOR ANY DIRECT,
   INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
   DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
   OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
   THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
   OF SUCH DAMAGES.

=cut
