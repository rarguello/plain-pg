#!/usr/bin/env bash
# t35 -- The documented way in from outside: a port-forward to postgresql-rw
#        reaches the primary. The client is the user's own psql, so this checks
#        the mechanism: the local port opens and the Service behind it is the
#        primary.
source "$(dirname "${BASH_SOURCE[0]}")/lib-test.sh"
load_credentials

echo "### t35 port-forward to the primary"

PORT=$((16000 + RANDOM % 1000))
oc -n "$NS" port-forward svc/postgresql-rw "$PORT:5432" >/tmp/t35-port-forward.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null' EXIT

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }
wait_for 30 "the forwarded port accepts a connection" port_open
check "it is still open a moment later" port_open

check_eq "the Service behind it is the primary" "$(primary_pod)" \
  "$(oc -n "$NS" get endpoints postgresql-rw -o jsonpath='{.subsets[0].addresses[0].targetRef.name}' 2>/dev/null)"
is_primary() { [ "$(pod_in_recovery "$(primary_pod)")" = "f" ]; }
wait_for 60 "and that pod answers as a primary" is_primary

kill "$PF_PID" 2>/dev/null
closed() { ! (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }
wait_for 30 "the port is closed once the forward is stopped" closed

t_summary
