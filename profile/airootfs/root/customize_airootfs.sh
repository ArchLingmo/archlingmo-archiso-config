#!/usr/bin/env bash
set -euo pipefail

mkdir -p /usr/share/xsessions
cat > /usr/share/xsessions/lingmo-xsession.desktop <<'EOF'
[Desktop Entry]
Type=Application
Exec=/usr/local/bin/lingmo-session-wrapper
TryExec=/usr/bin/lingmo-session
Name=Lingmo Desktop
Keywords=session
Comment=session
EOF

# Ensure the live user has a real home directory with the expected skeleton.
# ArchISO may ship the user in /etc/passwd without creating /home/<user>.
if id -u lingmo >/dev/null 2>&1; then
  install -d -m 0755 -o lingmo -g lingmo /home/lingmo
  cp -a /etc/skel/. /home/lingmo/ 2>/dev/null || true
  install -d -m 0755 -o lingmo -g lingmo /home/lingmo/Desktop
  chown -R lingmo:lingmo /home/lingmo
  # Rootless Podman (Linux boxes of lingmo-winrun) needs subordinate IDs; users
  # made by the installer get them from useradd, the live user doesn't
  grep -q '^lingmo:' /etc/subuid 2>/dev/null || usermod --add-subuids 100000-165535 lingmo
  grep -q '^lingmo:' /etc/subgid 2>/dev/null || usermod --add-subgids 100000-165535 lingmo
fi

if ! command -v calamares >/dev/null 2>&1; then
  cache_dir=/tmp/pacman-cache
  mkdir -p "$cache_dir"
  pacman_conf=/tmp/pacman-no-checkspace.conf
  cp /etc/pacman.conf "$pacman_conf"
  sed -i '/^CheckSpace$/d' "$pacman_conf"

  # The ISO build may have run with a working dir bind-mounted from the host.
  # In that case, ownership/permissions of the keyring directory can get messed up,
  # which breaks signature verification in arch-chroot.
  rm -rf /etc/pacman.d/gnupg
  pacman-key --init
  pacman-key --populate archlinux archlinuxcn || pacman-key --populate archlinux

  # What the image has before the build tools: whatever gets added from here on
  # (git, base-devel, Calamares' makedepends...) is removed again at the end,
  # except what Calamares itself needs at run time
  pacman -Qq | sort > /tmp/packages-before

  pacman --config "$pacman_conf" --cachedir "$cache_dir" -Syy --noconfirm --needed git base-devel

  if ! id -u builder >/dev/null 2>&1; then
    useradd -m builder
  fi
  usermod -aG wheel builder

  install -d -m 0755 -o builder -g builder /home/builder/.config/pacman
  cat > /home/builder/.config/pacman/makepkg.conf <<'EOF'
PACMAN='/usr/bin/pacman'
PACMAN_OPTS=(--noconfirm --needed --config /tmp/pacman-no-checkspace.conf --cachedir /tmp/pacman-cache)
EOF
  chown builder:builder /home/builder/.config/pacman/makepkg.conf

  install -d -m 0755 -o builder -g builder /tmp/aur
  su - builder -c '
    set -euo pipefail
    cd /tmp/aur
    rm -rf calamares
    git clone --depth 1 https://aur.archlinux.org/calamares.git
    cd calamares
    MAKEFLAGS="-j$(nproc)" makepkg -s --noconfirm
  '

  calamares_pkg="$(ls -1 /tmp/aur/calamares/calamares-*.pkg.tar.* | grep -v -- '-debug-' | head -n 1)"
  pacman --config "$pacman_conf" --cachedir "$cache_dir" -U --noconfirm "$calamares_pkg"

  # Drop the build tools (gcc, cmake, gdb, boost...: ~500 MiB installed) so the
  # ISO stays under GitHub's 2 GiB release limit. Everything added since the
  # snapshot becomes a dependency; whatever nothing needs is removed.
  pacman -Qq | sort | comm -13 /tmp/packages-before - | grep -vx calamares > /tmp/packages-added || true
  if [ -s /tmp/packages-added ]; then
    pacman -D --asdeps $(cat /tmp/packages-added) >/dev/null
    pacman -D --asexplicit calamares >/dev/null
    # Only packages added for the build: something already in the image is never touched
    while :; do
      unneeded="$( (pacman -Qtdq || true) | sort | comm -12 - /tmp/packages-added)"
      [ -n "$unneeded" ] || break
      pacman -R --noconfirm $unneeded
    done
  fi
  rm -f /tmp/packages-before /tmp/packages-added

  # The build user and its files were only needed to build Calamares: don't ship
  # them (the user would show up on the login screen of installed systems)
  userdel -r builder 2>/dev/null || true
  rm -rf /tmp/aur "$cache_dir" "$pacman_conf"
fi

# Packages nothing needs, not even as an optional dependency: base-devel and its
# chain (gdb, boost-libs, texinfo... ~110 MiB) stayed behind as orphans in the
# 2026.10.25 and 10.27 images. dkms keeps gcc and make
while :; do
  orphans="$(pacman -Qttdq || true)"
  [ -n "$orphans" ] || break
  pacman -Rn --noconfirm $orphans
done
