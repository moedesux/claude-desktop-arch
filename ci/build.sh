#!/usr/bin/env bash
# Lint, test, build, smoke-launch, and make the release source package in a
# clean Arch container.
# CI runs this; you can run the same thing locally with podman (see README).
#
#   ci/build.sh            build the PKGBUILD as committed
#   ci/build.sh --update   first move the PKGBUILD to Anthropic's newest version
#
# Runs as root in archlinux:base-devel. makepkg runs as the user "builder".
# Outputs: build.log, and dist/ with the source package and SHA256SUMS.
# dist/ holds no Anthropic code: makepkg --source leaves out the .deb.
set -euo pipefail
cd "$(dirname "$0")/.."

update=false
case "$*" in
  '') ;;
  --update) update=true ;;
  *) echo "usage: ci/build.sh [--update]" >&2; exit 2 ;;
esac

pacman -Syu --noconfirm --needed diffutils git namcap shellcheck
id builder > /dev/null 2>&1 || useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: /usr/bin/pacman' > /etc/sudoers.d/builder
chown -R builder: .
# sudo drops the environment; check-deb.sh needs CI to keep scripts out of logs.
as_builder() { sudo -u builder -- env "CI=${CI-}" "$@"; }
if [[ -n ${CI-} ]] && ! as_builder sh -c '[ -n "$CI" ]'; then
  echo "ci/build.sh: CI does not reach the build user; script text would leak into logs" >&2
  exit 1
fi

if $update; then
  as_builder ./update.sh
fi

shellcheck -S warning update.sh check-deb.sh ci/*.sh
shellcheck -s sh -S warning claude-desktop.sh
findings=$(namcap PKGBUILD)
[[ -z $findings ]] || { echo "$findings"; exit 1; }
as_builder ci/test.sh

# prepare() runs check-deb.sh, so upstream packaging drift fails here.
as_builder makepkg --syncdeps --noconfirm --cleanbuild 2>&1 | tee build.log
pkgs=(claude-desktop-*-x86_64.pkg.tar.zst)
ci/smoke.sh "${pkgs[0]}"

rm -rf dist
as_builder makepkg --source --force
as_builder mkdir dist
as_builder mv claude-desktop-*.src.tar.gz dist/claude-desktop.src.tar.gz
(cd dist && as_builder sh -c 'sha256sum claude-desktop.src.tar.gz > SHA256SUMS')
as_builder ci/check-dist.sh .
