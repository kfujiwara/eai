#!/usr/bin/perl5

###########################################################################
#
# admin.cgi - User registration tool for EAI prototype webmail client
#
# Copyright (c) 2008  Japan Registry Services Co., LTD. All Rights Reserved.
#
# Author: Kazunori Fujiwara <fujiwara@jprs.co.jp> <fujiwara@wide.ad.jp>
#
# Copyright and License are at the end of this file. 
# Documentation is avaiable by "perldoc"
#
my $Notice = "Warning: This web mail system is a prototype implementation for EAI work.<BR>Use of this program is limited to test purpose only.<BR><HR>";
my $copyright = "<HR>Copyright(c) 2007,2008 Japan Registry Services Co., Ltd. All rights reserved.<BR>
Author and Contact: <A HREF=\"mailto:fujiwara\@jprs.co.jp\">Kazunori Fujiwara</A>
";
#
###########################################################################
# Change this 2 lines for your system configuration (path).
###########################################################################
BEGIN { use lib '/home/eai/lib'; };
my $config = "/home/eai/bin/mail.conf";
###########################################################################
# Constants
###########################################################################
my $myname = "admin.cgi";   # CGI file name
my $version = "admin.cgi/fujiwara/20080625";

my $header = "Content-type: text/html; charset=UTF-8\n\n";

# Default value for mail.conf
my %option = ( debug => 0, LogCategory => "local0", TimeZone => "+0000",
	www_uid => 9999,
	Passwordfile => "/dev/null" );

###########################################################################
# Perl libraries
###########################################################################
require v5.8.8;
use Carp;
use strict;
use Socket;
use Getopt::Std;
use Date::Parse;
use HTTPD::UserAdmin();
use UTF8SMTP::CONFIG;

my $USER = $ENV{'REMOTE_USER'};
my %CGI;
&parse_cgi_header();
###########################################################################
# Parse config file
###########################################################################
if (!defined(%option = parse_config_file($myname, $config, %option))) {
    exit 1;
}
&print_option(%option) if ($option{debug} > 1);
###########################################################################
# Read user database
###########################################################################

my %userdb = &read_userdb($option{UserDBpath}, $option{MaildirPath}, 0);
&print_userdb(%userdb) if ($option{debug});

###########################################################################
# Main
###########################################################################
if ($option{Administrator} eq '' || $option{Administrator} ne $USER) {
	&error('You are not allowed to use this tool.');
}
if ($CGI{mode} eq 'submit') {
	&register_user();
} else {
	&error('');
}
exit 0;

###########################################################################
# Display subroutines
###########################################################################
sub debug
{
	my ($val) = @_;
	my $i;

	print $header;
	print $Notice;
	if ($val ne "") {
		print "$val<BR>\n";
	}
	foreach my $a (keys(%CGI)) {
	    print "$a: ",$CGI{$a},"<BR>\n";
	}
	print "<HR>\n";
	foreach my $a (keys(%option)) {
	    print "$a: ",$option{$a},"<BR>\n";
	}
	exit;
}

sub output
{
	my $val = shift;

	print $header."<HTML>
<head>
<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">
<title>UTF8SMTP Webmail prototype</title>
</head>
<body>
";
	print $Notice;
	if ($val ne "") {
		print "$val<BR>\n";
	}
	print $copyright;
	print "</BODY></HTML>\n";
	exit 0;
}

###########################################################################
# Parse CGI header
#
# $USER = Username (authenticated by basic authentication)
# $CGI{name} = CGI parameter
###########################################################################

sub parse_cgi_header
{
    my ($n, $CGIINPUT);
    if ($ENV{REQUEST_METHOD} eq "POST") {
	$n=read( STDIN, $CGIINPUT, $ENV{CONTENT_LENGTH} );
	# user=a&passwd=b&logout=1
    } elsif ($ENV{REQUEST_METHOD} eq "GET") {
	#REQUEST_URI = /cgi-bin/auth.pl?user=a&passwd=b
	($n, $CGIINPUT) = split(/\?/, $ENV{REQUEST_URI}, 2);
    }
    foreach my $lines (split(/&/, $CGIINPUT)) {
	my ($key, $val) = split(/=/, $lines, 2);
	$val =~ tr/+/ /;
	$val =~ s/%([0-9a-fA-F][0-9a-fA-F])/pack("C",hex($1))/eg;
	$CGI{$key} = $val;
    }
    return;
}

