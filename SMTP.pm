# $Id: SMTP.pm,v 1.27 2008/08/26 09:19:51 fujiwara Exp $
#
# SMTP protocol package for UTF8SMTP.
#
#    RFC 2821
#    draft-ietf-eai-smtpext-11.txt
#
# Author: Kazunori Fujiwara
# Contact: <fujiwara@jprs.co.jp>, <fujiwara@wide.ad.jp>
#
# Copyright and License are at the end of this file. 
# Documentation is avaiable by "perldoc"

package UTF8SMTP::SMTP;
use strict;
use Socket;
use Net::LibIDN;
use Net::DNS;
use Exporter;
use UTF8SMTP::MIME;
use UTF8SMTP::Downgrading;
use UTF8SMTP::CONFIG;
our @ISA = qw(Exporter);
our @EXPORT      = qw(readline transport_error transport_7bit transport_8bit transport_utf8smtp getsmtpresponse connect_mx connect_mx_ehlo parse_mailfrom sendcmd sendcmd2 mailaddr2domain getconnectfrom send_messages connectserver parse_mailboxes parse_mailbox);
our @EXPORT_OK   = qw();

use constant {
	transport_error => -1,
	transport_7bit => 0,
	transport_8bit => 1,
	transport_utf8smtp => 2,
};

my $smtp_debug = 0;
my $resolver = Net::DNS::Resolver->new;

###############################################################################
#
###############################################################################
sub readline
{
	my $fh = shift;
	my $timeout = shift;
	my $msg = shift;

	$msg = 'alarm' if ($msg eq '');
	$timeout = 60 if ($timeout eq '');

	local $SIG{ALRM} = sub { &logmsg_die($msg)};
	alarm($timeout);
	my $ret = <$fh>;
	alarm(0);
	return $ret;
}

###############################################################################
# from SMTPsender
###############################################################################
# read from socket
#   and parse SMTP response
#      $return[0] = response value
#      $return[1..n] = response string
sub getsmtpresponse
{
	my @response;
	my $value;
	my $next;
	my $str;
	my $pvalue = undef;
	my ($socket) = @_;

	do {
		my $line = <$socket>;
		chomp($line);
		chop($line) if ($line =~ /\r$/);
		return () unless ($line =~ /^(\d\d\d)(.)(.*)$/);
		$value = $1;
		$next = $2;
		$str = $3;
		push @response, $str;
		if (defined($pvalue)) {
			if ($pvalue != $value) {
				&logmsg_die("response value $value is not $pvalue: $line");
			}
		} else {
			$pvalue = $value;
		}
	} while($next eq "-");

	return ($value, @response);
}
sub connect_mx
{
	my ($host, $fh, $ipaddr, $proto);
	my ($mailaddr) = @_;
	$host = &mailaddr2domain($mailaddr);
	return (undef, "IDN:$host is not resolvable") if ($host eq '');
	my @mx = mx($resolver, $host);
	if ($#mx < 0) {
		$mx[0] = Net::DNS::RR->new("$host. 3600 IN MX 0 $host.");
	} else {
		@mx = sort { $a->preference <=> $b->preference } @mx;
	}
&logmsg("connect_mx:C:$mailaddr:$host") if ($smtp_debug>1);
	if ($smtp_debug > 1) {
		foreach my $rr (@mx) {
			&logmsg("MX($host) = ". $rr->preference. " ". $rr->exchange);
		}
	}
	foreach my $rr (@mx) {
		my ($name,$aliases,$addrtype,$length,@addrs) =
			gethostbyname($rr->exchange);
		for my $addr (@addrs) {

			my $proto = getprotobyname('tcp');
			socket($fh, PF_INET, SOCK_STREAM, $proto) || &logmsg_die("$mailaddr: socket: $!");
			my $sin = sockaddr_in(25,$addr);
			if (connect($fh,$sin)) {
				select($fh);
				$| = 1;
				select(STDOUT);
				&logmsg("$mailaddr connected to ".inet_ntoa($addr)) if ($smtp_debug > 1);
				return ($fh, inet_ntoa($addr));
			}
			close($fh);
		}
		return (undef, "Cannot connect: $mailaddr");
	}
	return (undef, "DNS resolv error: $host");
}
sub connectserver
{
	my($host,$port) = @_;
	my $socket;
	my @host = split(/:/, $host);
	$host = $host[0];
	$port = $host[1] if ($host[1] ne '');
	$port = 587 if ($port eq '');
	my $ipaddr = inet_aton($host) || return "";
	my $proto = getprotobyname('tcp');
	socket($socket, PF_INET, SOCK_STREAM, $proto) || return "";
	my $sin = sockaddr_in($port,$ipaddr);
	connect($socket,$sin) || return "";
	select($socket);
	$| = 1;
	select(STDOUT);
	return $socket;
}
####################################################################
# &connect_mx_ehlo("remote_domain_part", "my_name")
# returns ($status, $fh, $greetinghostname, $ipaddr)
#
#  status: transport_error...connection failed
#	   transport_7bit, transport_8bit, transport_utf8smtp
####################################################################

