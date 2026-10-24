#!/bin/bash
# CI check for one Lingmo component, run as root in an archlinux:latest
# container (GitHub Actions, or `docker run` locally). It builds the component
# the way the workspace's scripts/mkpkg.sh does (cmake_configure + ninja +
# install into a DESTDIR), then runs ctest when the component has tests.
# It never publishes anything.
#
# usage: component-check.sh <step> <component> [srcdir]
#   setup  add [archlingmo] (same block as profile/pacman.conf), pacman -Syu, git
#   deps   install the build deps: base-devel cmake ninja extra-cmake-modules
#          qt6-tools + the component's depends from components.conf
#   build  cmake configure + ninja + ninja install (DESTDIR); a metapackage
#          (PKGBUILD, no CMakeLists.txt) runs makepkg --printsrcinfo instead
#   test   ctest, when the build has tests
#   all    every step above
# env: TESTS=1|0 (default 1)  EXTRA_PACKAGES="pkg ..."  BUILD_DIR
#
# ci/packaging/components.conf and ci/scripts/common.sh are verbatim copies of
# the workspace files (sync with `make sync-ci` in the workspace).
set -euo pipefail
CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# common.sh sets ROOT=$CI_DIR and CONF=$CI_DIR/packaging/components.conf
source "$CI_DIR/scripts/common.sh"
PROFILE_PACMAN_CONF="$CI_DIR/../profile/pacman.conf"

step=${1:?usage: component-check.sh <setup|deps|build|test|all> <component> [srcdir]}
component=${2:?component name (repo column of components.conf)}
src=${3:-.}
TESTS=${TESTS:-1}
EXTRA_PACKAGES=${EXTRA_PACKAGES:-}
BUILD_DIR=${BUILD_DIR:-/tmp/lingmo-ci/$component}

line=$(components "$component")
[ -n "$line" ] || { echo "::error::$component is not in components.conf"; exit 1; }
IFS='|' read -r _repo pkg deps args _conflicts base <<<"$line"

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

has_cmake() { [ -f "$src/CMakeLists.txt" ]; }
is_metapackage() { [ -f "$src/PKGBUILD" ] && ! has_cmake; }
# Tests declared anywhere in the component's CMake files
has_tests() {
    grep -rqsE --include=CMakeLists.txt --include='*.cmake' \
        '^[^#]*(add_test|ecm_add_tests?|enable_testing)[[:space:]]*\(' "$src"
}

do_setup() {
    group "pacman: add [archlingmo]"
    if ! grep -q '^\[archlingmo\]' /etc/pacman.conf; then
        # The exact [archlingmo] block of the ISO's pacman.conf (SigLevel included)
        local block
        block=$(awk '/^\[/{on=($0=="[archlingmo]")} on' "$PROFILE_PACMAN_CONF")
        [ -n "$block" ] || { echo "::error::no [archlingmo] section in $PROFILE_PACMAN_CONF"; exit 1; }
        printf '\n%s\n' "$block" >> /etc/pacman.conf
    fi
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
    awk '/^\[archlingmo\]/{on=1} on' /etc/pacman.conf
    endgroup
    group "pacman -Syu"
    pacman -Syu --noconfirm --needed git
    endgroup
}

do_deps() {
    local pkgs=(base-devel)
    has_cmake && pkgs+=(cmake ninja extra-cmake-modules qt6-tools)
    # shellcheck disable=SC2206 # space separated lists
    pkgs+=($deps $EXTRA_PACKAGES)
    group "pacman -S ${pkgs[*]}"
    pacman -S --noconfirm --needed "${pkgs[@]}"
    endgroup
}

do_metapackage() {
    group "makepkg --printsrcinfo ($pkg)"
    # makepkg refuses to run as root, and the source may be read-only
    id builder >/dev/null 2>&1 || useradd -m builder
    local dir; dir=$(mktemp -d); cp "$src/PKGBUILD" "$dir/"; chown -R builder "$dir"
    runuser -u builder -- bash -c "cd '$dir' && makepkg --printsrcinfo" > "$dir/.SRCINFO.new"
    cat "$dir/.SRCINFO.new"
    endgroup
    if [ -f "$src/.SRCINFO" ] && ! diff -u "$src/.SRCINFO" "$dir/.SRCINFO.new"; then
        echo "::warning::.SRCINFO is out of date: run makepkg --printsrcinfo > .SRCINFO"
    fi
}

do_build() {
    if is_metapackage; then do_metapackage; return; fi
    has_cmake || { echo "::error::$src has neither CMakeLists.txt nor PKGBUILD"; exit 1; }
    local extra=()
    # Tests are built (overriding a -DBUILD_TESTING=OFF from components.conf)
    # only when the component has any; otherwise the build matches mkpkg's.
    if [ "$TESTS" = 1 ] && has_tests; then extra+=(-DBUILD_TESTING=ON); fi
    rm -rf "$BUILD_DIR"
    group "cmake configure: $args ${extra[*]}"
    # shellcheck disable=SC2086 # cmake args from components.conf are word-split, as in mkpkg
    cmake_configure "$src" "$BUILD_DIR" $args "${extra[@]}"
    endgroup
    group "ninja"
    ninja -C "$BUILD_DIR"
    endgroup
    group "ninja install (DESTDIR, like package())"
    DESTDIR="$BUILD_DIR/pkgroot" ninja -C "$BUILD_DIR" install >/dev/null
    echo "installed files: $(find "$BUILD_DIR/pkgroot" -type f | wc -l)"
    endgroup
}

do_test() {
    if is_metapackage || [ "$TESTS" != 1 ]; then echo "tests: skipped"; return; fi
    local count=0
    if [ -f "$BUILD_DIR/CTestTestfile.cmake" ]; then
        count=$(ctest --test-dir "$BUILD_DIR" -N | awk '/^Total Tests:/{print $3}')
    fi
    if [ "${count:-0}" -eq 0 ]; then echo "tests: none in $component"; return; fi
    group "ctest ($count tests)"
    export QT_QPA_PLATFORM=offscreen XDG_RUNTIME_DIR; XDG_RUNTIME_DIR=$(mktemp -d); chmod 700 "$XDG_RUNTIME_DIR"
    local run=(ctest --test-dir "$BUILD_DIR" --output-on-failure -j"$(nproc)")
    if command -v dbus-run-session >/dev/null; then run=(dbus-run-session -- "${run[@]}"); fi
    "${run[@]}"
    endgroup
}

echo "==> $component ($pkg ${base:-0}): $step"
case "$step" in
    setup) do_setup ;;
    deps) do_deps ;;
    build) do_build ;;
    test) do_test ;;
    all) do_setup; do_deps; do_build; do_test ;;
    *) echo "unknown step: $step"; exit 1 ;;
esac
