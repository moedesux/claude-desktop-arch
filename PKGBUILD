# Maintainer: moedesux
#
# Repackages Anthropic's official Debian package. Nothing is rebuilt or
# patched; the .deb payload is installed as-is plus a few Arch shims.
# Bump the version with ./update.sh, which checks Anthropic's apt signature.

pkgname=claude-desktop
pkgver=2.31226.1
pkgrel=1
pkgdesc="Claude desktop app (official Anthropic Linux build)"
arch=('x86_64')
url="https://code.claude.com/docs/en/desktop-linux"
license=('LicenseRef-Anthropic-Proprietary')
# Linked by the shipped ELF files (objdump NEEDED), then the rest of the
# .deb's Depends, which the app loads at runtime.
depends=('alsa-lib' 'at-spi2-core' 'cairo' 'dbus' 'expat' 'glib2' 'glibc'
         'gtk3' 'libcap-ng' 'libcups' 'libgcc' 'libpipewire' 'libseccomp'
         'libstdc++' 'libx11' 'libxcb' 'libxcomposite' 'libxdamage' 'libxext'
         'libxfixes' 'libxkbcommon' 'libxrandr' 'mesa' 'nspr' 'nss' 'pango'
         'systemd-libs'
         'hicolor-icon-theme' 'libnotify' 'libsecret' 'libxtst'
         'util-linux-libs' 'xdg-desktop-portal' 'xdg-utils')
# The .deb's Recommends.
optdepends=('gnome-keyring: store sign-in (or kwallet on KDE, or another Secret Service provider)'
            'libayatana-appindicator: tray icon'
            'bubblewrap: Claude Code shell sandbox'
            'socat: Claude Code shell sandbox'
            'qemu-system-x86: Cowork VM (also needs KVM and the kvm group)'
            'edk2-ovmf: Cowork VM firmware'
            'gjs: GNOME Shell search provider')
conflicts=('claude-desktop-bin' 'claude-desktop-extra')
# Prebuilt Electron; stripping can corrupt its embedded snapshots.
options=('!strip' '!debug')
source=("https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/$pkgname/${pkgname}_${pkgver}_amd64.deb"
        'check-deb.sh'
        'upstream.lock'
        'claude-desktop.sh')
# The local files are tracked in git next to this PKGBUILD.
sha256sums=('5a9bebdfcb1df6ce38767b373f3a7fabf77156a2ddd8a3f5d04961da5bde305e'
            'SKIP'
            'SKIP'
            'SKIP')

prepare() {
  # Stop if upstream changed anything the steps below assume. The check
  # unpacks about 800 MB, so keep it on disk instead of a RAM-backed /tmp.
  TMPDIR=$srcdir bash check-deb.sh "${source[0]##*/}"
}

package() {
  tar -xf data.tar.xz -C "$pkgdir"
  rm -r "$pkgdir/usr/share/lintian"

  # Upstream's /usr/bin/claude-desktop is a symlink to the binary. The wrapper
  # makes Chromium use the system keyring on desktops it doesn't recognize.
  rm "$pkgdir/usr/bin/claude-desktop"
  install -Dm755 claude-desktop.sh "$pkgdir/usr/bin/claude-desktop"

  # Arch allows unprivileged user namespaces, so Chromium's namespace
  # sandbox works without this helper being setuid root.
  chmod 0755 "$pkgdir/usr/lib/$pkgname/chrome-sandbox"

  # Files upstream's postinst copies at install time, shipped as package
  # files instead. Its apt-repo and AppArmor steps don't apply to Arch.
  local res="$pkgdir/usr/lib/$pkgname/resources"
  install -Dm644 -t "$pkgdir/usr/share/gnome-shell/search-providers" \
    "$res/gnome-search-provider/com.anthropic.Claude.search-provider.ini"
  install -Dm644 -t "$pkgdir/usr/share/dbus-1/services" \
    "$res/gnome-search-provider/com.anthropic.Claude.SearchProvider.service"
  install -Dm644 -t "$pkgdir/usr/share/mime/packages" \
    "$res/linux-mime/com.anthropic.Claude.xml"
  if [[ -x $res/bin/ccd ]]; then
    ln -s "../lib/$pkgname/resources/bin/ccd" "$pkgdir/usr/bin/ccd"
  fi

  # Cowork only probes Debian paths: /usr/share/OVMF/OVMF_{CODE,VARS}_4M.fd
  # and /usr/{libexec,bin}/virtiofsd. edk2-ovmf links /usr/share/OVMF to
  # /usr/share/edk2, and the .deb bundles its own virtiofsd.
  install -d "$pkgdir/usr/share/edk2"
  ln -s x64/OVMF_CODE.4m.fd "$pkgdir/usr/share/edk2/OVMF_CODE_4M.fd"
  ln -s x64/OVMF_VARS.4m.fd "$pkgdir/usr/share/edk2/OVMF_VARS_4M.fd"
  ln -s "../lib/$pkgname/resources/virtiofsd" "$pkgdir/usr/bin/virtiofsd"

  install -Dm644 "$pkgdir/usr/share/doc/$pkgname/copyright" \
    "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