sub connect_mx_ehlo
{
	my ($mailaddr, $me, $enable_tls) = @_;
	my ($status, $fh, $greetinghost); # Output of this function
	my $error;
	my (%features, $name, $value);
	my @response;

	$status = transport_error;
	$greetinghost = '';

	($fh, $error) = &connect_mx($mailaddr);
	if (!defined($fh)) {
	    $error = "cannot connect to $mailaddr: $error";
	    return ($status, $fh, $greetinghost, $error);
	}
	&logmsg("connection succed to $error for $mailaddr\n") if ($smtp_debug);
	@response = &getsmtpresponse($fh);
	&logmsg("recv: ".join(',', @response)) if ($smtp_debug);
	if ($response[0] != 220) {
	    $error = "remote host for $mailaddr ($error) status: ".$response[0];
	    return ($status, $fh, $greetinghost, $error);
	}
	($greetinghost) = split(/ /, $response[1]);
	&logmsg("send: EHLO $me") if ($smtp_debug);
	print $fh "EHLO $me\r\n";
	@response = &getsmtpresponse($fh);
	($name, $value) = split(/ /, $response[1]);
	if ($name ne $greetinghost) {
		&logmsg("remote greetinghost is changed: $greetinghost -> $name");
	}
	&logmsg("recv: ".join(',', @response)) if ($smtp_debug);
	shift @response;
	foreach (@response) {
		($name, $value) = split(/ /, $_);
		$name =~ tr /a-z/A-Z/;
		$features{$name} = ($value eq '') ? 1 : $value;
	}
	if ($enable_tls > 0 && defined($features{'STARTTLS'})) {
		use IO::Socket::SSL;
		print $fh "STARTTLS\r\n";
		@response = &getsmtpresponse($fh);
		my $new = IO::Socket::SSL->new_from_fd($fh, SSL_use_cert => undef);
		&logmsg("$mailaddr has STARTTLS. Try to enable TLS");
		if (!$new) {
		    &logmsg("IO::Socket::SSL : ".IO::Socket::SSL::errstr());
		    close($fh);
		    return &connect_mx_ehlo($mailaddr, $me, 0);
		}
		$fh = $new;
		&logmsg("STARTTLS: send: EHLO $me") if ($smtp_debug);
		print $fh "EHLO $me\r\n";
		@response = &getsmtpresponse($fh);
		&logmsg("STARTTLS:recv:".join(' ',@response)) if ($smtp_debug);
		($name, $value) = split(/ /, $response[1]);
		if ($name ne $greetinghost) {
		    &logmsg("remote greetinghost is changed: $greetinghost -> $name");
		}
		&logmsg("recv: ".join(',', @response)) if ($smtp_debug);
		shift @response;
		undef %features;
		foreach (@response) {
		    ($name, $value) = split(/ /, $_);
		    $name =~ tr /a-z/A-Z/;
		    $features{$name} = ($value eq '') ? 1 : $value;
		}
	}
	if (!defined($features{'8BITMIME'})) {
		$status = transport_7bit;
	} elsif (!defined($features{'UTF8SMTP'})) {
		$status = transport_8bit;
	} else {
		$status = transport_utf8smtp;
	}
	return ($status, $fh, $greetinghost, $error);
}

