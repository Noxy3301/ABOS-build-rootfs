# shadow-login does not print motd, do it ourselves
if [ -r /etc/motd ]; then
	cat /etc/motd
fi
