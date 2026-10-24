# Shared paths/helpers for the Lingmo scripts (sourced, not executed).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${STAGE:-$ROOT/.stage}"
CONF="$ROOT/packaging/components.conf"

# Prints "repo|pkgname|depends|cmakeargs" for each component (optionally filtered by repo)
components() {
    grep -vE '^\s*(#|$)' "$CONF" | { if [ -n "${1:-}" ]; then awk -F'|' -v r="$1" '$1==r'; else cat; fi; }
}

cmake_configure() { # <srcdir> <builddir> [extra args]
    local src=$1 build=$2; shift 2
    cmake -S "$src" -B "$build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$STAGE/usr" -DQT_NO_PRIVATE_MODULE_WARNING=ON \
        -Wno-dev "$@"
}
