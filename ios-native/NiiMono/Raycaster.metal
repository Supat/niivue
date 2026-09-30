//
//  Raycaster.metal — minimal MIP volume raycaster.
//  Proves the GPU half: a 3D NIfTI texture ray-marched in Metal, colour-mapped.
//  This is hand-written rather than transpiled from niivue's GLSL on purpose —
//  the spike answers "can Metal raycast our data", not "does niivue's shader run".
//  The niivue GLSL (8 programs) is what you'd run through SPIRV-Cross next.
//

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 invViewProj; // clip -> world
    float3   camPos;      // world-space eye
    float3   boxHalf;     // half-extents of the volume box (anisotropy baked in)
    float4   clips[3];    // clip planes in box space: xyz = unit normal, w = offset;
                          // the kept region of each is dot(xyz, p) <= w
    float    dataMin;
    float    dataMax;
    int      steps;       // samples along the ray (MIP)
    int      mode;        // 0 = MIP, 1 = niivue-style compositing
    int      clipCount;   // number of active planes in `clips` (0...3)
    int      clipCutaway; // 0 = keep what is on the kept side of every plane;
                          // 1 = remove only the corner on the removed side of every plane
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

fragment float4 frag(VSOut in [[stage_in]],
                     constant Uniforms& u   [[buffer(0)]],
                     texture3d<float> vol    [[texture(0)]],
                     texture1d<float> cmap   [[texture(1)]],
                     sampler samp            [[sampler(0)]]) {
    // Reconstruct a world-space ray through this pixel.
    float4 nearH = u.invViewProj * float4(in.ndc, 0.0, 1.0);
    float4 farH  = u.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 nearW = nearH.xyz / nearH.w;
    float3 farW  = farH.xyz  / farH.w;
    float3 ro = u.camPos;
    float3 rd = normalize(farW - nearW);

    float2 hit = intersectBox(ro, rd, u.boxHalf);
    // Clip planes. Normal mode trims the ray's [near, far] range to each plane's kept
    // half-space. Cutaway instead finds the stretch of the ray inside every plane's
    // removed half-space — (cut0, cut1), one interval since that region is convex — and
    // the marches below skip it.
    bool cutaway = u.clipCutaway != 0;
    float cut0 = -1e20, cut1 = 1e20;
    for (int i = 0; i < u.clipCount; ++i) {
        float o = dot(u.clips[i].xyz, ro), d = dot(u.clips[i].xyz, rd);
        if (abs(d) < 1e-6) { // ray parallel to the plane: entirely kept or entirely removed
            if (cutaway) { if (o <= u.clips[i].w) { cut1 = -1e20; } }
            else if (o > u.clips[i].w) { return float4(0, 0, 0, 1); }
        } else {
            float t = (u.clips[i].w - o) / d; // removed side is beyond t when d > 0
            if (cutaway) { if (d > 0.0) { cut0 = max(cut0, t); } else { cut1 = min(cut1, t); } }
            else { if (d > 0.0) { hit.y = min(hit.y, t); } else { hit.x = max(hit.x, t); } }
        }
    }
    if (!cutaway || u.clipCount == 0) { cut1 = -1e20; } // empty interval: nothing skipped
    if (hit.x > hit.y || hit.y < 0.0) { return float4(0, 0, 0, 1); } // miss
    float tIn = max(hit.x, 0.0);
    float window = max(u.dataMax - u.dataMin, 1e-6);

    if (u.mode == 1) {
        // Port of niivue's default volume render (fragRenderShader in shader-srcs.ts):
        // front-to-back alpha compositing, one sample per voxel, jittered start, early
        // termination at 0.95. Colour and opacity follow niivue's "gray" colormap:
        // grey = windowed intensity, alpha ramps 0 → 128/255, below-window is transparent.
        // ponytail: classifies the interpolated intensity per sample; niivue interpolates a
        // pre-classified RGBA texture. No clip planes, overlays or gradient lighting —
        // port those from kRenderInit/kRenderTail/fragRenderGradientShader when needed.
        float3 dims = float3(vol.get_width(), vol.get_height(), vol.get_depth());
        float3 uvw0 = (ro + rd * tIn) / (2.0 * u.boxHalf) + 0.5;
        float3 uvw1 = (ro + rd * hit.y) / (2.0 * u.boxHalf) + 0.5;
        float lenVox = length((uvw1 - uvw0) * dims);
        if (lenVox < 0.5) { return float4(0, 0, 0, 1); }
        float3 stepUVW = (uvw1 - uvw0) / lenVox;
        const float earlyTermination = 0.95;
        float4 acc = float4(0.0);
        float tStep = (hit.y - tIn) / lenVox; // ray distance per voxel step
        float skip0 = (cut0 - tIn) / tStep, skip1 = (cut1 - tIn) / tStep;
        float s = fract(sin(in.position.x * 12.9898 + in.position.y * 78.233) * 43758.5453);
        for (; s <= lenVox; s += 1.0) {
            // Jump over the cutaway. Assign rather than step back and `continue`: float
            // rounding could land just short of skip1 and repeat the jump forever.
            if (s > skip0 && s < skip1) { s = skip1; if (s > lenVox) { break; } }
            float v = vol.sample(samp, uvw0 + stepUVW * s, level(0)).r;
            if (v <= u.dataMin) { continue; }
            float txl = clamp((v - u.dataMin) / window, 2.0 / 256.0, 1.0);
            float a = txl * (128.0 / 255.0);
            if (a < 0.01) { continue; }
            acc += (1.0 - acc.a) * float4(float3(txl) * a, a);
            if (acc.a > earlyTermination) { break; }
        }
        return float4(acc.rgb / earlyTermination, 1.0);
    }

    float dt = (hit.y - tIn) / float(u.steps);
    float maxV = 0.0;
    for (int i = 0; i < u.steps; ++i) {
        float t = tIn + dt * float(i);
        if (t > cut0 && t < cut1) { continue; }
        float3 pos = ro + rd * t;
        float3 uvw = pos / (2.0 * u.boxHalf) + 0.5;       // [-half,half] -> [0,1]
        float v = vol.sample(samp, uvw, level(0)).r;
        maxV = max(maxV, v);                              // MIP
    }

    float norm = clamp((maxV - u.dataMin) / window, 0.0, 1.0);
    // Sample texel centres: the sampler is clamp-to-zero (for the volume), so u = 1.0
    // would blend the last LUT entry with the black border and turn saturated voxels grey.
    float3 rgb = cmap.sample(samp, (norm * 255.0 + 0.5) / 256.0).rgb;
    return float4(rgb, 1.0);
}
