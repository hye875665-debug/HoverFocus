#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_build="$task_root/Build"
task_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk"
task_modules="$task_build/Modules"
task_app="$task_build/HoverFocus.app"
mkdir -p "$task_modules" "$task_build/Checks" "$task_app/Contents/MacOS" \
  "$task_app/Contents/Resources"

task_flags=(-swift-version 6 -sdk "$task_sdk" -target arm64-apple-macos13.0
  -module-cache-path "$task_modules/Cache")
xcrun swiftc "${task_flags[@]}" -parse-as-library -emit-object -emit-module \
  -module-name HoverFocusCore "$task_root/HoverFocusCore/HoverDecisionEngine.swift" \
  -emit-module-path "$task_modules/HoverFocusCore.swiftmodule" \
  -o "$task_modules/HoverFocusCore.o"
xcrun swiftc "${task_flags[@]}" -I "$task_modules" \
  "$task_root"/HoverFocusApp/*.swift "$task_modules/HoverFocusCore.o" \
  -o "$task_app/Contents/MacOS/HoverFocus"

cp "$task_root/HoverFocusApp/Info.plist" "$task_app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string HoverFocus "$task_app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.yejialin.HoverFocus "$task_app/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 13.0 "$task_app/Contents/Info.plist"
cp "$task_root/HoverFocusApp/Resources/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
plutil -lint "$task_app/Contents/Info.plist"
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"

for task_check in WindowDiagnostics WindowRegressionChecks WindowActivationCheck; do
  xcrun swiftc "${task_flags[@]}" -I "$task_modules" \
    "$task_root/Tools/$task_check.swift" \
    "$task_root/HoverFocusApp/AccessibilityWindowResolver.swift" \
    "$task_modules/HoverFocusCore.o" -o "$task_build/Checks/$task_check"
done
printf 'Built and verified: %s\n' "$task_app"
