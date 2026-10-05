# Pindrop Build System
# Requires: Xcode, create-dmg (brew install create-dmg)

# Default recipe - show available commands
default:
    @just --list

# Variables
app_name := "Pindrop"
scheme := "Pindrop"
build_dir := "DerivedData/Build/Products"
release_dir := build_dir / "Release"
app_bundle := release_dir / app_name + ".app"
dmg_dir := "dist"

# Build configuration
xcode_project := "Pindrop.xcodeproj"

# Shared code-signing overrides for unsigned CI runners
signing_disabled := 'CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO'

# Clean all build artifacts
clean:
    @echo "🧹 Cleaning build artifacts..."
    rm -rf {{build_dir}}
    rm -rf {{dmg_dir}}
    rm -rf DerivedData
    @echo "✅ Clean complete"

# Shared xcodebuild build invocation (signed unless sign="no")
[private]
_build configuration sign="yes":
    xcodebuild \
        -project {{xcode_project}} \
        -scheme {{scheme}} \
        -configuration {{configuration}} \
        -derivedDataPath DerivedData \
        -skipPackagePluginValidation \
        {{ if sign == "no" { signing_disabled } else { "" } }} \
        build

# Build for development (Debug, Xcode-managed signing)
build:
    @echo "🔨 Building {{app_name}} (Debug)..."
    @just _build Debug
    @echo "✅ Debug build complete"

# Build signed Debug .app and copy it into /Applications
install:
    @./scripts/install-to-applications.sh Debug /Applications

# Build signed Release .app and copy it into /Applications
install-release:
    @./scripts/install-to-applications.sh Release /Applications

# Build for release (Xcode-managed signing)
build-release:
    @echo "🔨 Building {{app_name}} (Release)..."
    @just _build Release
    @echo "✅ Release build complete"
    @echo "📦 App bundle: {{app_bundle}}"

# Build for development on unsigned CI runners
build-unsigned:
    @echo "🔨 Building {{app_name}} (Debug, unsigned)..."
    @just _build Debug no
    @echo "✅ Unsigned debug build complete"

# Build for release on unsigned CI runners
build-release-unsigned:
    @echo "🔨 Building {{app_name}} (Release, unsigned)..."
    @just _build Release no
    @echo "✅ Unsigned release build complete"

# Legacy fallback when no Apple signing identity is available
build-self-signed: build-release-unsigned
    @echo "🔏 Re-signing with explicit nested order (required for macOS TCC permissions)..."
    ./scripts/sign-app-bundle.sh {{app_bundle}} -
    @echo "✅ Self-signed build complete"

# Self-signed DMG (no developer account needed)
dmg-self-signed: build-self-signed
    @echo "📦 Creating self-signed DMG..."
    @./scripts/create-dmg-self-signed.sh
    @echo "✅ Self-signed DMG created in {{dmg_dir}}/"

# Localization pipeline
l10n-import-current:
    @python3 scripts/localization.py import-current

l10n-sync:
    @python3 scripts/localization.py sync

l10n-lint:
    @python3 scripts/localization.py lint

l10n-add-locale locale:
    @python3 scripts/localization.py add-locale "{{locale}}"

# Create a signed DMG for distribution
dmg: export-app
    @echo "📦 Creating DMG..."
    @./scripts/create-dmg.sh
    @echo "✅ DMG created in {{dmg_dir}}/"

# Archive for App Store / Notarization
archive:
    @echo "📦 Creating archive..."
    xcodebuild archive \
        -project {{xcode_project}} \
        -scheme {{scheme}} \
        -configuration Release \
        -archivePath {{build_dir}}/{{app_name}}.xcarchive \
        -allowProvisioningUpdates
    @echo "✅ Archive created: {{build_dir}}/{{app_name}}.xcarchive"

