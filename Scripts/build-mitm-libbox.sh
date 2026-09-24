#!/usr/bin/env bash

# Build Libbox.xcframework from sing-box v1.15.0-alpha.7 + the MITM port.
#
# The MITM implementation starts from the upstream dev-mitm-2 branch
# and includes the local HTTP pipeline, body codec, Script Hub and Apple UI
# fixes recorded in the reproducible patch below.
# The ported result is recorded as Patches/mitm-1.15.patch so the kernel is
# reproducible from pristine upstream sources.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_dir="$project_root/Core/sing-box"
patch_file="$project_root/Patches/mitm-1.15.patch"
base_version="v1.15.0-alpha.7"
framework_source="$core_dir/Libbox.xcframework"
framework_target="$project_root/Libbox.xcframework"

git -C "$project_root" submodule update --init Core/sing-box

# Reproduce the ported kernel: pristine base tag + patch.
if ! git -C "$core_dir" rev-parse --verify -q "$base_version" > /dev/null; then
    git -C "$core_dir" fetch --depth 1 origin tag "$base_version"
fi
if git -C "$core_dir" apply --check "$patch_file" 2> /dev/null; then
    git -C "$core_dir" checkout -q "$base_version"
    git -C "$core_dir" apply "$patch_file"
elif ! git -C "$core_dir" apply --reverse --check "$patch_file" 2> /dev/null; then
    echo "Core source does not match $base_version or the patched state." >&2
    exit 1
fi

go_bin="$(go env GOPATH)/bin"
if [[ ! -x "$go_bin/gomobile" || ! -x "$go_bin/gobind" ]]; then
    echo "gomobile v0.1.5 is required. Install it with Go 1.24:" >&2
    echo "  go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.5" >&2
    echo "  go install github.com/sagernet/gomobile/cmd/gobind@v0.1.5" >&2
    exit 1
fi

export PATH="$go_bin:$PATH"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

(
    cd "$core_dir"
    go run ./cmd/internal/build_libbox -target apple -platform ios -debug
)

mkdir -p "$framework_target"
rsync -a --delete "$framework_source/" "$framework_target/"

binary="$framework_target/ios-arm64/Libbox.framework/Libbox"
for marker in tls_decryption surge_url_rewrite surge_header_rewrite surge_body_rewrite surge_map_local http-response-jq "jq body rewrite skipped" application/x-apple-aspen-config "request script returned a body without requires_body" "Surge HTTP API is not supported by sing-box" snell; do
    if ! strings "$binary" | grep -F "$marker" > /dev/null; then
        echo "Marker missing from Libbox: $marker" >&2
        exit 1
    fi
done

echo "MITM Libbox ready: $framework_target"
