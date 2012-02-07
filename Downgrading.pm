# $Id: Downgrading.pm,v 1.18 2008/07/08 08:05:15 fujiwara Exp $
#
# Downgrading: UTF8SMTP Downgrading package
#
#    draft-ietf-eai-downgrade-06.txt
#    draft-fujiwara-eai-downgraded-display-00.txt
#
# Author: Kazunori Fujiwara
# Contact: <fujiwara@jprs.co.jp>, <fujiwara@wide.ad.jp>
#
# Copyright and License are at the end of this file. 
# Documentation is avaiable by "perldoc"

package UTF8SMTP::Downgrading;
require 5.8.8;
use strict;
use Getopt::Std;
use UTF8SMTP::MIME;
use MIME::Base64;
use MIME::QuotedPrint;

BEGIN {
	use Exporter   ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
	# set the version for version checking
	$VERSION     = 0.01;
	# if using RCS/CVS, this may be preferred
	$VERSION = sprintf "%d.%03d", q$Revision: 1.18 $ =~ /(\d+)/g;
	@ISA         = qw(Exporter);
	@EXPORT      = qw(decoding_downgraded_message downgrading downgrading_testonly downgrading_8bit downgrading_7bit downgrading_noerror downgrading_error need_to_downgrade decoding_mime decoding_technique_1 decoding_technique_2 decoding_decode_base64 smtp_envelope_generate envelope_addr_downgrade decoding_headeronly decoding_nofolding);
	%EXPORT_TAGS = ();     # eg: TAG => [ qw!name1 name2! ],
	# your exported package globals go here,
	# as well as any optionally exported functions
	@EXPORT_OK   = qw(@error);
}

my $mime_debug = 0;
my $debug_downgrading = 0;
my (@error);
my (@boundary);
my $content_transfer_encoding;
my $multipartflag;
my $contenttype_charset;
my $contenttype;