# Export a Developer ID-signed app bundle for distribution
export-app: archive
    @echo "📤 Exporting app..."
    xcodebuild -exportArchive \
        -archivePath {{build_dir}}/{{app_name}}.xcarchive \
        -exportPath {{release_dir}} \
        -exportOptionsPlist scripts/ExportOptions.plist \
        -allowProvisioningUpdates
    @echo "✅ App exported to {{release_dir}}"

# Sign the app bundle (requires Developer ID certificate)
sign:
    @echo "✍️  Signing app bundle..."
    ./scripts/sign-app-bundle.sh {{app_bundle}} "Developer ID Application"
    @echo "✅ App signed"

# Verify code signature
verify-signature:
    @echo "🔍 Verifying signature..."
    codesign --verify --deep --strict --verbose=2 {{app_bundle}}
    spctl --assess --type execute --verbose=2 {{app_bundle}}
    @echo "✅ Signature verified"

# Notarize the DMG (requires Apple Developer account)
notarize dmg_path:
    @echo "📝 Notarizing {{dmg_path}}..."
    @result_file=$(mktemp) && \
    xcrun notarytool submit {{dmg_path}} \
        --keychain-profile "notarytool-password" \
        --wait \
        --output-format json > "$result_file" && \
    python3 -c 'import json, sys; result=json.load(open(sys.argv[1], encoding="utf-8")); status=result.get("status"); summary=result.get("statusSummary", "Unknown notarization failure"); sys.exit(0 if status == "Accepted" else (print("Notarization failed: %s - %s" % (status or "unknown", summary), file=sys.stderr) or 1))' "$result_file"
    @echo "✅ Notarization complete"

# Staple notarization ticket to DMG
staple dmg_path:
    @echo "📎 Stapling notarization ticket..."
    xcrun stapler staple {{dmg_path}}
    @echo "✅ Stapling complete"

