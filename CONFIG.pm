# $Id: CONFIG.pm,v 1.15 2008/07/01 04:08:43 fujiwara Exp $
#
# Author: Kazunori Fujiwara
# Contact: <fujiwara@jprs.co.jp>, <fujiwara@wide.ad.jp>
#
# Copyright and License are at the end of this file. 
# Documentation is avaiable by "perldoc"

package UTF8SMTP::CONFIG;
use strict;
use warnings;
use Sys::Syslog;
use Exporter;
our (@ISA, @EXPORT, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(logmsg_die logmsg parse_config_file print_option read_userdb print_userdb);
@EXPORT_OK   = qw();

sub logmsg_die($)
{
	&logmsg(@_);
	exit 1;
}
sub logmsg($)
{
	my ($arg) = @_;
	if ($arg =~ /[^\000-\177]/) {
		while($arg =~ /^([\000-\177]*)([^\000-\177])(.*)$/) {
			$arg = $1.sprintf("\\x%02x", ord($2)).$3;
		}
	}
	syslog("info", "%s", $arg);
}

sub parse_config_file($$%)
{
	my ($progname_path, $file, %option) = @_;
	my ($dir, $progname);
	if ($progname_path =~ /^(.*\/)([^\/]+)$/) {
		$dir = $1;
		$progname = $2;
	} else {
		$dir = '';
		$progname = $progname_path;
	}
	my $path;

	$option{progname} = $progname;
	$option{progdir} = $dir;

	if ($file eq '') {
	    $path = $dir . 'mail.conf';
	} elsif ($file =~ /^\//) {
		$path = $file;
	} else {
		$path = $dir.$file;
	}
	if (!open (F, "$path")) {
	    openlog($progname, "ndelay,pid", $option{LogCategory});
	    &logmsg("No config file: $file");
	    return %option;
	}
	while(<F>) {
		chomp;
		next if (/^#/);
		if (/^([^:@]+)(|@[^:@]*):\s*(\S*.*)\s*$/) {
			if ($2 eq '' || $2 eq '@' || $2 eq '@'.$progname) {
				$option{$1} = $3;
			}
		} else {
		    openlog($progname, "ndelay,pid", $option{LogCategory});
		    &logmsg("syntax error: $_");
		    return %option;
		}
	}
	close(F);
	openlog($progname, "ndelay,pid", $option{LogCategory});
	&print_option(%option) if ($option{debug} > 1);

	return %option;
}

sub print_option(%)
{
    my (%option) = @_;

	foreach my $k (keys(%option)) {
		&logmsg("$k = [$option{$k}]");
	}
}

sub print_userdb
{
	my (%userdb) = @_;
	foreach my $k (keys(%userdb)) {
		if ($k eq '') {
			logmsg("default alias -> ".$userdb{$k}->{alias});
		} elsif ($k eq $userdb{$k}->{user}) {
			logmsg("user $k uid ".$userdb{$k}->{uid}." path ".$userdb{$k}->{path});
		} else {
			logmsg("alias $k -> ".$userdb{$k}->{alias});
		}
	}
}

sub read_userdb
{
	my ($file, $maildirpath, $ignore_user_path) = @_;
	my %userdb;

	open (F, "$file") || logmsg_die("cannot open $file");
	while($_ = <F>) {
		chomp;
		my ($flag, $user, $passwd, $uid, $path) = split(/:/);
		if ($flag eq "R") {
			if ($ignore_user_path ne 0 || $path eq '') {
			    $path = $maildirpath. '/' . $user;
			} elsif (!($path =~ /^\//)) {
			    $path = $maildirpath. '/'. $path;
			}
			$userdb{$user} = { user => $user, uid => $uid, path => $path };
		} elsif ($flag eq "A") {
			$userdb{$user} = { user => '', alias => $passwd };
		}
	}
	close(F);
	return %userdb;
}

1;

=head1 NAME

UTF8SMTP::CONFIG - Config and logging support module for UTF8SMTP

=head1 DESCRIPTION

This is support subroutines for UTF8SMTP implementation.

=head1 USAGE

 TBD

=head1 Bugs

 This program may have many problems.
 If you find any problem, please contact to the author.

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
