cscli=/run/current-system/sw/bin/cscli
key=/var/lib/crowdsec-caddy-bouncer/key
[ -s "$key" ] || (umask 077; openssl rand -hex 32 > "$key")

for i in $(seq 1 30); do
  "$cscli" lapi status >/dev/null 2>&1 && break
  sleep 2
done

"$cscli" bouncers delete caddy >/dev/null 2>&1 || true
"$cscli" bouncers add caddy -k "$(cat "$key")" >/dev/null

(umask 077; echo "CROWDSEC_API_KEY=$(cat "$key")" > /run/crowdsec-caddy-bouncer/env)
