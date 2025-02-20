#!/bin/bash
set -e
yum install bind bind-utils -y
systemctl start named
systemctl enable named
cat << EOT | tee /etc/named.conf
options {
        listen-on port 53 { 127.0.0.1; 192.168.0.221; 10.10.0.40; };
        listen-on-v6 port 53 { ::1; };
        directory       "/var/named";
        dump-file       "/var/named/data/cache_dump.db";
        statistics-file "/var/named/data/named_stats.txt";
        memstatistics-file "/var/named/data/named_mem_stats.txt";
        secroots-file   "/var/named/data/named.secroots";
        recursing-file  "/var/named/data/named.recursing";
        allow-query     { localhost; 192.168.0.0/16; 10.10.0.0/24; };

        /*
         - If you are building an AUTHORITATIVE DNS server, do NOT enable recursion.
         - If you are building a RECURSIVE (caching) DNS server, you need to enable
           recursion.
         - If your recursive DNS server has a public IP address, you MUST enable access
           control to limit queries to your legitimate users. Failing to do so will
           cause your server to become part of large scale DNS amplification
           attacks. Implementing BCP38 within your network would greatly
           reduce such attack surface
        */
        recursion yes;

        dnssec-validation yes;

        managed-keys-directory "/var/named/dynamic";
        geoip-directory "/usr/share/GeoIP";

        pid-file "/run/named/named.pid";
        session-keyfile "/run/named/session.key";

        /* https://fedoraproject.org/wiki/Changes/CryptoPolicy */
        include "/etc/crypto-policies/back-ends/bind.config";
};

logging {
        channel default_debug {
                file "data/named.run";
                severity dynamic;
        };
};

zone "." IN {
        type hint;
        file "named.ca";
};

zone "ocp.server.lab" IN {
        type master;
        file "forward.zone";
        allow-update { none; };
};

zone "0.10.10.in-addr.arpa" IN {
        type master;
        file "reverse.zone";
        allow-update { none; };
};


include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOT

cat << EOT | tee /var/named/forward.zone
\$TTL 1D
@       IN SOA  bastion.ocp.server.lab. root.ocp.server.lab. (
                                        0       ; serial
                                        1D      ; refresh
                                        1H      ; retry
                                        1W      ; expire
                                        3H )    ; minimum

@       IN      NS      bastion.ocp.server.lab.

bastion.ocp.server.lab.     IN      A       10.10.0.40
api.ocp.server.lab.         IN      A       10.10.0.40
api-int.ocp.server.lab.     IN      A       10.10.0.40
*.apps.ocp.server.lab.      IN      A       10.10.0.40

bootstrap.ocp.server.lab.   IN      A       10.10.0.41
master1.ocp.server.lab.     IN      A       10.10.0.42
master2.ocp.server.lab.     IN      A       10.10.0.43
master3.ocp.server.lab.     IN      A       10.10.0.44
worker1.ocp.server.lab.     IN      A       10.10.0.45
worker2.ocp.server.lab.     IN      A       10.10.0.46

EOT

cat << EOT | tee /var/named/reverse.zone
\$TTL 1D
@       IN      SOA     bastion.ocp.server.lab.     root.ocp.server.lab.(
                                                0       ; serial
                                                1D      ; refresh
                                                1H      ; retry
                                                1W      ; expire
                                                3H )    ; minimum

@       IN      NS      bastion.ocp.server.lab.
@       IN      NS      ocp.server.lab.
40      IN      PTR     bastion.ocp.server.lab.

40      IN      PTR     api.ocp.server.lab.
40      IN      PTR     api-int.ocp.server.lab.
41      IN      PTR     bootstrap.ocp.server.lab.

42      IN      PTR     master1.ocp.server.lab.
43      IN      PTR     master2.ocp.server.lab.
44      IN      PTR     master3.ocp.server.lab.

45      IN      PTR     worker1.ocp.server.lab.
46      IN      PTR     worker2.ocp.server.lab.

EOT

chown root:named /var/named/forward.zone
chown root:named /var/named/reverse.zone

systemctl restart named
SERVICE="named"
# Check if the service is running
if ! systemctl is-active --quiet "$SERVICE"; then
  echo "The $SERVICE service is not running. Terminating script."
  exit 1
fi
echo "$SERVICE is running. Continuing the script..."
yum install haproxy -y
systemctl start haproxy
systemctl enable haproxy
cat << EOT | tee /etc/haproxy/haproxy.conf
#---------------------------------------------------------------------
# Example configuration for a possible web application.  See the
# full configuration options online.
#
#   https://www.haproxy.org/download/1.8/doc/configuration.txt
#
#---------------------------------------------------------------------

#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    # to have these messages end up in /var/log/haproxy.log you will
    # need to:
    #
    # 1) configure syslog to accept network log events.  This is done
    #    by adding the '-r' option to the SYSLOGD_OPTIONS in
    #    /etc/sysconfig/syslog
    #
    # 2) configure local2 events to go to the /var/log/haproxy.log
    #   file. A line like the following can be added to
    #   /etc/sysconfig/syslog
    #
    #    local2.*                       /var/log/haproxy.log
    #
    log         127.0.0.1 local2

    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    daemon

    # turn on stats unix socket
# use if not designated in their block
#---------------------------------------------------------------------
defaults
    mode                    http
    log                     global
    option                  dontlognull
    option http-server-close
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout http-keep-alive 10s
    timeout check           10s
    maxconn                 3000

#---------------------------------------------------------------------
# main frontend which proxys to the backends
frontend stats
    bind *:1936
    mode        http
    log         global
    maxconn 10
    stats enable
    stats hide-version
    stats refresh 30s
    stats show-node
    stats show-desc Stats for ocp cluster
    stats auth admin:admin
    stats uri /stats

listen api-server-6443
    bind *:6443
    mode tcp
    server bootstrap bootstrap.ocp.server.lab:6443 check inter 1s backup
    server master1 master1.ocp.server.lab:6443 check inter 1s
    server master2 master2.ocp.server.lab:6443 check inter 1s
    server master3 master3.ocp.server.lab:6443 check inter 1s

listen machine-config-server-22623
    bind *:22623
    mode tcp
    server bootstrap bootstrap.ocp.server.lab:22623 check inter 1s backup
    server master1 master1.ocp.server.lab:22623 check inter 1s
    server master2 master2.ocp.server.lab:22623 check inter 1s
    server master3 master3.ocp.server.lab:22623 check inter 1s

listen ingress-router-443
    bind *:443
    mode tcp
    balance source
    server worker1 worker1.ocp.server.lab:443 check inter 1s
    server worker2 worker2.ocp.server.lab:443 check inter 1s

listen ingress-router-80
    bind *:80
    mode tcp
    balance source
    server worker1 worker1.ocp.server.lab:80 check inter 1s
    server worker2 worker2.ocp.server.lab:80 check inter 1s

EOT

setenforce 0

systemctl stop firewalld
systemctl disable firewalld
systemctl restart haproxy
