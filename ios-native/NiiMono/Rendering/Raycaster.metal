//
//  Raycaster.metal — volume raycaster: MIP and a port of niivue's default compositing
//  render, with clip planes. Hand-written MSL rather than transpiled niivue GLSL.
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 invViewProj; // clip -> world
    float3   camPos;      // world-space eye
    float3   boxHalf;     // half-extents of the volume box (anisotropy baked in)
    float4   clips[6];    // clip planes in box space: xyz = unit normal, w = offset;
                          // the kept region of each is dot(xyz, p) <= w
    float    dataMin;
    float    dataMax;
    int      steps;       // samples along the ray (MIP)
    int      mode;        // 0 = MIP, 1 = niivue-style compositing, 2 = solid lit surface at the Black level
    int      clipCount;   // number of active planes in `clips` (0...6)
    int      clipCutaway; // 0 = keep what is on the kept side of every plane;
                          // 1 = remove only the corner on the removed side of every plane
    int      clipHighlight; // 1 = draw each plane as a tinted sheet with an outline
    int      crosshairOn;   // 1 = draw axis lines through `crosshair`
    float3   crosshair;     // crosshair point in box space
    int      overlayOn;     // 1 = a label volume is bound at texture(2), its LUT at texture(3)
    float    overlayOpacity;
    int      overlayGhost;  // 1 = fade unlabelled tissue so labelled structures show through, 2 = labels alone
    float    cameraClip;    // rays start this far from the eye (0 = at the eye / box entry)
    int      fovCount;      // station FOV boxes at buffer(1): [lo, hi] pairs in box space
    float    crosshairStep; // box-space spacing of the crosshair's scale ticks (0 = none)
    int      cutoutOn;      // 1 = a noise mask is bound at texture(4): voxels marked in it are empty
    int      clipKeepLabels;// 1 = clipping removes unlabelled tissue only; visible segments stay whole
};

struct VSOut {
    float4 position [[position]];
    float2 ndc;
};

// Fullscreen triangle, no vertex buffer.
vertex VSOut vtx(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2); // (0,0),(2,0),(0,2)
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.ndc = p * 2.0 - 1.0;
    return o;
}

// Ray vs axis-aligned box centered at origin. Returns tNear,tFar (tNear<tFar => hit).
static float2 intersectBox(float3 ro, float3 rd, float3 halfExtent) {
    float3 inv = 1.0 / rd;
    float3 t0 = (-halfExtent - ro) * inv;
    float3 t1 = ( halfExtent - ro) * inv;
    float3 tmin = min(t0, t1), tmax = max(t0, t1);
    float n = max(max(tmin.x, tmin.y), tmin.z);
    float f = min(min(tmax.x, tmax.y), tmax.z);
    return float2(n, f);
}

