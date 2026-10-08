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
| Toolbar | 3D / Multi / Axial / Coronal / Sagittal, Mirror (slices), view presets (3D), Snapshot (PNG of the canvas at screen resolution → share sheet, including Save Image to Photos), Share, Inspector. The view selector stays at the window's horizontal centre; the button cluster keeps the bar's trailing end, over the inspector column when that is open; when the space right of the selector can't hold every button (a narrow window), everything but Inspector folds into a More menu |
| Slider track | A tap either side of the knob nudges the value one unit |
| 3D: drag | Orbit |
| 3D: two-finger drag, or secondary-button drag | Pan |
| 3D: pinch, or scroll | Zoom towards the fingers / pointer |
| 3D: double-tap | Reset to the fitted starting view |
| 3D Rendering › Clip at Camera | Nothing nearer the camera than a chosen fraction of the way to the orbit pivot is drawn, so zooming into the volume shows its inside |
| Multi: tap a slice pane | Move the crosshair (and the other two slices) to that point |

Slice views show L/R, A/P, S/I edge labels; the 3D view shows a rotating orientation
indicator. Multi shows coronal, sagittal, axial and 3D in a 2×2 grid at one shared
scale and zoom, linked by a crosshair drawn in all four panes. The inspector holds window level (Black/White), the 3D rendering mode
(MIP; Volume — a port of NiiVue's default compositing shader; or Surface — everything above
the Black level drawn as one opaque, lit surface whatever its intensity: an isosurface at the
window's lower bound, the hit refined by bisection and shaded from a smoothed intensity
gradient — central differences 1, 2 and 3 voxels apart summed, since a one-voxel or box-filtered
gradient rings the skin with contour lines — with clip-plane cut faces lit as their plane; labels keep their colour on it, and the
segmentation's show-through modes see through the skin to the labels), up to six tiltable
3D clip planes with cutaway and highlight options, and volume info.

**Clipping around segments.** Inspector › 3D › "Keep Visible Segments" makes the clip planes
(and the cutaway) remove unlabelled tissue only: voxels of the visible segments are drawn whole
inside the clipped-away region, so an organ stays complete while the body around it is opened.
Hidden labels are clipped like the rest. The ray then marches the whole box and drops only the
unlabelled samples in the removed region (`clipKeepLabels` in Raycaster.metal). Saved in the
sidecar; `-clipKeepSegments YES` for checks.

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
assuming the missing limbs share the imaged composition. A tap on the class list switches its
masses between kg and percent of the subject's weight.

**Image role and companions.** The Image section says what the opened file is (Water / Fat /
Other, inferred from a `_W` / `_F` suffix) and holds the companion Dixon image(s) the tissue
classes need: the other one of the pair, found beside the scan or chosen by hand (both for
Other). The networks run on the water image when there is one.

**Sidecar.** Everything in the inspector — view, window, clip planes, segmentation
visibility and opacity, body-composition inputs, the image role, the companion images (as
bookmarks) and the segmentation maps themselves — is saved to `<scan>.niimono/`
(`settings.json`, `shown.nii.gz`, `kept.nii.gz`, `kept2.nii.gz`, `profile-<view>.jpg`, and
`drawing.nii.gz` + `drawing.prev.nii.gz`, the drawing as an export with its label names) beside
the scan when that folder is writable, else under the app's Application Support keyed by the
scan's name and size. Settings save 1.5 s after the last change, maps when they appear;
opening the scan again restores all of it, so a generated segmentation is never recomputed.
The Sidecar section shows where it lives and can delete it. Safeguards, after a drawing was
lost: nothing is saved while the sidecar is being read back (a half-restored state once wrote
settings without the map names); a map that can't be read back stops all saving, with a
warning and "Save Anyway", instead of being dropped and its file deleted; a drawing whose slot
is unreadable comes back from `drawing.nii.gz`; evicted iCloud files are downloaded first; map
saves run one at a time; and a scan whose key changed (keys used to include the file date,
which iCloud can change under an open document) finds its earlier sidecar by name, preferring
the one with the most saved maps.

**Profile.** The inspector's Profile section holds six photos of the subject: axial top and
bottom, coronal front and back, sagittal left and right, picked from the photo library (no library permission is
needed: the system picker runs out of process) or from Files; a green check mark after the
view's name means a person was detected in its photo (Vision's human detector). Each is stored upright, at most 2048 px on
its longest side, as a JPEG in the sidecar. A tap on a row's name shows or hides its preview.

