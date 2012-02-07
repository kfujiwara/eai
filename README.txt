JPRS's UTF8SMTP/EAI prototype implementation.
					Kazunori Fujiwara, JPRS
					June 18, 2008

This package contains SMTP Sender (Sender), Submission server daemon
(Submission), SMTP daemon (SMTPreceiver), Downgrade program
(Downgrade), POP3 server (POP3d) and Web mail (mail.cgi).

To performe a practical interoperability test, SMTP AUTH and STARTTLS
functions are implemented in Submission server. Also STLS capability
and UIDL capability is implemented in POP3 server.

The Sender program reads the target SMTP/Submission server address,
SMTP commands, SMTP data from given files.  File format and usages are
described in the Sender program. The email originator must write
complete message/global message with envelope and destination server
information using text editor. The Sender program send the specified
message to the specified SMTP/submission server.

Submission server program waits on the submission port, processes SMTP
submission, sends messages to the the recipients' MDA.  It does not
support DSN and error bouncing.  It is invoked by inetd.  If the
recipient does not support UTF8SMTP extension, Submission program
tries to downgrade. Submission program supports STARTTLS and SMTP
Authentication (AUTH PLAIN only).

SMTPreceiver waits on the SMTP port, and receives messages to the
local recipients' mailboxes.  It is invoked by inetd.  The mailbox
format is Maildir. SMTPreceiver program supports STARTTLS.

The mail.cgi program retrieves messeages from local file system
(Maildir format). The mail.cgi sends messages directly using
integrated Submission perl module.

POP3d is a POP3 server and it supports SMTPreceiver's mail spool.
It is invoked by inetd. POP3d supports AUTH, UIDL, UTF8, STLS
capabilities.

Downgrade program can perform UTF8SMTP downgrading and display
downgraded messages.

        text editor
           +
Name:      Sender    Submission      SMTPreceiver   POP3d         IM+Downgrade
Documents: [S+U]      [S+U+d]           [S+U]       [U+P+d]       [U+P+e]
Func:        UA========>MSA=============>MDA------->POPserver----->UA
protocol:     submission       SMTP          file             POP3
               SMTP AUTH                    (Maildir)
               STARTTLS

        Web Mail                                    Web Mail
Impls:   mail.cgi                    SMTPreceiver   mail.cgi
Docs:    [S+U+d]                      [S+U]         [S+U+e]
Funcs:      UA+MSA====================>MDA---------->UA
Proto:                   SMTP               file
                                         (Maildir)

[S]: RFC 2821 + draft-ietf-eai-smtpext
[U]: RFC 2822 + draft-ietf-eai-utf8headers
[D]: DSN RFCs + draft-ietf-eai-dsn
[P]: POP RFCs + draft-ietf-eai-pop
[d]: draft-ietf-eai-downgrade
[e]: draft-(ietf|fujiwara)-eai-downgraded-display

IM program can read user's mailboxes into MH style mailboxes.  it can
handle UTF8 messages, as is.  Users can manipulate messages using
imls, imcat commands.

'imcat <number> | Downgrade -2' decodes downgraded message.

Each program contains documents inside the program. Try perldoc.
  'perldoc POP3d' shows POP3d usage.

--------------------
IM is an Email client interface programs developed by IM development team.
   http://tats.hauN.org/im/

Downgrade, SMTPreceiver, Sender, Submission, POP3d, mail.cgi are
developed by Kazunori Fujiwara, JPRS.

I prepared my Email addresses written in fujiwara.html.
Please send me UTF8SMTP emails.

--------------------
