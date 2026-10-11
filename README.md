# claude-desktop-arch

Installs Anthropic's official Linux build of
[Claude Desktop](https://code.claude.com/docs/en/desktop-linux) on Arch Linux.

The PKGBUILD downloads the `.deb` from Anthropic's apt repository and installs
its files unchanged. It uses no AUR packages, no third-party patches, and no
repackaged Windows installer.

> [!NOTE]
> This is an unofficial community package and is not affiliated with Anthropic.
> Anthropic supports the Linux app only on Debian and Ubuntu. Report problems
> with this package here, not to Anthropic.

## Requirements

- Arch Linux, x86_64
- `base-devel`, `curl`, and `gnupg`

## Install

This repository never distributes Claude Desktop itself. Both install methods
run `makepkg` on your computer, and `makepkg` downloads the app from Anthropic.

### From a release

Each [release](https://github.com/moedesux/claude-desktop-arch/releases)
contains a source package: the PKGBUILD and the helper scripts, with the
SHA256 of Anthropic's `.deb` pinned. A daily GitHub Actions job publishes a
new release when Anthropic publishes a new version.

```sh
curl -fLO https://github.com/moedesux/claude-desktop-arch/releases/latest/download/claude-desktop.src.tar.gz
tar -xf claude-desktop.src.tar.gz
cd claude-desktop
makepkg -si
```

To update, download the newest release and run the same commands.

### From a clone

```sh
git clone https://github.com/moedesux/claude-desktop-arch.git
cd claude-desktop-arch
makepkg -si
```

To update, run `git pull && makepkg -si`. You can also check Anthropic's
repository yourself with `update.sh`, as described in [Update](#update).

Start **Claude** from your application launcher, or run `claude-desktop`. On
Wayland, the app uses Wayland directly, without XWayland. This was tested on
Hyprland.

## Update

```sh
./update.sh && makepkg -si
```

`update.sh` finds the newest version in Anthropic's apt repository and pins it
in the PKGBUILD. Each step is checked before the next one runs:

1. The fingerprint of `keys/claude-desktop-archive-keyring.asc` must be
   `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`. Anthropic publishes this
   fingerprint in its [install guide](https://code.claude.com/docs/en/desktop-linux).
2. `InRelease` must have a valid signature from that key and must not be past
   its `Valid-Until` date. The date check blocks an old, replayed index. A bad,
   expired, or revoked signature stops the update. If `InRelease` also has a
   signature from an unknown key, `update.sh` continues and shows a warning,
   because this happens when Anthropic rotates keys.
3. `Packages` must match the SHA256 listed in the signed `InRelease`.
4. The `.deb` SHA256 comes from `Packages`. makepkg checks the download
   against it.

If any step fails, `update.sh` stops and leaves the PKGBUILD unchanged.

### Daily update notification (optional)

A systemd user timer can check for a new version once a day and send a desktop
notification. It sends a critical notification if signature verification
fails. It does not install anything.

```sh
mkdir -p ~/.config/systemd/user
sed "s#@REPO@#$PWD#" systemd/claude-desktop-update-check.service \
  > ~/.config/systemd/user/claude-desktop-update-check.service
cp systemd/claude-desktop-update-check.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now claude-desktop-update-check.timer
```

Run the installation commands from the repository directory. If you move the
directory, run them again.

To check now, run `./update.sh --check`.

### When upstream changes the package

`upstream.lock` holds a reviewed snapshot of the upstream details that the
PKGBUILD relies on. Each line starts with its kind:

| Kind | Contents |
|---|---|
| `relation` | Depends, Recommends, and other package relations |
| `script` | SHA256 of each Debian install or remove script, which the PKGBUILD reimplements. If a hash changes, `check-deb.sh` prints the new script in full. |
| `library` | System libraries that the shipped binaries link |
| `file` | File layout and permissions |
| `path` | Absolute system paths that the app's code names |

On every build, `prepare()` runs `check-deb.sh`. If the new `.deb` differs
from the snapshot, the build stops and prints a diff. To continue:

1. Read the diff and update the PKGBUILD. For example, add a dependency or
   adjust a Cowork path link.
2. Record the new state:

   ```sh
   ./check-deb.sh --accept claude-desktop_<version>_amd64.deb
   ```

3. Run `makepkg -si`.

## Automation

The workflow `.github/workflows/build.yml` runs `ci/build.sh` in a clean
`archlinux:base-devel` container:

- **Push and pull request:** lint the scripts, run namcap and `ci/test.sh`,
  build the package (which includes the `check-deb.sh` gate), run the smoke
  test, and run `ci/check-dist.sh` on the release files.
- **Daily:** run `update.sh`. If Anthropic published a new version and the
  gate passes, the workflow commits the new PKGBUILD and publishes a release.
  If the upstream packaging changed, the workflow opens an issue with the
  diff and publishes no release. Any other failure of the daily run, such as
  a signature check or the smoke test, also opens an issue. A repeat failure
  adds a comment to the open issue.

The smoke test (`ci/smoke.sh`) installs the built package in the clean
container, then:

1. Runs `ldd` on every binary before installing anything else, and fails on
   a library that `depends` does not provide.
2. Starts the app through the launcher with `XDG_CURRENT_DESKTOP=Hyprland`,
   an unlocked GNOME Keyring, and a virtual X display.
3. Fails if the app exits within 30 seconds or logs that it can't store
   secrets.

It catches broken runtime behavior that the packaging snapshot can't see.
It doesn't catch a library the app loads only when you use a specific
feature.

Releases contain only the source package. The built `.pkg.tar.zst` is never
uploaded, because it contains Anthropic's app. In CI, `check-deb.sh` names a
changed maintainer script without printing it, so public logs never contain
Anthropic's code.

`ci/test.sh` runs offline in a few seconds and needs no container. It tests
the signature checks with a fake apt repository and throwaway keys, the drift
gate with small hand-built `.deb` files, the release guard, and the launcher.
Its GnuPG home is temporary, so it never touches your keyring.

To run the full CI build locally:

```sh
podman run --rm -v "$PWD":/repo:Z -w /repo docker.io/library/archlinux:base-devel ci/build.sh
```

Run it on a copy of the repository: `ci/build.sh` changes file ownership to a
build user.

## Changes from the Debian package

- **Launcher.** Upstream's `/usr/bin/claude-desktop` is a symlink to the
  binary. This package replaces it with a short wrapper script. Chromium picks
  where to store secrets from `XDG_CURRENT_DESKTOP`. On desktops it doesn't
  recognize, such as Hyprland, Sway, and niri, it falls back to plain-text
  storage, and the app shows "No system keyring is available". On those
  desktops the wrapper adds `--password-store=gnome-libsecret`, so the app
  uses the Secret Service from GNOME Keyring, KeePassXC, or a similar program.
  On KDE and GNOME the wrapper adds nothing.
- **Install-time files.** Upstream's postinst creates the GNOME search
  provider, the MIME types, and the `ccd` link at install time. This package
  ships them as normal package files.
- **Debian-only steps.** The postinst steps for the apt repository and
  AppArmor do not apply to Arch, so this package leaves them out.
- **`chrome-sandbox`.** This package installs it without setuid root. Arch
  allows unprivileged user namespaces, so Chromium's namespace sandbox works
  without it. On a kernel that disables unprivileged user namespaces, such as
  `linux-hardened`, the sandbox can't start and the app may not run. This case
  is untested.
- **Cowork paths.** Cowork looks for its VM files only at Debian paths.
  Symlinks point those paths at the firmware from `edk2-ovmf` and at the
  `virtiofsd` binary in the `.deb`.

## Cowork

Cowork runs tasks in a local virtual machine. It needs hardware virtualization
turned on in your firmware, two optional packages, and membership in the `kvm`
group:

```sh
sudo pacman -S --asdeps qemu-system-x86 edk2-ovmf
sudo usermod -aG kvm "$USER"
```

After you join the group, log out and back in.

## Troubleshooting

- **"No system keyring is available", or the app asks you to sign in every
  time.** The app saves your sign-in through the Secret Service. Install and
  unlock `gnome-keyring` (or use KWallet on KDE Plasma), quit Claude
  completely, including the tray icon, then start it again. To check whether
  it worked, run `grep safeStorage ~/.config/Claude/logs/main.log | tail -1`.
  If the newest line says `isEncryptionAvailable=false`, Claude still can't
  reach an unlocked keyring.
- **The build stops at `check-deb.sh`.** The upstream package changed. See
  [When upstream changes the package](#when-upstream-changes-the-package).

## Files

| Path | Purpose |
|---|---|
| `PKGBUILD` | Repackages the `.deb` |
| `update.sh` | Updates the PKGBUILD to the newest version and checks signatures |
| `check-deb.sh` | Compares a `.deb` with the reviewed snapshot |
| `ci/build.sh` | Lints, tests, builds, and makes the release source package in a container |
| `ci/test.sh` | Offline behavior tests |
| `ci/smoke.sh` | Installs and launches the built package in CI |
| `ci/check-dist.sh` | Fails if a release or the git tree would include Anthropic's code |
| `.github/workflows/build.yml` | CI, daily update check, and releases |
| `claude-desktop.sh` | Launcher that selects the system keyring on desktops such as Hyprland |
| `keys/` | Anthropic's public signing key for the apt repository |
| `upstream.lock` | Reviewed snapshot of upstream packaging |
| `systemd/` | Optional daily update check |

## License

The packaging scripts are licensed under [0BSD](LICENSE).

Claude Desktop is proprietary software from Anthropic PBC. This repository
does not contain or redistribute it. The build downloads the application from
Anthropic. `keys/` contains Anthropic's public signing key, which Anthropic
publishes for package verification.