// Colour of one ray through the volume. `hit` is the ray's [near, far] range in the box.
// `tSurface` receives the ray distance of the first tissue sample (1e20 if none).
static float4 shade(float4 fragPos, constant Uniforms& u, texture3d<float> vol,
                    texture1d<float> cmap, texture3d<uint> labels, texture1d<float> lut,
                    texture3d<uint> cutout,
                    sampler samp, float3 ro, float3 rd, float2 hit, thread float& tSurface) {
    // Removed noise: voxels marked in the cutout mask are treated as empty.
    float3 cdims = float3(cutout.get_width(), cutout.get_height(), cutout.get_depth());
    auto cutAt = [&](float3 uvw) -> bool {
        return u.cutoutOn != 0 && cutout.read(uint3(clamp(uvw, 0.0, 0.9999) * cdims)).r != 0;
    };
    // Label (0 = none/hidden) and its colour at a texture coordinate.
    float3 ldims = float3(labels.get_width(), labels.get_height(), labels.get_depth());
    auto labelAt = [&](float3 uvw) -> uint {
        if (u.overlayOn == 0) { return 0; }
        uint l = labels.read(uint3(clamp(uvw, 0.0, 0.9999) * ldims)).r;
        return lut.read(l).a > 0.0 ? l : 0;
    };
    // Clip planes. Normal mode trims the ray's [near, far] range to each plane's kept
    // half-space. Cutaway instead finds the stretch of the ray inside every plane's
    // removed half-space — (cut0, cut1), one interval since that region is convex — and
    // the marches below skip it.
    bool cutaway = u.clipCutaway != 0;
    // Keep visible segments: march the whole box and drop only unlabelled samples in the
    // removed region, so segments show whole inside the clipped-away part.
    bool keep = u.clipKeepLabels != 0 && u.overlayOn != 0;
    float2 full = hit;
    bool rayRemoved = false; // keep: a plane parallel to the ray removes all of it
    float cut0 = -1e20, cut1 = 1e20;
    int enabledClips = 0;
    // Surface render: the normal of the face the ray enters tissue through when that is a
    // clip plane (else the box face or the camera clip, set below), and of the plane that
    // ends the cutaway; a cut face is lit as that plane rather than by the tissue gradient.
    float3 entryNormal = float3(0.0), cutNormal = float3(0.0);
    for (int i = 0; i < u.clipCount; ++i) {
        if (all(u.clips[i].xyz == float3(0.0))) { continue; } // plane switched off: keeps its slot (and colour)
        enabledClips += 1;
        float o = dot(u.clips[i].xyz, ro), d = dot(u.clips[i].xyz, rd);
        if (abs(d) < 1e-6) { // ray parallel to the plane: entirely kept or entirely removed
            if (cutaway) { if (o <= u.clips[i].w) { cut1 = -1e20; } }
            else if (o > u.clips[i].w) { if (keep) { rayRemoved = true; } else { return float4(0, 0, 0, 1); } }
        } else {
            float t = (u.clips[i].w - o) / d; // removed side is beyond t when d > 0
            if (cutaway) { if (d > 0.0) { cut0 = max(cut0, t); } else if (t < cut1) { cut1 = t; cutNormal = u.clips[i].xyz; } }
            else { if (d > 0.0) { hit.y = min(hit.y, t); } else if (t > hit.x) { hit.x = t; entryNormal = u.clips[i].xyz; } }
        }
    }
    if (!cutaway || enabledClips == 0) { cut1 = -1e20; } // empty interval: nothing skipped
    float2 kept = hit;
    if (keep) { hit = full; }
    auto clippedAt = [&](float t) -> bool {
        return rayRemoved || t < kept.x || t > kept.y || (t > cut0 && t < cut1);
    };
    if (hit.x > hit.y || hit.y < 0.0) { return float4(0, 0, 0, 1); } // miss
    // Camera clip: nothing nearer than cameraClip is drawn, so zooming into the volume
    // looks inside instead of at the tissue pressed against the lens.
    float tIn = max(hit.x, u.cameraClip);
    if (tIn >= hit.y) { return float4(0, 0, 0, 1); }
    float window = max(u.dataMax - u.dataMin, 1e-6);

    // One sample per voxel along the ray, for the compositing and surface renders.
    float3 dims = float3(vol.get_width(), vol.get_height(), vol.get_depth());
    float3 uvw0 = (ro + rd * tIn) / (2.0 * u.boxHalf) + 0.5;
    float3 uvw1 = (ro + rd * hit.y) / (2.0 * u.boxHalf) + 0.5;
    float lenVox = length((uvw1 - uvw0) * dims);
    float3 stepUVW = (uvw1 - uvw0) / max(lenVox, 1e-6);
    float tStep = (hit.y - tIn) / max(lenVox, 1e-6); // ray distance per voxel step
    float skip0 = (cut0 - tIn) / tStep, skip1 = (cut1 - tIn) / tStep;
    // At most 1024 samples a ray: a whole-body scan's diagonal is 1000-2000 voxels, and a
    // frame of such rays (every ray that misses the body marches the whole box) can outlast
    // the GPU watchdog, which kills the frame and the ones queued behind it. Longer rays
    // take a longer stride; the compositing corrects its opacity for it.
    float stride = max(1.0, lenVox / 1024.0);

    if (u.mode == 2) {
        // Solid surface: the first sample above the Black level, whatever its intensity, is
        // an opaque surface (the skin, or a cut face), lit from the intensity gradient there —
        // an isosurface at the window's lower bound. Labels keep their colour on it.
        if (lenVox < 0.5) { return float4(0, 0, 0, 1); }
        if (tIn > hit.x) { entryNormal = -rd; } // the camera clip: a face square to the view
        else if (all(entryNormal == float3(0.0))) { // the box face the ray comes in through
            float3 pe = (ro + rd * hit.x) / u.boxHalf, ae = abs(pe);
            entryNormal = ae.x > ae.y && ae.x > ae.z ? float3(sign(pe.x), 0.0, 0.0)
                        : ae.y > ae.z ? float3(0.0, sign(pe.y), 0.0) : float3(0.0, 0.0, sign(pe.z));
        }
        bool ghostly = u.overlayGhost == 1 && u.overlayOn != 0; // see through unlabelled tissue to the labels
        bool labelsOnly = u.overlayGhost == 2 && u.overlayOn != 0;
        auto solidAt = [&](float3 uvw, float t, thread uint& lab) -> bool {
            if (cutAt(uvw)) { return false; }
            lab = labelAt(uvw);
            if (lab != 0) { return true; }
            if (labelsOnly || (keep && clippedAt(t))) { return false; }
            return vol.sample(samp, uvw, level(0)).r > u.dataMin;
        };
        auto lit = [&](float3 base, float3 nrm) -> float3 {
            float3 L = normalize(-rd + float3(0.0, 0.0, 0.6)); // a headlight, a little from above
            float diff = max(dot(nrm, L), 0.0);
            float spec = pow(max(dot(reflect(-L, nrm), -rd), 0.0), 16.0);
            return base * (0.25 + 0.7 * diff) + 0.08 * spec;
        };
        float3 faceN = entryNormal; // non-zero until the ray has passed an empty sample
        float sPrev = -1.0;         // the last sample known empty, for the refinement
        float3 ghost = float3(0.0); bool ghosted = false;
        for (float s = 0.0; s <= lenVox; s += stride) {
            if (!keep && s > skip0 && s < skip1) { s = skip1; faceN = cutNormal; sPrev = -1.0; if (s > lenVox) { break; } }
            float t = tIn + s * tStep;
            float3 uvw = uvw0 + stepUVW * s;
            uint lab = 0;
            if (!solidAt(uvw, t, lab)) { faceN = float3(0.0); sPrev = s; continue; }
            // Refine between the last empty sample and this one (four bisections), so the
            // surface doesn't show whole-voxel steps.
            float sHit = s;
            if (sPrev >= 0.0) {
                float a = sPrev, b = s;
                for (int k = 0; k < 4; ++k) {
                    float m = 0.5 * (a + b); uint l2 = 0;
                    if (solidAt(uvw0 + stepUVW * m, tIn + m * tStep, l2)) { b = m; } else { a = m; }
                }
                sHit = b; uvw = uvw0 + stepUVW * sHit;
            }
            // Normal: a cut face keeps its plane's; tissue takes the intensity gradient,
            // facing the camera. Central differences 1, 2 and 3 voxels either side, summed:
            // the derivative of a tent-shaped kernel, so the normal varies smoothly where a
            // one-voxel difference (or a box-filtered mip level) rings the skin with contour
            // lines. Scaled per axis to box units so anisotropic voxels don't skew it.
            float3 nrm = faceN;
            if (all(nrm == float3(0.0))) {
                float3 g = float3(0.0);
                for (int k = 1; k <= 3; ++k) {
                    float3 e = float(k) / dims;
                    g += float3(vol.sample(samp, uvw + float3(e.x, 0, 0), level(0)).r - vol.sample(samp, uvw - float3(e.x, 0, 0), level(0)).r,
                                vol.sample(samp, uvw + float3(0, e.y, 0), level(0)).r - vol.sample(samp, uvw - float3(0, e.y, 0), level(0)).r,
                                vol.sample(samp, uvw + float3(0, 0, e.z), level(0)).r - vol.sample(samp, uvw - float3(0, 0, e.z), level(0)).r)
                         / (2.0 * e * 2.0 * u.boxHalf);
                }
                nrm = dot(g, g) > 1e-12 ? normalize(-g) : -rd;
            }
            if (dot(nrm, rd) > 0.0) { nrm = -nrm; }
            float3 base = float3(0.82);
            if (lab != 0) { base = mix(base, lut.read(lab).rgb, u.overlayOpacity); }
            float3 col = lit(base, nrm);
            tSurface = min(tSurface, tIn + sHit * tStep);
            if (lab == 0 && ghostly) { // keep the skin faintly and go on to the labels
                if (!ghosted) { ghost = col; ghosted = true; }
                faceN = float3(0.0); sPrev = -1.0;
                continue;
            }
            return float4(ghosted ? mix(col, ghost, 0.3) : col, 1.0);
        }
        return float4(ghosted ? ghost * 0.3 : float3(0.0), 1.0);
    }

    if (u.mode == 1) {
        // Port of niivue's default volume render (fragRenderShader in shader-srcs.ts):
        // front-to-back alpha compositing, one sample per voxel, jittered start, early
        // termination at 0.95. Colour and opacity follow niivue's "gray" colormap:
        // grey = windowed intensity, alpha ramps 0 → 128/255, below-window is transparent.
        // ponytail: classifies the interpolated intensity per sample; niivue interpolates a
        // pre-classified RGBA texture. No clip planes, overlays or gradient lighting —
        // port those from kRenderInit/kRenderTail/fragRenderGradientShader when needed.
        if (lenVox < 0.5) { return float4(0, 0, 0, 1); }
        const float earlyTermination = 0.95;
        float4 acc = float4(0.0);
        float s = fract(sin(fragPos.x * 12.9898 + fragPos.y * 78.233) * 43758.5453);
        for (; s <= lenVox; s += stride) {
            // Jump over the cutaway. Assign rather than step back and `continue`: float
            // rounding could land just short of skip1 and repeat the jump forever.
            if (!keep && s > skip0 && s < skip1) { s = skip1; if (s > lenVox) { break; } }
            float3 uvw = uvw0 + stepUVW * s;
            if (cutAt(uvw)) { continue; }
            float v = vol.sample(samp, uvw, level(0)).r;
            uint lab = labelAt(uvw);
            if (keep && lab == 0 && clippedAt(tIn + s * tStep)) { continue; }
            if (v <= u.dataMin && lab == 0) { continue; }
            float txl = clamp((v - u.dataMin) / window, 2.0 / 256.0, 1.0);
            float a = txl * (128.0 / 255.0);
            float3 rgb = float3(txl);
            if (lab != 0) {
                // Labelled voxel: blend in its colour, and give dark structures (lungs,
                // bone) enough opacity to show at all.
                rgb = mix(rgb, lut.read(lab).rgb, u.overlayOpacity);
                a = max(a, 0.4 * u.overlayOpacity);
            } else if (u.overlayGhost != 0 && u.overlayOn != 0) {
                a *= u.overlayGhost == 2 ? 0.0 : 0.08;
            }
            if (stride > 1.0) { a = 1.0 - pow(1.0 - a, stride); } // the opacity of `stride` voxels
            if (a < 0.01) { continue; }
            tSurface = min(tSurface, tIn + s * tStep);
            acc += (1.0 - acc.a) * float4(rgb * a, a);
            if (acc.a > earlyTermination) { break; }
        }
        return float4(acc.rgb / earlyTermination, 1.0);
    }

    float dt = (hit.y - tIn) / float(u.steps);
    float maxV = 0.0;
    uint maxLab = 0;
    for (int i = 0; i < u.steps; ++i) {
        float t = tIn + dt * float(i);
        if (!keep && t > cut0 && t < cut1) { continue; }
        float3 pos = ro + rd * t;
        float3 uvw = pos / (2.0 * u.boxHalf) + 0.5;       // [-half,half] -> [0,1]
        if (cutAt(uvw)) { continue; }
        float v = vol.sample(samp, uvw, level(0)).r;
        uint lab = labelAt(uvw);
        if (keep && lab == 0 && clippedAt(t)) { continue; }
        if (u.overlayGhost != 0 && u.overlayOn != 0 && lab == 0) { continue; } // labelled tissue only
        if (v > u.dataMin) { tSurface = min(tSurface, t); }
        if (v > maxV) { maxV = v; maxLab = lab; }          // MIP, remembering the label there
    }

    float norm = clamp((maxV - u.dataMin) / window, 0.0, 1.0);
    // Sample texel centres: the sampler is clamp-to-zero (for the volume), so u = 1.0
    // would blend the last LUT entry with the black border and turn saturated voxels grey.
    float3 rgb = cmap.sample(samp, (norm * 255.0 + 0.5) / 256.0).rgb;
    if (maxLab != 0) { rgb = mix(rgb, lut.read(maxLab).rgb, u.overlayOpacity); }
    return float4(rgb, 1.0);
}

