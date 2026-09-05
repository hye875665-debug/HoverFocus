#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_app="$task_root/Build/HoverFocus.app"
task_dist="$task_root/Dist"
task_info="$task_root/HoverFocusApp/Info.plist"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_info")"
task_arch="arm64"
task_name="HoverFocus-${task_version}-${task_arch}"
task_dmg="$task_dist/$task_name.dmg"
task_stage="$(mktemp -d "${TMPDIR:-/tmp}/hoverfocus-dmg.XXXXXX")"

cleanup() {
  rm -rf "$task_stage"
}
trap cleanup EXIT

/bin/zsh "$task_root/Tools/build-local.sh"
mkdir -p "$task_dist"

/usr/bin/ditto "$task_app" "$task_stage/HoverFocus.app"
ln -s /Applications "$task_stage/Applications"

if [[ -x /usr/bin/SetFile ]]; then
  cp "$task_root/HoverFocusApp/Resources/AppIcon.icns" "$task_stage/.VolumeIcon.icns"
  /usr/bin/SetFile -a C "$task_stage"
fi

/usr/bin/hdiutil create \
  -volname "HoverFocus" \
  -srcfolder "$task_stage" \
  -format UDZO \
  -ov \
  "$task_dmg"

(
  cd "$task_dist"
  /usr/bin/shasum -a 256 "${task_dmg:t}" > SHA256SUMS.txt
)

printf 'Packaged: %s\n' "$task_dmg"
printf 'Checksums: %s\n' "$task_dist/SHA256SUMS.txt"
