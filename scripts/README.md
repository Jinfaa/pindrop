# Build Scripts

This directory contains scripts for building and packaging Pindrop.

## Scripts

### `create-dmg.sh`

Creates a distributable DMG file for macOS.

**Requirements:**
- `create-dmg` (install via `brew install create-dmg`)
- Signed export of `Pindrop.app` in `DerivedData/Build/Products/Release/`

**Usage:**
```bash
./scripts/create-dmg.sh
```

Or use the justfile:
```bash
just dmg
```

**Output:**
- DMG file in `dist/Pindrop.dmg`

### `ExportOptions.plist`

Configuration file for Xcode archive exports. Used when creating signed builds for distribution.

**Setup:**
1. Sign into Xcode with your Apple Developer account
2. Enable automatic signing for the `Pindrop` target
3. Ensure a Developer ID Application certificate is available for export

## Build Workflow

### Development Build

```bash
just build
```

### Release Build

```bash
just build-release
```

### Create DMG

```bash
just dmg
```

### Manual GitHub Release

```bash
just release 1.9.0
```

This will:
1. Create/edit contextual release notes (`release-notes/vX.Y.Z.md`)
2. Bump version/build and commit the change (if needed)
3. Build, notarize, and staple the signed release DMG
4. Render release notes HTML (`just release-notes-html`)
5. Create and push tag
6. Create GitHub release using `gh` with notes + DMG + release notes HTML

### Notarization (requires Apple Developer account)

```bash
just notarize dist/Pindrop.dmg
just staple dist/Pindrop.dmg
```

## Directory Structure

```
scripts/
├── README.md                   # This file
├── create-dmg.sh               # Signed DMG creation script
├── create-dmg-self-signed.sh   # Fallback self-signed DMG script
├── sign-app-bundle.sh          # Manual/fallback bundle signing
├── render_release_notes_html.py # Release notes Markdown -> HTML
└── ExportOptions.plist         # Xcode export configuration
```

## Notes

- All scripts should be executable (`chmod +x script.sh`)
- `just dmg` expects `just export-app` semantics and packages the exported signed app
- `just dmg-self-signed` is retained only as a fallback path
- Notarization requires an Apple Developer account and proper credentials
