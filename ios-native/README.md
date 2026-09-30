# NiiMono — Preview-style MRI viewer for iPadOS

A fully native Swift viewer for NIfTI volumes (no WKWebView, no JS). It behaves like
Preview: launch into the system document browser, open a `.nii` / `.nii.gz`, and get
a full-bleed image under a glass toolbar with the document title menu.

Requires Xcode 27 / iPadOS 27 (plus Xcode's Metal Toolchain component:
`xcodebuild -downloadComponent MetalToolchain`).

## Run

Open `NiiMono.xcodeproj` and run on an iPad or iPad simulator. The project uses a
synchronized folder, so any file added to `NiiMono/` is picked up automatically.
Get a volume onto the device via Files/AirDrop (`T1w_DEMO.nii.gz` here is a sample).
On a simulator:

```sh
C=$(xcrun simctl get_app_container booted org.niivue.NiiMono data)
cp T1w_DEMO.nii.gz "$C/Documents/" && xcrun simctl openurl booted "file://$C/Documents/T1w_DEMO.nii.gz"
```

## Interaction

| Gesture | Action |
|---|---|
| Pinch / drag | Zoom and pan (UIScrollView — native bounce and deceleration) |
| Double-tap | Zoom in on the point / back to fit |
| Tap | Hide or show the toolbar and scrubber |
| Vertical drag or trackpad scroll (unzoomed) | Step through slices |
| Bottom scrubber | Jump to a slice |
| Toolbar | 3D / Axial / Coronal / Sagittal, Mirror (slices), view presets (3D), Share, Inspector |
| Slider track | A tap either side of the knob nudges the value one unit |
| 3D: drag | Orbit |
| 3D: two-finger drag, or secondary-button drag | Pan |
| 3D: pinch, or scroll | Zoom towards the fingers / pointer |
| 3D: double-tap | Reset to the fitted starting view |

Slice views show L/R, A/P, S/I edge labels; the 3D view shows a rotating orientation
indicator. The inspector holds window level (Black/White), the 3D rendering mode
(MIP, or Volume — a port of NiiVue's default compositing shader), up to six tiltable
3D clip planes with cutaway and highlight options, and volume info.

Launch arguments for simulator checks: `-plane Axial|Coronal|Sagittal|3D`, `-clip
Axial,Sagittal,…` (comma-separated, up to six), `-clipTilt <degrees>`, `-clipCutaway YES`,
`-clipHighlight YES`, `-inspector YES`.

## Files

| File | Role |
|---|---|
| `NiiMono/NiiMonoApp.swift` | `DocumentGroup` app, document type, viewer chrome. |
| `NiiMono/SliceView.swift` | Zoomable 2D slice view (UIScrollView + CPU-windowed CGImage). |
| `NiiMono/StepSlider.swift` | Slider that steps one unit on track taps. |
| `NiiMono/NIfTI.swift` | NIfTI-1 reader. Pure Foundation; reorients to RAS+ at load, extracts slices. |
| `NiiMono/VolumeRenderer.swift`, `Raycaster.metal` | 3D raycaster (MIP + NiiVue-style compositing, clip planes), camera, gestures and SwiftUI host. |
| `Info.plist` | Document types (`.nii`, gzip) and document-browser keys. |
| `spike/nifti_check.swift` | Self-check for the reader: decode, scaling, reorientation, slice orientation. |

Run the reader check (Swift only allows top-level code in `main.swift`, hence the copy):

```sh
mkdir -p /tmp/ncheck && cp spike/nifti_check.swift /tmp/ncheck/main.swift
swiftc NiiMono/NIfTI.swift /tmp/ncheck/main.swift -O -o /tmp/ncheck/ncheck && /tmp/ncheck/ncheck T1w_DEMO.nii.gz
```

## Conventions and limits

- Display is neurological (patient left on screen left), sagittal nose right — niivue's defaults.
- Oblique acquisitions snap to the nearest axes (no resampling).
- NIfTI-1 single-file, scalar datatypes, first volume of a 4D series. No meshes, DICOM,
  overlays, colormaps or drawing yet. The Volume render omits NiiVue's overlays and
  gradient lighting.
- Any `.gz` is openable in the browser (`.nii.gz` has no file type of its own);
  non-NIfTI files fail with an alert.
- Debug builds take a few seconds to parse a volume (unoptimized loop); Release is ~0.1 s.