sub generate_header()
{
	my ($name, $value) = @_;
	return &folding($value eq '' ? $name : $name.': '.$value);
}
###############################################################################
# getheaderfromfile(*FileHandle, init)
#
# This function reads a header field.
# '' means end of header fields.
###############################################################################
use constant {
	getheaderfromfile_init => 1,
	getheaderfromfile_read => 0,
	getheaderfromfile_ignore_comment => 2
};
my $getheaderfromfile_buffer = '';
my $getheaderfromfile_eoh = 0;
sub getheaderfromfile
{
	my ($fh, $init) = @_;
	my ($output, $tmp);

	if ($init == getheaderfromfile_ignore_comment) {
		while(<$fh>) {
			chomp;
			last if (!($_ =~ /^#/));
		}
		$getheaderfromfile_eoh = eof $fh;
		$getheaderfromfile_buffer = $_;
		return '';
	}
	if ($init == getheaderfromfile_init) {
		$getheaderfromfile_eoh = 0;
		$getheaderfromfile_buffer = '';
		return '';
	}
	return '' if ($getheaderfromfile_eoh);
	if ($getheaderfromfile_buffer ne '') {
		if ($getheaderfromfile_buffer =~ /^[\r\n]+$/) {
			return '';
		}
		if (!($getheaderfromfile_buffer =~ /^\S*/)) {
			$output = $getheaderfromfile_buffer;
			$getheaderfromfile_buffer = '';
			chomp($output);
			return $output;
		}
	}
	for ( ; ; ) {
		$tmp = <$fh>;
		$getheaderfromfile_eoh = eof $fh;
		if ($getheaderfromfile_buffer eq '') {
			$getheaderfromfile_buffer = $tmp;
			if ($tmp =~ /^[\r\n]+$/) {
				$tmp = '';
				last;
			}
			$tmp = '';
		} elsif ($tmp =~ /^[ \t]/) {
			$getheaderfromfile_buffer .= $tmp;
			$tmp = '';
		} else {
			last;
		}
		last if ($getheaderfromfile_eoh);
	}
	my $output = $getheaderfromfile_buffer;
	$getheaderfromfile_buffer = $tmp;
	chomp($output);
	return $output;
}

###############################################################################
#
# Each header's downgrading method
#
# &regist_downgrading('headers:headers', *func)
#   sub func($name, $value)
#	 returns full header fields
###############################################################################
my %downgrading;
sub regist_downgrading
{
	my ($str, $func) = @_;
	$str =~ tr/A-Z/a-z/;
	foreach my $i (split(/:/, $str)) {
		$downgrading{$i} = $func;
	}
}
my %mimedowngrading;
sub regist_mimedowngrading
{
	my ($str, $func) = @_;
	$str =~ tr/A-Z/a-z/;
	foreach my $i (split(/:/, $str)) {
		$mimedowngrading{$i} = $func;
	}
}
my %decoding;
sub regist_decoding
{
	my ($str, $func) = @_;
	$str =~ tr/A-Z/a-z/;
	foreach my $i (split(/:/, $str)) {
		$decoding{$i} = $func;
	}
}
my %mimedecoding;
sub regist_mimedecoding
{
	my ($str, $func) = @_;
	$str =~ tr/A-Z/a-z/;
	foreach my $i (split(/:/, $str)) {
		$mimedecoding{$i} = $func;
	}
}
###############################################################################
# mailbox_downgrading:
#
#   Input: mailbox
#   Output: ($changed,$newvalue)
#			$changed: 1 or 0
#			$newvalue: downgraded value (comments and mailboxes)
###############################################################################
sub mailbox_downgrading {
	my ($input) = @_;
	my $changed = 0;
	my ($value, $cfws1, $display, $cfws2, $first, $second, $tail);
	my $newvalue;
	$value = $input;
	my $removefmt = 'Internationalized Address %s removed:;';

	($cfws1, $value) = &get_CFWS($value, 1);
	$display = '';
	$cfws2 = '';
	if ($value =~ /^([^(<]*)([(<].*|)$/) {
		$display = $1;
		$value = $2;
		($cfws2, $value) = &get_CFWS($value, 1);
	}
	if (substr($value, 0, 1) ne '<') {
		if (&non_ascii($display)) {
			if ($display =~ /^(.*)([ \t]*:[ \t]*;)$/) {
				$newvalue = $cfws1.&rfc2047_bq('', $1, &rfc2047q_display).$2.$cfws2.&rfc2047incomments($value);
			} else {
				$newvalue = $cfws1.
					sprintf($removefmt,&rfc2047_bq('', $display, &rfc2047q_display)).
					$cfws2.&rfc2047incomments($value);
				$changed = 1;
			}
		} else {
			$newvalue = $cfws1.$display.$cfws2.&rfc2047incomments($value);
		}
		if (&non_ascii($newvalue)) {
			push @error, "bad mailbox(illegal tailing word): $input";
		}
		return ($changed, $newvalue);
	}
	if (&non_ascii($display)) {
		$display = &rfc2047_bq('', $display, &rfc2047q_display).' ';
	}
	if ($value =~ /^<([^ \t<>]+)[ \t]+<[ \t]*([^ \t<>]+)[ \t]*>>(.*)$/) {
		$first = $1;
		$second = $2;
		$value = $3;
		$changed = 1;
		$newvalue = $cfws1.$display.$cfws2.'<'.$second.'>'.&rfc2047incomments($value);
	} elsif ($value =~ /^(<[^ \t<>]+>)(.*)$/) {
		$first = $1;
		$value = $2;
		if (!&non_ascii($first)) {
			$newvalue = $cfws1.$display.$cfws2.$first.&rfc2047incomments($value);
			$changed = 0;
		} else {
			$newvalue = $cfws1.$display.$cfws2.
				sprintf($removefmt,&rfc2047_bq('', $first, &rfc2047q_display)).
				&rfc2047incomments($value);
			$changed = 1;
		}
	} else {
		push @error, "bad mailbox format: $input";
	}
	if (&non_ascii($newvalue)) {
		push @error, "bad mailbox(illegal tailing word): $input";
	}
	return ($changed, $newvalue);
}
###############################################################################
# mailboxes_downgrading: Address header fields value downgrading
#
#   Input: address header field value
#   Output: ($changed,$newvalue)
#			$changed: number of downgraded mailboxes
#			$newvalue: downgraded value (comments and mailboxes)
###############################################################################
sub mailboxes_downgrading {
	my ($value) = @_;
	my @mailboxes = split(/,/, $value);
	my @new;
	my $changed = 0;
	my $c;
	my $i;
	my $v;

	for ($i = 0; $i <= $#mailboxes; $i++) {
		($c, $mailboxes[$i]) = &mailbox_downgrading($mailboxes[$i]);
		$changed += $c;
	}
	$value = join(',', @mailboxes);
	return ($changed, $value);
}
###############################################################################
# Address header fields downgrading
###############################################################################
sub addressheader_downgrading {
	my ($name,$value) = @_;
	my @h = ();

	my ($changed, $value2) = &mailboxes_downgrading($value);
	push @h, &generate_header($name, $value2);
	if ($changed) {
		push @h, &generate_header(&rfc2047_bq("Downgraded-$name", $value, &rfc2047q_unstructured));
	}
	return @h;
}
my $addressheaderlist = 'From:Sender:Reply-to:To:CC:Bcc:Resent-from:Resent-sender:Resent-to:Resent-cc:Return-Path:Delivered-To';
&regist_downgrading($addressheaderlist, *addressheader_downgrading);
&regist_decoding($addressheaderlist, *commentsonly_decoding);

my (%addressheaderlist, %downgraded_addressheaderlist);
&regist_addressheaderlist($addressheaderlist);
sub regist_addressheaderlist
{
	my ($str) = @_;
	$str =~ tr/A-Z/a-z/;
	foreach my $i (split(/:/, $str)) {
		$addressheaderlist{$i} = "downgraded-$i";
		$downgraded_addressheaderlist{"downgraded-$i"} = $i;
	}
}

###############################################################################
# non-ASCII in comments only
###############################################################################
sub commentsonly_downgrading{
	my ($name,$value) = @_;
	return (&generate_header($name, &rfc2047comments($value)));
}
&regist_downgrading('Date:Message-id:In-reply-to:References:Resent-date:Resent-message-id:Mime-version:Content-ID', *commentsonly_downgrading);
&regist_mimedowngrading('Content-ID', *commentsonly_downgrading);

sub commentsonly_decoding{
	my ($name,$value) = @_;
	return (&generate_header($name, &decode_rfc2047comments($value)));
}
&regist_decoding('Date:Message-id:In-reply-to:References:Resent-date:Resent-message-id:Mime-version:Content-ID', *commentsonly_decoding);
&regist_mimedecoding('Content-ID', *commentsonly_decoding);

###############################################################################
# Subject:
###############################################################################
sub unstructured_downgrading {
	my ($name,$value) = @_;
	return (&generate_header(&rfc2047_bq($name, $value, &rfc2047q_unstructured)));
};
&regist_downgrading('subject:content-description', *unstructured_downgrading);
&regist_mimedowngrading('content-description', *unstructured_downgrading);

sub unstructured_decoding {
	my ($name,$value) = @_;
	return (&generate_header($name, &decode_unstructured($value)));
};
&regist_decoding('subject:content-description:downgraded-mail-from:downgraded-rcpt-to', *unstructured_decoding);
&regist_mimedecoding('content-description', *unstructured_decoding);

###############################################################################
# Received:
###############################################################################
sub received_downgrading {
	my ($name,$value) = @_;
	if ($value =~ /^(.*)[ \t]+[Ff][Oo][Rr][ \t]+(.*);(.*)$/) {
		my ($b, $f, $a) = ($1, $2, $3);
		if (&non_ascii($f)) {
			$value = $b .';'. $a;
			return (&generate_header($name, $value));
		}
	}
	#return (&generate_header(('Downgraded-'.$name, $value, &rfc2047q_unstructured)));
	return (&generate_header(&rfc2047_bq('Downgraded-'.$name, $value, &rfc2047q_unstructured)));
};
&regist_downgrading('received', *received_downgrading);
###############################################################################
# Content-Type:, Content-Disposition:
###############################################################################
sub mime_downgrading {
	my ($name,$value) = @_;
	my ($value2);
	if (!&non_ascii($value)) { # no need to convert
		return ();
	}
	$value2 = &rfc2047comments($value);
	if (!&non_ascii($value2)) { # no need to convert
		return (&generate_header($name, $value2));
	}
	my @value = split(/;/, $value2);
	my ($i, $before_param, $attr, $after_attr, $value, $after_value);
	my ($c1, $word, $c2);
	for ($i = 0; $i <= $#value; $i++) {
		$value2 = $value[$i];
		if ($value2 =~ /[^\000-\177]/) {
		if ($value2 =~ /^([ \t]*)([!#$%&'*+-.0-9A-Z^_`a-z{|}~]+)([ \t]*=[ \t]*)([^ \t]+(|.*[^ \t]+))([ \t]*)$/) {
			($before_param, $attr, $after_attr, $value, $after_value) =
			($1, $2, $3, $4, $6);
			($c1, $value) = &get_CFWS($value, 0);
			($word, $value) = &get_word($value);
			($c2, $value) = &get_CFWS($value, 0);
			$value2 = $before_param . &rfc2231_encode($attr, $word). $after_value;
		} else {
			push @error, "unknown non-ASCII: [$value2]";
		}
		$value[$i] = $value2;
		}
	}
	return (&generate_header($name, join(';', @value)));
};

sub mime_downgrading_contenttype {
	my ($name,$input) = @_;
	my ($inputc, $boundary);
	my $inputc = &rfc2047comments($input);
	my @value = split(/;/, $inputc);
	my ($i, $before_param, $attr, $after_attr, $value, $value2, $after_value);
	my ($c1, $word, $c2);
	push @error, "Content-Type contains NonASCII: $value"
		if (&non_ascii($value[0]));
	$multipartflag = ($value[0] =~ /^Multipart\//i);
	$boundary = '';
	for ($i = 1; $i <= $#value; $i++) {
		$value2 = $value[$i];
		if ($value2 =~ /^([ \t]*)([!#$%&'*+-.0-9A-Z^_`a-z{|}~]+)([ \t]*=[ \t]*)([^ \t]+(|.*[^ \t]+))([ \t]*)$/) {
		($before_param, $attr, $after_attr, $value, $after_value) =
			($1, $2, $3, $4, $6);
		($c1, $value) = &get_CFWS($value, 0);
		($word, $value) = &get_word($value);
		($c2, $value) = &get_CFWS($value, 0);
		if ($multipartflag && $attr =~ /^boundary$/i) {
			if (substr($word, 0, 1) eq '"') {
				$boundary = substr($word, 1, length($word)-2);
			} else {
				$boundary = $word;
			}
			$boundary = '--'.$boundary;
			push @boundary, $boundary;
print"[new_boundary: $boundary]\n" if ($mime_debug);
		}
		if (&non_ascii($value2)) {
			$value[$i] = $before_param . &rfc2231_encode($attr, $word). $after_value;
		}
		}
	}
	if (!&non_ascii($input)) {
		return ();
	} elsif (!&non_ascii($value2)) {
		return (&generate_header($name, $inputc));
	} else {
		return (&generate_header($name, join('; ', @value)));
	}
};

sub mime_decoding {
	my ($name,$value) = @_;
	my ($value2);
	$value2 = &decode_rfc2047comments($value);
	my @value = split(/;/, $value2);
	@value = &mime_rfc2231_decode(@value);
	return (&generate_header($name, join('; ', @value)));
};

sub mime_decoding_contenttype {
	my ($name,$input) = @_;
	my ($inputc, $boundary, $changed);
	$changed = 0;
	my $inputc = &decode_rfc2047comments($input);
	my @value = split(/;/, $inputc);
	$multipartflag = ($value[0] =~ /^Multipart\//i);
	$contenttype = $value[0];
	$boundary = '';
	for (my $i = 1; $i <= $#value; $i++) {
		my $value2 = $value[$i];
		if ($value2 =~ /^([ \t]*)([!#$%&'*+-.0-9A-Z^_`a-z{|}~]+)([ \t]*=[ \t]*)([^ \t]+(|.*[^ \t]+))([ \t]*)$/) {
			my ($before_param, $attr, $after_attr, $value, $after_value) =
				($1, $2, $3, $4, $6);
			my ($attrC) = $attr;
			$attrC = tr /A-Z/a-z/;
			my ($c1, $value) = &get_CFWS($value, 0);
			my ($word, $value) = &get_word($value);
			my ($c2, $value) = &get_CFWS($value, 0);
			if ($multipartflag && $attr eq "boundary") {
				if (substr($word, 0, 1) eq '"') {
					$boundary = substr($word, 1, length($word)-2);
				} else {
					$boundary = $word;
				}
				$boundary = '--'.$boundary;
				push @boundary, $boundary;
print"[new_boundary: $boundary]\n" if ($mime_debug);
			} elsif ($attr eq "charset") {
				$value =~ tr /A-Z/a-z/;
				$contenttype_charset = $value;
			}
		}
	}
	@value = &mime_rfc2231_decode(@value);
	return (&generate_header($name, join(';', @value)));
};

sub content_transfer_encoding_downgrading {
	my ($name,$value) = @_;
	$content_transfer_encoding = $value;
	$content_transfer_encoding =~ tr/A-Z/a-z/;
	return ();
};

&regist_downgrading('content-type', *mime_downgrading_contenttype);
&regist_mimedowngrading('content-type', *mime_downgrading_contenttype);
&regist_decoding('content-type', *mime_decoding_contenttype);
&regist_mimedecoding('content-type', *mime_decoding_contenttype);

&regist_downgrading('content-disposition', *mime_downgrading);
&regist_mimedowngrading('content-disposition', *mime_downgrading);
&regist_decoding('content-disposition', *mime_decoding);
&regist_mimedecoding('content-disposition', *mime_decoding);

&regist_downgrading('content-transfer-encoding', *content_transfer_encoding_downgrading);
&regist_mimedowngrading('content-transfer-encoding', *content_transfer_encoding_downgrading);
&regist_decoding('content-transfer-encoding', *content_transfer_encoding_downgrading);
&regist_mimedecoding('content-transfer-encoding', *content_transfer_encoding_downgrading);

###############################################################################
# each header fields downgrading
###############################################################################
sub downgradeeachheader
{
	my ($name, $value) = @_;
	my ($name1) = $name;
	my $sub;

	$name1 =~ tr/A-Z/a-z/;

	$sub = $downgrading{$name1};
	if (defined($sub)) {
		return $sub->($name, $value);
	}
	return (&generate_header(&rfc2047_bq('Downgraded-'.$name, $value, &rfc2047q_unstructured)));
}


###############################################################################
#
# envelope_addr_downgrade($mailfrom)
#
###############################################################################
sub envelope_addr_downgrade($)
{
	my $mailfrom = shift;
	return $mailfrom->{addr} if ($mailfrom->{addr} ne '' && !non_ascii($mailfrom->{addr}));
	return $mailfrom->{altaddr} if ($mailfrom->{altaddr} ne '');
	return '';
}

###############################################################################
#   SMTP Downgrading    MAIL FROM, RCPT To
#   MAIL FROM: <uPath> ALT-ADDRESS=Mailbox [other parameters]
#   input: 'Mail From'|'Rcpt To', SMTP parameters
#   output: (smtp parameters, downgraded header field)
###############################################################################
sub smtp_envelope_generate($$$)
{
	my ($name, $mailfrom, $downgrade) = @_;
	my ($i, $new, $d, $name2, $e);
	my ($addr, $altaddr, @param) = ($mailfrom->{addr}, $mailfrom->{altaddr}, $mailfrom->{param});
	$d = '';
	if ($downgrade) {
		for ($i = 0; $i <= $#param; $i++) {
			if ($param[$i] =~ /^(orcpt=)(.*)$/i) {
				$param[$i] = $1.&xtext_encode($2);
				last;
			}
		}
	}
	if ($downgrade) {
		if (&non_ascii($addr)) {
			return ('', '') if ($altaddr eq '');
			$new = &xtext_decode($altaddr);
			$name2 = $name;
			$name2 =~ s/ /-/g;
			$d = &generate_header(&rfc2047_bq('Downgraded-'.$name2, '<'.$addr.'> <'.$new.'>', &rfc2047q_unstructured));
			$addr = $new;
			$altaddr = '';
		}
		$e = $name.': <'.$addr.'> '.join(' ', @param);
	} else {
		if ($altaddr ne '') {
			$e = $name.': <'.$addr.'> ALT-ADDRESS='.$altaddr.' '.join(' ', @param);
		} else {
			$e = $name.': <'.$addr.'> '.join(' ', @param);
		}
	}
	return ($e, $d);
}
###############################################################################
#
# Header fields downgrading
#
###############################################################################

sub downgrading_init
{
	@error = ();
	@boundary = ();
	$content_transfer_encoding = '';
	$multipartflag = 0;
	$contenttype_charset = '';
	$contenttype = '';
}
###############################################################################
sub print_boundaries
{
	print "[",join(' ', @boundary),"]\n";
}

my $boundary_pattern;
sub update_boundary_pattern
{
	&print_boundaries if ($mime_debug);
	$boundary_pattern = '^('.join('|', @boundary).')(--|)[ \t]*$';
}
###############################################################################
#
# downgrading($fh, $mode)
# returns ( $status, $body8bit, $error_ref, @message)
#
###############################################################################
use constant {
	downgrading_testonly => 0,
	downgrading_8bit => 1,
	downgrading_7bit => 2,
	downgrading_noerror => 0,
	downgrading_error => 1,
	need_to_downgrade => 2
};
sub downgrading
{
	my ($fh, $mode) = @_;
	my ($input, $orig, $name, $name1, $value);
	my $ret = downgrading_noerror;
	my (@h, @error, @header, @body);
	my $body8bit = 0;

	&getheaderfromfile($fh, getheaderfromfile_init);
	while(($orig = &getheaderfromfile($fh, getheaderfromfile_read)) ne '') {
		last if ($orig eq '');
		$input = &unfolding($orig);
		if ($input =~ /^([!-9;-~]+):[ \t]*([^ \t]+.*)$/) {
			$name = $1;
			$name1 = $name;
			$name1 =~ tr/A-Z/a-z/;
			$value = $2;
			@h = ();
			if ($name1 =~ /^downgraded-/) {
				push @error, "Removed $name: $value";
				next;
			}
			if ($name1 eq 'content-type' || $name1 eq 'content-transfer-encoding') {
				$ret = need_to_downgrade if (&non_ascii($value));
				@h = &downgradeeachheader($name, $value);
			} elsif ($mode == downgrading_testonly) {
				$ret = need_to_downgrade if (&non_ascii($value));
				next;
			} elsif (&non_ascii($value)) {
				@h = &downgradeeachheader($name, $value);
			}
			if ($#h < 0) {
				push @header, $orig;
			} else {
				push @header, @h;
			}
		} else {
			push @error, "broken: $input";
		}
	}
	if ($#boundary >= 1) {
		push @error, "Multiple boundary parameter in header fields";
	}
	if ($#boundary < 0) {
		my $bodydata = '';
		while (<$fh>) {
			$bodydata .= $_;
		}
		if ($mode == downgrading_testonly) {
			$body8bit = 1 if (&non_ascii($bodydata));
		} elsif ($mode == downgrading_7bit &non_ascii($bodydata)) {
			$bodydata =~ s/\n/\r\n/g;
			push @body, MIME::Base64::encode_base64($bodydata);
			for (my $i = 0; $i <= $#header; $i++) {
				if ($header[$i] =~ /^content-transfer-encoding:[ \t]*([^ \t]+)(|[ \t].*)$/i) {
					$header[$i] = "Content-Transfer-Encoding: base64";
					last;
				}
			}
		} else {
			push @body, $bodydata;
		}
		$bodydata = '';
	} else {
		my $found;
		my $bodydata = '';
		my @mimeheader = ();
		my $bodyconverted = 0;

		&update_boundary_pattern;
		while(<$fh>) {
			$input = $_;
			chomp;
			if (!/$boundary_pattern/) {
				$bodydata .= $input;
				next;
			}
			$found = 0;
			for ($found = 0; $found <= $#boundary; $found++) {
				last if (/^($boundary[$found])(-+|)[ \t]*/);
			}
			my $endmark = $2;
			if ($found < $#boundary) {
				splice(@boundary, $found + 1);
				&update_boundary_pattern;
			} elsif ($endmark ne '') {
				splice(@boundary, $found);
				&update_boundary_pattern;
			}
			if ($mode == downgrading_testonly) {
				$body8bit = 1 if (&non_ascii($bodydata));
			} elsif ($mode == downgrading_7bit && &non_ascii($bodydata)) {
				if ($#mimeheader >= 0) {
					for (my $i = 0; $i <= $#mimeheader; $i++) {
						if ($mimeheader[$i] =~ /^content-transfer-encoding:[ \t]*([^ \t]+)(|[ \t].*)$/i) {
							$mimeheader[$i] = "Content-Transfer-Encoding: base64";
							last;
						}
					}
				}
				$bodydata =~ s/\n/\r\n/g;
				$bodydata = MIME::Base64::encode_base64($bodydata);
				$bodyconverted = 1;
			}
			if ($#mimeheader >= 0) {
				if ($mode != downgrading_testonly) {
					push @body, join("\n", @mimeheader)."\n\n";
				}
				@mimeheader = ();
			}
			if ($mode != downgrading_testonly) {
				if ($bodydata ne '') {
					push @body, $bodydata;
				}
				push @body, $input;
			}
			$bodydata = '';
			next if ($endmark ne '');
			&print_boundaries if ($mime_debug);
			&getheaderfromfile($fh, getheaderfromfile_init);

			# Parse MIME body part header fields
			$multipartflag = 0;
			$content_transfer_encoding = '';
			while (($orig = getheaderfromfile($fh, getheaderfromfile_read)) ne '') {
				$input = &unfolding($orig);
				my @h = ();
				if ($input =~ /^([!-9;-~]+):[ \t]*([^ \t]+.*)$/) {
					($name, $value) = ($1, $2);
					($name1 = $name) =~ tr/A-Z/a-z/;
					if (&non_ascii($value)) {
						$ret = need_to_downgrade;
						if (defined($mimedowngrading{$name1})) {
							@h = $mimedowngrading{$name1}->($name, $value);
						}
					} elsif ($name1 eq 'content-type' || $name1 eq 'content-transfer-encoding') {
						if (defined($mimedowngrading{$name1})) {
							@h = $mimedowngrading{$name1}->($name, $value);
						}
					}
				}
				if ($#h < 0) {
					push @mimeheader, $orig;
				} else {
					push @mimeheader, @h;
				}
			}
			if ($multipartflag && $mode != downgrading_testonly) {
				&update_boundary_pattern;
				push @body, join("\n",@mimeheader)."\n\n";
				@mimeheader = ();
			}
		}
		if ($bodyconverted) {
			for (my $i = 0; $i <= $#header; $i++) {
				if ($header[$i] =~ /^content-transfer-encoding:[ \t]*([^ \t]+)(|[ \t].*)$/i) {
					$header[$i] = "Content-Transfer-Encoding: 7bit";
					last;
				}
			}
		}
	}
	return ($ret, $body8bit, \@error, join("\n", @header)."\n\n", @body);
}

#my ($r, $b, $error_ref, @message) = &downgrading(*STDIN, downgrading_testonly);
#my ($r, $b, $error_ref, @message) = &downgrading(*STDIN, downgrading_7bit);
#print "result=", $r, "\n";
#print "body8bit=", $b, "\n";
#foreach my $l (@data) {
#	print $l;
#}

# insert a space before and after "(),".
# remove duplicated space
# decode rfc2047 encoded-word which charset=UTF-8
sub canonicalize_address_header_value
{
	my ($v) = @_;
	$v = &decode_rfc2047comments($v);
	my @v = split(/\"/, $v);
	for (my $i = 0; $i <= $#v; $i += 2) {
		$v[$i] =~ y/\t/ /;
		while($v[$i] =~ /^(.*[^ ])([(),].*)$/) {
			$v[$i] = $1.' '.$2;
		}
		while($v[$i] =~ /^(.*[(),])([^ ].*)$/) {
			$v[$i] = $1.' '.$2;
		}
		while($v[$i] =~ /^(.*)  +([^ ].*|)/) {
			$v[$i] = $1.' '.$2;
		}
	}
	$v = join('"', @v);
	if ($v =~ /^(\S+):\s*(\S*.*\S*)\s*$/) {
		my ($n, $vv) = ($1, $2);
		$n =~ y/A-Z/a-z/;
		$v = $n . ':' . $v;
	}
	return $v;
}

sub displaying_technique_2_sub($$)
{
	my ($href, $eref) = @_;
	# $$href[$index]   $#{$href}
	# push @$eref, "error"
	my $removed = 0;
	my ($i, $nameC, @headername, @headervalue, @downgraded);
	for ($i = 0; $i <= $#{$href}; $i++) {
		if ($$href[$i] =~ /^([!-9;-~]+):[ \t]*([^ \t]+.*)$/) {
			my ($name, $value) = ($1, $2);
			($nameC = $name) =~ tr/A-Z/a-z/;
			$headername[$i] = $nameC;
			if (defined($downgraded_addressheaderlist{$nameC})) {
				my $D = &decode_unstructured($value);
				my ($c, $dD) = &mailboxes_downgrading($D);
				my $C = &canonicalize_address_header_value($dD);
				my $rec = {};
				$rec->{name} = $downgraded_addressheaderlist{$nameC};
				$rec->{value} = $C;
				push @downgraded, $rec;
			} elsif (defined($addressheaderlist{$headername[$i]})) {
				$headervalue[$i] = &canonicalize_address_header_value($value);
			}
		}
	}
#	foreach my $k (@downgraded) {
#		print '{',$k->{name},',',$k->{value},"}\n";
#	}
	for ($i = 0; $i <= $#headername; $i++) {
		if (defined($headervalue[$i])) {
			foreach my $k (@downgraded) {
				if ($headername[$i] eq $k->{name} && $headervalue[$i] eq $k->{value}) {
					$$href[$i] = '';
					$removed++;
					last;
				}
			}
		}
	}
	return $removed;
}

##############################################################################
# decoding_downgraded_message($fh)
# returns ( $status, $error_ref, @message)
###############################################################################
use constant {
	decoding_mime => 0,
	decoding_technique_1 => 1,
	decoding_technique_2 => 2,
	decoding_decode_base64 => 4,
	decoding_headeronly => 8,
	decoding_nofolding => 16
};

sub decoding_downgraded_message($$)
{
	my ($fh, $mode) = @_;
	my ($input, $orig, $name, $name1, $value);
	my $ret = downgrading_noerror;
	my (@h, @error, @header, @body);

	my $removed;
	my $downgraded = 0;
	my $cte = '';
	my $decodebase64 = $mode & decoding_decode_base64;
	my $headerdecodemode = $mode & 3;
	&downgrading_init;
	&getheaderfromfile($fh, getheaderfromfile_init);
	while(($orig = &getheaderfromfile($fh, getheaderfromfile_read)) ne '') {
		last if ($orig eq '');
		push @header, &unfolding($orig);
	}
	if ($headerdecodemode == decoding_technique_2) {
		$removed = &displaying_technique_2_sub(\@header);
		if ($removed > 0) {
			for (my $i = 0; $i <= $#header; $i++) {
				if ($header[$i] eq '') {
					splice @header, $i, 1;
					$i--;
				}
			}
		}
	}
	for (my $i = 0; $i <= $#header; $i++) {
		next if ($header[$i] eq '');
		if ($header[$i] =~ /^([!-9;-~]+):[ \t]*([^ \t]+.*)$/) {
			$name = $1;
			$name1 = $name;
			$name1 =~ tr/A-Z/a-z/;
			$value = $2;
			@h = ();
			if ($name1 eq 'content-transfer-encoding') {
				$cte = $value;
			}
			if (defined($decoding{$name1})) {
				@h = $decoding{$name1}->($name, $value);
			} elsif ($name =~ /^downgraded-(.*)$/i) {
				$downgraded++;
				$h[0] = &unstructured_decoding($headerdecodemode!=decoding_mime?$1:$name, $value);
			}
			if ($h[0] ne '') {
				$header[$i] = ($mode & decoding_nofolding) ? &unfolding($h[0]) : $h[0];
			} else {
				$header[$i] = ($mode & decoding_nofolding) ? $header[$i] : &folding($header[$i]);
			}
		} else {
			push @error, "broken: $input";
		}
	}
	if ($#boundary >= 1) {
		push @error, "Multiple boundary parameter in header fields";
	}
	if ($removed > 0) {
		$ret |= 256;
	}
	if ($downgraded > 0) {
		$ret |= 512;
	}
	$cte =~ s/A-Z/a-z/;
	if ($cte ne '' && $cte ne '8bit') {
		$ret |= 1024;
	}
	if ($mode & decoding_headeronly) {
		return ($ret, \@error, @header);
	}
	push @body, join("\n", @header)."\n\n";
	if ($#boundary < 0) {
		my $bodydata = '';
		while (<$fh>) {
			$bodydata .= $_;
		}
		if ($decodebase64 && $contenttype =~ /^(Text|Message)\//i && $content_transfer_encoding eq 'base64') {
			$bodydata = MIME::Base64::decode_base64($bodydata);
			$bodydata =~ s/\r\n/\n/g;
		} elsif ($decodebase64 && $contenttype =~ /^(Text|Message)\//i && $content_transfer_encoding eq 'quoted-printable') {
			$bodydata = MIME::QuotedPrint::decode_qp($bodydata);
		}
		push @body, $bodydata;
	} else {
		my $found;
		my $bodydata = '';
		my @mimeheader = ();
		&update_boundary_pattern;
		while(<$fh>) {
			$input = $_;
			chomp;
			if (!/$boundary_pattern/) {
				$bodydata .= $input;
				next;
			}
			$found = 0;
			for ($found = 0; $found <= $#boundary; $found++) {
				last if (/^($boundary[$found])(-+|)[ \t]*/);
			}
			my $endmark = $2;
			if ($found < $#boundary) {
				splice(@boundary, $found + 1);
				&update_boundary_pattern;
			} elsif ($endmark ne '') {
				splice(@boundary, $found);
				&update_boundary_pattern;
			}
			if ($#mimeheader >= 0) {
				push @body, join("\n", @mimeheader)."\n\n";
				@mimeheader = ();
			}
			if ($decodebase64 && $contenttype =~ /^(Text|Message)\//i && $content_transfer_encoding eq 'base64') {
				$bodydata = MIME::Base64::decode_base64($bodydata);
				$bodydata =~ s/\r\n/\n/g;
			}
			push @body, $bodydata;
			push @body, $input;
			$bodydata = '';
			next if ($endmark ne '');
			&print_boundaries if ($mime_debug);
			&getheaderfromfile($fh, getheaderfromfile_init);
			# Parse MIME body part header fields
			$multipartflag = 0;
			$content_transfer_encoding = '';
			while (($orig = getheaderfromfile($fh, getheaderfromfile_read)) ne '') {
				$input = &unfolding($orig);
				my @h = ();
				if ($input =~ /^([!-9;-~]+):[ \t]*([^ \t]+.*)$/) {
					($name, $value) = ($1, $2);
					($name1 = $name) =~ tr/A-Z/a-z/;
					if (defined($mimedecoding{$name1})) {
						@h = $mimedecoding{$name1}->($name, $value);
					}
				}
				if ($h[0] eq '') {
					push @mimeheader, $orig;
				} else {
					push @mimeheader, $h[0];
				}
			}
			if ($multipartflag) {
				&update_boundary_pattern;
				push @body, join("\n", @mimeheader)."\n\n";
				@mimeheader = ();
			}
		}
		if ($#mimeheader >= 0) {
			push @body, join("\n", @mimeheader)."\n\n";
			@mimeheader = ();
		}
		if ($bodydata ne '') {
			push @body, $bodydata;
		}
	}
	return ($ret, \@error, @body);
}

#my ($r, $error_ref, @message) = &decoding_downgraded_message(*STDIN, decoding_technique_2);
#foreach my $l (@message) {
#	print $l;
#}

1;

=head1 NAME

UTF8SMTP::Downgrading - UTF8SMTP Downgrade/Downgraded Display

=head1 DESCRIPTION


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
