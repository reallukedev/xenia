#!/bin/zsh
# Archives Xenia and uploads it to App Store Connect, where it lands in TestFlight:
#
#   scripts/apple/testflight.sh                 # iPhone and Mac
#   scripts/apple/testflight.sh ios             # one platform (ios or macos)
#   scripts/apple/testflight.sh --no-upload     # sign and export to target/testflight, upload nothing
#
# Signs with the team in apple/Local.xcconfig. Uploads as the Apple account signed in to Xcode
# (Settings > Accounts), or with an App Store Connect API key when ASC_KEY_PATH, ASC_KEY_ID and
# ASC_ISSUER_ID are set. Xcode numbers each upload one past the highest build App Store Connect
# has for this version, so CURRENT_PROJECT_VERSION in project.yml doesn't need bumping for it.
set -euo pipefail

ROOT="${0:A:h:h:h}"
APPLE="$ROOT/apple"
OUT="$ROOT/target/testflight"

upload=true
platforms=()
for arg in "$@"; do
  case "$arg" in
    --no-upload) upload=false ;;
    ios|macos) platforms+=("$arg") ;;
    *) echo "usage: $0 [--no-upload] [ios] [macos]" >&2; exit 64 ;;
  esac
done
(( ${#platforms} )) || platforms=(ios macos)

auth=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

mkdir -p "$OUT"
(cd "$APPLE" && xcodegen --quiet)

if $upload; then destination=upload; else destination=export; fi
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<$upload/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST

for platform in $platforms; do
  case "$platform" in
    ios) scheme="Xenia iOS"; generic="generic/platform=iOS" ;;
    macos) scheme="Xenia macOS"; generic="generic/platform=macOS" ;;
  esac
  archive="$OUT/Xenia-$platform.xcarchive"
  rm -rf "$archive" "$OUT/$platform"

  echo "==> Archiving $scheme"
  xcodebuild archive -quiet -project "$APPLE/Xenia.xcodeproj" -scheme "$scheme" \
    -destination "$generic" -archivePath "$archive" -allowProvisioningUpdates $auth

  if $upload; then echo "==> Uploading $scheme"; else echo "==> Exporting $scheme"; fi
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/$platform" -allowProvisioningUpdates $auth
done

if $upload; then
  echo "Uploaded. Builds show up in App Store Connect > TestFlight once Apple finishes processing them."
else
  echo "Exported to $OUT."
fi