sub htmlescape
{
	my $k;
	$k = shift;
	$k =~ s/\&/\&amp;/g;
	$k =~ s/\</\&lt;/g;
	$k =~ s/\>/\&gt;/g;
	$k =~ s/\"/\&quot;/g;
	return $k;
}

sub error
{
    my $L = shift;
    if ($L ne '') {
	$L .= '<BR><HR>';
    }
   $L .= "Register new user:<BR>
<FORM ACTION=\"$myname\" method=\"POST\">
ASCII Address: <input type=\"text\" size=\"64\" maxlength=\"64\" name=\"address1\" value=\"\"><BR>
Internationalized Address: <input type=\"text\" size=\"64\" maxlength=\"64\" name=\"address2\" value=\"\"><BR>
Password: <input type=\"text\" size=\"64\" maxlength=\"64\" name=\"passwd1\" value=\"\"><BR>
Re-enter Password: <input type=\"text\" size=\"64\" maxlength=\"64\" name=\"passwd2\" value=\"\"><BR>
<input type=\"submit\" name=\"mode\" value=\"submit\">
</FORM>
";
&output($L);
}

sub register_user
{
	if (!defined($CGI{passwd1}) || $CGI{passwd1} eq '' || ($CGI{passwd1} ne $CGI{passwd2})) {
		&error("Wrong password input. Password change request failed.");
	} elsif ($CGI{address1} eq '') {
		&error("Empty ASCII address is disallowed.");
	} elsif (!($CGI{address1} =~ /^[0-9A-Za-z-]+$/)) {
		&error("ASCII address contains disallowed characters. Allowed characters are '0-9a-zA-Z-'.");
	} elsif (defined($userdb{$CGI{address1}})) {
		&error("ASCII address ".$CGI{address1}." is already used.");
	} elsif (!($CGI{address2} =~ /^[-0-9a-zA-Z\x80-\xff]+$/)) {
		&error("non-ASCII address contains disallowed characters. Allowed characters are '0-9a-zA-Z- and UTF-8 non-ASCII characters'.");
	} elsif (defined($userdb{$CGI{address2}})) {
		&error("Internationalized address ".$CGI{address2}." is already used.");
	} else {
		open(F, '>>', $option{UserDBpath}) || &error("Cannot open user database file");
		print F 'R:'.$CGI{address1}.'::'.$option{www_uid}.':'."\n";
		print F 'A:'.$CGI{address2}.':'.$CGI{address1}."\n";
		close(F);
		my $userpath = $option{MaildirPath}.'/'.$CGI{address1};
		mkdir $userpath, 0700;
		mkdir $userpath.'/new', 0700;
		mkdir $userpath.'/cur', 0700;
		mkdir $userpath.'/tmp', 0700;
		my @textpasswd = (DBType => 'Text', DB => $option{Passwordfile}, Server => 'apache');
		my $user = new HTTPD::UserAdmin @textpasswd;
		if ($user->add($CGI{address1}, $CGI{passwd1})) {
			$user->commit;
			&error("User added: $CGI{address1}");
		}
		&error("User registration failed. Contact to administrator.");
	}
}

1;

=head1 NAME

admin.cgi - User registration tool for EAI prototype webmail client

=head1 DESCRIPTION

User registration tool

=head1 Instration

=head1 Usage

=head1 Bugs

 This program may have many problems.
 If you find any problem, please contact to the author.

=head1 Author

  Kazunori Fujiwara <fujiwara@jprs.co.jp> <fujiwara@wide.ad.jp>

=head1 Copyright and License

Copyright(c) 2008 Japan Registry Services Co., Ltd.
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
   "Copyright(c) 2008  Japan Registry Service Co., Ltd.
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