**Side by side.** In landscape, a slice view can show its profile photo beside it (the toolbar
button before Snapshot; enabled once that photo exists): Axial ↔ Axial Top, Coronal ↔ Coronal
Back, Sagittal ↔ Sagittal Right, and with Mirror on Axial Bottom, Coronal Front, Sagittal Left.
The photo is placed so the same anatomy sits at the same spot in both panes and follows the
slice's zoom and pan (`ProfileAlignment.swift`): shoulder and hip joints are matched when the
scan has segmented bones (the tops of the humeri and femora in a `total_mr` map) and Vision
finds the body pose in the photo; failing that, the body outlines' width and centre; failing
that, the photo is fitted to the slice. Axial slices only ever use the outline. A tap on the
photo drops a marker there and at the matching position on the slice. Snapshot captures
both panes.

**Show Profile.** In the 3D and Multi views the same toolbar slot holds Show Profile, which
puts an ID-photo crop of the subject's face (35 × 45, from the Coronal Front photo) in the top
left corner of the render. It is enabled once that photo exists and Vision finds a face in it.

**Launch screen.** The screen in front of the document browser offers "Open <last scan>",
a one-tap return to the last file opened (a security-scoped bookmark; the file is handed to
the document browser's delegate, as if it had been picked there — the system refuses file
URLs passed to `UIApplication.open` on a device). The browser itself is the system's and runs
out of process on iPadOS 26, so its folder can't be steered from the app.

**Files locations.** Scans kept in *On My iPad › NiiMono* or *iCloud Drive › NiiMono* (the
app's own containers; the iCloud one comes from the CloudDocuments entitlement in
`NiiMono.entitlements` + `NSUbiquitousContainers` in Info.plist) get their sidecar written
right beside them; files picked from anywhere else are reachable only individually, so
their sidecars go to the fallback location.

**Masking.** "Mask to Visible Segments" (Segmentation section) turns the visible labels
into a mask: only the scan inside them is shown, without the label colours (slices are black
outside, the 3D render draws only the labelled tissue), so hiding a label cuts it out too. Saved in
the sidecar; `-segMask YES` for checks.

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

**Noise removal.** Inspector › Image › Noise Removal › "Remove Noise…" opens the
segmentation editor with one fixed "Noise" label: paint over stray signal and artifacts with
the same tools (brush, eraser, fill, smoothing, undo, Pencil). The slice panes show the paint;
the 3D pane already renders the scan with it cut out. After Done, the marked voxels are black
on every slice and left out of the 3D render (a second r8Uint mask texture the raycaster skips),
"Remove Marked Noise" toggles it, and "Clear Noise Mask" drops it. The scan's data is not
changed (no second copy in memory, and erasing the mask brings voxels back); the mask is saved
in the sidecar as `noise.nii.gz`. Generate Segmentation runs the networks on a copy with the
noise set to background and clears noise voxels from both generated maps (the tissue classes
run on the original water/fat images and are cleared after, avoiding two more 250 MB copies).
"Export Cleaned Scan…" writes `<scan>_clean.nii.gz`: float32 on the scan's own grid and
orientation under a copy of its header (embedded metadata kept), noise set to the scan's
minimum (`spike/clean_export_check.swift` round-trips it). "Export Noise Mask…" shares the
mask itself as `<scan>_noise.nii.gz` (uint8 on the scan's grid and orientation, tagged
`{"niimono":"noise"}` in a header extension), so the same voxels can be marked on another
image of the acquisition — the Dixon water, fat, in-phase and opposed-phase images share
the grid — by opening that image and choosing "Import Noise Mask…"; any mask NIfTI on the
scan's grid imports, every nonzero voxel counting as noise, replacing the mask in place
(`CleanupMaskFile.swift`; `spike/mask_file_check.swift` round-trips both kinds).

