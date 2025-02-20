#!/bin/bash
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
systemctl status named