sub parse_mailfrom($)
{
	my ($param) = @_;
	my ($addr, $altaddr, @param, $i);
	$param =~ s/\t/ /g;
	@param = split(/ /, $param);
	if ($#param < 0) {
	    return undef;
	}
	$addr = $param[0];
	$altaddr = '';
	splice(@param, 0, 1);
	for ($i = 0; $i <= $#param; $i++) {
		if ($param[$i] eq '') {
			splice(@param, $i,1);
		} elsif ($param[$i] =~ /^alt-address=(.*)$/i) {
			$altaddr = $1;
			splice(@param, $i,1);
			last;
		}
	}
	if ($addr ne "<>") {
		if ($addr =~ /^<(\S+)>$/) {
			$addr = $1;
		}
	}
	if (!($addr =~ /^\S+@\S+$/)) {
		return undef;
	}
	if ($altaddr ne '' && !($altaddr =~ /^\S+@\S+$/)) {
		return undef;
	}
	return { addr => $addr, altaddr=>$altaddr, param=>@param};
}

sub sendcmd
{
	my ($fh, $msg) = @_;
	print $fh $msg."\r\n";
	&logmsg("sendcmd:send: $msg") if ($smtp_debug > 1);
	my @response = &getsmtpresponse($fh);
	&logmsg("sendcmd:recv: ".join(',', @response)) if ($smtp_debug);
	return ('10000') if ($#response <0);
	return @response;
}

sub sendcmd2
{
	my @r = &sendcmd(@_);
	return $r[0];
}

sub mailaddr2domain($)
{
	my $mailaddr = shift;
	my ($user, $host0) = split(/@/, $mailaddr);
	my $host = $host0;
	if (&non_ascii($host)) {
		$host = Net::LibIDN::idn_to_ascii($host, 'UTF-8');
		&logmsg("IDN [$host0] is converted as $host");
	}
	return $host;
}

sub getconnectfrom
{
	my $socket = getpeername STDIN;
	my $src;
	if (!defined($socket)) {
		# debug;
		$src = 'stdin [0.0.0.0]';
	} else {
		my ($port, $iaddr) = sockaddr_in($socket);
		my $name = gethostbyaddr($iaddr, AF_INET);
		my $ipaddr = inet_ntoa($iaddr);
		$src = "$name [$ipaddr]";
	}
	return $src;
}

sub send_messages
{
	my ($filename, $myname, $smtpfrom, $mailfrom, @recipient) = @_;
	my $globalp;
	my @error;
	my $do_downgrade;
	my @downgrade_required;
	my @message;
	my $message_fh;
	my $errorref;
	my $mailfrom_ascii;
	use constant {
		downgrade_8bit => &downgrading_8bit,
		downgrade_7bit => &downgrading_7bit, 
        	downgrade_none => &downgrading_testonly,
	};

	&logmsg("send_messages: smtp_debug = $smtp_debug") if ($smtp_debug);
	my $now_string = &datetime_string(time);
	open($message_fh, "$filename") || logmsg_die("cannot open $filename");
	my ($status, $body8bit) = &downgrading($message_fh, &downgrading_testonly);
	$globalp = ($status == need_to_downgrade);
	$globalp = 1 if (&non_ascii($mailfrom->{addr}));

	$mailfrom->{ascii} = &envelope_addr_downgrade($mailfrom);
	&logmsg("globalp=$globalp mailfrom-ascii=\"".$mailfrom->{ascii}."\"") if ($smtp_debug > 1);
	foreach my $k (@recipient) {
		my $globalp2 = $globalp;
		# MAIL FROM: <$mailfrom->{addr}> ALT-ADDRESS=$mailfrom->{altaddr} @{$mailfrom->{param}}
		# RCPT TO: <$k->{addr}> ALT-ADDRESS=$k->{altaddr} @{$k->{param}}
		$k->{ascii} = &envelope_addr_downgrade($k);
		$globalp2 = 1 if (&non_ascii($k->{addr}));
		my ($status, $fh, $greetinghost, $ipaddr) = &connect_mx_ehlo($k->{addr}, $myname, 1);
		&logmsg ("connect_mx_ehlo(".$k->{addr}." returns $status,$fh,$greetinghost)") if ($smtp_debug > 1);
		if (!defined($fh) || $status == transport_error) {
			push @error, "!CONNECT:".$k->{addr};
			&logmsg ("!CONNECT:".$k->{addr}) if ($smtp_debug > 1);
			next;
		}
		$k->{ipaddr} = $ipaddr;
		if ($status != transport_utf8smtp && $globalp2) { # need to downgrade
			if ((&mailaddr2domain($k->{addr}) ne &mailaddr2domain($k->{ascii})) || $mailfrom->{ascii} eq '') {
				&logmsg("SMTP-Downgrade: QUIT because address changed: ".$k->{addr}." to ".$k->{ascii}) if ($smtp_debug > 1);
				print $fh "QUIT\r\n";
				close($fh);
				if ($k->{ascii} eq ''||$mailfrom->{ascii} eq '') {
					push @error, "!Downgradable:From ".&generate_mailbox($mailfrom)." To ".&generate_mailbox($k);
					next;
				}
				my ($status, $fh, $greetinghost,$ipaddr) = &connect_mx_ehlo($k->{ascii}, $myname, 1);
				if (!defined($fh) || $status == transport_error) {
					push @error, "!CONNECT:".$k->{ascii};
					next;
				}
				$k->{ipaddr} = $ipaddr;
				$status = transport_8bit if ($status == transport_utf8smtp);
			}
		}
		$k->{fh} = $fh;
		$k->{status} = $status;
		if ($status == transport_7bit && $body8bit) {
			$do_downgrade = downgrade_7bit;
		} elsif ($globalp2 != 0 && $status != transport_utf8smtp) {
			$do_downgrade = downgrade_8bit;
		} else {
			$do_downgrade = downgrade_none;
		}
		my ($d1, $d2);
		($k->{mailfrom}, $d1) = &smtp_envelope_generate('MAIL FROM', $mailfrom, $do_downgrade != downgrade_none);
		($k->{rcptto}, $d2) = &smtp_envelope_generate('RCPT TO', $k, $do_downgrade != downgrade_none);
		$k->{added} = &cat_headerfields($d1,$d2,&folding("Received: from $smtpfrom by ".$myname." for ".($do_downgrade==downgrade_none?&generate_mailbox($k):'<'.$k->{ascii}.'>')."; ".$now_string));
		$k->{downgrade} = $do_downgrade;
		$downgrade_required[$do_downgrade] = 1;
	}
	if ($#error >= 0) {
		foreach my $k (@recipient) {
			my $fh = $k->{fh};
			next if (!defined($fh));
			print $fh "QUIT\r\n";
			close($fh);
		}
		return @error;
	}
	foreach my $k (@recipient) {
		my $fh = $k->{fh};
		next if (!defined($fh));
		my @r;
		@r = &sendcmd($fh, $k->{mailfrom});
		if ($#r < 0 || $r[0] <= 200 || $r[0] >= 500) {
			my $msg = '!RESPONSE '.$k->{ipaddr}.' '.$k->{mailfrom}.' -> '.join(' ',@r);
			&logmsg($msg) if ($smtp_debug > 1);
			push @error, $msg;
			last;
		}
		@r = &sendcmd($fh, $k->{rcptto});
		if ($#r < 0 || $r[0] <= 200 || $r[0] >= 500) {
			my $msg = '!RESPONSE '.$k->{ipaddr}.' '.$k->{rcptto}.' -> '.join(' ',@r);
			&logmsg($msg) if ($smtp_debug > 1);
			push @error, $msg;
			last;
		}
	}
	if ($#error >= 0) {
		foreach my $k (@recipient) {
			my $fh = $k->{fh};
			next if (!defined($fh));
			print $fh "QUIT\r\n";
			close($fh);
		}
		return @error;
	}
	foreach my $k (@recipient) {
		my $fh = $k->{fh};
		&logmsg("sending to: ".&generate_mailbox($k)." : DATA") if ($smtp_debug > 1);
		next if (!defined($fh));
		my @r = &sendcmd($fh, "DATA");
		if ($#r < 0 || $r[0] <= 200 || $r[0] >= 500) {
			my $msg = '!RESPONSE '.$k->{ipaddr}.' DATA -> '.join(' ',@r);
			&logmsg($msg) if ($smtp_debug > 1);
			push @error, $msg;
			last;
		}
		my $r = $k->{added};
		$r =~ s/\n/\r\n/g;
		print $fh $r;
	}
	if ($#error >= 0) {
		foreach my $k (@recipient) {
			my $fh = $k->{fh};
			next if (!defined($fh));
			close($fh);
		}
		return (@error);
	}
	foreach my $i (downgrade_8bit, downgrade_7bit, downgrade_none) {
		next if (!$downgrade_required[$i]);
		&logmsg ("start sending II ".$i) if ($smtp_debug >1);
		if ($i == downgrade_none) {
			foreach my $k (@recipient) {
				next if ($k->{downgrade} != $i);
				my $fh = $k->{fh};
				next if (!defined($fh));
				seek $message_fh, 0, 0;
				while (<$message_fh>) {
					$_ =~ tr /\r//d;
					$_ = "..\n" if ($_ eq ".\n");
					s/\n/\r\n/;
					print $fh $_;
				}
			}
		} else {
			seek $message_fh, 0, 0;
			my @body;
			&logmsg("start downgrading $i") if ($smtp_debug >1);
			($status, $body8bit, $errorref, @body) = &downgrading($message_fh, $i);
			&logmsg("downgrading $i returns $status") if ($smtp_debug > 1);
			foreach my $k (@recipient) {
				next if ($k->{downgrade} != $i);
				my $fh = $k->{fh};
				next if (!defined($fh));
				foreach my $m (@body) {
					$m =~ tr /\r//d;
					if ($m =~ /^\.\n/) { $m = '.'.$m; };
					$m =~ s/\n\.\n/\n\.\.\n/g;
					$m =~ s/\n/\r\n/g;
					print $fh $m;
				}
			}
		}
	}
	foreach my $k (@recipient) {
		my $fh = $k->{fh};
		next if (!defined($fh));
		my $r;
		if (($r = &sendcmd2($fh, ".")) != 250) {
			close($fh);
			push @error, "!RESPONSE $r: ".&generate_mailbox($k);
			next;
		} else {
			&logmsg("Send to ".&generate_mailbox($k)." done");
		}
		&sendcmd($fh, "QUIT");
		$k->{fh} = undef;
		close($fh);
	}
	close($message_fh);
	return (@error);
}

sub parse_mailbox
{
	my $line = shift;
	my $cfws;
	my $display;
	my $addr = '';
	my $altaddr = '';

	($cfws, $line) = &get_CFWS($line, 0);
	if ($line  =~ /^([^<(]+)([(<].*|)$/) {
		$display = $1;
		$line = $2;
	}
	($cfws, $line) = &get_CFWS($line, 0);
	if ($line eq '' || substr($line, 0, 1) ne '<') {
		if ($display =~ /^([^ \t]+)@([^ \t]+)(|[ \t]*)$/) {
			my $user = $1;
			my $host = $2;
			if (&non_ascii($host)) {
				$host = Net::LibIDN::idn_to_unicode(Net::LibIDN::idn_to_ascii($host, 'UTF-8'));
			}
			$addr = $user.'@'.$host;
		}
	} else {
		if ($line =~ /^<([^ \t<>]+@[^ \t<>]+)[ \t]*<([^ \t<>]+@[^ \t<>]+)>>/) {
			$addr = $1;
			$altaddr = $2;
		} elsif ($line =~ /^<([^ \t<>]+@[^ \t<>]+)>/) {
			$addr = $1;
		}
	}
	if ($addr eq '') {
		return '';
	} else {
		return { addr=>$addr, altaddr=>$altaddr };
	}
}

sub parse_mailboxes
{
	my $line = shift;
	my @addr;
	my $output;
	my $error = '';
	while ($line ne '') {
		if ($line =~ /^([^:,]+)(|(,)(.*))$/) {
			$line = $4;
			$output .= $1 . $3;
			my $addr = &parse_mailbox($1);
			if ($addr eq '') {
				$error .= "Bad address: $1\n";
			} else {
				push @addr, $addr;
			}
		} elsif ($line =~ /^([^:,]+:)([^;]+);(.*)$/) {
			$line = $3;
			$output .= $1.';';
			foreach my $k (split(/,/, $2)) {
				my $addr = &parse_mailbox($k);
				if ($addr eq '') {
					$error .= "Bad address: $k\n";
				} else {
					push @addr, $addr;
				}
			}
		} else {
			$error .= "Bad address: $line\n";
			$line = '';
		}
	}
	return ($output, $error, @addr);
}

1;

=head1 NAME

UTF8SMTP::SMTP - SMTP protocol package for UTF8SMTP

=head1 DESCRIPTION

This is an implementation of draft-ietf-eai-smtp-11.txt and RFC 2821.

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
