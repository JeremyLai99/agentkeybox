# AgentKeyBox Production Icon Assets

These are individual production assets, not design-board crops.

## App icon
- `agentkeybox-app-icon.png` — raster master for 128 px and larger
- `app-icon/AppIcon-Simplified.svg` (64 px) and `app-icon/AppIcon-Tiny.svg` (16/32 px)
- `AppIcon.icns` and `AppIcon.appiconset/` — generated; do not edit by hand

Regenerate after changing a master:

```bash
./assets/brand/generate-app-iconset-macos.sh
```

For small sizes, use the simplified artwork rather than blindly downscaling the 1024 artwork.

## Menu bar
- `menu-bar/MenuBarTemplate.svg`
- transparent monochrome PNGs at 16, 18, 22 px and @2x equivalents 32, 36, 44 px
- intended for `NSImage.isTemplate = true`

## Approval
- `ui/ApprovalRequest.svg`
- PNGs at 128, 64, 32 px

## Credential types
Each has SVG + PNG at 128, 64, 32:
- API key / token
- `.env`
- `.p8`
- `.pem`
- JSON / service account

## Key geometry rule
All AgentKeyBox key artwork follows the same rule:
- one circular bow/head at the rear
- straight shaft
- teeth only at the front
- never a circular element at both ends


## Small-size legibility revision

- `.env`, `.p8`, `.pem`, and `JSON` labels are constrained to a fixed content panel and must never overflow the document frame.
- The menu-bar template intentionally uses only **Box + Key** so it remains readable at 16–22 px.
- Menu-bar exports are checked at 16, 18, and 22 px instead of being judged only while enlarged.
