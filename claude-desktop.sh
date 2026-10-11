#!/bin/sh
# Chromium picks its password store from XDG_CURRENT_DESKTOP. On desktops it
# doesn't recognize (Hyprland, Sway, niri, ...) it falls back to plain-text
# storage, so the app can't save your sign-in. Ask for the Secret Service
# (GNOME Keyring, KeePassXC, ...) instead. KDE and GNOME already work.
case ":${XDG_CURRENT_DESKTOP-}:" in
  *:KDE:* | *:GNOME:*) ;;
  *)
    case " $* " in
      *" --password-store="*) ;;
      *) set -- --password-store=gnome-libsecret "$@" ;;
    esac
    ;;
esac
exec /usr/lib/claude-desktop/claude-desktop "$@"
