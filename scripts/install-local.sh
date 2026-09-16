#!/bin/bash
# Install this fork's build as the machine's `axe`.
#
# The binary resolves its frameworks through `@executable_path/Frameworks`, so it cannot simply be
# symlinked out of `build_products` — the whole directory has to travel together. This copies it to
# a stable prefix and puts a wrapper on PATH, which is the same shape Homebrew's own formula uses
# (`bin/axe` execs `libexec/axe`). A copy, not a link, so rebuilding the fork cannot leave the
# machine pointing at a half-written binary — re-run this when you want the new build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${REPO_ROOT}/build_products"
# Homebrew's prefix, because it is user-writable (no sudo) and sits ahead of /usr/local on PATH —
# so this replaces the formula's `axe` rather than racing it.
PREFIX="${AXE_INSTALL_PREFIX:-/opt/homebrew}"
LIBEXEC="${PREFIX}/lib/gnosis-axe"
WRAPPER="${PREFIX}/bin/axe"

if [[ ! -x "${SOURCE}/axe" ]]; then
  echo "no build at ${SOURCE}/axe — run: AXE_CODESIGN_IDENTITY=- ./scripts/build.sh" >&2
  exit 1
fi

SUDO=""
if [[ ! -w "${PREFIX}/bin" ]]; then
  SUDO="sudo"
fi

echo "installing $(cd "${REPO_ROOT}" && git describe --tags --always --dirty) -> ${WRAPPER}"

# Staged, then swapped: a host mid-run resolves `axe` through the wrapper at any instant, so the
# old tree must stay whole until the new one is complete. Deleting first left a window in which
# every command ENOENTed, and it once killed three runs.
STAGING="${LIBEXEC}.incoming.$$"
$SUDO rm -rf "${STAGING}"
$SUDO mkdir -p "${STAGING}" "${PREFIX}/bin"
# -R so Frameworks and the resource bundle land beside the binary, which is what @executable_path
# resolves against; without them every command fails to load FBSimulatorControl.
$SUDO cp -R "${SOURCE}/axe" "${SOURCE}/Frameworks" "${STAGING}/"
if [[ -d "${SOURCE}/AXe_AXe.bundle" ]]; then
  $SUDO cp -R "${SOURCE}/AXe_AXe.bundle" "${STAGING}/"
fi

# `mv` over a directory is not atomic, so the old tree is moved aside rather than deleted under a
# caller, and only removed once the new one is in place.
RETIRED="${LIBEXEC}.retired.$$"
if [[ -d "${LIBEXEC}" ]]; then
  $SUDO mv "${LIBEXEC}" "${RETIRED}"
fi
$SUDO mv "${STAGING}" "${LIBEXEC}"
$SUDO rm -rf "${RETIRED}"

$SUDO tee "${WRAPPER}" >/dev/null <<WRAP
#!/bin/bash
# gnosis' AXe fork — see ${REPO_ROOT}. Reinstall with scripts/install-local.sh
exec "${LIBEXEC}/axe" "\$@"
WRAP
$SUDO chmod +x "${WRAPPER}"

echo "installed: $("${WRAPPER}" --version)"
echo "which axe: $(command -v axe)"
