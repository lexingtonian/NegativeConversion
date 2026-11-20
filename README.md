# Negative Conversion

A macOS app that turns camera scans of film negatives, colour and
black-and-white, into positive JPEG or 16-bit TIFF files. Each frame is
measured on its own; the film holder, borders and small bright lights are
ignored, and the measured area can be adjusted by hand.

Available on the Mac App Store:
https://apps.apple.com/app/id6760002684

The source is in [`NegativeConverter/`](NegativeConverter/): a Swift
package with the conversion maths (`NegativeCore`), the app, and its
tests. See [`NegativeConverter/README.md`](NegativeConverter/README.md)
for how the conversion works and how to build it.

Copyright (C) 2025-2026 Ari Jaaksi. Available under the GNU General
Public License v3 or a commercial licence; see
[`NegativeConverter/LICENSE.txt`](NegativeConverter/LICENSE.txt).
Commercial licensing: ari@slowlight.art