#!/bin/bash

OUTPUT=${1:-restartMemc.sh}

cat > "$OUTPUT" << 'EOF'
#!/bin/bash
addr=$(head -1 memcached.conf)
port=$(awk 'NR==2{print}' memcached.conf)

# kill old instance
ssh ${addr} "[ -f /tmp/memcached.pid ] && cat /tmp/memcached.pid | xargs kill 2>/dev/null || true"

# launch memcached
ssh ${addr} "memcached -u root -l ${addr} -p ${port} -c 10000 -d -P /tmp/memcached.pid"
sleep 1

# init
RET=$(echo -e "set serverNum 0 0 1\r\n0\r\nquit\r" | nc ${addr} ${port})
echo -e "set clientNum 0 0 1\r\n0\r\nquit\r" | nc ${addr} ${port}
if [ ! -z "$RET" ]; then
  exit 0
fi

addr=$(head -1 memcached.conf)
port=$(awk 'NR==2{print}' memcached.conf)

# kill old instance
ssh ${addr} "[ -f /tmp/memcached.pid ] && cat /tmp/memcached.pid | xargs kill 2>/dev/null || true"

# launch memcached
ssh ${addr} "memcached -u root -l ${addr} -p ${port} -c 10000 -d -P /tmp/memcached.pid"
sleep 1

# init
echo -e "set serverNum 0 0 1\r\n0\r\nquit\r" | nc ${addr} ${port}
echo -e "set clientNum 0 0 1\r\n0\r\nquit\r" | nc ${addr} ${port}
EOF

chmod +x "$OUTPUT"
