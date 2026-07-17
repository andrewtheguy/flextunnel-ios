# Sign the unsigned iOS IPA

The workflow in `.github/workflows/unsigned-ios.yml` publishes an unsigned
device build as `flextunnel-unsigned.ipa`. It has no code signatures or
provisioning profiles and cannot be installed until it is signed for an Apple
developer team.

Flextunnel contains two code bundles, so each signer needs two App IDs and two
matching profiles:

- the main `Flextunnel.app`;
- the embedded `FlextunnelWidgets.appex` WidgetKit extension.

This guide uses Apple's command-line tools on macOS. The current app contains
no embedded dynamic frameworks. If that changes, sign frameworks first without
entitlements, then the widget, and finally the containing app.

## Background location

The app's background location capability is stored in `Info.plist` as
`UIBackgroundModes = location`, together with
`NSLocationWhenInUseUsageDescription`. It is not a code-sign entitlement and
does not appear in a provisioning profile. The workflow verifies both values
before publishing, and changing the bundle IDs or signing the app does not
remove them.

Do not add a made-up location key to a signing entitlements plist. Code-sign
entitlements must come from the provisioning profile selected for that bundle.

## Requirements

- macOS with Xcode installed.
- A valid Apple Development certificate and its private key in the Keychain.
- Separate iOS development profiles for the app and widget bundle IDs. Both
  profiles must include the signing certificate and destination device.
- Developer Mode enabled on the device when installing with `devicectl`.

The example uses development signing for a registered device. Ad Hoc signing
uses the same component and profile matching rules with an Apple Distribution
identity and Ad Hoc profiles.

Keep certificates, private keys, Apple credentials, and signing secrets local.
Never commit them or upload them to an untrusted signing service.

Run the command blocks below in the same Terminal session so their variables
remain available.

## 1. Download and verify the prerelease

Download `flextunnel-unsigned.ipa` and `SHA256SUMS.txt` from the same GitHub
prerelease. Set the absolute download directory and verify the IPA:

```bash
DOWNLOAD_DIR="/absolute/path/to/downloads"

(
  cd "$DOWNLOAD_DIR" || exit 1
  awk '$2 == "flextunnel-unsigned.ipa" { print }' SHA256SUMS.txt \
    | shasum -a 256 -c -
)
```

Continue only if this prints `flextunnel-unsigned.ipa: OK`.

## 2. Choose bundle IDs, profiles, and an identity

The released binary starts with these identifiers:

```text
dev.flexaccess.flextunnel
dev.flexaccess.flextunnel.widgets
```

Keep them only if your team owns matching App IDs. Otherwise register unique
explicit App IDs with your Apple developer team. The widget identifier should
be nested under the app identifier, for example:

```bash
APP_BUNDLE_ID="com.yourname.flextunnel"
WIDGET_BUNDLE_ID="$APP_BUNDLE_ID.widgets"
```

Create a development profile for each App ID. Xcode-managed profiles are
normally stored under:

```text
~/Library/Developer/Xcode/UserData/Provisioning Profiles/
```

List valid identities and copy the 40-character hash for the intended Apple
Development identity:

```bash
security find-identity -v -p codesigning
```

Set absolute profile paths and the identity hash:

```bash
APP_PROFILE="/absolute/path/to/app.mobileprovision"
WIDGET_PROFILE="/absolute/path/to/widget.mobileprovision"
SIGNING_IDENTITY="0123456789ABCDEF0123456789ABCDEF01234567"
```

The same team must own both profiles. The identity must be included in both,
and both `ProvisionedDevices` arrays must include the destination device's
hardware UDID.

## 3. Unpack the IPA and decode both profiles

```bash
SIGN_ROOT="$(mktemp -d /tmp/flextunnel-sign.XXXXXX)"
UNSIGNED_IPA="$DOWNLOAD_DIR/flextunnel-unsigned.ipa"
SIGNED_IPA="$DOWNLOAD_DIR/flextunnel-signed.ipa"
APP_PATH="$SIGN_ROOT/Payload/Flextunnel.app"
WIDGET_PATH="$APP_PATH/PlugIns/FlextunnelWidgets.appex"
APP_PROFILE_PLIST="$SIGN_ROOT/app-profile.plist"
WIDGET_PROFILE_PLIST="$SIGN_ROOT/widget-profile.plist"
APP_ENTITLEMENTS="$SIGN_ROOT/app-entitlements.plist"
WIDGET_ENTITLEMENTS="$SIGN_ROOT/widget-entitlements.plist"

unzip -q "$UNSIGNED_IPA" -d "$SIGN_ROOT"
test -d "$APP_PATH"
test -d "$WIDGET_PATH"

if codesign --display "$APP_PATH" >/dev/null 2>&1 \
  || codesign --display "$WIDGET_PATH" >/dev/null 2>&1; then
  echo "error: downloaded IPA is unexpectedly signed" >&2
  exit 1
fi

security cms -D -i "$APP_PROFILE" > "$APP_PROFILE_PLIST"
security cms -D -i "$WIDGET_PROFILE" > "$WIDGET_PROFILE_PLIST"
```

Confirm the profiles belong to the same team and exactly match the selected
bundle IDs. The App ID prefix is usually the Team ID, but older accounts can
use a different prefix:

```bash
APP_TEAM_ID="$(plutil -extract TeamIdentifier.0 raw -o - \
  "$APP_PROFILE_PLIST")"
WIDGET_TEAM_ID="$(plutil -extract TeamIdentifier.0 raw -o - \
  "$WIDGET_PROFILE_PLIST")"
APP_ID_PREFIX="$(plutil -extract ApplicationIdentifierPrefix.0 raw -o - \
  "$APP_PROFILE_PLIST")"
WIDGET_ID_PREFIX="$(plutil -extract ApplicationIdentifierPrefix.0 raw -o - \
  "$WIDGET_PROFILE_PLIST")"
PROFILE_APP_ID="$(plutil -extract Entitlements.application-identifier raw \
  -o - "$APP_PROFILE_PLIST")"
PROFILE_WIDGET_ID="$(plutil -extract Entitlements.application-identifier raw \
  -o - "$WIDGET_PROFILE_PLIST")"

[[ "$APP_TEAM_ID" == "$WIDGET_TEAM_ID" ]]
[[ "$PROFILE_APP_ID" == "$APP_ID_PREFIX.$APP_BUNDLE_ID" ]]
[[ "$PROFILE_WIDGET_ID" == \
  "$WIDGET_ID_PREFIX.$WIDGET_BUNDLE_ID" ]]

plutil -extract ExpirationDate raw -o - "$APP_PROFILE_PLIST"
plutil -extract ExpirationDate raw -o - "$WIDGET_PROFILE_PLIST"
plutil -extract ProvisionedDevices xml1 -o - "$APP_PROFILE_PLIST"
plutil -extract ProvisionedDevices xml1 -o - "$WIDGET_PROFILE_PLIST"

plutil -extract Entitlements xml1 \
  -o "$APP_ENTITLEMENTS" "$APP_PROFILE_PLIST"
plutil -extract Entitlements xml1 \
  -o "$WIDGET_ENTITLEMENTS" "$WIDGET_PROFILE_PLIST"
```

Use `xcrun devicectl device info details --device DEVICE_ID` to find the
hardware `udid`; it differs from the CoreDevice identifier used by
`devicectl --device`.

## 4. Apply the bundle IDs and preserve location configuration

```bash
plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_ID" \
  "$APP_PATH/Info.plist"
plutil -replace CFBundleIdentifier -string "$WIDGET_BUNDLE_ID" \
  "$WIDGET_PATH/Info.plist"

[[ "$(plutil -extract UIBackgroundModes.0 raw -o - \
  "$APP_PATH/Info.plist")" == "location" ]]
test -n "$(plutil -extract NSLocationWhenInUseUsageDescription raw -o - \
  "$APP_PATH/Info.plist")"
```

## 5. Embed profiles and sign inside out

Each code bundle receives its own profile and that profile's authorized
entitlements. Sign the widget before the containing app:

```bash
ditto --norsrc --noextattr --noqtn --noacl \
  "$WIDGET_PROFILE" "$WIDGET_PATH/embedded.mobileprovision"
ditto --norsrc --noextattr --noqtn --noacl \
  "$APP_PROFILE" "$APP_PATH/embedded.mobileprovision"

codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$WIDGET_ENTITLEMENTS" \
  --generate-entitlement-der \
  --timestamp=none \
  "$WIDGET_PATH"

codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  --generate-entitlement-der \
  --timestamp=none \
  "$APP_PATH"
```

Never use `codesign --deep` to create these signatures. It cannot choose the
correct profile and entitlements for each nested bundle.

## 6. Verify and repackage

```bash
codesign --verify --strict --verbose=4 "$WIDGET_PATH"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

codesign --display --verbose=4 --entitlements :- "$WIDGET_PATH"
codesign --display --verbose=4 --entitlements :- "$APP_PATH"

[[ "$(plutil -extract CFBundleIdentifier raw -o - \
  "$WIDGET_PATH/Info.plist")" == "$WIDGET_BUNDLE_ID" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - \
  "$APP_PATH/Info.plist")" == "$APP_BUNDLE_ID" ]]
[[ "$(plutil -extract UIBackgroundModes.0 raw -o - \
  "$APP_PATH/Info.plist")" == "location" ]]

ditto -c -k --keepParent \
  --norsrc --noextattr --noqtn --noacl \
  "$SIGN_ROOT/Payload" "$SIGNED_IPA"

unzip -tq "$SIGNED_IPA"
shasum -a 256 "$SIGNED_IPA"
```

The displayed Team ID, application identifier, bundle ID, profile, and
certificate must agree for each component. `flextunnel-signed.ipa` remains
valid only while its certificate and both profiles remain valid.

## 7. Install on a registered device

```bash
xcrun devicectl list devices

DEVICE_ID="00000000-0000-0000-0000-000000000000"
xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH"
```

`devicectl` installs the extracted `.app`, not the enclosing IPA. Installation
software that accepts IPA files can use `flextunnel-signed.ipa`.

If installation fails, verify that both profiles match their bundle IDs,
contain the signing certificate and device UDID, belong to the same team, and
have not expired.

## Build from source instead

Building from source lets Xcode manage the signing assets and is less
error-prone. Configure `DEVELOPMENT_TEAM`, replace both
`PRODUCT_BUNDLE_IDENTIFIER` values in `project.yml` with App IDs owned by that
team, regenerate the project, then run:

```bash
scripts/create-archive-ios.sh --allow-provisioning-updates
```
