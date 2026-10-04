# AgentKeyBox Brand & Visual Direction

## Status

This document defines the current visual direction for AgentKeyBox and should be used as the reference for the macOS app UI, website, documentation graphics, and future brand assets.

The selected app icon direction is:

> **Key in a Box + Agent**

The visual communicates three ideas:

1. **Box** — credentials are kept in one controlled place.
2. **Key** — the product manages developer credentials and access.
3. **Agent** — AI coding agents request access rather than receiving secrets freely.

The interaction behind the symbol remains:

> **AI asks. You approve.**

---

## 1. Primary icon concept

The primary icon uses an open credential box with a small AI agent emerging from it.

A conventional key symbol is displayed clearly on the front of the box.

### Meaning

The **box** represents AgentKeyBox as the local credential container.

The **key** represents API keys, tokens, `.p8`, `.pem`, JSON credentials, and other developer credentials.

The **agent** represents Claude Code, Codex, Cursor, and future coding-agent integrations.

The agent should appear to be **requesting or interacting with the box**, not owning it.

> The agent can ask for access, but the credential remains under the user's control.

Small signal marks above the agent can suggest an active request or notification.

---

## 2. Design principles

### Friendly security

AgentKeyBox should feel secure without fear-based cybersecurity imagery.

Prefer:
- rounded geometry
- calm depth
- clear objects
- approachable agent character
- soft highlights
- controlled contrast

Avoid:
- aggressive shields
- warning-heavy visuals
- hacker/cyberpunk motifs
- neon overload
- military or surveillance aesthetics

### Native macOS character

Use:
- rounded-square app icon container
- dimensional but restrained materials
- soft shadows
- subtle translucency where useful
- polished highlights
- clear silhouettes at small sizes

The application UI should remain cleaner and flatter than the app icon. Do not turn every UI control into a 3D object.

### Human control first

Visual hierarchy should reinforce:

**Permission > Security > AI**

AI is present, but should never visually dominate the key or container.

---

## 3. Primary palette

The current icon establishes a cool blue palette.

### Midnight Navy — `#061C4A`

Use for:
- deep backgrounds
- dark-mode surfaces
- high-contrast brand moments

### AgentKey Blue — `#0867E8`

Use for:
- primary accent
- selected states
- primary buttons when appropriate
- links and active controls

### Electric Cyan — `#16DDF3`

Use sparingly for:
- permission/request signals
- key highlight
- active agent indicators

### Ice White — `#F4F8FF`

Use for:
- light surfaces
- icon material
- subtle elevated panels

### Slate / Ink — `#0B1733`

Use for:
- text
- dark icon details
- dark UI foreground elements

These are initial design tokens derived from the selected visual direction, not final colorimetric measurements. Production assets should later normalize them into a fixed token set.

---

## 4. Gradient direction

For brand illustrations and the app icon:

**AgentKey Blue → Midnight Navy**

with selective Electric Cyan highlights.

Recommended:
- brighter blue toward upper-left / active-facing surfaces
- navy toward depth/background areas
- cyan only at interaction points

Avoid rainbow or purple-heavy generic AI gradients.

---

## 5. Agent character

The agent is deliberately minimal:

- white/light rounded shell
- dark visor
- two simple cyan/white eyes
- no mouth
- no detailed humanoid body
- no complex robot mechanics

It should read as an **AI coding agent**, not become a mascot that takes over the brand.

The same visual language may later appear in onboarding, empty states, connection status, and approval illustrations, but should be used sparingly.

---

## 6. Key geometry

The key must look unmistakably like a conventional key:

- circular bow/head at the rear
- straight shaft
- one or two simple teeth at the front
- no circular shape at the tooth end
- simplified enough to read at 16–32 px

Avoid:
- infinity-shaped keys
- two-headed key symbols
- chain-link shapes
- ornate antique keys

The key is a semantic signal, not decoration.

---

## 7. Box geometry

The box represents controlled local storage.

Preferred:
- open top
- rounded edges
- slightly dimensional construction
- strong front face for the key symbol
- simple silhouette

It should not look like:
- a cardboard shipping box
- bank vault
- treasure chest
- crypto wallet

---

## 8. UI translation

The app icon is richer than the application UI.

Translate the same system into the UI using:

- native macOS spacing and controls
- AgentKey Blue as primary accent
- Electric Cyan reserved for active/request states
- rounded cards and sheets
- subtle material/depth rather than heavy gradients
- Midnight Navy for high-emphasis surfaces
- simple line/glyph icons for ordinary controls