# Manual GitHub release workflow
# Usage: just release 1.9.0
# Runs locally: signed DMG -> notarize/staple -> release notes -> tag -> push tag -> gh release create
release version:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="{{version}}"
    TAG="v${VERSION}"
    DMG_PATH="{{dmg_dir}}/{{app_name}}.dmg"
    NOTES_PATH="release-notes/${TAG}.md"
    NOTES_HTML_ASSET="release-notes-${TAG}.html"
    NOTES_HTML_PATH="{{dmg_dir}}/${NOTES_HTML_ASSET}"

    # Validate version format (X.Y.Z)
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "❌ Invalid version format: $VERSION"
        echo "   Expected format: X.Y.Z (e.g., 1.9.0)"
        exit 1
    fi

    echo "🚀 Releasing Pindrop ${TAG}"
    echo ""

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "❌ You have uncommitted changes. Please commit or stash them first."
        exit 1
    fi

    # Ensure required tools are available
    for tool in just gh create-dmg; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "❌ Required tool not found: $tool"
            exit 1
        fi
    done

    # Ensure gh is authenticated
    if ! gh auth status -h github.com >/dev/null 2>&1; then
        echo "❌ GitHub CLI is not authenticated."
        echo "   Run: gh auth login"
        exit 1
    fi

    # Ensure release does not already exist
    if gh release view "${TAG}" >/dev/null 2>&1; then
        echo "❌ GitHub release already exists: ${TAG}"
        exit 1
    fi

    # Ensure release notes exist and are edited
    if [ ! -f "${NOTES_PATH}" ]; then
        echo "📝 No release notes found for ${TAG}. Creating draft..."
        just release-notes "${VERSION}"
        echo "❌ Draft release notes created at ${NOTES_PATH}."
        echo "   Review/edit the file and rerun: just release ${VERSION}"
        exit 1
    fi
    if grep -q "TODO" "${NOTES_PATH}"; then
        echo "❌ Release notes still contain TODO markers: ${NOTES_PATH}"
        echo "   Please finalize notes before releasing."
        exit 1
    fi

    # Get current version
    CURRENT_VERSION=$(grep 'MARKETING_VERSION = ' Pindrop.xcodeproj/project.pbxproj | head -1 | sed 's/.*= \(.*\);/\1/')
    CURRENT_BUILD=$(grep 'CURRENT_PROJECT_VERSION = ' Pindrop.xcodeproj/project.pbxproj | head -1 | sed 's/.*= \(.*\);/\1/')
    LATEST_TAG=$(git tag --sort=-version:refname | head -1)
    LATEST_RELEASE_BUILD=""
    if [ -n "${LATEST_TAG}" ]; then
        LATEST_RELEASE_BUILD=$(git show "${LATEST_TAG}:Pindrop.xcodeproj/project.pbxproj" 2>/dev/null | grep 'CURRENT_PROJECT_VERSION = ' | head -1 | sed 's/.*= \(.*\);/\1/' || true)
    fi
    BASE_BUILD=${CURRENT_BUILD}
    if [ -n "${LATEST_RELEASE_BUILD}" ] && [ "${LATEST_RELEASE_BUILD}" -gt "${BASE_BUILD}" ]; then
        BASE_BUILD=${LATEST_RELEASE_BUILD}
    fi
    echo "📋 Current version: ${CURRENT_VERSION}"
    echo "📋 Current build: ${CURRENT_BUILD}"
    echo "📋 Latest release tag: ${LATEST_TAG:-none}"
    if [ -n "${LATEST_RELEASE_BUILD}" ]; then
        echo "📋 Latest released build: ${LATEST_RELEASE_BUILD}"
    fi
    echo "📋 New version: ${VERSION}"
    echo ""

    if [ "$CURRENT_VERSION" = "$VERSION" ]; then
        echo "ℹ️  Version already set to ${VERSION}; keeping build ${CURRENT_BUILD}."
    else
        NEXT_BUILD=$((BASE_BUILD + 1))
        echo "📋 New build: ${NEXT_BUILD}"
        echo ""

        # Update MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.pbxproj
        echo "📝 Updating version and build number in Xcode project..."
        sed -i '' "s/MARKETING_VERSION = ${CURRENT_VERSION};/MARKETING_VERSION = ${VERSION};/g" Pindrop.xcodeproj/project.pbxproj
        sed -i '' "s/CURRENT_PROJECT_VERSION = ${CURRENT_BUILD};/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" Pindrop.xcodeproj/project.pbxproj

        # Verify the changes
        NEW_VERSION=$(grep 'MARKETING_VERSION = ' Pindrop.xcodeproj/project.pbxproj | head -1 | sed 's/.*= \(.*\);/\1/')
        NEW_BUILD=$(grep 'CURRENT_PROJECT_VERSION = ' Pindrop.xcodeproj/project.pbxproj | head -1 | sed 's/.*= \(.*\);/\1/')
        if [ "$NEW_VERSION" != "$VERSION" ]; then
            echo "❌ Failed to update version"
            exit 1
        fi
        if [ "$NEW_BUILD" != "$NEXT_BUILD" ]; then
            echo "❌ Failed to update build number"
            exit 1
        fi
        echo "✅ Version updated to ${VERSION} (build ${NEXT_BUILD})"

        # Commit the version bump
        echo "📦 Committing version bump..."
        git add Pindrop.xcodeproj/project.pbxproj
        git commit -m "chore: bump version to ${VERSION} (build ${NEXT_BUILD})"
    fi

    # Step 1: Build signed release DMG
    echo "📦 Building signed release DMG..."
    just dmg

    # Step 2: Notarize and staple the DMG before publishing
    echo "📝 Notarizing release DMG..."
    just notarize "${DMG_PATH}"
    echo "📎 Stapling notarization ticket..."
    just staple "${DMG_PATH}"

    # Step 3: Render release notes HTML asset
    just release-notes-html "${VERSION}"
    if [ ! -f "${NOTES_HTML_PATH}" ]; then
        echo "❌ Expected rendered release notes asset was not generated: ${NOTES_HTML_PATH}"
        exit 1
    fi

    # Step 4: Validate release notes
    echo "📝 Using release notes: ${NOTES_PATH}"

    # Step 5: Create annotated tag (if needed)
    if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        echo "ℹ️  Tag already exists locally: ${TAG}"
    else
        echo "🏷️  Creating tag ${TAG}..."
        git tag -a "${TAG}" -m "Release ${TAG}"
    fi

    # Step 6: Push tag (if needed)
    if git ls-remote --exit-code --tags origin "${TAG}" >/dev/null 2>&1; then
        echo "ℹ️  Tag already exists on origin: ${TAG}"
    else
        echo "🚀 Pushing tag to origin..."
        git push origin "${TAG}"
    fi

    # Step 7: Create GitHub release and attach assets
    echo "📤 Creating GitHub release with DMG + release notes..."
    gh release create "${TAG}" "${DMG_PATH}" "${NOTES_HTML_PATH}" \
        --title "Pindrop ${TAG}" \
        --notes-file "${NOTES_PATH}"

    # Step 8: Sync release notes to the website changelog (best-effort, non-fatal)
    echo "🌐 Syncing website changelog..."
    if ! just sync-website-changelog "${VERSION}"; then
        echo "⚠️  Website changelog sync failed (non-fatal)."
        echo "   Run manually: just sync-website-changelog ${VERSION}"
    fi

    echo ""
    echo "✅ Release ${TAG} published!"
    echo ""
    echo "📋 Uploaded assets:"
    echo "  - ${DMG_PATH}"
    echo "  - ${NOTES_HTML_PATH}"
    echo "📝 Release notes:"
    echo "  - ${NOTES_PATH}"
    echo ""
    echo "ℹ️  Optional follow-up: push main when you're ready."

