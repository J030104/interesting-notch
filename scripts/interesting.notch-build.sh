#!/bin/bash
set -euo pipefail

if [[ $# != 3 || ( "$1" != verify && "$1" != relaunch ) || ! "$3" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Usage: bash $0 {verify|relaunch} /path/to/interesting.notch.app <full Git commit>" >&2
    exit 2
fi

mode="$1"
app="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
expected_revision="$3"
plist="$app/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist")"
if [[ "$bundle_id" != io.github.j030104.interesting-notch ]]; then
    echo "Unexpected bundle identifier: $bundle_id" >&2
    exit 1
fi

codesign --verify --deep --strict "$app"
executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$plist")"
# Swift can inline short UI labels in Release. Check the file payload text instead.
if ! strings "$app/Contents/MacOS/$executable" | grep -F 'Read these local file attachments when answering:' >/dev/null; then
    echo 'This build is missing file attachment support.' >&2
    exit 1
fi

revision="$(/usr/libexec/PlistBuddy -c 'Print InterestingNotchSourceRevision' "$plist" 2>/dev/null || true)"
if [[ "$revision" != "$expected_revision" ]]; then
    echo "Expected commit $expected_revision, found ${revision:-no commit recorded}." >&2
    exit 1
fi
echo "Verified interesting.notch build $revision."

if [[ "$mode" == relaunch ]]; then
    osascript -l JavaScript -e '
        ObjC.import("AppKit");
        for (const app of $.NSRunningApplication.runningApplicationsWithBundleIdentifier("io.github.j030104.interesting-notch").js) {
            app.terminate;
        }
    '
    running_app() {
        osascript -l JavaScript -e '
            ObjC.import("AppKit");
            $.NSRunningApplication.runningApplicationsWithBundleIdentifier("io.github.j030104.interesting-notch").js
                .filter(app => !app.terminated)
                .map(app => (app.finishedLaunching ? "ready:" : "starting:") + ObjC.unwrap(app.bundleURL.path))
                .join("\n");
        '
    }
    for ((attempt = 0; attempt < 40; attempt++)); do
        [[ -z "$(running_app)" ]] && break
        sleep 0.25
    done
    if [[ -n "$(running_app)" ]]; then
        echo 'interesting.notch did not quit.' >&2
        exit 1
    fi
    open "$app"
    for ((attempt = 0; attempt < 40; attempt++)); do
        if [[ "$(running_app)" == "ready:$app" ]]; then
            echo "Running $app"
            exit 0
        fi
        sleep 0.25
    done
    echo "Could not confirm launch of $app." >&2
    exit 1
fi
