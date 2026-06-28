#!/bin/bash
echo "=== Port 3000 Diagnostics ==="
echo "Date: $(date)"
echo ""

echo "Listening on port 3000:"
netstat -tlnp | grep 3000 || echo "Nothing listening on 3000"

echo ""
echo "NAT rules:"
iptables -t nat -L -n

echo ""
echo "Forward rules:"
iptables -L FORWARD -n -v

echo ""
echo "Connectivity tests:"
echo "From PVE to VM:"
curl -m 2 http://10.10.10.50:3000 2>&1 | head -1

echo ""
echo "Testing from inside VM:"
ssh ubuntu@10.10.10.50 "curl -m 2 http://localhost:3000 2>&1 | head -1"

echo ""
echo "=== End of diagnostics ==="