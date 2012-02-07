#!/usr/bin/perl5

###########################################################################
#
# mail.cgi - EAI prototype webmail client
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
my $myname = "mail.cgi";   # CGI file name
my $version = "mail.cgi/fujiwara/20080723";

my $header = "Content-type: text/html; charset=UTF-8\n\n";

# Default value for mail.conf
my %option = ( debug => 0, LogCategory => "local0", TimeZone => "+0000",
	IgnoreUserPath => 1, Passwordfile => "/dev/null" );

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
use UTF8SMTP::MIME;
use UTF8SMTP::SMTP;
use UTF8SMTP::Downgrading;

my $USER = $ENV{'REMOTE_USER'};
my %CGI;
&parse_cgi_header();
###########################################################################
# Parse config file
###########################################################################
if (!defined(%option = parse_config_file($myname, $config, %option))) {
    exit 1;
}

###########################################################################
# Read user database
###########################################################################

my %userdb = &read_userdb($option{UserDBpath}, $option{MaildirPath}, $option{IgnoreUserPath});
&print_userdb(%userdb) if ($option{debug});
my $folderbase = $userdb{$USER}->{path}.'/';

###########################################################################
# set Timezone
###########################################################################
&set_datetime_tz($option{TimeZone}, $option{TimeZoneOffset});

###########################################################################
# Generate mail adddresses
###########################################################################
if ($userdb{$USER}->{user} ne $USER || $userdb{$USER}->{uid} != $< || !-d $folderbase) {
	if ($CGI{mode} eq 'passwd') {
		&change_passwd("");
	} elsif ($CGI{mode} eq 'submit_passwd') {
		&submit_passwd;
	}
	&showloginpage("Error: Not supported user: \"$USER\"");
}
if (!defined($option{altaddr})) {
	$option{altaddr} = $USER.'@'.$option{MyHostName};
}
if (!defined($option{addr})) {
	foreach my $k (keys(%userdb)) {
		if ($userdb{$k}->{user} eq '' && $userdb{$k}->{alias} eq $USER) {
			$option{addr} = $k.'@'.(($option{MyIDNHostName} ne '')?$option{MyIDNHostName}:$option{MyHostName});
			last;
		}
	}
}
if (!defined($option{addr})) {
	$option{addr} = $option{altaddr};
	$option{altaddr} = '';
	$option{envelope} = { addr=>$option{addr} };
} else {
	$option{envelope} = { addr=>$option{addr}, altaddr=>$option{altaddr} };
}
###########################################################################
# Main
###########################################################################
my $default_folder = 'new';

if (!defined($CGI{folder}) || ! ($CGI{folder} =~ /^[a-zA-Z-_\x80-\xff]+$/)) {
	$CGI{folder} = $default_folder;
}

if ($CGI{mode} eq 'decode2' || $CGI{mode} eq 'mime' || $CGI{mode} eq 'orig') {
	&show_message("");
} elsif ($CGI{mode} eq 'remove') {
	&remove_message("");
} elsif ($CGI{mode} eq 'reply' || $CGI{mode} eq 'reply2') {
	&reply_message("");
} elsif ($CGI{mode} eq 'newmail') {
	&edit_message("", 0);
} elsif ($CGI{mode} eq 'Preview_message') {
	&edit_message("", 1);
} elsif ($CGI{mode} eq 'Send_message') {
	&send_message("");
} elsif ($CGI{mode} eq 'refile') {
	&refile_message("");
} elsif ($CGI{mode} eq 'passwd') {
	&change_passwd("");
} elsif ($CGI{mode} eq 'editfolder') {
	&edit_folder("");
} elsif ($CGI{mode} eq 'Create_Folder') {
	&create_folder("");
} elsif ($CGI{mode} eq 'Remove_Folder') {
	&remove_folder("");
} elsif ($CGI{mode} eq 'submit_passwd') {
	&submit_passwd;
} elsif ($CGI{mode} eq 'list' || $CGI{mode} eq 'Discard_message') {
	&show_list('');
} elsif (defined($CGI{mode})) {
	&show_list("Mode=".$CGI{mode}." is not implemented<BR><HR>");
} else {
	&show_list('');
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
	my ($val) = @_;
	my $line;

	$line = $header."<HTML>
<head>
<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">
<title>JPRS EAI Webmail prototype</title>
</head>
<body>
". $Notice.
"email address = ".&htmlescape(&generate_mailbox(\%option))."<HR>\n".
"<A HREF=\"$myname\">[Check new mail]</A>  ".
"<A HREF=\"$myname?mode=newmail\">[Send mail]</A>  ".
"<A HREF=\"$myname?mode=passwd\">[Change Password]</A>  ".
"<A HREF=\"$myname?mode=editfolder\">[Create/Remove Folder]</A>  ".
"<BR>\nFolders: ";
	foreach my $f (&get_folders) {
		$line .= "<A HREF=\"$myname?folder=$f\">[$f] </A>";
	}
	$line .= "<HR>\n";
	if ($val ne "") {
		$line .= "$val<BR>\n";
	}
	$line .= $copyright."</BODY></HTML>\n";
	print $line;
	exit 0;
}

