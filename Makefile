PROGRAM = Downgrade Submission SMTPreceiver Sender POP3d
MODULES = CONFIG.pm MIME.pm SMTP.pm Downgrading.pm

DESTDIR = /jails/eai/home/eai/bin/
DESTDIR_WMC = /jails/eai/home/webmail/data/
DESTMODULE = /jails/eai/home/eai/lib/UTF8SMTP/
DESTCGI = /jails/eai/home/webmail/www
DESTCGITMP = /jails/eai/home/webmail/tmp
DESTTMP = /jails/eai/home/eai/tmp/
MAILDIR = /jails/eai/home/eai/maildirs/
WDATA = index.html README.txt .htaccess
WPROG = mail.cgi admin.cgi

install:
	install -c -m 755 $(WDATA) $(DESTCGI)
	install -c -m 755 $(WPROG) $(DESTCGI)
	install -c -m 755 $(PROGRAM) $(DESTDIR)
	install -c -m 755 $(MODULES) $(DESTMODULE)
	-(cd $(DESTDIR); ln -s SMTPreceiver SMTPreceiver8; ln -s SMTPreceiver SMTPreceiver7)

package:
	(cd ..; tar cvzf eai-prototype-`date +%Y%m%d`.tar.gz `cat eai/list`)

makedir:
	mkdir -p $(DESTDIR) $(DESTMODULE) $(DESTTMP) $(MAILDIR) $(DESTCGITMP)
	chown eai:eai $(DESTDIR) $(DESTMODULE) $(DESTTMP) $(MAILDIR)
	chmod 775 $(DESTDIR) $(DESTMODULE) $(MAILDIR)
	chmod 700 $(DESTTMP)
	chown www:www $(DESTCGITMP)
	chmod 700 $(DESTCGITMP)