# Sync a release's notes into the website changelog collection
# Copies release-notes/vX.Y.Z.md (with version/date frontmatter) into the
# pindrop-website repo, commits just that file, and pushes so Vercel redeploys.
# Website location defaults to ../pindrop-website; override with PINDROP_WEBSITE_DIR.
# Usage: just sync-website-changelog 1.22.0
sync-website-changelog version:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="{{version}}"
    TAG="v${VERSION}"
    SITE_DIR="${PINDROP_WEBSITE_DIR:-../pindrop-website}"
    SRC="release-notes/${TAG}.md"
    DEST_REL="src/content/changelog/${TAG}.md"
    DEST="${SITE_DIR}/${DEST_REL}"

    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "❌ Invalid version format: $VERSION (expected X.Y.Z)"
        exit 1
    fi
    if [ ! -f "${SRC}" ]; then
        echo "❌ Release notes not found: ${SRC}"
        exit 1
    fi
    if [ ! -d "${SITE_DIR}/src/content/changelog" ]; then
        echo "❌ Website changelog directory not found: ${SITE_DIR}/src/content/changelog"
        echo "   Clone pindrop-website next to this repo or set PINDROP_WEBSITE_DIR."
        exit 1
    fi

    # Release date comes from the tag when it exists, today otherwise.
    RELEASE_DATE=$(git for-each-ref --format='%(creatordate:short)' "refs/tags/${TAG}")
    if [ -z "${RELEASE_DATE}" ]; then
        RELEASE_DATE=$(date +%F)
    fi

    {
        echo "---"
        echo "version: \"${VERSION}\""
        echo "date: ${RELEASE_DATE}"
        echo "---"
        echo ""
        cat "${SRC}"
    } > "${DEST}"
    echo "✅ Wrote ${DEST}"

    if git -C "${SITE_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${SITE_DIR}" add "${DEST_REL}"
        if git -C "${SITE_DIR}" diff --cached --quiet; then
            echo "ℹ️  Website changelog already up to date."
        else
            git -C "${SITE_DIR}" commit -m "changelog: add ${TAG}"
            if git -C "${SITE_DIR}" push; then
                echo "🚀 Website changelog pushed; the site will redeploy."
            else
                echo "⚠️  Committed but push failed. Push manually from ${SITE_DIR}."
                exit 1
            fi
        fi
    else
        echo "⚠️  ${SITE_DIR} is not a git repo; file written but not committed."
    fi

