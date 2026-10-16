#!/bin/bash
# usage: diag.sh <host>  -> host, accepts TLS1.2?, cert key (from a TLS 1.3 handshake)
h=$1
t12=$(timeout 15 openssl s_client -connect "$h:1965" -servername "$h" -tls1_2 -brief </dev/null 2>&1 | grep -m1 -o "Protocol version: TLSv1.2\|alert [a-z ]*\|errno=[0-9]*\|no protocols available\|unexpected eof\|Peer signature type: [a-z_0-9-]*\|wrong version number" | tr '\n' ' ')
key=$(timeout 15 openssl s_client -connect "$h:1965" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -text 2>/dev/null | grep -m1 -o "Public Key Algorithm: [a-zA-Z0-9]*\|Public-Key: ([0-9]* bit)" | tr '\n' ' ')
sig=$(timeout 15 openssl s_client -connect "$h:1965" -servername "$h" </dev/null 2>/dev/null | openssl x509 -noout -text 2>/dev/null | grep -m1 -o "Signature Algorithm: [a-zA-Z0-9-]*")
printf "%s\t%s\t%s\t%s\n" "$h" "${t12:-none}" "${key:-?}" "${sig:-?}"
