ssh root@192.168.8.52 'curl -sS -X PATCH \
  -H "X-API-Key: $(sed -n "s/^api-key=//p" /etc/powerdns/pdns.conf)" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:8181/api/v1/servers/localhost/zones/acme.example. \
  -d @- <<JSON
{"rrsets": [{"name": "www.acme.example.", "type": "A",
             "changetype": "DELETE"}]}
JSON'
