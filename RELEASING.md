# Releasing Pindrop

This document describes the release process for Pindrop.

## Release Process

### Prerequisites

- macOS development machine with Developer ID signing and notarization credentials
- Xcode installed
- `just` command runner: `brew install just`

### Steps

1. **Update version numbers** in Xcode project settings

2. **Build and sign the release**:
```bash
just release 1.0.0
```
This will:
- Clean build artifacts
- Build the release version
- Sign the app with your Developer ID
- Create a DMG in `dist/Pindrop.dmg`
- Notarize the DMG with Apple
- Staple the notarization ticket to the DMG
- Render version-specific release notes HTML from `release-notes/vX.Y.Z.md`
- Create and push the `vX.Y.Z` tag
- Create the GitHub release with `dist/Pindrop.dmg` and `dist/release-notes-vX.Y.Z.html`
