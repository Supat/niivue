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
    float3   clipNormal;  // unit normal of the clip plane, in box space
    float    dataMin;
    float    dataMax;
    int      steps;       // samples along the ray (MIP)
    int      mode;        // 0 = MIP, 1 = niivue-style compositing
    int      clipOn;      // 0 = no clip plane
    float    clipOffset;  // kept region is dot(clipNormal, p) <= clipOffset
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
    if (u.clipOn != 0) {
        // Clip plane: trim the ray's [near, far] range to the kept half-space.
        float o = dot(u.clipNormal, ro), d = dot(u.clipNormal, rd);
        if (abs(d) < 1e-6) {
            if (o > u.clipOffset) { return float4(0, 0, 0, 1); }
        } else {
            float t = (u.clipOffset - o) / d;
            if (d > 0.0) { hit.y = min(hit.y, t); } else { hit.x = max(hit.x, t); }
        }
    }
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
        float s = fract(sin(in.position.x * 12.9898 + in.position.y * 78.233) * 43758.5453);
        for (; s <= lenVox; s += 1.0) {
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
        float3 pos = ro + rd * (tIn + dt * float(i));
        float3 uvw = pos / (2.0 * u.boxHalf) + 0.5;       // [-half,half] -> [0,1]
        float v = vol.sample(samp, uvw).r;
        maxV = max(maxV, v);                              // MIP
    }

    float norm = clamp((maxV - u.dataMin) / window, 0.0, 1.0);
    // Sample texel centres: the sampler is clamp-to-zero (for the volume), so u = 1.0
    // would blend the last LUT entry with the black border and turn saturated voxels grey.
    float3 rgb = cmap.sample(samp, (norm * 255.0 + 0.5) / 256.0).rgb;
    return float4(rgb, 1.0);
}
