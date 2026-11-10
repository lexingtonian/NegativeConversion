# Test tools

These are not part of the app. They were used to develop the conversion maths
without real scans: a film simulator turns ordinary photographs into fake
negative scans, and a command-line harness runs the conversion core on them.

## simulator (Python 3 with numpy, scipy, pillow, scikit-image)

- `synth.py <out-dir>`: single test frames (colour and black-and-white; tight,
  holder border, sprocket holes; over- and underexposed; fog; backlit).
- `synth_roll.py <out-dir>`: frames exposed at box speed, including a correctly
  exposed subject in front of a background four to five stops brighter.
- Each frame is written as `<name>.half` (int32 width, int32 height, then
  half-float RGBA, linear light) plus `<name>.ref.png`, the original scene.
- `sheet.py` and `sheet2.py` lay out negative, conversion and original side by
  side as one PNG.

The film model (contrast, mask densities, dye crosstalk) is invented. It shows
that the maths is consistent, not that real film will look right.

## negcli (Swift)

```bash
cd Tools/negcli
swift build -c release
.build/release/negcli --roll frames/*.half
```

For each frame this writes `<name>.fit.rgba` (fitted to the picture) and
`<name>.trust.rgba` (by film exposure) as raw 8-bit RGBA, and prints what the
analysis found.