**Scan repair (banding and blemishes).** Inspector › Image › Scan Repair › "Repair Scan…"
opens the editor with three fixed paints, Blemish selected, on the slice view in use (coronal
from 3D or Multi). *Band* (coronal view first, where a band between
stitched stations runs across): every painted voxel gets a value interpolated along z
(head–foot) between the nearest unpainted voxels above and below it in its column. *Blemish*
(a streak or spot inside tissue): the painted voxels are filled in from the unpainted voxels
around them within the slice they were painted on — Laplace's equation solved over the paint
with the surroundings fixed (Gauss–Seidel with over-relaxation), so a streak in a smooth
region comes out as that region's own gradient. In-plane rather than 3D because the slices
either side often carry the same streak and a 3D fill would feed it back in; a streak that
shows on several slices is painted on each (the mask records the plane: 2 sagittal,
3 coronal, 4 axial). *Cut* (value 5): the painted voxels go to the scan's background, what
Remove Noise does but written into the repaired scan. The ± menu next to the paints repeats
each stroke on that many slices either side (its in-plane shape, same paint, one undo step),
for a streak that runs through several slices. Both repair live: after every stroke (and fill, erase, undo, smoothing)
the columns it touched are filled in again and blemish paint within 8 voxels re-solved, voxels
no longer painted getting their original values back, so the slice panes and the 3D pane show
the repair as it is painted (~0.1 s a stroke in Debug); a note under the top bar says what
each stroke changed. Done keeps it, Cancel drops it. Unlike noise removal this changes
intensities, so the viewer holds a repaired copy of the scan (one 250 MB copy while it is
made) used everywhere — slices, 3D (only the touched z slices are re-uploaded), Generate
Segmentation, the cleaned-scan export — and keeps the original values of the replaced voxels,
so "Edit Scan Repair…" and "Undo Scan Repair" put them back first. The mask (1 = band,
2–4 = blemish by plane) is saved in the sidecar as `repair.nii.gz` and re-applied on opening
(`ScanRepair.repaired`; `spike/scan_repair_check.swift`); the scan file isn't written.
"Export Scan Repair…" shares that mask as `<scan>_repair.nii.gz` (uint8 on the scan's grid
and orientation, tagged `{"niimono":"repair"}`), and "Import Scan Repair…" on another image
of the acquisition (the Dixon variants share the grid) replaces the repair there with it and
applies it: paint values 1–5 are kept, other nonzero values dropped (the status line says how
many), and a file our export tagged as a noise mask is refused rather than taken as band.
"Export Cleaned Scan…" (its own section once either exists) writes noise removed and repairs
applied.

**In-phase and opposed-phase images.** Inspector › Segmentation › Image can add the scan's
Dixon in-phase (`<tag>_in`) and opposed-phase (`<tag>_opp`) images ("Add" when they lie beside
the scan, else "Choose…"); their dark rims at water–fat boundaries show cavities clearly.
They load only when added (each is the scan's size in memory), are kept in the sidecar, and
"Remove" frees them.

**Drawing a segmentation.** Inspector › Segmentation › "Draw Segmentation…" opens the
editor full screen: the drawing slice on the right, and on the left a reference slice (tap it
to move the drawing slice; the plane menu and ⇄ swap the two panes) above the 3D render of the
labels (the eye button hides the scan so the labels stand alone). The image picker in the top bar switches both slice panes between the scan and any
loaded companion (water, fat, in-phase, opposed-phase), each with its own levels; the 3D pane
stays on the scan. Apple Pencil paints with
the brush, erases, or flood-fills a closed outline on the slice in view; fingers pan, zoom
and scrub, unless "Draw with Finger" is on. The brush size is in millimetres, so it holds
across zoom and anisotropic voxels. Labels are picked, named, coloured and reordered (drag handles; the inspector lists a
drawing's labels in that order) in the label list that opens from the label chip; a label locked there (padlock) can't be drawn over,
erased, filled or smoothed by anything until unlocked (the lock is saved with the label); undo
and redo work per stroke (⌘Z / ⇧⌘Z, 50 steps). The wand smooths the surface of the label being edited in 3D (other labels are untouched,
and it only grows into unlabelled voxels) (tap:
σ 2 mm; hold for light 1 mm or strong 3.5 mm): the label's mask is Gaussian-blurred (σ in mm
per axis, so anisotropic voxels are handled) and kept where it is above one half, which removes
the steps between drawn slices, bumps and pinholes, and also anything thinner than about σ (a
lone painted slice). Once a label has been smoothed, the wand smooths only what was edited since: strokes,
fills and undo record the 4³-voxel bricks where the label's voxels actually changed, and
smoothing writes only there plus a brick around (covering the kernel radius) so new edges
blend in; everything else keeps its earlier smoothing. "Whole Label" in its menu smooths all
of it again. The bookkeeping (smoothed, edited bricks) is kept with the label names in the
sidecar. One undo step; vDSP throughout, ~1 s for a whole-body grid even in Debug. "Done" shows the drawing as the segmentation
("Custom drawing", alongside any generated or loaded maps in the Show picker; "Remove
Segmentation" removes only the map on screen; Generate Segmentation and Load Segmentation…
stay on offer while only the drawing is loaded, and the new map joins it) and the sidecar
saves it with its label names; "Edit Drawing…" reopens it. "Copy Labels to Drawing…" adds labels of the generated (or loaded)
map on screen to the drawing: a sheet lists them, ticked as they are visible; a copied label
joins a drawn label of the same name (so copying it again adds to it), the rest become new
labels with their names and colours, and voxels already drawn keep their label. The editor
then opens on the result. "Export…" shares the drawing as
`<scan>_drawing.nii.gz`: a uint8 label NIfTI on the scan's own grid and orientation (its voxels
back in the file's index order under a copy of the scan's header, so ITK-SNAP, 3D Slicer or
FSLeyes overlay it on the original scan), with the label names and colours as JSON in a header
extension. "Import…" takes any label map on the scan's grid as the drawing, reading the names
back from our own exports and naming other labels "Label n". Strokes change the label grid in
place (`LabelGrid`) and are published ~30 times a second: the slice panes recomposite and the
3D render re-uploads only the z slices touched.

