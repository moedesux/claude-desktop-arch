#!/usr/bin/env bash
# Install the built package and launch it the way a user on Hyprland would.
# Fails if a linked library is missing from depends, if the app exits early,
# or if it can't store secrets in an unlocked keyring (the launcher's job).
#
#   ci/smoke.sh PKGFILE
#
# Runs as root in a throwaway container: it installs packages and adds a user.
set -euo pipefail
pkg=$(realpath "${1:?usage: ci/smoke.sh PKGFILE}")
seconds=30

pacman -U --noconfirm "$pkg"

# Check linked libraries before installing anything else: the test helpers
# below pull in libraries (gtk3, ...) that would hide a gap in depends.
missing=$(find /usr/lib/claude-desktop -type f | while IFS= read -r f; do
  if [[ $(head -c4 "$f" | od -An -c | tr -d ' ') == 177ELF ]]; then
    ldd "$f" 2> /dev/null | grep 'not found' || true
  fi
done | sort -u)
if [[ -n $missing ]]; then
  echo "ci/smoke.sh: libraries missing after installing only the package and its depends:" >&2
  echo "$missing" >&2
  exit 1
fi

pacman -S --noconfirm --needed gnome-keyring xorg-server-xvfb
id smoke > /dev/null 2>&1 || useradd -m smoke

# Container runtimes often block user namespaces, which Chromium's sandbox
# needs. Only then run without it; the check targets startup, not the sandbox.
flags=()
if ! sudo -u smoke unshare --user true 2> /dev/null; then
  echo "ci/smoke.sh: no user namespaces here, launching with --no-sandbox"
  flags+=(--no-sandbox)
fi

# A fresh session bus with an unlocked default keyring, as a desktop login
# provides. An empty password creates no keyring, and without the default
# alias gnome-keyring asks for a GUI prompt instead.
sudo -u smoke mkdir -p /home/smoke/.local/share/keyrings
sudo -u smoke sh -c 'echo login > /home/smoke/.local/share/keyrings/default'
rc=0
# The app log is root's file on purpose.
# shellcheck disable=SC2024
sudo -u smoke -H -- env XDG_CURRENT_DESKTOP=Hyprland dbus-run-session -- sh -c '
  printf ci | gnome-keyring-daemon --unlock --components=secrets > /dev/null
  exec timeout --kill-after=5 "$0" xvfb-run -a claude-desktop "$@"
' "$seconds" "${flags[@]}" > /home/smoke/app.log 2>&1 || rc=$?
pkill -u smoke || true

log=/home/smoke/.config/Claude/logs/main.log
fail() {
  echo "ci/smoke.sh: $*" >&2
  echo "--- last lines of app output:" >&2
  tail -20 /home/smoke/app.log >&2
  exit 1
}
# timeout exits 124 when the app was still running, which is the pass case.
[[ $rc == 124 ]] || fail "app exited after less than ${seconds}s (exit $rc)"
[[ -s $log ]] || fail "app wrote no main.log"
if grep -q 'isEncryptionAvailable=false' "$log"; then
  fail "app can't use the keyring: $(grep -m1 'isEncryptionAvailable=false' "$log")"
fi
echo "ci/smoke.sh: app ran ${seconds}s and stored secrets in the keyring."
