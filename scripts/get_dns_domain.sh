ssh root@192.168.8.52 'curl -sS \
  -H "X-API-Key: $(sed -n "s/^api-key=//p" /etc/powerdns/pdns.conf)" \
  http://127.0.0.1:8181/api/v1/servers/localhost/zones/acme.example.' |
  python3 -m json.tool
