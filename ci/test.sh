#!/usr/bin/env bash
# Behavior tests: the update trust chain, the drift gate, the release guard,
# and the launcher wrapper. Offline: a fake apt repo signed with throwaway
# keys stands in for Anthropic's.
#
#   ci/test.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every gpg call in this file uses this keyring, never the user's.
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"

failures=0
pass() { printf 'ok    %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}
# expect NAME CODE CMD...: CMD must exit with CODE. Output lands in $work/out.
expect() {
  local name=$1 want=$2 got=0
  shift 2
  "$@" > "$work/out" 2>&1 || got=$?
  if [[ $got == "$want" ]]; then
    pass "$name"
  else
    fail "$name: exit $got, expected $want"
    tail -5 "$work/out" | sed 's/^/      /'
  fi
}
# check NAME CMD...: CMD must succeed.
check() {
  local name=$1
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}
has() { grep -qF -- "$1" "$work/out"; }
lacks() { ! grep -qF -- "$1" "$work/out"; }

# --- update.sh: trust chain ------------------------------------------------

gpg -q --batch --passphrase '' --quick-gen-key pinned@test ed25519 sign never 2> /dev/null
gpg -q --batch --passphrase '' --quick-gen-key other@test ed25519 sign never 2> /dev/null
pinned=$(gpg --with-colons -k pinned@test | awk -F: '$1 == "fpr" { print $10; exit }')
ver=$(sed -n 's/^pkgver=//p' "$root/PKGBUILD")
sha=$(awk -F"'" '/^sha256sums=/ { print $2 }' "$root/PKGBUILD")
future=$(date -u -d '+7 days' '+%a, %d %b %Y %H:%M:%S UTC')
past=$(date -u -d '-1 day' '+%a, %d %b %Y %H:%M:%S UTC')

# make_repo NAME VALID_UNTIL VERSION SIGNER...: a signed one-package apt repo.
make_repo() {
  local dir=$work/$1 until=$2 v=$3
  shift 3
  local dists=$dir/dists/stable
  mkdir -p "$dists/main/binary-amd64/by-hash/SHA256"
  printf 'Package: claude-desktop\nVersion: %s\nFilename: pool/main/c/claude-desktop/claude-desktop_%s_amd64.deb\nSHA256: %s\n\n' \
    "$v" "$v" "$sha" > "$dir/Packages"
  local h
  h=$(sha256sum < "$dir/Packages" | cut -d' ' -f1)
  cp "$dir/Packages" "$dists/main/binary-amd64/by-hash/SHA256/$h"
  printf 'Origin: Test\nValid-Until: %s\nSHA256:\n %s %s main/binary-amd64/Packages\n' \
    "$until" "$h" "$(stat -c %s "$dir/Packages")" > "$dir/Release"
  local signers=() s
  for s in "$@"; do signers+=(-u "$s"); done
  gpg -q --batch "${signers[@]}" --clearsign -o "$dists/InRelease" "$dir/Release"
}

# checkout NAME REPO: a copy of update.sh that trusts the test key and repo.
checkout() {
  local dir=$work/$1
  mkdir -p "$dir/keys"
  cp "$root/PKGBUILD" "$dir/"
  gpg --armor --export pinned@test > "$dir/keys/claude-desktop-archive-keyring.asc"
  sed -e "s|^fpr=.*|fpr=$pinned|" -e "s|^repo=.*|repo=file://$work/$2|" \
    "$root/update.sh" > "$dir/update.sh"
  chmod +x "$dir/update.sh"
  grep -qx "fpr=$pinned" "$dir/update.sh" && grep -qx "repo=file://$work/$2" "$dir/update.sh" ||
    { echo "ci/test.sh: update.sh no longer has fpr= and repo= lines to redirect" >&2; exit 1; }
}
# Pin an older version, as a checkout looks before an update.
make_old() {
  sed -i -e 's/^pkgver=.*/pkgver=1.0.0/' -e 's/^pkgrel=.*/pkgrel=3/' \
    -e "s/^sha256sums=('[0-9a-f]*'/sha256sums=('$(printf '0%.0s' {1..64})'/" "$work/$1/PKGBUILD"
}

make_repo good "$future" "$ver" pinned@test
make_repo rotating "$future" "$ver" pinned@test other@test
make_repo foreign "$future" "$ver" other@test
make_repo expired "$past" "$ver" pinned@test
make_repo epoch "$future" "1:$ver" pinned@test
make_repo tampered "$future" "$ver" pinned@test
sed -i 's/^Origin: Test/Origin: Evil/' "$work/tampered/dists/stable/InRelease"

checkout c-good good
expect "update: pinned key signature accepted" 0 "$work/c-good/update.sh"
check "update: current version reported" has "Already at $ver"
checkout c-rotating rotating
expect "update: extra unknown signature accepted" 0 "$work/c-rotating/update.sh"
check "update: extra unknown signature warns" has "warning"
checkout c-foreign foreign
expect "update: signature from another key rejected" 1 "$work/c-foreign/update.sh"
checkout c-tampered tampered
expect "update: tampered InRelease rejected" 1 "$work/c-tampered/update.sh"
checkout c-expired expired
expect "update: expired Release rejected" 1 "$work/c-expired/update.sh"
check "update: expiry named" has "expired"
expect "update: unknown argument rejected" 2 "$work/c-good/update.sh" --chek
check "update: unknown argument leaves PKGBUILD" cmp -s "$work/c-good/PKGBUILD" "$root/PKGBUILD"
checkout c-bump good
make_old c-bump
expect "update: bump succeeds" 0 "$work/c-bump/update.sh"
check "update: bump reproduces committed PKGBUILD" cmp -s "$work/c-bump/PKGBUILD" "$root/PKGBUILD"
checkout c-epoch epoch
make_old c-epoch
cp "$work/c-epoch/PKGBUILD" "$work/epoch.before"
expect "update: Debian epoch version rejected" 1 "$work/c-epoch/update.sh"
check "update: epoch leaves PKGBUILD" cmp -s "$work/c-epoch/PKGBUILD" "$work/epoch.before"

# --- check-deb.sh: drift gate ------------------------------------------------

marker=TEST-MARKER-7f3a
# make_deb NAME POSTINST DEPENDS: a minimal .deb in the upstream layout.
make_deb() {
  local d=$work/deb-$1
  mkdir -p "$d/ctl" "$d/data/usr/lib/claude-desktop/resources" "$d/data/usr/bin"
  printf 'Package: claude-desktop\nVersion: 1.0\nDepends: %s\n' "$3" > "$d/ctl/control"
  printf '#!/bin/sh\n%s\n' "$2" > "$d/ctl/postinst"
  cp /usr/bin/true "$d/data/usr/lib/claude-desktop/claude-desktop"
  printf 'p="/usr/share/OVMF/OVMF_CODE_4M.fd"' > "$d/data/usr/lib/claude-desktop/resources/app.asar"
  ln -s ../lib/claude-desktop/claude-desktop "$d/data/usr/bin/claude-desktop"
  echo 2.0 > "$d/debian-binary"
  tar -cJf "$d/control.tar.xz" -C "$d/ctl" .
  tar -cJf "$d/data.tar.xz" -C "$d/data" .
  (cd "$d" && ar rc "$work/$1.deb" debian-binary control.tar.xz data.tar.xz)
}
make_deb base "true" "libgtk-3-0, libnss3"
make_deb script "echo $marker" "libgtk-3-0, libnss3"
make_deb depends "true" "libgtk-3-0, libnss3, libnew1"

mkdir "$work/gate"
cp "$root/check-deb.sh" "$work/gate/"
expect "drift: --accept records a snapshot" 0 "$work/gate/check-deb.sh" --accept "$work/base.deb"
expect "drift: unchanged package passes" 0 "$work/gate/check-deb.sh" "$work/base.deb"
expect "drift: new dependency fails" 1 env -u CI "$work/gate/check-deb.sh" "$work/depends.deb"
check "drift: new dependency shown" has "+relation Depends: libnew1"
expect "drift: changed script fails in CI" 1 env CI=true "$work/gate/check-deb.sh" "$work/script.deb"
check "drift: changed script named in CI" has "postinst changed"
check "drift: script text kept out of CI logs" lacks "$marker"
expect "drift: changed script fails locally" 1 env -u CI "$work/gate/check-deb.sh" "$work/script.deb"
check "drift: script text shown locally" has "$marker"

# --- check-dist.sh: release guard --------------------------------------------

# make_dist NAME EXTRA_SRC_FILE EXTRA_DIST_FILE: a repo root with dist/ built.
make_dist() {
  local d=$work/$1 f
  mkdir -p "$d/dist" "$d/src/claude-desktop"
  for f in .SRCINFO PKGBUILD check-deb.sh claude-desktop.sh upstream.lock $2; do
    touch "$d/src/claude-desktop/$f"
  done
  bsdtar -czf "$d/dist/claude-desktop.src.tar.gz" -C "$d/src" claude-desktop
  touch "$d/dist/SHA256SUMS" ${3:+"$d/dist/$3"}
  rm -r "$d/src"
}
make_dist dist-ok "" ""
expect "release: our files only passes" 0 "$root/ci/check-dist.sh" "$work/dist-ok"
make_dist dist-pkg "" claude-desktop-1.0-1-x86_64.pkg.tar.zst
expect "release: built package in dist/ fails" 1 "$root/ci/check-dist.sh" "$work/dist-pkg"
make_dist dist-src claude-desktop_1.0_amd64.deb ""
expect "release: .deb inside source package fails" 1 "$root/ci/check-dist.sh" "$work/dist-src"
make_dist dist-git "" ""
git -C "$work/dist-git" init -q
cp /usr/bin/true "$work/dist-git/helper"
git -C "$work/dist-git" add helper
expect "release: tracked binary fails" 1 "$root/ci/check-dist.sh" "$work/dist-git"

# --- claude-desktop.sh: launcher ---------------------------------------------

printf '#!/bin/sh\nprintf "%%s|" "$@"\n' > "$work/stub"
chmod +x "$work/stub"
sed "s|/usr/lib/claude-desktop/claude-desktop|$work/stub|" "$root/claude-desktop.sh" > "$work/wrapper"
grep -q "$work/stub" "$work/wrapper" ||
  { echo "ci/test.sh: claude-desktop.sh no longer execs /usr/lib/claude-desktop/claude-desktop" >&2; exit 1; }
argv() { env XDG_CURRENT_DESKTOP="$1" sh "$work/wrapper" "${@:2}"; }
flag=--password-store=gnome-libsecret
check "launcher: Hyprland gets keyring flag" test "$(argv Hyprland claude://x 'a b')" = "$flag|claude://x|a b|"
check "launcher: KDE unchanged" test "$(argv KDE claude://x 'a b')" = "claude://x|a b|"
check "launcher: GNOME unchanged" test "$(argv ubuntu:GNOME claude://x)" = "claude://x|"
check "launcher: unset desktop gets keyring flag" \
  test "$(env -u XDG_CURRENT_DESKTOP sh "$work/wrapper" x)" = "$flag|x|"
check "launcher: user's --password-store wins" test "$(argv Hyprland --password-store=basic)" = "--password-store=basic|"

# --- lint: set -e trap ---------------------------------------------------------

# `[[ cond ]] && cmd` returns 1 when cond is false. As the last command of a
# loop or function under set -e, that silently stops the script.
if grep -nE '^\s*\[\[[^]]*\]\]\s*&&' "$root"/*.sh "$root"/ci/*.sh "$root/PKGBUILD" > "$work/out"; then
  fail "lint: write '[[ ... ]] && cmd' as an if statement"
  sed 's/^/      /' "$work/out"
else
  pass "lint: no '[[ ... ]] && cmd' statements"
fi

echo
if ((failures)); then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
