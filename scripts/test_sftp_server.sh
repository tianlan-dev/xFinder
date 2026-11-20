#!/bin/zsh
# Starts a throwaway sshd on 127.0.0.1:2222 with generated keys under /tmp/xf-sshd
# and runs the SFTP integration tests against it. Never touches ~/.ssh.
set -euo pipefail
cd "$(dirname "$0")/.."
D=/tmp/xf-sshd
rm -rf "$D"; mkdir -p "$D/root"
ssh-keygen -q -t ed25519 -N '' -f "$D/hostkey"
ssh-keygen -q -t rsa -b 3072 -N 'test-passphrase' -f "$D/client_rsa"
ssh-keygen -q -t ed25519 -N '' -f "$D/client_ed"
cat "$D/client_rsa.pub" "$D/client_ed.pub" > "$D/authorized_keys"
cat > "$D/sshd_config" <<CFG
Port 2222
ListenAddress 127.0.0.1
HostKey $D/hostkey
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $D/sshd.pid
Subsystem sftp internal-sftp
CFG
# Second server without an SFTP subsystem (connect must fail fast and clearly).
sed -e 's/^Port 2222/Port 2223/' -e '/^Subsystem/d' -e "s|^PidFile .*|PidFile $D/sshd2.pid|" \
  "$D/sshd_config" > "$D/sshd_nosftp_config"
/usr/sbin/sshd -D -e -f "$D/sshd_config" > "$D/sshd.log" 2>&1 &
PID=$!
/usr/sbin/sshd -D -e -f "$D/sshd_nosftp_config" > "$D/sshd2.log" 2>&1 &
PID2=$!
trap 'kill $PID $PID2 2>/dev/null || true' EXIT
sleep 1
for key in client_ed client_rsa; do
  pass=""; [[ $key == client_rsa ]] && pass="test-passphrase"
  echo "== $key"
  XF_SFTP_TEST_PORT=2222 XF_SFTP_TEST_KEY="$D/$key" XF_SFTP_TEST_PASSPHRASE="$pass" XF_SFTP_TEST_ROOT="$D/root" XF_SFTP_NOSUBSYSTEM_PORT=2223 \
    swift test --filter "SFTPIntegrationTests|SCPIntegrationTests" 2>&1 | grep -E "error:|failed|passed|skipped|Executed" | grep -v "^warning" || true
done
