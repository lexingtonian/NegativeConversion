# Handover: Negative Converter

This project was written in a cloud session that could not build or run Mac
code. You are picking it up in a session on the owner's Mac.

## What the app is

A macOS SwiftUI app (Swift package, macOS 13+) that converts camera scans of
film negatives (Valoi scanning rig, raw/JPEG/TIFF) into positive JPEGs. The
README explains the conversion step by step; read it before changing the maths.

- `Sources/NegativeCore`: all conversion maths, plain Swift, no Apple frameworks.
- `Sources/NegativeConverter`: Core Image decoding, JPEG writing, SwiftUI interface.
- `Tests/NegativeCoreTests`: unit tests for the core.
- `Tools`: the film simulator and command-line harness used to develop the
  maths (see `Tools/README.md`). Not part of the app.

## State of the code

- Builds and runs on the owner's Mac (Swift 6.4, macOS 26). 13 unit tests pass.
- First run on real scans (Sony ILCE-6000 raw files; one colour roll in
  `~/Documents/colorconvtmp`, black-and-white in `~/Documents/Scanned`) came
  out dark with a yellow-green cast. Causes found and fixed, 2026-11-10:
  - `CIRAWFilter.shadowBias` (default 3) subtracts a constant from every
    pixel. It wiped out most of the blue channel in the dense parts of the
    negative. Now set to 0 in `ImagePipeline.loadLinear`.
  - With true black levels the holder is sensor noise around zero, and holder
    detection missed it. `markHolder` now finds the holder's own level first.
  - Red and blue were matched to green at the densest 0.2 % of the picture,
    which is often coloured (sky, lamps). They are now matched over the whole
    picture (`NegativeAnalysis.layerContrast`).
  - Clear film inside the measured area set the black point and made shadows
    grey. It is now left out of the measurement.
  - Default contrast and mid-tone targets were raised (`ToneCurve.baseContrast`
    1.3, `ToneCurve.liftTargets`), judged against the owner's earlier
    conversions of the same frames (`*_p6.jpg` in `colorconvtmp`).
- `NegativeConverter --convert <out folder> <files>` converts without the
  window and prints the analysis. Use it with real scans before changing the
  maths; the simulator in `Tools` did not predict any of the faults above.
- The app starts through AppKit (`NegativeConverterApp.swift`). Startup works;
  the numbered `[NegativeConverter]` log lines are still in and can go.
- Export writes JPEG or 16-bit TIFF (`OutputFormat`, `ImagePipeline.export`),
  same pixel count as the original and its dots per inch. Checked from the
  command line (`--export jpeg|tiff <out folder> <files>`) on raw and JPEG
  input; the format picker in the window was not clicked by me.
- Still unverified: drag and drop, TIFF input.

## What the owner has decided

- A natural-looking result outranks every other requirement.
- **Every frame is converted on its own.** The scanning camera sets exposure per
  frame, so nothing may be shared or compared between frames. Do not add
  roll-wide settings.
- They liked the idea of "trust the film's exposure" (`ToneMode.filmExposure`).
  On their real scans it was unreliable, so the default was changed to
  `fitToPicture` on 2026-11-10 without asking them first; they have been told.
  Film exposure remains a choice per frame.
- They want changes made directly in this folder. No downloads, no copy and paste.
- They want blunt, plain answers and short instructions.

## Constants most likely to need tuning on real scans

- `ToneCurve.baseContrast`, `ToneCurve.liftTargets`, `ToneCurve.strongestLift`:
  contrast and brightness when fitted to the picture.
- `FilmReference.colorWhiteDensityAboveBase` (1.00, from one real roll) and
  `whiteDensityAboveBase` (1.05, black-and-white: textbook Zone VIII 1.2-1.3 corrected for camera-scan flare):
  brightness in film-exposure mode.
- `NegativeAnalyzer.clearFilmEvenness` and the border test in `pictureRect`:
  whether a frame is judged to show clear film.
- Holder detection thresholds in `markHolder`.
- `NegativeAnalyzer.blackAndWhiteChromaSpread`, `blackAndWhiteChromaExtremes`,
  `orangeMaskDensity`: colour versus black-and-white. Film with an orange mask
  is never black-and-white, and neither is a frame with a small strongly
  coloured object (`DSC05039`, a red buoy on a grey sea, on film with hardly
  any mask; the raw file was never available to test, only its exports).
  The mask test assumes a roughly daylight-coloured scanning light; under a
  very warm light, black-and-white film would be taken for colour.

## Known weaknesses

- Colour balance assumes the picture's colours average out to grey.
- Bare backlight beside black-and-white film is taken for clear film, which
  ruins film-exposure mode on such frames (most of the owner's black-and-white
  scans). Fit to picture is not affected.
- Uneven scanning light shows as lighter edges in the positive.
- Saturation was never calibrated against real colour film.
- A smooth, even, dark area at the edge of a tight frame can be mistaken for
  clear film.
- Bare backlight beside black-and-white film is only recognised as sprocket holes.