// One colour per clip plane; ClipSetting.colors in VolumeRenderer.swift mirrors these.
constant float3 kClipColors[6] = {
    float3(1.00, 0.27, 0.23), float3(0.20, 0.78, 0.35), float3(0.04, 0.52, 1.00),
    float3(1.00, 0.80, 0.00), float3(0.75, 0.35, 0.95), float3(0.39, 0.82, 1.00),
};

// Station FOV colour per session; mirrors FOVSession.colors.
constant float3 kFOVColors[6] = {
    float3(1.00, 0.84, 0.00), float3(0.20, 0.85, 1.00), float3(1.00, 0.40, 0.85),
    float3(0.45, 0.95, 0.35), float3(1.00, 0.55, 0.15), float3(0.70, 0.55, 1.00),
};

fragment float4 frag(VSOut in [[stage_in]],
                     constant Uniforms& u   [[buffer(0)]],
                     constant float4 *fov    [[buffer(1)]],
                     texture3d<float> vol    [[texture(0)]],
                     texture1d<float> cmap   [[texture(1)]],
                     texture3d<uint> labels  [[texture(2)]],
                     texture1d<float> lut    [[texture(3)]],
                     texture3d<uint> cutout  [[texture(4)]],
                     sampler samp            [[sampler(0)]]) {
    // Reconstruct a world-space ray through this pixel.
    float4 nearH = u.invViewProj * float4(in.ndc, 0.0, 1.0);
    float4 farH  = u.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 nearW = nearH.xyz / nearH.w;
    float3 farW  = farH.xyz  / farH.w;
    float3 ro = u.camPos;
    float3 rd = normalize(farW - nearW);

    float2 box = intersectBox(ro, rd, u.boxHalf);
    if (box.x > box.y || box.y < 0.0) { return float4(0, 0, 0, 1); } // ray misses the volume
    float tSurface = 1e20;
    float4 color = shade(in.position, u, vol, cmap, labels, lut, cutout, samp, ro, rd, box, tSurface);

    if (u.clipHighlight != 0) {
        // Plane highlight: wherever the ray crosses a clip plane inside the volume box,
        // tint the pixel with that plane's colour; near the box faces draw it solid, which
        // outlines the plane. ponytail: drawn on top of the render (not depth-tested
        // against tissue) so a plane stays visible even where it is buried.
        for (int i = 0; i < u.clipCount; ++i) {
            float d = dot(u.clips[i].xyz, rd);
            if (abs(d) < 1e-6) { continue; } // also skips switched-off planes (zero normal)
            float t = (u.clips[i].w - dot(u.clips[i].xyz, ro)) / d;
            if (t <= max(box.x, 0.0) || t >= box.y) { continue; }
            float3 toFace = u.boxHalf - abs(ro + rd * t);
            float edge = min(toFace.x, min(toFace.y, toFace.z));
            color.rgb = mix(color.rgb, kClipColors[i], edge < 0.006 ? 0.9 : 0.16);
        }
    }
    // Station FOVs: wireframes of each box's 12 edges in their session's colour, drawn on top like the plane
    // highlight with the crosshair's line test and width; edges behind the tissue surface
    // are fainter.
    for (int i = 0; i < u.fovCount; ++i) {
        float3 lo = fov[2 * i].xyz, hi = fov[2 * i + 1].xyz;
        float3 tint = kFOVColors[int(fov[2 * i].w) % 6];
        for (int a = 0; a < 3; ++a) {
            float3 e = float3(a == 0, a == 1, a == 2);
            float3 n = cross(rd, e);
            float nn = dot(n, n);
            if (nn < 1e-8) { continue; }
            for (int k = 0; k < 4; ++k) {
                // Edge along axis a at the (lo|hi, lo|hi) corners of the other two axes.
                float3 p0 = lo;
                p0[(a + 1) % 3] = (k & 1) ? hi[(a + 1) % 3] : lo[(a + 1) % 3];
                p0[(a + 2) % 3] = (k & 2) ? hi[(a + 2) % 3] : lo[(a + 2) % 3];
                float3 w = p0 - ro;
                float t = dot(cross(w, e), n) / nn;
                float s = dot(cross(w, rd), n) / nn + p0[a]; // position along the edge
                if (t <= 0.0 || s < lo[a] || s > hi[a]) { continue; }
                float dist = abs(dot(w, n)) / sqrt(nn), thick = 0.0015 * t;
                float alpha = (t > tSurface ? 0.3 : 0.85) * (1.0 - smoothstep(0.5 * thick, thick, dist));
                color.rgb = mix(color.rgb, tint, alpha);
            }
        }
    }
    if (u.crosshairOn != 0) {
        // Crosshair: three axis-aligned lines through the point, clipped to the box, drawn
        // on top like the plane highlight: red where the line is in front of the tissue
        // surface, green where it runs behind it (inside the body). Thickness grows with
        // distance so it stays about one pixel wide on screen.
        const float3 red = float3(1.0, 0.25, 0.2), green = float3(0.3, 0.9, 0.4);
        float3 w = u.crosshair - ro;
        for (int a = 0; a < 3; ++a) {
            float3 e = float3(a == 0, a == 1, a == 2);
            float3 n = cross(rd, e);
            float nn = dot(n, n);
            if (nn < 1e-8) { continue; }                     // ray parallel to this line
            float t = dot(cross(w, e), n) / nn;              // closest approach along the ray
            float s = dot(cross(w, rd), n) / nn;             // ... and along the line
            float3 q = u.crosshair + e * s;
            if (t <= 0.0 || any(abs(q) > u.boxHalf + 1e-4)) { continue; }
            float dist = abs(dot(w, n)) / sqrt(nn), thick = 0.0015 * t;
            // Scale ticks every crosshairStep out from the point: short, wider bands.
            float reach = thick, strength = 0.45;
            if (u.crosshairStep > 0.0) {
                float k = round(s / u.crosshairStep);
                if (k != 0.0 && abs(s - k * u.crosshairStep) < 1.2 * thick) { reach = 6.0 * thick; strength = 0.8; }
            }
            float3 tint = t > tSurface ? green : red;
            color.rgb = mix(color.rgb, tint, strength * (1.0 - smoothstep(0.5 * reach, reach, dist)));
        }
    }
    return color;
}
