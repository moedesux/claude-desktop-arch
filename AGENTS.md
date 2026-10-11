# AGENTS.md

- Tests: `ci/test.sh` (offline, isolated GNUPGHOME). Full CI build with the smoke launch (`ci/smoke.sh`): README "Automation".
- Upstream drift (build stops in `prepare()`): follow README "When upstream changes the package", ending with `./check-deb.sh --accept <deb>`.
- Run `ci/build.sh` only on a copy of the repo: it chowns the tree to a build user.
- Publish only our own files. Anthropic's `.deb`, built packages, and maintainer-script text stay out of git, releases, logs, and issues; `ci/check-dist.sh` enforces the release side.
- Review rules: `CODING_STANDARDS.md`.
