//
//  Accumulate.metal — sliding-window bookkeeping for OrganSegmenter, on the GPU so a
//  Debug build stays usable: Gaussian-weighted logit accumulation into a ring buffer of
//  z slabs, and the per-voxel argmax that finalizes slabs the window has passed. z is the
//  outermost (and, for a whole-body scan, longest) axis, so the ring is one patch deep.
//
//  Layouts (all C order, last index fastest):
//    logits  [class][pz][py][px]          one patch of network output
//    gauss   [pz][py][px]                 importance weights for a patch
//    ring    [slab][class][Y][X]          slab = z % pz; holds pz slabs of the padded image
//    labels  [Z][Y][X]                    result over the padded image
//

#include <metal_stdlib>
using namespace metal;

struct AccParams {
    uint pz, py, px;      // patch extents
    uint z0, y0, x0;      // patch position in the padded image
    uint Z, Y, X;         // padded image extents
    uint classes;
};

// One thread per (x, z*py + y, class) element of the patch's logits.
kernel void accumulate(device half* ring            [[buffer(0)]],
                       device const half* logits    [[buffer(1)]],
                       device const float* gauss    [[buffer(2)]],
                       constant AccParams& p        [[buffer(3)]],
                       uint3 gid                    [[thread_position_in_grid]]) {
    uint x = gid.x, z = gid.y / p.py, y = gid.y % p.py, c = gid.z;
    if (x >= p.px || z >= p.pz || c >= p.classes) { return; }
    uint pi = ((c * p.pz + z) * p.py + y) * p.px + x;
    float w = gauss[(z * p.py + y) * p.px + x];
    uint slab = (p.z0 + z) % p.pz;
    uint ri = ((slab * p.classes + c) * p.Y + (p.y0 + y)) * p.X + (p.x0 + x);
    ring[ri] = half(float(ring[ri]) + float(logits[pi]) * w);
}

struct FinParams {
    uint Z, Y, X;
    uint classes;
    uint ringSlabs;       // pz
    uint firstSlab;       // first z slab to finalize
    uint slabCount;
};

// One thread per (x, y, slab): argmax over classes → label, then clear the ring cells.
kernel void finalize(device half* ring          [[buffer(0)]],
                     device uchar* labels       [[buffer(1)]],
                     constant FinParams& p      [[buffer(2)]],
                     uint3 gid                  [[thread_position_in_grid]]) {
    uint x = gid.x, y = gid.y, r = gid.z;
    if (x >= p.X || y >= p.Y || r >= p.slabCount) { return; }
    uint z = p.firstSlab + r, slab = z % p.ringSlabs;
    float best = -1e30; uint bestC = 0;
    for (uint c = 0; c < p.classes; ++c) {
        uint ri = ((slab * p.classes + c) * p.Y + y) * p.X + x;
        float v = float(ring[ri]);
        if (v > best) { best = v; bestC = c; }
        ring[ri] = 0.0h;
    }
    labels[(z * p.Y + y) * p.X + x] = uchar(bestC);
}