# Generate a draft release notes file for a version
# Usage: just release-notes 1.9.0
release-notes version:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="{{version}}"
    TAG="v${VERSION}"
    NOTES_DIR="release-notes"
    NOTES_PATH="${NOTES_DIR}/${TAG}.md"

    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "❌ Invalid version format: $VERSION"
        echo "   Expected format: X.Y.Z (e.g., 1.9.0)"
        exit 1
    fi

    mkdir -p "${NOTES_DIR}"

    if [ -f "${NOTES_PATH}" ]; then
        echo "ℹ️  Release notes already exist: ${NOTES_PATH}"
        exit 0
    fi

    if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        PREV_TAG=$(git tag --sort=-version:refname | awk -v tag="${TAG}" '$0 != tag {print; exit}')
    else
        PREV_TAG=$(git tag --sort=-version:refname | head -1)
    fi

    COMMITS=$(git log --no-merges --pretty=format:'- %s' "${PREV_TAG:+${PREV_TAG}..HEAD}" | head -8 || true)
    COMPARE_URL=""
    if [ -n "${PREV_TAG}" ]; then
        COMPARE_URL="https://github.com/watzon/pindrop/compare/${PREV_TAG}...${TAG}"
    fi

    printf '%s\n' \
        "## What's New" \
        '' \
        "- TODO: Add 2-5 user-facing highlights for ${TAG}." \
        '' \
        '## Improvements' \
        '' \
        '- TODO: Add notable fixes, polish, or infrastructure changes users should know about.' \
        '' \
        '## Full Changelog' \
        '' \
        "${COMPARE_URL:-TODO: Add compare URL}" \
        > "${NOTES_PATH}"

    if [ -n "${COMMITS}" ]; then
        printf '\n## Commit Context (for drafting)\n\n%s\n' "${COMMITS}" >> "${NOTES_PATH}"
    fi

    echo "✅ Draft release notes created: ${NOTES_PATH}"
    echo "✏️  Review/edit the file, remove TODO markers, then run: just release ${VERSION}"

# Render versioned release notes HTML from the markdown source
# Usage: just release-notes-html 1.9.0
release-notes-html version:
    #!/usr/bin/env bash
    set -euo pipefail

    VERSION="{{version}}"
    TAG="v${VERSION}"
    NOTES_PATH="release-notes/${TAG}.md"
    NOTES_HTML_PATH="{{dmg_dir}}/release-notes-${TAG}.html"

    if [ ! -f "${NOTES_PATH}" ]; then
        echo "❌ Release notes not found: ${NOTES_PATH}"
        exit 1
    fi

    mkdir -p "{{dmg_dir}}"
    python3 scripts/render_release_notes_html.py \
        --input "${NOTES_PATH}" \
        --output "${NOTES_HTML_PATH}" \
        --version "${TAG}"

    echo "✅ Rendered release notes HTML: ${NOTES_HTML_PATH}"

# Open project in Xcode
xcode:
    @echo "🔧 Opening Xcode..."
    open {{xcode_project}}

# Lint Swift code (requires SwiftLint)
lint:
    @echo "🔍 Linting Swift code..."
    @if command -v swiftlint >/dev/null 2>&1; then \
        swiftlint; \
    else \
        echo "⚠️  SwiftLint not installed. Run: brew install swiftlint"; \
    fi

# Format Swift code (requires SwiftFormat)
format:
    @echo "✨ Formatting Swift code..."
    @if command -v swiftformat >/dev/null 2>&1; then \
        swiftformat .; \
    else \
        echo "⚠️  SwiftFormat not installed. Run: brew install swiftformat"; \
    fi

# Development workflow: clean, build
dev: clean build
    @echo "✅ Development build complete"

# CI workflow: clean, unsigned build, unsigned release build
ci: clean build-unsigned build-release-unsigned
    @echo "✅ CI workflow complete"