sub showloginpage
{
	my $L = shift;
	&output("$L<BR><HR><A HREF=\"$myname\">enter your username and password</A><BR>");

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

###########################################################################
# Create_Folder
###########################################################################
sub edit_folder
{
    my $L = "Edit folder configuration:<BR>
<FORM ACTION=\"$myname\" method=\"POST\">
Folder: <input type=\"text\" size=\"50\" maxlength=\"50\" name=\"newfolder\" value=\"\"><BR>
<input type=\"submit\" name=\"mode\" value=\"Create_Folder\">
<input type=\"submit\" name=\"mode\" value=\"Remove_Folder\">
</FORM>
";
&output($L);
}

sub create_folder
{
	$CGI{folder} = $default_folder;
	if ($CGI{newfolder} =~ /^[a-zA-Z-_\x80-\xff]+$/) {
		my $d = $folderbase.$CGI{newfolder};
		if (-d $d) {
			show_list('Folder='.$CGI{newfolder}.' exists<BR><HR>');
		} else {
			mkdir $d;
			show_list('Folder='.$CGI{newfolder}.' is created.<BR><HR>');
		}
	} else {
		show_list('Wrong folder name: '.$CGI{newfolder}.'<BR><HR>');
	}
}

sub remove_folder
{
	$CGI{folder} = $default_folder;
	my $n = $CGI{newfolder};
	my $d = $folderbase.$n;
	my $L = '';
	if ($n eq 'new' || $n eq 'cur' || $n eq 'tmp') {
		$L = 'Default folder cannot be removed: '.$n.'<BR><HR>';
	} elsif (!($n =~ /^[a-zA-Z-_]+$/)) {
		$L = 'Wrong folder name: '.$CGI{newfolder}.'<BR><HR>';
	} elsif (! -d $d) {
		$L = 'Folder='.$n.' does not exist<BR><HR>';
	} elsif (rmdir $d) {
		$L = 'Folder='.$n.' is successfully removed<BR><HR>';
	} else {
		$L = 'Folder='.$n.' cannot be removed because '.$!.'<BR><HR>';
	}
	show_list($L);
}

###########################################################################
# Remote message command removes message of folder=$CGI{folder} id=$CGI{id}
###########################################################################
sub remove_message
{
	my $file = $folderbase.$CGI{folder}.'/'.$CGI{id};
	if (-f $file) {
		unlink $file;
		show_list('Folder='.$CGI{folder}.' '.$CGI{id}.' is removed<BR><HR>');
	} else {
		show_list('Folder='.$CGI{folder}.' '.$CGI{id}.' is not exist<BR><HR>');
	}
}

###########################################################################
# Refile message command refiles message folder=$CGI{folder} id=$CGI{id} to $CGI{newfolder}
###########################################################################
sub refile_message
{
	my $file = $folderbase.$CGI{folder}.'/'.$CGI{id};
	my $newdir = $folderbase.$CGI{newfolder};
	my $newfile = $newdir.'/'.$CGI{id};
	if (-f $file && -d $newdir) {
		rename $file, $newfile;
		show_list('Folder='.$CGI{folder}.' '.$CGI{id}.' is refiled to ['.$CGI{newfolder}.']<BR><HR>');
	} else {
		show_list('Folder='.$CGI{folder}.' '.$CGI{id}.' is not exist<BR><HR>');
	}
}

###########################################################################
# Show list command generates mail index page
#
# &show_list($header_html)
###########################################################################
sub generate_mail_index
{
	my $d = $folderbase.$CGI{folder}.'/';
	opendir (D, $d)|| &output("error: opendir $d<BR><A HREF=\"$myname?mode=newmail\">Send mail</A> to yourself to generate your mailbox.");
	my @files = sort ( grep { /^[^.].*/ } (readdir(D)));
	closedir D;
	my $line;
	$line = "<TABLE border=\"1\"><TR><TH>decode<BR>2</TH><TH>mime<BR>decode</TH><TH>orig<BR>inal</TH><TH>status</TH><TH nowrap>Date</TH><TH>From</TH><TH>Subject</TH></TR>\n";
	foreach my $l (@files) {
		my $F;
		open($F, "$d$l") || &output("error: cannot open $d$l: $_");
		my ($ret, $errorref, @header) =
		 	&decoding_downgraded_message($F, decoding_technique_2 | decoding_headeronly | decoding_nofolding);
		close($F);
		my ($from, $subject, $datestr) = ('','','');
		my $downgraded = '';
		if ($ret & 512) { $downgraded .= 'D'; }
		if ($ret & 256) { $downgraded .= 'A'; }
		if ($ret & 1024) { $downgraded .= '7'; }
		$downgraded = '-' if ($downgraded eq '');
		foreach my $l (@header) {
			if ($l =~ /^(\S+):\s+(.*)$/) {
				my ($name, $value) = ($1, $2);
				$name =~ y/A-Z/a-z/;
				if ($name eq "subject") {
					$subject = &htmlescape($value);
				} elsif ($name eq "from") {
					$from = &htmlescape($value);
				} elsif ($name eq "date") {
					$datestr = $value;
				}
			}
		}
		if ($datestr ne '') {
			my ($ss,$mm,$hh,$day,$month,$year,$zone) = strptime($datestr);
			$datestr = sprintf("%d/%d", $month+1, $day);
		}
		$line .= "<TR><TD><A HREF=\"$myname?mode=decode2&folder=$CGI{folder}&id=$l\">show</A></TD>"
	 		."<TD><A HREF=\"$myname?mode=mime&folder=$CGI{folder}&id=$l\">mime</A>"
	 		."<TD><A HREF=\"$myname?mode=orig&folder=$CGI{folder}&id=$l\">orig</A>"
			."</TD><TD>$downgraded</TD><TD>$datestr</TD><TD>$from</TD><TD>$subject</TD></TR>\n";
	}
	$line .= "</TABLE>
status: D indicates Downgraded message. 7 indicates 7bit message<BR>
";
	return $line;
};

sub show_list
{
	my $L = shift;
	$L .= 
		"Mail indexes for $USER folder [".$CGI{folder}."]: ".&generate_mail_index;
	&output($L);
}

###########################################################################
# Get folders
#
# @folder_list = &get_folders();
###########################################################################
sub get_folders
{
	my @files;
	push @files, 'new';
	opendir (D, $folderbase)|| return ();
	push @files, sort ( grep {!/^(\..*|new|cur|tmp)$/ } (readdir(D)));
	closedir D;
	push @files, 'cur';
	push @files, 'tmp';
	return @files;
};

###########################################################################
# Show message command shows mail message of id=$ID 
#
# &show_message()
###########################################################################
sub show_message
{
	my $L = '';
	my $f = $CGI{id};
	my $d = $folderbase.$CGI{folder}.'/';
	my $F; open($F, "$d$f") || &output("error: cannot open $d$f: $_");
	my ($ret, $errorref, @fields);
	if ($CGI{mode} eq 'orig') {
		while($_ = <$F>) {
			push @fields, $_;
		}
	} else {
		($ret, $errorref, @fields) =
	 	&decoding_downgraded_message($F, (($CGI{mode} eq 'decode2')?decoding_technique_2:decoding_mime)|decoding_decode_base64);
	}
	close($F);
	$L = 
#"Show folder=".$CGI{folder}." id=".$CGI{id}."<BR>\n".
		"<A HREF=\"$myname?mode=reply".(($CGI{mode} eq 'decode2')?"2":"")."&folder=$CGI{folder}&id=$f\">[Reply]</A>  ".
		"<A HREF=\"$myname?mode=remove&folder=$CGI{folder}&id=$f\">[Remove]</A> ";
	$L .= 'Refile to: ';
	foreach my $i (&get_folders) {
		if ($i ne $CGI{folder}) {
			$L .= "<A HREF=\"$myname?mode=refile&folder=$CGI{folder}&id=$f&newfolder=$i\">[$i]</A> ";
		}
	}
	$L .= "<BR>\n";
	$L .= "<PRE>";
	foreach my $k (@fields) {
		$k = &htmlescape($k);
		$L .= $k;
	}
	$L .= "</PRE><HR>".&generate_mail_index;
	&output($L);
}
###########################################################################
# Reply message command generates reply message of id=$ID
# and invokes message editor
#
# &reply_message()
###########################################################################
sub reply_message
{
	my $L = '';
	my $f = $CGI{id};
	my $F;
	my $d = $folderbase.$CGI{folder}.'/';
	my $body;
	open($F, "$d$f") || &output("error: cannot open $d$f: $_");
	my ($ret, $errorref, @header) =
	 &decoding_downgraded_message($F, (($CGI{mode} eq 'reply2')?decoding_technique_2:decoding_mime) | decoding_headeronly | decoding_nofolding);
	my ($from, $to, $cc, $subject) = ('','','','');
	foreach my $l (@header) {
		if ($l =~ /^(\S+):\s+(.*)$/) {
			my ($name, $value) = ($1, $2);
			$name =~ y/A-Z/a-z/;
			if ($name eq "subject") {
				$subject = $value;
			} elsif ($name eq "to") {
				$to = $value;
			} elsif ($name eq "cc") {
				$cc = $value;
			} elsif ($name eq "from") {
				$from = $value;
			}
		}
	}
	seek $F, 0, 0;
	my ($ret, $errorref, @header) =
	 &decoding_downgraded_message($F, (($CGI{mode} eq 'reply2')?decoding_technique_2:decoding_mime) | decoding_nofolding | decoding_decode_base64);
	$body = join('',@header);
	close $F;
	$CGI{subject} = "Re: ".$subject;
	$CGI{from} = '';
	$CGI{to} = $from;
	if ($to ne '' && $cc ne '') {
		$CGI{cc} = $to .','. $cc;
	} else {
		$CGI{cc} = $to.$cc;
	}
	$body =~ s/\n/\n\> /g;
	$body = '> '.$body;
	$CGI{body} = $body;
	&edit_message("", 0);
}
sub edit_userconfig
{
    my $L = "Edit user configuration:<BR><HR>
<FORM ACTION=\"$myname\" method=\"POST\">
Internationalized Address: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"address\" value=\""
.$option{address}."\"><BR>
Alt-Address: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"address\" value=\""
.$option{altaddress}."\"><BR>
<input type=\"submit\" name=\"mode\" value=\"submit_userconfig\">
</FORM>
";
&output($L);
}

sub change_passwd
{
	my $L = shift;
	$L .= "Change password:<BR>
<FORM ACTION=\"$myname\" method=\"POST\">
Password: <input type=\"password\" size=\"20\" maxlength=\"60\" name=\"passwd1\" value=\"\"><BR>
Retype Password: <input type=\"password\" size=\"20\" maxlength=\"60\" name=\"passwd2\" value=\"\"><BR>
<input type=\"submit\" name=\"mode\" value=\"submit_passwd\">
</FORM>
";
&output($L);
}

sub submit_passwd
{
	if (!defined($CGI{passwd1}) || $CGI{passwd1} eq '' || ($CGI{passwd1} ne $CGI{passwd2})) {
		&change_passwd("Wrong password input. Password change request failed.<BR><HR>");
	}
	my @textpasswd = (DBType => 'Text', DB => $option{Passwordfile}, Server => 'apache');
	my $user = new HTTPD::UserAdmin @textpasswd;
	if ($user->update($USER, $CGI{passwd1})) {
		$user->commit;
		&showloginpage("Password changed<BR><HR>");
	} else {
		&change_passwd("Password change failed. Contact to administrator.<BR><HR>");
	}
}

sub generate_message
{
	my ($msg, $error, $mailfrom, $to, $cc, $error1, @cc, @rcptto);
	$error = '';
	$mailfrom = &parse_mailbox($CGI{from});
	$msg = 'From: '.$CGI{from}."\n";
	if ($mailfrom eq '') { $error .= "From is empty"; }
	($to, $error1, @rcptto) = &parse_mailboxes($CGI{to});
	$msg .= 'To: '.$to."\n" if ($to ne '');
	$error .= $error1;
	($cc, $error1, @cc) = &parse_mailboxes($CGI{cc});
	$error .= $error1;
	$msg .= 'Cc: '.$cc."\n" if ($cc ne '');
	if ($CGI{messageid} eq '') {
		$CGI{messageid} = '<'.$$.'.'.$USER.'@'.$option{MyHostName}.'>';
	}
	push @rcptto, @cc;
	if ($#rcptto < 0) {
		$error .= "To, CC headers are empty\n";
	}
	if ($CGI{MyCopy} == 1) {
		push @rcptto, $option{envelope};
	}
	$msg .= 'Subject: '.$CGI{subject}."\n" if ($CGI{subject} ne '');
	$msg .= 'Message-Id: '.$CGI{messageid}."\n";
	my $lt = &datetime_string(time);
	$msg .= 'Date: '.$lt."\n";
	my $sender = &generate_mailbox(\%option);
	if ($CGI{from} ne $sender) {
		$msg .= "Sender: $sender\n";
	}
	if (&non_ascii($CGI{body})) {
		$msg .= "Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n";
	} else {
		$msg .= "Content-Type: text/plain; charset=US-ASCII\nContent-Transfer-Encoding: 7bit\n";
	}
	$msg .= "X-Mailer: $version\n";
	$msg .= "\n".$CGI{body}."\n";
	return ($error, $msg, $mailfrom, @rcptto);
}

sub edit_message
{
	my $L = shift;
	my $mode = shift;
	if ($mode) {
		my ($error, $msg, $mailfrom, @rcptto) = &generate_message;
		if ($error ne '') {
			$L .= "Error:<BR><PRE>";
			foreach my $k (split(/\n/, $error)) {
				$L .= "        ".&htmlescape($k)."\n";
			}
			$L .= "<HR>\n";
		}
		$L .= "Generated envelope and message:<PRE>Mail From: ".&htmlescape(&generate_envelope($mailfrom))."\n";
		foreach my $k (@rcptto) {
			$L .= "RCPT To: ".&htmlescape(&generate_envelope($k))."\n";
		}
		$L .= "\n".&htmlescape($msg)."</PRE><HR>\n";
	} else {
		$CGI{MyCopy}='1';
	}
$L .= "Message editor:<BR>
<FORM ACTION=\"$myname\" method=\"POST\">
<input type=\"submit\" name=\"mode\" value=\"Preview_message\"><BR>
<input type=\"submit\" name=\"mode\" value=\"Send_message\"><BR>
<input type=\"submit\" name=\"mode\" value=\"Discard_message\"><BR>
From: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"from\" value=\""
.&htmlescape(($CGI{from}eq'')?&generate_mailbox(\%option):$CGI{from})."\"><BR>
To: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"to\" value=\""
.&htmlescape($CGI{to})."\"><BR>
CC: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"cc\" value=\""
.&htmlescape($CGI{cc})."\"><BR>
Subject: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"subject\" value=\""
.&htmlescape($CGI{subject})."\"><BR>
Message-Id: <input type=\"text\" size=\"80\" maxlength=\"255\" name=\"messageid\" value=\""
.&htmlescape($CGI{messageid})."\"><BR>
<input type=\"checkbox\" name=\"MyCopy\" value=\"1\" ".($CGI{MyCopy} eq "1" ?"checked=\"checked\"":"").">Bcc to me<BR>
Message: <BR>
<textarea name=\"body\" cols=80 rows=1000>".&htmlescape($CGI{body})."</textarea><BR>
</FORM>
";
&output($L);
}

sub send_message
{
	my ($error, $msg, $mailfrom, @rcptto) = &generate_message;
	my $tmpfile = $option{tmpdir}.'msg.'.$$;
	open (F, ">$tmpfile") || &edit_message("Error: Cannot write temporary file: $tmpfile<BR>");
	print F $msg;
	close(F);
	my $smtpfrom = "localhost (mail.cgi user=$USER)";
	my @error = &send_messages($tmpfile, $option{Myname}, $smtpfrom, $mailfrom, @rcptto);
	if ($#error >= 0) {
	    &edit_message("Cannot send: ".&htmlescape(join(",",@error)).".<BR><HR>");
	}
	unlink $tmpfile;
	&show_list("Successfully sent the message<BR><HR>");
}

1;

=head1 NAME

mail.cgi - EAI Prototype Webmail Client

=head1 DESCRIPTION

EAI Prototype Webmail Client

This is an implementation of draft-ietf-eai-smtpext,
draft-ietf-eai-utf8headers, draft-ietf-eai-downgrade,
draft-fujiwara-eai-downgraded-display-00.

=head1 Instration

 1. First, prepare Web server and SMTPreceiver, Submission program.
    - This program requires CGI and Basic authentication.
    - HTTPD::UserAdmin module is required.
    - UTF8SMTP:: modules are required.

 2. Edit two lines:
      BEGIN { use lib '/home/eai/lib'; };
      my $config = "/home/eai/bin/mail.conf";

 3. put this CGI program into WWW directory
    Also prepare basic authentication for this CGI program.

 4. Write config file: mail.conf.

 It contains colon sparated field name and field value.
 The field name field is composed of the field name and the program name. 
 Two fields are separated by '@'.
 Program name sub field may be omitted.
 Don't include useless spaces or comments.
 The line starts with '#' character is treated as comment line.

 The configuration file is shared with SMTPreceiver, Submission,
 POP3d, mail.cgi.

       Passwordfile:     password file for Basic Authentication (read/write)
       UserDBpath:       SMTPreceiver's userdb path (read only)
       MaildirPath:      SMTPreceiver's MaildirPath (read/write)
       LogCategory:      Logging category [local0]
       MyHostName:       ASCII hostname
       MyIDNHostName:    IDN hostname written by UTF-8 encoding
       tmpdir:           temporary directory (writable)
       TimeZone:         Timezone written in Date header field (+0900)
       TimeZoneOffset:   Time differences from GMT. (32400)

  5. Generate Passwordfile.

  6. Operation:
     - Add user
         User's UID in userdb must be equal to WWW CGI UID.
         If the CGI runs user 80,
          the UID written in SMTPreceiver's userdb is 80.
         Real username must be ASCII.
         UTF-8 username must be aliases for the ASCII username.
         Add user entry for the password file using htpasswd command.

=head1 Usage

  - If your mail directry is not exist, send dummy mail to your address.

  - After logged in, message indexes are shown. (Show indexes)
    Each index contains Date, From, Subject, Status,
    'show', 'mime', 'orig' links.

    - 'show' link shows email message with displaying downgraded message.
      - with 'Reply', 'Remove' and 'Refile to:' links.
        - 'Remove' link removes the message.
        - 'Reply' link generates reply message and invokes message editor.
        - 'Refile to:' links refiles the message to specified folder.

    - 'mime' link shows email message with mime decoding.
      - with 'Reply', 'Remove' and 'Refile to:' links.
        - 'Remove' link removes the message.
        - 'Reply' link generates reply message and invokes message editor.
        - 'Refile to:' links refiles the message to specified folder.

    - 'orig' link shows the original message.
      - with 'Reply', 'Remove' and 'Refile to:' links.
        - 'Remove' link removes the message.
        - 'Reply' link generates reply message and invokes message editor.
        - 'Refile to:' links refiles the message to specified folder.

  - You can move another folders using 'Folders:' links.

  - 'Send mail' link invokes message editor.

  - Message Editor:
   - Fill From:, To:, CC:, Subject:, Message text boxes.
   - Pressing Preview_message button shows generated envelope and message.
   - Pressing Send_message button sends the message.
   - Pressing Discard_message button discards the message.

  - Create/Remove Folder link shows edit folder configuration page.
   - In the page, you can create/remove folders.

=head1 Bugs

 This program may have many problems.
 If you find any problem, please contact to the author.

 Non-ASCII check is achived by /[^000-177]/.
 Only support for UTF-8. Other character encoding is ignored.

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
