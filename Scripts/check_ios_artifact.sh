#!/bin/bash
set -eu

app_bundle="${1:?usage: check_ios_artifact.sh /path/to/Auralis.app [expected-commit]}"
expected_commit="${2:-}"

if [ ! -d "${app_bundle}" ]; then
    echo "artifact bundle not found: ${app_bundle}" >&2
    exit 1
fi

# Debug builds use a small launcher executable and put the Swift program in
# Auralis.debug.dylib.  Scan every Mach-O in the app (including extensions) so
# the check proves the identifiers made it into a loadable binary, regardless
# of the selected build configuration.
binaries=()
while IFS= read -r -d '' candidate; do
    if [[ "$(file -b "${candidate}")" == Mach-O* ]]; then
        binaries[${#binaries[@]}]="${candidate}"
    fi
done < <(find "${app_bundle}" -type f -print0)

if [ "${#binaries[@]}" -eq 0 ]; then
    echo "no Mach-O binary found in artifact: ${app_bundle}" >&2
    exit 1
fi

contains() {
    needle="$1"
    for candidate in "${binaries[@]}"; do
        if strings "${candidate}" | rg -F --quiet -- "${needle}"; then
            return 0
        fi
    done
    return 1
}

for identifier in \
    "auralis.settings.musicHaptics" \
    "auralis.nowPlaying.musicHaptics"; do
    if ! contains "${identifier}"; then
        echo "artifact is missing required UI identifier: ${identifier}" >&2
        exit 1
    fi
done

if [ -n "${expected_commit}" ] && ! contains "${expected_commit}"; then
    echo "artifact provenance does not contain expected commit: ${expected_commit}" >&2
    exit 1
fi

echo "iOS artifact contains Music Haptics identifiers${expected_commit:+ and commit ${expected_commit}}"
