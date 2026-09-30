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
| Tap | Hide or show the toolbar and scrubber (they also hide by themselves after 4 s) |
| Vertical drag or trackpad scroll (unzoomed) | Step through slices |
| Bottom scrubber | Jump to a slice |
| Toolbar | 3D / Multi / Axial / Coronal / Sagittal, Mirror (slices), view presets (3D), Snapshot (PNG of the canvas at screen resolution → share sheet), Share, Inspector |
| Slider track | A tap either side of the knob nudges the value one unit |
| 3D: drag | Orbit |
| 3D: two-finger drag, or secondary-button drag | Pan |
| 3D: pinch, or scroll | Zoom towards the fingers / pointer |
| 3D: double-tap | Reset to the fitted starting view |
| Multi: tap a slice pane | Move the crosshair (and the other two slices) to that point |

Slice views show L/R, A/P, S/I edge labels; the 3D view shows a rotating orientation
indicator. Multi shows coronal, sagittal, axial and 3D in a 2×2 grid at one shared
scale and zoom, linked by a crosshair drawn in all four panes. The inspector holds window level (Black/White), the 3D rendering mode
(MIP, or Volume — a port of NiiVue's default compositing shader), up to six tiltable
3D clip planes with cutaway and highlight options, and volume info.

**Segmentation overlay.** The inspector's Segmentation section loads a label map on the
scan's grid (`.nii`/`.nii.gz`, integer labels, 0 = background) and colours slices and the
3D render with it: per-label toggles, opacity, and a "show through tissue" mode for 3D.
Files named `*tissues*` get the 14 tissue classes/colours of the body-composition pipeline,
`*total_mr*` TotalSegmentator's 50 structure names, anything else numbered labels. A sibling
`<scan>_tissues.nii.gz` (also in a `seg/` folder; Dixon suffix `_W/_F/_in/_opp` stripped)
is picked up automatically when the scan opens.

**Body composition.** With a segmentation loaded, the inspector lists each class's volume
and mass (typical tissue densities) and, given the subject's weight and which body segments
lie outside the scan (Dempster/Winter mass fractions; thighs as a percentage), checks the
imaged mass against the expected share and extrapolates muscle and fat to the whole body,
assuming the missing limbs share the imaged composition.

**On-device segmentation.** "Generate Segmentation" in the Segmentation section runs both
TotalSegmentator `total_mr` networks (Dataset850 organs, Dataset851 muscles/bones; nnU-Net
3d_fullres, fold 0) as Core ML models bundled in the app (`NiiMono/Organs.mlpackage`,
`Muscles.mlpackage`, 59 MB each, fp16), merges them into the 50-structure map, and — when the
Dixon fat image is available (`<tag>_F.nii.gz` beside a `<tag>_W` scan, or chosen by hand) —
derives the 14 tissue classes of the body-composition pipeline (`TissueClassifier.swift`:
fat-fraction muscle and fat with the muscle.py / tissue_render.py morphology, visceral fat by
the per-slice trunk hull). `OrganSegmenter.swift` reproduces the TotalSegmentator/nnU-Net
inference chain (1.5 mm resampling, crop, z-score, 0.8-step sliding window with Gaussian
blending, argmax; accumulation on the GPU via `Accumulate.metal`, which also holds the
morphology kernel). Checked against the Python pipeline on a whole-body Dixon scan: mean
Dice 0.992 over the 49 structures present and ≥ 0.98 on every tissue class (muscle and both
fat classes 0.999–1.000); about 80 s in all on an M1 Mac, ~1.7 GB peak. Needs a real device:
the simulator's CPU-only Core ML path allocates ~19 GB and dies. Models are regenerated with
`tools/convert_organ_model.py <out> organs|muscles` (TotalSegmentator weights, Python 3.11
with torch 2.7 + coremltools). The weights are under TotalSegmentator's non-commercial licence.

Launch arguments for simulator checks: `-plane 3D|Multi|Axial|Coronal|Sagittal`, `-clip
Axial,Sagittal,…` (comma-separated, up to six), `-clipTilt <degrees>`, `-clipCutaway YES`,
`-clipHighlight YES`, `-inspector YES`, `-segGhost YES`, `-segmentOrgans YES`.

## Files

| File | Role |
|---|---|
| `NiiMono/NiiMonoApp.swift` | `DocumentGroup` app, document type, viewer chrome. |
| `NiiMono/SliceView.swift` | Zoomable 2D slice view (UIScrollView + CPU-windowed CGImage). |
| `NiiMono/StepSlider.swift` | Slider that steps one unit on track taps. |
| `NiiMono/Segmentation.swift` | Label tables, overlay state, slice compositing and the inspector section. |
| `NiiMono/OrganSegmenter.swift`, `Accumulate.metal`, `Organs.mlpackage`, `Muscles.mlpackage` | On-device TotalSegmentator models and their inference chain. |
| `NiiMono/TissueClassifier.swift` | The 14 tissue classes from Dixon water/fat + structure labels (morphology on the GPU). |
| `NiiMono/Snapshot.swift` | Captures the visible panes to a PNG and presents the share sheet. |
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
