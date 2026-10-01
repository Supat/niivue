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

**Image role and companions.** The Image section says what the opened file is (Water / Fat /
Other, inferred from a `_W` / `_F` suffix) and holds the companion Dixon image(s) the tissue
classes need: the other one of the pair, found beside the scan or chosen by hand (both for
Other). The networks run on the water image when there is one.

**Sidecar.** Everything in the inspector — view, window, clip planes, segmentation
visibility and opacity, body-composition inputs, the image role, the companion images (as
bookmarks) and the segmentation maps themselves — is saved to `<scan>.niimono/`
(`settings.json`, `shown.nii.gz`, `kept.nii.gz`) beside the scan when that folder is
writable, else under the app's Application Support keyed by the scan's name, size and date.
Settings save 1.5 s after the last change, maps when they appear; opening the scan again
restores all of it, so a generated segmentation is never recomputed. The Sidecar section
shows where it lives and can delete it.

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
fat classes 0.999–1.000); about 70 s in all on an M1 Mac (29 + 29 s for the networks on the Neural Engine, 12 s for the tissue classes), ~1.7 GB peak. Needs a real device:
the simulator's CPU-only Core ML path allocates ~19 GB and dies. Models are regenerated with
`tools/convert_organ_model.py <out> organs|muscles` (TotalSegmentator weights, Python 3.11
with torch 2.7 + coremltools). The weights are under TotalSegmentator's non-commercial licence.

Launch arguments for simulator checks: `-plane 3D|Multi|Axial|Coronal|Sagittal`, `-clip
Axial,Sagittal,…` (comma-separated, up to six), `-clipTilt <degrees>`, `-clipCutaway YES`,
`-clipHighlight YES`, `-inspector YES`, `-segGhost YES`, `-segmentOrgans YES`.

## Files (MVVM)

| Folder | Contents |
|---|---|
| `NiiMono/App` | `NiiMonoApp` (DocumentGroup) and `MRIDocument`. |
| `NiiMono/Models` | `NIfTI` reader/writer + `NiftiVolume`/`LabelVolume`; `Sidecar` settings + `ImageRole`; `LabelTable` (tissue classes, total_mr names, densities); `SegmentationMap` + `SegmentationOverlay` and the slice compositing; `BodyCompositionEstimate`; viewer value types (`Plane`, `RenderMode`, `ClipSetting`, `ViewPreset`). |
| `NiiMono/ViewModels` | `ViewerViewModel` (plane, slices, window, clip planes, crosshair), `SegmentationViewModel` (shown/kept maps, visibility, loading, generation), `BodyCompositionViewModel` (subject inputs). |
| `NiiMono/Views` | `DocumentView`, `ViewerView` (canvas, toolbar, chrome), `InspectorView`, `SegmentationSection`, `BodyCompositionSection`, `SliceView` (UIScrollView), `RenderView` (MTKView host, gestures), `StepSlider`. |
| `NiiMono/Services` | `SidecarStore`; `SegmentationPipeline` (file loading, model runs, sibling discovery), `OrganSegmenter` (nnU-Net inference), `TissueClassifier`, `Snapshot`, `Accumulate.metal` (GPU accumulation, argmax, morphology). |
| `NiiMono/Rendering` | `VolumeRenderer` (Metal) and `Raycaster.metal`. |
| `NiiMono/Resources` | `Organs.mlpackage`, `Muscles.mlpackage`. |
| `Info.plist` | Document types (`.nii`, gzip) and document-browser keys. |
| `spike/nifti_check.swift` | Self-check for the reader: decode, scaling, reorientation, slice orientation, labels. |
| `tools/convert_organ_model.py` | Regenerates the Core ML models from the TotalSegmentator checkpoints. |

Run the reader check (Swift only allows top-level code in `main.swift`, hence the copy):

```sh
mkdir -p /tmp/ncheck && cp spike/nifti_check.swift /tmp/ncheck/main.swift
swiftc NiiMono/Models/NIfTI.swift /tmp/ncheck/main.swift -O -o /tmp/ncheck/ncheck && /tmp/ncheck/ncheck T1w_DEMO.nii.gz
```

## Conventions and limits

- Display is neurological (patient left on screen left), sagittal nose right — niivue's defaults.
- Oblique acquisitions snap to the nearest axes (no resampling).
- NIfTI-1 single-file, scalar datatypes, first volume of a 4D series. No meshes, DICOM,
  overlays, colormaps or drawing yet. The Volume render omits NiiVue's overlays and
  gradient lighting.
- Any `.gz` is openable in the browser (`.nii.gz` has no file type of its own);
  non-NIfTI files fail with an alert.
- Loading is vectorised (vDSP), so even Debug builds open a 64-million-voxel whole-body scan in about a second; the segmentation models and the tissue classifier are GPU/Neural Engine work and don't care much about the build configuration, but the remaining CPU passes (flood fills, hull) are several times slower in Debug.
