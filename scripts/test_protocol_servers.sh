#!/bin/zsh
# Starts throwaway FTP, FTPS, WebDAV and S3 (moto) servers on 127.0.0.1 and runs
# the protocol integration tests against each. Needs a Python venv with
# pyftpdlib, pyopenssl, wsgidav, cheroot and moto[server]:
#   python3 -m venv /tmp/xf-venv && /tmp/xf-venv/bin/pip install pyftpdlib pyopenssl wsgidav cheroot "moto[server]"
set -uo pipefail
cd "$(dirname "$0")/.."
VENV=${XF_VENV:-/tmp/xf-venv}
D=/tmp/xf-servers
rm -rf "$D"; mkdir -p "$D/ftp" "$D/ftps" "$D/dav"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 2 -subj "/CN=127.0.0.1" 2>/dev/null
cat "$D/key.pem" "$D/cert.pem" > "$D/both.pem"
PIDS=()
"$VENV/bin/python" scripts/testservers/ftp_server.py "$D/ftp" 2121 plain > "$D/ftp.log" 2>&1 & PIDS+=($!)
"$VENV/bin/python" scripts/testservers/ftp_server.py "$D/ftps" 2122 tls "$D/both.pem" > "$D/ftps.log" 2>&1 & PIDS+=($!)
"$VENV/bin/wsgidav" --host 127.0.0.1 --port 8088 --root "$D/dav" --auth anonymous --server cheroot > "$D/dav.log" 2>&1 & PIDS+=($!)
"$VENV/bin/moto_server" -H 127.0.0.1 -p 9099 > "$D/s3.log" 2>&1 & PIDS+=($!)
trap 'kill ${PIDS[@]} 2>/dev/null' EXIT
sleep 3
curl -s -X PUT http://127.0.0.1:9099/xf-test-bucket > /dev/null

run() {
  echo "== $1"
  shift
  env "$@" swift test --filter ProtocolIntegrationTests 2>&1 | grep -E "error:|failed|passed|Executed" | grep -v "^warning" || true
}
run FTP XF_IT_PROTOCOL=ftp XF_IT_PORT=2121 XF_IT_USER=tester XF_IT_PASS=secret
run FTPS XF_IT_PROTOCOL=ftpsExplicit XF_IT_PORT=2122 XF_IT_USER=tester XF_IT_PASS=secret
run WebDAV XF_IT_PROTOCOL=webdav XF_IT_PORT=8088
run S3 XF_IT_PROTOCOL=s3 XF_IT_PORT=9099 XF_IT_USER=testing XF_IT_PASS=testing XF_IT_BUCKET=xf-test-bucket XF_IT_PLAIN_HTTP=1
