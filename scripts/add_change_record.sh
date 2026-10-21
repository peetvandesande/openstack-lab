ssh root@192.168.8.52 'curl -sS -X PATCH \
  -H "X-API-Key: $(sed -n "s/^api-key=//p" /etc/powerdns/pdns.conf)" \
  -H "Content-Type: application/json" \
  http://127.0.0.1:8181/api/v1/servers/localhost/zones/acme.example. \
  -d @- <<JSON
{"rrsets": [{"name": "www.acme.example.", "type": "A", "ttl": 300,
             "changetype": "REPLACE",
             "records": [{"content": "192.168.37.158", "disabled": false}]}]}
JSON'
