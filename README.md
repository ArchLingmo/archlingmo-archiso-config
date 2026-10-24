# archlingmo-archiso-config
Archiso config used by ArchLingmo (a branch of Lingmo OS based on Arch Linux).
> [!NOTE]
> This project is still WIP and not ready for production environment.

## Build
```console
# pacman -Syu archiso git grub
# pacman -Syu base-devel pacman-contrib   # necessário para `make pkgs`/`make build`
# pacman-key --lsign-key 'farseerfc@archlinux.org'
# cat >> /etc/pacman.conf << EOF
[archlinuxcn]
Server = https://repo.archlinuxcn.org/$arch
EOF
# pacman -Sy archlinuxcn-keyring
$ git clone --depth 1 https://github.com/devalexandre/archlingmo-archiso-config
$ cd archlingmo-archiso-config

# ISO (normal)
$ make iso

# ISO via container (se não tiver `archiso`/`mkarchiso` no host)
$ make iso-container

# ISO via container usando pacotes buildados em `$(PKGBUILDER_DIR)/outputs` (recomendado durante dev)
$ make iso-container-local

# ISO offline com repositório local embutido (pacotes Lingmo buildados localmente)
# - ajusta/override via PKGBUILDER_DIR e LOCAL_REPO_DIR
$ make build
```
Find the ISO file in `out/` after building.

## Release (CI)
`.github/workflows/release-iso.yml` builds the ISO from `[archlingmo]` and
publishes it as a GitHub release of this repo; the site
(devalexandre.github.io/archlingmo) shows the latest release by itself.

The tag is the ISO date, `YYYY.MM.DD`. Tag the commit and push the tag:

```console
$ git tag 2026.10.24
$ git push origin 2026.10.24
```

The workflow builds with `SOURCE_DATE_EPOCH` set to that date, so the ISO is
`archlingmo-2026.10.24-x86_64.iso` even if the runner builds it a day later.
It then runs `scripts/release-iso.sh`:
- fails if the ISO is 2 GiB or larger (GitHub's limit per release file);
- writes the `.sha256` and the package list (`.pkglist.txt`, read from the ISO),
  and logs the package diff against the previous release;
- creates the release (or replaces the files of an existing one) with the
  ISO, `.sha256` and `.pkglist.txt`, and the usual notes (the site reads the SHA-256 from them).

You can also run it from the Actions tab (*Release ISO* → *Run workflow*) with
an optional tag, which defaults to today's date (UTC). It needs only the
`GITHUB_TOKEN`; the job takes about 1 h on `ubuntu-latest`.

Local fallback, from the workspace (builds with your Docker, uploads with `gh`):

```console
$ make iso          # or: make -C archlingmo-archiso-config iso-container FORCE_REBUILD=1
$ make upload-iso   # same scripts/release-iso.sh; also updates the site's site.json
```

`scripts/release-iso.sh --dry-run out/<iso>` runs the checks and prints the
notes without uploading anything.

## Component CI
`.github/workflows/component-check.yml` is the reusable build check every
Lingmo component calls from its own `.github/workflows/ci.yml` (on push and pull
requests to `main`):

```yaml
jobs:
  check:
    uses: devalexandre/archlingmo-archiso-config/.github/workflows/component-check.yml@main
    # with:
    #   tests: false                  # do not build or run the tests
    #   extra-packages: python-pytest # test-only deps
```

It runs `ci/component-check.sh` in `archlinux:latest`: it adds `[archlingmo]`
(the same block as `profile/pacman.conf`), installs base-devel, cmake, ninja,
extra-cmake-modules and qt6-tools plus the component's depends, builds it like
the workspace's `scripts/mkpkg.sh` (cmake configure + ninja + install into a
DESTDIR) and runs ctest when the component has tests. The metapackage
(`lingmo-desktop`) runs `makepkg --printsrcinfo`. Nothing is published.

Locally, with the component checkout mounted read-only:

```console
$ docker run --rm -v "$PWD":/ci:ro -v ../lingmo-clock:/src:ro archlinux:latest \
    bash /ci/ci/component-check.sh all lingmo-clock /src
```

> [!IMPORTANT]
> `ci/packaging/components.conf` and `ci/scripts/common.sh` are copies of the
> workspace's `packaging/components.conf` and `scripts/common.sh` (the workspace
> is not a repo). After changing them, run `make sync-ci` in the workspace and
> commit `ci/` here. A new component also needs its own `ci.yml`.

### See also
[Archiso page on ArchWiki](https://wiki.archlinux.org/title/Archiso)
