# Negative Converter

A macOS app that turns camera photographs of film negatives (colour or
black-and-white) into positive JPEG or TIFF files.

Drop files or folders onto the window, check the previews, choose an output
folder, press **Convert**. Camera raw, JPEG and TIFF are accepted; raw gives the
most faithful result because its pixel values are still proportional to light.

Requires macOS 13 or later and Xcode 15 or later.

## Running it

**In Xcode:** open `Package.swift` (File > Open), pick the `NegativeConverter`
scheme and "My Mac", press Run. For normal use switch the scheme to the Release
configuration (Product > Scheme > Edit Scheme > Run > Build Configuration);
debug builds convert several times more slowly.

**From Terminal:**

```bash
swift run -c release NegativeConverter
```

**Without the window, for testing:**

```bash
swift run -c release NegativeConverter --convert <output folder> <files>
```

writes each file's conversion at preview size in both tone modes and prints
what the analysis measured.

**As a double-clickable app:**

```bash
./make-app.sh
```

Output is JPEG (8 bits per channel) or TIFF (16 bits per channel, lossless,
LZW-compressed), chosen next to the Convert button. Either has exactly as many
pixels as the decoded original and carries over its dots-per-inch figure.
Files are named `<original name>_positive.jpg` or `.tif`. Existing files are
never overwritten; a number is appended instead.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/NegativeCore` | All of the conversion maths. Plain Swift, no Apple frameworks. |
| `Sources/NegativeConverter` | The app: Core Image decoding, JPEG writing, SwiftUI interface. |
| `Tests/NegativeCoreTests` | Unit tests for the core (`swift test`). |

## How the conversion works

1. **Decode to linear light.** Raw files are developed flat (no tone curve, no
   local tone mapping, fixed 5000 K white balance) into a wide-gamut linear
   space. A reduced copy (1600 px) is analysed; the result is then applied to
   the full-resolution file, so the preview matches the export.
2. **Set aside what is not picture.**
   - *Film holder:* pixels far darker than the densest film that connect to the
     edge of the frame.
   - *Bare backlight* (sprocket holes, gaps beside the film): a tight cluster
     clearly brighter than clear film. On colour film it is recognised by not
     being orange; on black-and-white film only the sprocket-hole pattern is
     accepted.
   - *Unexposed film border:* lines of clear film around the picture.
   - A small safety margin is trimmed on top of that.

   These areas are ignored for measuring only. They stay in the output, which
   has the same framing as the input.
3. **Measure the film.** Each pixel is converted to density
   (`-log10` of its value). In green, the density of the thinnest and the
   densest picture content is found (0.4 % and 99.8 % points). Clear film that
   lies inside the measured area (a sliver of border, the gap to the next
   frame) is left out, so the black point is the picture's own darkest part.
   Red and blue follow green: how much faster or slower their density rises
   than green's is taken from all pixels of the picture together (the layer
   contrast), counted from clear film when the frame shows some. This removes
   the orange mask and the unequal contrast of the three colour layers, and it
   does not depend on the brightest spots being neutral.
4. **Colour or black-and-white.** Film with an orange mask is colour film.
   Otherwise, if the three channels rise and fall together everywhere, the
   film is black-and-white and is converted from a single luminance channel
   to a neutral grey image. "Everywhere" includes the most differently
   coloured half percent of the picture, so one small coloured object in a
   grey scene is enough to make the frame colour.
5. **Tones, fitted to the picture** (the default). The frame's own thinnest
   and densest content become black and white. Density is turned back into
   scene light using the usual response of negative film, then encoded for the
   screen with an S-curve. If large parts of the picture would still sit low,
   the mid-tones are lifted. Scenes under about three stops of range are not
   stretched to full black-to-white.
6. **Tones, by film exposure** (when chosen, and only if the frame shows clear
   film). Tones are placed by how far above clear film they sit on the
   negative, which is decided by the exposure given in the camera. A correctly
   exposed subject then comes out right whatever is behind it; a much brighter
   background rolls off towards white. Clear film is taken from the frame
   itself. Brightness slides the whole scale, like print exposure. On real
   scans this mode proved unreliable as a default: frames come out too bright
   or too dark whenever the film was not exposed and developed to the
   calibration, and bare backlight beside black-and-white film is taken for
   clear film.

In both modes the curve rolls off smoothly beyond its end points.

The numbers that shape the result are constants at the top of
`NegativeAnalysis.swift` (`NegativeAnalyzer`) and `ConversionRecipe.swift`
(`ToneCurve`).

## Known limits

- "By film exposure" is literal: an overexposed negative comes out bright and
  an underexposed one dark. Its calibration is a typical value, not measured
  per film.
- A smooth, even, dark area at the very edge of a tightly framed picture can
  be mistaken for clear film.
- Colour balance assumes the colours of the picture average out to grey. A
  frame filled by one colour comes out too neutral. Use Warmth and Tint.
- The scanning light is assumed even. Where it falls off towards the edges,
  the positive gets lighter there.
- Each frame is measured on its own; frames of one roll are not forced to share
  a colour balance.
- Bare backlight next to black-and-white film is only recognised as sprocket
  holes. A plain strip of bare light beside the film is treated as picture and
  lifts the shadows.
- JPEG output is 8-bit sRGB, so some tonal precision of a raw file is lost;
  TIFF keeps 16 bits. A 16-bit TIFF of a 24-megapixel frame is about 140 MB,
  black-and-white included (it is written as RGB).

## Licence

Copyright (C) 2025-2026 Ari Jaaksi. Available under the GNU General Public
License v3 or a commercial licence; see `LICENSE.txt`. Commercial licensing:
ari@slowlight.art.
