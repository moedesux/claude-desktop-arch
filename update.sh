#!/usr/bin/env bash
# Point PKGBUILD at the newest claude-desktop in Anthropic's apt repo.
# With --check, only report (and notify) when the installed version is behind.
#
# Trust chain, each link checked before the next is used:
#   pinned key fingerprint -> InRelease signature -> Packages SHA256 -> .deb SHA256
# The fingerprint is the one published at
# https://code.claude.com/docs/en/desktop-linux.
set -euo pipefail
cd "$(dirname "$0")"

fpr=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
key=keys/claude-desktop-archive-keyring.asc
repo=https://downloads.claude.ai/claude-desktop/apt/stable
debarch=amd64

check=false
case "$*" in
  '') ;;
  --check) check=true ;;
  *) echo "usage: update.sh [--check]" >&2; exit 2 ;;
esac

notify() { command -v notify-send >/dev/null && notify-send -a "Claude Desktop" "$@" || true; }
warn() {
  echo "update.sh: warning: $*" >&2
  if $check; then notify "Update check warning" "$*"; fi
}
die() {
  echo "update.sh: $*" >&2
  if $check; then notify -u critical "Update check failed" "$*"; fi
  exit 1
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

got=$(gpg --show-keys --with-colons "$key" | awk -F: '$1 == "fpr" { print $10; exit }')
[[ $got == "$fpr" ]] || die "$key has fingerprint $got, expected $fpr"
gpg --dearmor < "$key" > "$tmp/key.gpg"

# gpgv --output writes only the signed bytes, so nothing unsigned is parsed.
# It writes them even when verification fails, so trust only the status lines.
# Like apt, accept a valid signature from the pinned key even when another
# signature can't be checked, which happens while Anthropic rotates keys.
curl -fsSo "$tmp/InRelease" "$repo/dists/stable/InRelease"
status=$(gpgv --status-fd 1 --keyring "$tmp/key.gpg" --output "$tmp/Release" "$tmp/InRelease" 2>/dev/null || true)
if grep -qE '^\[GNUPG:\] (BADSIG|EXPSIG|EXPKEYSIG|REVKEYSIG) ' <<< "$status"; then
  die "InRelease has a bad, expired, or revoked signature"
fi
awk -v f="$fpr" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok = 1 } END { exit !ok }' <<< "$status" ||
  die "InRelease is not signed by $fpr"
if grep -qE '^\[GNUPG:\] (ERRSIG|NO_PUBKEY) ' <<< "$status"; then
  warn "InRelease also has a signature from an unknown key. Anthropic may be rotating keys; check the fingerprint at https://code.claude.com/docs/en/desktop-linux"
fi

# Refuse a stale index: a replayed old Release could hold back a security fix.
valid_until=$(sed -n 's/^Valid-Until: //p' "$tmp/Release")
(( $(date -d "$valid_until" +%s) > $(date +%s) )) || die "Release expired at $valid_until"

# Fetch Packages by its signed hash so a repo update mid-run can't mix versions.
pkgs_sha=$(awk -v f="main/binary-$debarch/Packages" '
  /^SHA256:/ { s = 1; next } /^[^ ]/ { s = 0 } s && $3 == f { print $1 }' "$tmp/Release")
[[ -n $pkgs_sha ]] || die "no SHA256 for main/binary-$debarch/Packages in Release"
curl -fsSo "$tmp/Packages" "$repo/dists/stable/main/binary-$debarch/by-hash/SHA256/$pkgs_sha"
echo "$pkgs_sha  $tmp/Packages" | sha256sum -c --quiet || die "Packages hash mismatch"

read -r ver sha file < <(awk '
  /^Package: / { p = $2 } /^Version: / { v = $2 } /^SHA256: / { h = $2 } /^Filename: / { f = $2 }
  /^$/ { if (p == "claude-desktop") print v, h, f; p = "" }
  END  { if (p == "claude-desktop") print v, h, f }' "$tmp/Packages" | sort -V | tail -1)
# Arch pkgver allows no Debian epoch (1:) or revision (-1).
[[ $ver =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "version $ver needs manual handling in PKGBUILD"
[[ $file == "pool/main/c/claude-desktop/claude-desktop_${ver}_$debarch.deb" ]] ||
  die "unexpected pool path $file"

cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
if $check; then
  installed=$(pacman -Q claude-desktop 2>/dev/null | awk '{ sub(/-[^-]*$/, "", $2); print $2 }')
  if [[ $installed == "$ver" ]]; then
    echo "Installed $ver is current."
    exit 0
  fi
  msg="$ver is available (installed: ${installed:-none}). Run: ./update.sh && makepkg -si in $PWD"
  echo "$msg"
  notify "Update available" "$msg"
  exit 0
fi
if [[ $ver == "$cur" ]]; then
  echo "Already at $ver."
  exit 0
fi
sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1/" \
  -e "s/^sha256sums=('[0-9a-f]*'/sha256sums=('$sha'/" PKGBUILD
echo "Updated $cur -> $ver ($sha). Build with: makepkg -si"
