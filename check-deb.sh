#!/usr/bin/env bash
# Compare a claude-desktop .deb against upstream.lock, the reviewed snapshot of
# every upstream detail the PKGBUILD relies on. Any difference fails, so a
# packaging change upstream can't slip through a version bump unnoticed.
#
#   check-deb.sh FILE.deb            fail with a diff if upstream drifted
#   check-deb.sh --accept FILE.deb   after adapting PKGBUILD, record the new state
#
# Each lock line starts with its kind:
#   relation  Depends, Recommends, ... -> depends and optdepends
#   script    maintainer script hash   -> steps the PKGBUILD reimplements
#   library   linked system library    -> depends
#   file      mode and path            -> install steps and links
#   path      system path in app code  -> compatibility links (Cowork)
set -euo pipefail

accept=false
if [[ ${1-} == --accept ]]; then
  accept=true
  shift
fi
deb=$(realpath "${1:?usage: check-deb.sh [--accept] FILE.deb}")
name=$(basename "$deb")
lock=$(dirname "$(realpath "$0")")/upstream.lock

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/ctl" "$tmp/data"
bsdtar -xf "$deb" -C "$tmp"
tar -xf "$tmp/control.tar.xz" -C "$tmp/ctl"
tar -xf "$tmp/data.tar.xz" -C "$tmp/data"
app=$tmp/data/usr/lib/claude-desktop

relations() {
  awk -F': ' '/^(Pre-Depends|Depends|Recommends|Suggests|Conflicts|Breaks|Provides|Replaces):/ {
    n = split($2, d, /, /); for (i = 1; i <= n; i++) print $1 ": " d[i] }' "$tmp/ctl/control"
}

# Hashed, not copied: they are Anthropic's code and this repo is public.
scripts() {
  local f
  for f in preinst postinst prerm postrm config triggers conffiles; do
    if [[ -f $tmp/ctl/$f ]]; then
      echo "$f $(sha256sum < "$tmp/ctl/$f" | cut -d' ' -f1)"
    fi
  done
}

# Libraries the shipped ELF files link, minus the ones bundled with the app.
libraries() {
  find "$app" -name '*.so*' -printf '%f\n' | sort -u > "$tmp/bundled"
  find "$app" -type f -print0 | while IFS= read -r -d '' f; do
    if [[ $(head -c4 "$f" | od -An -c | tr -d ' ') == 177ELF ]]; then
      objdump -p "$f" | awk '/NEEDED/ { print $2 }'
    fi
  done | sort -u | comm -23 - "$tmp/bundled"
}

# Everything outside the app directory, plus the resources the PKGBUILD links
# or installs. Locale JSON files are left out. Mode is kept to catch setuid.
files() {
  tar -tvf "$tmp/data.tar.xz" | awk '{ $2 = $3 = $4 = $5 = ""; print }' | tr -s ' ' |
    awk '{ p = $2 }
      p !~ /^\.\/usr\/lib\/claude-desktop\// ||
      p ~ /^\.\/usr\/lib\/claude-desktop\/[^\/]+$/ ||
      p ~ /\/resources\/[^\/]+$/ && p !~ /\/resources\/[a-z][a-z][a-z]?(-[A-Za-z0-9]+)?\.json$/ ||
      p ~ /\/resources\/(bin|gnome-search-provider|linux-mime)\//'
}

# Absolute system paths named in the app's code. This is how Cowork's Debian
# firmware and virtiofsd paths were found.
paths() {
  LC_ALL=C grep -aohE "[\"'\`]/(usr|etc|opt|lib|bin|sbin)/[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*[\"'\`]" \
    "$app/resources/app.asar" | tr -d "\"'\`"
}

for kind in relation script library file path; do
  case $kind in
    relation) relations ;; script) scripts ;; library) libraries ;;
    file) files ;; path) paths ;;
  esac | LC_ALL=C sort -u | sed "s/^/$kind /"
done > "$tmp/snapshot"

if $accept; then
  cp "$tmp/snapshot" "$lock"
  echo "Recorded $name in $lock. Commit it with the PKGBUILD changes."
  exit 0
fi

if ! diff -u --label reviewed --label "$name" "$lock" "$tmp/snapshot" > "$tmp/drift"; then
  cat "$tmp/drift" >&2
  # A hash shows that a script changed, not how, so print new ones in full.
  # Not in CI: public logs would republish Anthropic's code.
  comm -13 <(grep '^script ' "$lock" | sort) <(grep '^script ' "$tmp/snapshot" | sort) |
    while read -r _ f _; do
      if [[ -n ${CI-} ]]; then
        printf '\n%s changed. Run ./check-deb.sh %s locally to read it.\n' "$f" "$name" >&2
      else
        printf '\n==== %s in %s ====\n' "$f" "$name" >&2
        cat "$tmp/ctl/$f" >&2
      fi
    done
  cat >&2 <<EOF

check-deb.sh: upstream packaging changed since the last review (diff above).
Adapt PKGBUILD to it, then run:
  ./check-deb.sh --accept $name
EOF
  exit 1
fi
echo "check-deb.sh: $name matches the reviewed snapshot."
