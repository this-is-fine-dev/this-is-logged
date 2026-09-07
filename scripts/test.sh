#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
MODULE_CACHE="$PROJECT_ROOT/.build/ModuleCache"
SDK_PATH=${SDKROOT:-$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d -name 'MacOSX[0-9]*.sdk' | sort -V | head -1)}

if rg -q 'MainActor\.assumeIsolated' "$PROJECT_ROOT/macos/main.swift"; then
  echo "unsafe MainActor assumption crashes the refresh timer" >&2
  exit 1
fi

if rg -q '\.utilityWindow' "$PROJECT_ROOT/macos"; then
  echo "utility window style shrinks application title bars" >&2
  exit 1
fi

for window_source in main.swift SyncWindowController.swift ClaudeActivityWindowController.swift; do
  if ! rg -q 'toolbarStyle = \.unifiedCompact' "$PROJECT_ROOT/macos/$window_source"; then
    echo "$window_source does not use the full-size unified title bar" >&2
    exit 1
  fi
  if ! rg -q 'titleVisibility = \.hidden' "$PROJECT_ROOT/macos/$window_source" ||
     ! rg -q 'titlebarAppearsTransparent = true' "$PROJECT_ROOT/macos/$window_source" ||
     ! rg -q '\.fullSizeContentView' "$PROJECT_ROOT/macos/$window_source"; then
    echo "$window_source does not embed window controls in the application surface" >&2
    exit 1
  fi
done

if ! rg -q 'window\?\.orderFrontRegardless\(\)' "$PROJECT_ROOT/macos/ClaudeActivityWindowController.swift"; then
  echo "Claude activity window may remain hidden after the status menu closes" >&2
  exit 1
fi

if rg -q 'ActivityJiraLogger|addWorklog|saveToJira' "$PROJECT_ROOT/macos/ClaudeActivityWindowController.swift"; then
  echo "Claude activity dashboard must remain analysis-only" >&2
  exit 1
fi

if ! rg -q 'activity\.events\.suffix\(50\)' "$PROJECT_ROOT/macos/ClaudeActivityWindowController.swift"; then
  echo "Claude activity dashboard must keep its bounded event list" >&2
  exit 1
fi

if rg -q 'Timer\.scheduledTimer\(timeInterval:.*#selector\(refresh\)' "$PROJECT_ROOT/macos/main.swift"; then
  echo "unsafe Timer selector for @MainActor refresh" >&2
  exit 1
fi

if ! rg -Uq 'private func runAgent\([^}]+Task\.detached' "$PROJECT_ROOT/macos/main.swift"; then
  echo "launchctl is started synchronously from the main UI actor" >&2
  exit 1
fi

if rg -n '^  override var isFlipped' "$PROJECT_ROOT/macos"; then
  echo "actor-isolated AppKit isFlipped override can crash while a window is released" >&2
  exit 1
fi

if rg -n '^  func (menuWillOpen|applicationShouldHandleReopen|userNotificationCenter)' "$PROJECT_ROOT/macos/main.swift"; then
  echo "actor-isolated Objective-C delegate callback can crash outside the Swift main executor" >&2
  exit 1
fi

if rg -q 'CommandLine\.arguments' "$PROJECT_ROOT/macos/main.swift"; then
  echo "CommandLine.arguments is not concurrency-safe on the release runner" >&2
  exit 1
fi

if rg -q 'menu\.autoenablesItems = false' "$PROJECT_ROOT/macos/main.swift"; then
  echo "disabled menu validation prevents Sparkle from exposing updater readiness" >&2
  exit 1
fi

if rg -q 'action: #selector\(SPUStandardUpdaterController\.checkForUpdates' "$PROJECT_ROOT/macos/main.swift"; then
  echo "direct Sparkle action loses the first click while the updater is starting" >&2
  exit 1
fi

if ! rg -Uq 'private func presentUpdater\(_ sender: Any\?\) \{\n    NSApplication\.shared\.activate\(ignoringOtherApps: true\)\n    updaterController\.checkForUpdates\(sender\)\n  \}' "$PROJECT_ROOT/macos/main.swift"; then
  echo "Sparkle window can open behind the current application" >&2
  exit 1
fi

env SDKROOT="$SDK_PATH" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift run --disable-sandbox --disable-keychain --package-path "$PROJECT_ROOT" ThisIsLoggedSelfcheck
env SDKROOT="$SDK_PATH" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift run --disable-sandbox --disable-keychain --package-path "$PROJECT_ROOT" ThisIsLogged --selfcheck
env SDKROOT="$SDK_PATH" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift run --disable-sandbox --disable-keychain --package-path "$PROJECT_ROOT" ThisIsLogged --sync-layout-selfcheck
env SDKROOT="$SDK_PATH" SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  swift run --disable-sandbox --disable-keychain --package-path "$PROJECT_ROOT" ThisIsLogged --activity-layout-selfcheck