### Approval UI

Approval should be the strongest brand moment inside the product.

Recommended semantic use:
- normal request: AgentKey Blue
- needs attention / actively requesting: Electric Cyan accent
- destructive / deny: native semantic red
- success: native semantic green

Do not use cyan for every control; it should retain meaning.

---

## 9. Typography

Use the macOS system typography stack for product UI.

For marketing/brand surfaces:
- modern neo-grotesk / system-adjacent sans serif
- clean proportions
- high legibility
- no futuristic techno typefaces

Canonical spelling:

**AgentKeyBox**

The camel-case structure visually communicates:

**Agent / Key / Box**

---

## 10. Required production variants

The selected concept should eventually be rebuilt as controlled production assets rather than relying solely on generated raster artwork.

Required:
- 1024 × 1024 master app icon
- 512 × 512
- 256 × 256
- 128 × 128
- 64 × 64
- 32 × 32
- 16 × 16
- monochrome symbol
- simplified small-size glyph
- light-background variant
- dark-background variant
- wordmark + symbol lockup

The 16 px and 32 px versions may require manual simplification instead of simple downscaling.

---

## 11. Additional visual assets

After the app icon is finalized, prioritize:

1. **macOS menu-bar template icon**
   - monochrome
   - simple box/key or box/agent silhouette

2. **Approval-request glyph**
   - compact agent + key/access indicator
   - suitable for permission sheets and notifications

3. **Credential-type icons**
   - API key/token
   - `.env`
   - `.p8`
   - `.pem`
   - JSON/service account

4. **Agent connection states**
   - connected
   - requesting
   - disconnected
   - setup required

5. **Empty-state illustration**
   - agent interacting with an empty credential box
   - use only where illustration adds clarity

6. **Wordmark**
   - AgentKeyBox text lockup compatible with the icon

Do not build a large custom icon library before the public-alpha UI structure is stable. Prefer SF Symbols for ordinary interface actions.

---

## 12. Source asset

Current selected visual reference:

`assets/brand/agentkeybox-app-icon.png`

This is the current visual reference and product-direction asset. It is **not yet the final vector/master production asset**.


---

## 13. Production asset set

The first production-ready icon asset set now lives under `assets/brand/`.

### App icon

`assets/brand/app-icon/`

- `AppIcon-1024.png` is the primary raster master derived from the selected **Key in a Box + Agent** artwork.
- Standard raster exports are included at 512, 256, 128, 64, 32, and 16 px.
- `AppIcon-Simplified.svg` provides simplified small-size artwork.
- `AppIcon-Tiny.svg` is pixel-aware artwork specifically for 16/32 px, where the full illustration loses legibility.

`assets/brand/AppIcon.appiconset/` contains a macOS asset-catalog-ready set with `Contents.json`.

Do not generate 16/32 px icons by blindly downscaling the 1024 artwork. Use the dedicated tiny/simplified variants.

### Menu bar template

`assets/brand/menu-bar/`

The menu-bar artwork is intentionally different from the app icon:

- monochrome only
- transparent background
- front-facing simplified geometry
- rendered at 16, 18, 22 px and @2x equivalents 32, 36, 44 px
- intended to be loaded as a macOS template image (`NSImage.isTemplate = true`)

Do not maintain separate white and black menu-bar art. macOS should tint the template image automatically for the current appearance.

### Approval request

`assets/brand/ui/ApprovalRequest.svg`

This is the compact branded permission/request glyph. Use it only where the AgentKeyBox identity adds value, such as approval UI or a request notification. Ordinary buttons should continue to use SF Symbols.

### Credential types

`assets/brand/credential-types/`

Production credential-type glyphs are deliberately flat/duotone rather than miniature 3D app icons:

- `Credential-APIKey`
- `Credential-ENV`
- `Credential-P8`
- `Credential-PEM`
- `Credential-JSON`

Each has an SVG master and 128/64/32 px PNG exports.

Provider logos remain separate from AgentKeyBox credential-type icons.

### Connection and status icons

Do not create a custom branded icon for every state. Use native semantic/SF Symbols for generic UI states such as:

- connected / success
- disconnected / error
- pending
- settings required
- deny / destructive actions

This prevents visual overload and keeps the app macOS-native.

### Locked key geometry rule

Every production AgentKeyBox key must follow this geometry:

> **One circular bow/head at the rear + one straight shaft + teeth at the front.**

There must never be a circular element at both ends of the key.
