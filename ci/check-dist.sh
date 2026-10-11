#!/usr/bin/env bash
# Fail if a release or the git tree would publish Anthropic's code.
#
#   ci/check-dist.sh DIR    DIR is the repo root, with dist/ already built
#
# Releases may hold only the source package and its checksum, and the source
# package only our own files. The allowlist is deliberate: adding a file to
# source=() means updating it here, after checking the file is ours.
set -euo pipefail
cd "${1:?usage: check-dist.sh DIR}"

allowed='claude-desktop/
claude-desktop/.SRCINFO
claude-desktop/PKGBUILD
claude-desktop/check-deb.sh
claude-desktop/claude-desktop.sh
claude-desktop/upstream.lock'

fail() { echo "check-dist.sh: $*" >&2; exit 1; }

got=$(ls -A dist | LC_ALL=C sort)
[[ $got == $'SHA256SUMS\nclaude-desktop.src.tar.gz' ]] ||
  fail "dist/ must hold exactly SHA256SUMS and claude-desktop.src.tar.gz, found: $(echo $got)"

got=$(bsdtar -tf dist/claude-desktop.src.tar.gz | LC_ALL=C sort)
[[ $got == "$allowed" ]] ||
  fail "unexpected source package contents:"$'\n'"$(diff <(echo "$allowed") <(echo "$got"))"

if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    case $f in *.deb | *.pkg.tar.*) fail "tracked package file: $f" ;; esac
    if [[ -f $f && $(head -c4 "$f" | od -An -c | tr -d ' ') == 177ELF ]]; then
      fail "tracked binary: $f"
    fi
  done < <(git ls-files -z)
else
  echo "check-dist.sh: not a git checkout, skipping the tracked-files check" >&2
fi
echo "check-dist.sh: release contents and tracked files are ours."
