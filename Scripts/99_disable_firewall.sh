#!/bin/sh
[ -x /etc/init.d/firewall ] || exit 0
/etc/init.d/firewall disable
/etc/init.d/firewall stop
