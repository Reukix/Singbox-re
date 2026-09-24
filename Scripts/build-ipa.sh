#!/usr/bin/env bash

# Build a signed, installable IPA for the device listed in the ad-hoc
# provisioning profile in .signing/.
#
# The profile only covers the main App ID, so every component is signed with
# the profile's own entitlement set (the standard approach for this kind of
# profile). iCloud container access is NOT granted by the profile, so iCloud
# profile sync does not work in the resulting build; local profiles and MITM
# are unaffected.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile_file="${PROFILE_PATH:-$project_root/.signing/profile.mobileprovision}"
identity="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your iPhone Distribution identity, e.g. 'iPhone Distribution: Name (TEAMID)'}"
derived_data="$project_root/build/DerivedData-ipa"
output_ipa="${OUTPUT_IPA:-$project_root/sing-box-1.15.0-alpha.7-mitm.ipa}"
app_marketing_version="${APP_MARKETING_VERSION:-1.15.0}"
app_build_version="${APP_BUILD_VERSION:-11}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f "$profile_file" ]]; then
    echo "Provisioning profile not found: $profile_file" >&2
    echo "Import signing assets first: ./Scripts/import-signing-assets.sh <archive>" >&2
    exit 1
fi

keychain="$project_root/build/signing.keychain-db"
keychain_password_file="$project_root/build/.signing-keychain-password"

# Set up a dedicated signing keychain on first run. The P12 is imported via
# PEM because the macOS security tool rejects this P12's legacy encryption.
if [[ ! -f "$keychain" ]]; then
    p12_file="$(find "$project_root/.signing" -maxdepth 1 -name '*.p12' -print -quit)"
    if [[ -z "$p12_file" || -z "${SIGNING_P12_PASSWORD:-}" ]]; then
        echo "First run requires the P12 and SIGNING_P12_PASSWORD." >&2
        exit 1
    fi
    keychain_password="$(openssl rand -hex 16)"
    pem_file="$(mktemp)"
    chmod 600 "$pem_file"
    openssl pkcs12 -in "$p12_file" -passin "pass:$SIGNING_P12_PASSWORD" -legacy -nodes -out "$pem_file" 2> /dev/null
    security create-keychain -p "$keychain_password" "$keychain"
    security import "$pem_file" -k "$keychain" -f pemseq -T /usr/bin/codesign -T /usr/bin/security > /dev/null
    rm -f "$pem_file"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
    security list-keychains -d user -s "$keychain" $(security list-keychains -d user | sed 's/"//g')
    printf '%s' "$keychain_password" > "$keychain_password_file"
    chmod 600 "$keychain_password_file"
fi

security unlock-keychain -p "$(cat "$keychain_password_file")" "$keychain"

if ! security find-identity -v -p codesigning | grep -F "$identity" > /dev/null; then
    echo "Signing identity not in keychain: $identity" >&2
    exit 1
fi

xcodebuild \
    -project "$project_root/sing-box.xcodeproj" \
    -scheme SFI \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    MARKETING_VERSION="$app_marketing_version" \
    CURRENT_PROJECT_VERSION="$app_build_version" \
    CODE_SIGNING_ALLOWED=NO \
    build

app_path="$derived_data/Build/Products/Release-iphoneos/sing-box.app"
if [[ ! -d "$app_path" ]]; then
    echo "Built app not found: $app_path" >&2
    exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

profile_plist="$work_dir/profile.plist"
security cms -D -i "$profile_file" > "$profile_plist"

# Sign every component with the profile's own entitlement set: it is
# guaranteed to pass on-device validation because it is exactly what the
# profile grants.
plutil -extract Entitlements xml1 -o "$work_dir/entitlements.plist" "$profile_plist"

sign_component() {
    local target="$1"
    local with_entitlements="$2"
    local args=(--force --sign "$identity" --timestamp=none)
    if [[ "$with_entitlements" == "yes" ]]; then
        args+=(--entitlements "$work_dir/entitlements.plist")
        cp "$profile_file" "$target/embedded.mobileprovision"
    fi
    codesign "${args[@]}" "$target"
}

# Deepest components first: frameworks, then app extensions, then the app.
while IFS= read -r -d '' framework; do
    sign_component "$framework" no
done < <(find "$app_path" \( -name '*.framework' -o -name '*.dylib' \) -print0 2> /dev/null)

while IFS= read -r -d '' appex; do
    sign_component "$appex" yes
done < <(find "$app_path" -name '*.appex' -print0 2> /dev/null)

sign_component "$app_path" yes

codesign --verify --deep --strict --verbose=2 "$app_path"

rm -f "$output_ipa"
(
    cd "$work_dir"
    mkdir Payload
    cp -R "$app_path" Payload/
    zip -qry "$output_ipa" Payload
)

echo "IPA ready: $output_ipa"
