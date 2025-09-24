#!/usr/bin/env bash
# Capture build errors from Xcode logs automatically
# Usage: ./build-errors.sh [watch]

set -euo pipefail

DEVICE_ID="00008140-000A292A0CE0801C"
BUNDLE_ID="com.filowatt.kiloworld"
PROJECT="kiloworld.xcodeproj"
SCHEME="kiloworld"

# Function to extract and show build errors
show_build_errors() {
    echo "🔍 Checking for build errors..."
    
    # Always build when explicitly run - skip optimization checks
    echo "🔨 Running targeted build to catch all errors..."
    
    # Use Swift compiler directly for ultra-fast syntax checking (no SPM resolution)
    echo "⚡ Running fast Swift syntax check (no SPM redownload)..."
    local swift_errors=""
    
    # First, check Swift syntax only - this is instant and catches 90% of errors
    for swift_file in $(find kiloworld/ -name "*.swift" -type f); do
        local file_errors
        file_errors=$(xcrun swiftc -frontend -parse -verify-ignore-unknown "$swift_file" \
            -I /Users/kiloverse/Library/Developer/Xcode/DerivedData/kiloworld-folppxpfcfgeugfnfmmfrqrevedt/Build/Products/Debug-iphoneos \
            -F /Users/kiloverse/Library/Developer/Xcode/DerivedData/kiloworld-folppxpfcfgeugfnfmmfrqrevedt/Build/Products/Debug-iphoneos \
            2>&1 | grep "error:" || true)
        
        if [[ -n "$file_errors" ]]; then
            swift_errors="$swift_errors\n$file_errors"
        fi
    done
    
    # Always run full build to catch all errors (linking, frameworks, etc.)
    if [[ -z "$swift_errors" ]]; then
        echo "✅ Swift syntax check passed!"
        echo "🔨 Running full build to catch linking and framework errors..."
    else
        echo "❌ Swift syntax errors found:"
        echo "$swift_errors"
        echo "🔨 Running full build anyway to show all errors..."
    fi
    
    # Always run the full build - this catches all types of errors
    local build_output
    build_output=$(timeout 300s xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -skipPackagePluginValidation -skipMacroValidation \
        -onlyUsePackageVersionsFromResolvedFile \
        -allowProvisioningUpdates \
        build 2>&1 || echo "❌ BUILD FAILED or timed out after 5 minutes")
    
    # Extract actual errors with comprehensive patterns
    local errors
    errors=$(echo "$build_output" | grep -E "(error:|❌|BUILD FAILED|failed with exit code|Command .* failed|Linker command failed|Code signing error|compilation failed)" | grep -v "AppIntents.framework dependency found" | grep -v "Metadata extraction skipped" || true)
    
    # Also check for specific Swift/Metal compilation errors
    local swift_compile_errors
    swift_compile_errors=$(echo "$build_output" | grep -E "(.swift:[0-9]+:[0-9]+:|.metal:[0-9]+:[0-9]+:)" | grep "error:" || true)
    
    # Combine all error types
    if [[ -n "$swift_compile_errors" ]]; then
        if [[ -n "$errors" ]]; then
            errors="$errors\n$swift_compile_errors"
        else
            errors="$swift_compile_errors"
        fi
    fi
    
    # Extract warnings separately
    local warnings
    warnings=$(echo "$build_output" | grep -E "(warning:|⚠️)" | grep -v "AppIntents.framework dependency found" | grep -v "Metadata extraction skipped" || true)
    
    # Check if build actually succeeded
    local build_succeeded
    build_succeeded=$(echo "$build_output" | grep "BUILD SUCCEEDED" || true)
    
    if [[ -n "$errors" ]] && [[ -z "$build_succeeded" ]]; then
        echo "🚨 Build Errors Found:"
        echo "----------------------------------------"
        echo "$errors"
        echo "----------------------------------------"
        return 1
    else
        if [[ -n "$warnings" ]]; then
            echo "⚠️ Build succeeded with warnings:"
            echo "----------------------------------------"
            echo "$warnings"
            echo "----------------------------------------"
        fi
        echo "✅ Build successful!"
        return 0
    fi
}

# Function to launch app if build succeeds
launch_app() {
    # Try multiple possible app locations
    local app_paths=(
        "/Users/kiloverse/Library/Developer/Xcode/DerivedData/kiloworld-folppxpfcfgeugfnfmmfrqrevedt/Build/Products/Debug-iphoneos/$SCHEME.app"
        "./build/Build/Products/Debug-iphoneos/$SCHEME.app"
        "$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null | grep "BUILT_PRODUCTS_DIR" | head -1 | sed 's/.*= *//')/$SCHEME.app"
    )
    
    local app_path=""
    for path in "${app_paths[@]}"; do
        if [[ -d "$path" ]]; then
            app_path="$path"
            echo "📱 Found app at: $app_path"
            break
        fi
    done
    
    if [[ -z "$app_path" ]]; then
        echo "❌ No app found in any of these locations:"
        for path in "${app_paths[@]}"; do
            echo "   - $path"
        done
        return 1
    fi
    
    echo "📦 Installing and launching app..."
    
    # Install first
    if ! xcrun devicectl device install app --device "$DEVICE_ID" "$app_path"; then
        echo "❌ Failed to install app"
        return 1
    fi
    
    echo "✅ App installed successfully!"
    
    # Try to launch with retries for device lock
    echo "🚀 Attempting to launch app..."
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        echo "🔄 Launch attempt $attempt/$max_attempts..."
        
        if xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing --activate "$BUNDLE_ID" 2>/dev/null; then
            echo "✅ App launched successfully!"
            return 0
        else
            local exit_code=$?
            echo "⚠️  Launch attempt $attempt failed"
            
            if [[ $attempt -lt $max_attempts ]]; then
                echo "💡 If your device is locked, please unlock it and wait..."
                echo "⏳ Retrying in 3 seconds..."
                sleep 3
            fi
        fi
        
        ((attempt++))
    done
    
    echo "❌ Failed to launch app after $max_attempts attempts"
    echo "💡 Try manually launching the app, or ensure your device is unlocked"
    echo "🔧 You can also run: xcrun devicectl device process launch --device $DEVICE_ID $BUNDLE_ID"
    return 1
}

# Watch mode - continuously monitor for changes
if [[ "${1:-}" == "watch" ]]; then
    echo "👀 Watching for file changes... (Ctrl+C to stop)"
    echo "📝 Edit your code, and I'll auto-build and show errors"
    
    # Use fswatch if available, otherwise fall back to simple loop
    if command -v fswatch >/dev/null 2>&1; then
        fswatch -o kiloworld/ | while read -r; do
            echo ""
            echo "📝 File changed, building..."
            if show_build_errors; then
                launch_app
            fi
            echo "👀 Waiting for next change..."
        done
    else
        echo "💡 Install fswatch for better file watching: brew install fswatch"
        while true; do
            if show_build_errors; then
                launch_app
            fi
            sleep 5
        done
    fi
else
    # Single run mode
    if show_build_errors; then
        launch_app
    else
        echo "🔧 Fix the errors above and run again"
        exit 1
    fi
fi