# Baton macOS App Visual Design System

## Vision

Create a premium native macOS music player whose appearance adapts to
the currently playing artwork while preserving a consistent Baton
identity.

## Design Principles

-   Content first.
-   Native macOS.
-   Artwork influences the UI without overwhelming it.
-   Excellent accessibility and readability.
-   Motion should feel calm and intentional.

## Color Architecture

### Permanent Brand Color

Primary Baton Orange: **#E98345**

Use ONLY for: - Logo - Primary actions - Install / GitHub buttons -
Brand icons - Marketing identity

Never replace the Baton brand color with artwork colors.

### Dynamic Music Palette

Generate a palette from the current album artwork.

Required outputs: - Primary Accent - Secondary Accent - Neutral Dark -
Highlight - Optional Gradient

Example:

Blue artwork - Primary #4F89FF - Secondary #79A9FF - Neutral #2A2D33 -
Highlight #C9DFFF

Orange artwork - Primary #E67B3D - Secondary #F2A15A - Neutral #2A2522 -
Highlight #FFE4D3

## Surface Hierarchy

Do NOT tint every surface equally.

Sidebar - Accent opacity 8%

Toolbar - Accent opacity 6%

Content - Accent opacity 4%

Player - Accent opacity 10%

Selection - Accent opacity 35%

Buttons - 100% accent

This creates visual depth.

## Selection

Instead of only a border:

-   1 px border
-   Soft outer glow
-   Small scale animation
-   Smooth 150--200ms transition

## Player

Artwork should influence:

-   Progress bar
-   Volume slider
-   Favorite icons
-   Playback glow
-   Optional blurred reflection

## Motion

Avoid flashy animations.

Preferred: - Crossfade between themes - 300--500 ms transitions - Gentle
background interpolation

## Accessibility

Always guarantee: - WCAG AA contrast - Automatic light/dark text
switching - Minimum readable contrast regardless of artwork

## Future Ideas

-   Dynamic gradients
-   Adaptive waveform
-   Animated equalizer using artwork colors
-   Ambient lighting behind artwork