Launch arguments for simulator checks: `-plane 3D|Multi|Axial|Coronal|Sagittal`, `-clip
Axial,Sagittal,…` (comma-separated, up to six), `-clipTilt <degrees>`, `-clipCutaway YES`,
`-clipHighlight YES`, `-inspector YES`, `-segGhost YES`, `-segmentOrgans YES`, `-openLast YES` (the launch screen opens
the last scan by itself), `-sideBySide YES`, `-showProfile YES`, `-openEditor YES` (opens the segmentation editor), `-openRepair YES` (the scan repair editor).

## Files (MVVM)

| Folder | Contents |
|---|---|
| `NiiMono/App` | `NiiMonoApp` (DocumentGroup) and `MRIDocument`. |
| `NiiMono/Models` | `NIfTI` reader/writer + `NiftiVolume`/`LabelVolume`; `Sidecar` settings + `ImageRole`; `LabelTable` (tissue classes, total_mr names, densities); `SegmentationMap` + `SegmentationOverlay` + `LabelGrid` and the slice compositing; `LabelPainter` (brush, line, fill on a slice); `BodyCompositionEstimate`; viewer value types (`Plane`, `RenderMode`, `ClipSetting`, `ViewPreset`). |
| `NiiMono/ViewModels` | `ViewerViewModel` (plane, slices, window, clip planes, crosshair), `SegmentationViewModel` (shown/kept maps, visibility, loading, generation), `BodyCompositionViewModel` (subject inputs), `DrawingViewModel` (segmentation editor: labels, tools, undo). |
| `NiiMono/Views` | `DocumentView`, `ViewerView` (canvas, toolbar, chrome), `InspectorView`, `SegmentationSection`, `SegmentationEditor`, `BodyCompositionSection`, `SliceView` (UIScrollView), `RenderView` (MTKView host, gestures), `StepSlider`. |
| `NiiMono/Services` | `SidecarStore`; `CustomSegmentationFile` (drawing import/export); `CleanupMaskFile` (noise mask and scan repair import/export); `ProfileAlignment` (scan and photo landmarks, photo placement); `SegmentationPipeline` (file loading, model runs, sibling discovery), `OrganSegmenter` (nnU-Net inference), `TissueClassifier`, `Snapshot`, `Accumulate.metal` (GPU accumulation, argmax, morphology). |
| `NiiMono/Rendering` | `VolumeRenderer` (Metal) and `Raycaster.metal`. |
| `NiiMono/Resources` | `Organs.mlpackage`, `Muscles.mlpackage`. |
| `Info.plist`, `NiiMono.entitlements` | Document types (`.nii`, gzip), the iCloud Drive container, iCloud Documents entitlements. |
| `spike/nifti_check.swift` | Self-check for the reader: decode, scaling, reorientation, slice orientation, labels. |
| `spike/label_export_check.swift` | Round trip of the drawing export on real scans (permuted and flipped orientations): same labels back, scan affine kept, JSON extension intact. |
| `spike/label_painter_check.swift` | Self-check for the drawing tools: slice addressing, brush, gap-free lines, fill, undo round trip (build line in its header). |
| `spike/mask_file_check.swift` | Round trip of the noise mask and scan repair exports on real scans: same voxels back, repair paint kept and other values dropped, a mask of the other kind refused, an empty one refused. |
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
