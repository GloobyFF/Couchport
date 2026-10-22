#include <metal_stdlib>
using namespace metal;

// Parameters shared with the Swift side (must match ColorParams layout).
struct ColorParams {
    uint  matrix;      // 0 = BT.709, 1 = BT.601
    uint  fullRange;   // 0 = video range, 1 = full range
    float exposure;    // additive EV in linear-ish space, -1...1
    float contrast;    // 0.5...1.5, 1 = neutral
    float saturation;  // 0...2, 1 = neutral
    float gamma;       // 0.5...2.2, 1 = neutral
    uint  flipH;       // 0 = normal, 1 = mirror left-right
    uint  flipV;       // 0 = normal, 1 = mirror top-bottom
    uint  transfer;    // 0 = SDR (BT.709 / sRGB curve), 1 = PQ (ST 2084), 2 = HLG
    uint  tenBit;      // 1 = 10-bit samples MSB-aligned in 16-bit planes (x420)
    float hdrWhite;    // nits mapped to SDR white for HDR sources (e.g. 203)
    float hdrPeak;     // brightest source nits kept before roll-off (e.g. 1000)
};

// Rec.709 and Rec.601 YCbCr -> RGB matrices (columns applied to {Y,Cb,Cr}).
constant float3x3 kYCbCr709 = float3x3(
    float3(1.0,      1.0,      1.0),
    float3(0.0,     -0.187324, 1.8556),
    float3(1.5748,  -0.468124, 0.0));

constant float3x3 kYCbCr601 = float3x3(
    float3(1.0,      1.0,     1.0),
    float3(0.0,     -0.344136, 1.772),
    float3(1.402,   -0.714136, 0.0));

constant float3x3 kYCbCr2020 = float3x3(
    float3(1.0,      1.0,      1.0),
    float3(0.0,     -0.164553, 1.8814),
    float3(1.4746,  -0.571353, 0.0));

// Linear BT.2020 primaries -> linear BT.709 primaries.
constant float3x3 kRec2020To709 = float3x3(
    float3( 1.6605, -0.1246, -0.0182),
    float3(-0.5876,  1.1329, -0.1006),
    float3(-0.0728, -0.0083,  1.1187));

// SMPTE ST 2084 (PQ) EOTF: encoded 0...1 -> nits 0...10000.
static inline float3 pqToNits(float3 e) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = 2413.0 / 4096.0 * 32.0;
    const float c3 = 2392.0 / 4096.0 * 32.0;
    float3 p = pow(max(e, 0.0), float3(1.0 / m2));
    float3 l = pow(max(p - c1, 0.0) / (c2 - c3 * p), float3(1.0 / m1));
    return l * 10000.0;
}

// ARIB STD-B67 (HLG) inverse OETF + a simple 1000-nit OOTF.
static inline float3 hlgToNits(float3 e) {
    const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
    float3 lo = (e * e) / 3.0;
    float3 hi = (exp((e - c) / a) + b) / 12.0;
    float3 scene = select(lo, hi, e > 0.5);
    float ys = dot(scene, float3(0.2627, 0.6780, 0.0593));
    return scene * pow(max(ys, 1e-6), 0.2) * 1000.0;
}

// Extended Reinhard on the max channel: keeps hue, rolls highlights off
// smoothly so `peak` (in units of SDR white) lands exactly on white.
static inline float3 toneMap(float3 lin, float peak) {
    float m = max(max(lin.r, lin.g), lin.b);
    if (m <= 1e-6) { return lin; }
    float p2 = max(peak * peak, 1.0);
    float mapped = m * (1.0 + m / p2) / (1.0 + m);
    return lin * (mapped / m);
}

// sRGB transfer functions. Grading maths (exposure, saturation) is physically
// meaningful in linear light, so we linearise, grade, then re-encode. Precise
// piecewise sRGB, not a pow(2.2) approximation.
static inline float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    return select(lo, hi, c > 0.04045);
}

static inline float3 linearToSrgb(float3 c) {
    c = max(c, 0.0);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(lo, hi, c > 0.0031308);
}

// Converts a biplanar NV12 pair (luma + chroma textures) to RGB, applying
// range expansion, the selected color matrix, and creative grading.
kernel void convertYCbCrToRGB(texture2d<float, access::read>   lumaTex   [[texture(0)]],
                              texture2d<float, access::sample> chromaTex [[texture(1)]],
                              texture2d<float, access::write>  outTex    [[texture(2)]],
                              constant ColorParams&            params    [[buffer(0)]],
                              uint2                            gid       [[thread_position_in_grid]]) {
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    // Optionally mirror the source read coordinate. Output is always written at
    // gid, so both the window and theater paths pick up the same flip.
    uint2 src = gid;
    if (params.flipH == 1) { src.x = w - 1 - src.x; }
    if (params.flipV == 1) { src.y = h - 1 - src.y; }

    float y = lumaTex.read(src).r;
    // Chroma is half-resolution in both axes (4:2:0). Sample it bilinearly in
    // normalized coordinates instead of a nearest-neighbour integer divide, so
    // coloured edges (HUD text, blood bars, UI outlines) get smooth chroma
    // transitions instead of blocky steps. clamp_to_edge keeps reads in bounds.
    constexpr sampler chromaSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);
    float2 uv = (float2(src) + 0.5) / float2(w, h);
    float2 cbcr = chromaTex.sample(chromaSampler, uv).rg;

    // Range expansion.
    if (params.tenBit == 1) {
        // x420: 10-bit code values in the top bits of 16-bit samples.
        float y10 = y * 65535.0 / 64.0;
        float2 c10 = cbcr * 65535.0 / 64.0;
        if (params.fullRange == 0) {
            y = (y10 - 64.0) / 876.0;
            cbcr = (c10 - 512.0) / 896.0;
        } else {
            y = y10 / 1023.0;
            cbcr = (c10 - 512.0) / 1023.0;
        }
    } else if (params.fullRange == 0) {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cbcr = (cbcr - 128.0 / 255.0) * (255.0 / 224.0);
    } else {
        cbcr = cbcr - 0.5;
    }

    float3 ycbcr = float3(y, cbcr.x, cbcr.y);
    float3x3 m = (params.matrix == 1) ? kYCbCr601 : ((params.matrix == 2) ? kYCbCr2020 : kYCbCr709);
    float3 rgb = clamp(m * ycbcr, 0.0, 1.0);   // non-linear (transfer-encoded)

    // --- To linear BT.709, SDR white = 1.0 ---
    float3 lin;
    if (params.transfer == 1 || params.transfer == 2) {
        float3 nits = (params.transfer == 1) ? pqToNits(rgb) : hlgToNits(rgb);
        float white = max(params.hdrWhite, 1.0);
        lin = toneMap(nits / white, max(params.hdrPeak, white) / white);
        if (params.matrix == 2) { lin = kRec2020To709 * lin; }
        lin = clamp(lin, 0.0, 1.0);
    } else {
        lin = srgbToLinear(rgb);
        if (params.matrix == 2) { lin = clamp(kRec2020To709 * lin, 0.0, 1.0); }
    }

    // --- Creative grading ---
    // Exposure and saturation are physically meaningful in LINEAR light, so do
    // them there to avoid the hue shifts / greyed highlights that come from
    // scaling gamma-encoded values directly.
    lin *= max(1.0 + params.exposure, 0.0);                 // exposure (linear scale)
    float luma = dot(lin, float3(0.2126, 0.7152, 0.0722));  // Rec.709 luma in linear
    lin = max(mix(float3(luma), lin, params.saturation), 0.0);
    rgb = linearToSrgb(lin);

    // Gamma and contrast are perceptual "look" controls; apply in display space.
    rgb = pow(max(rgb, 0.0), float3(1.0 / max(params.gamma, 0.01)));
    rgb = (rgb - 0.5) * params.contrast + 0.5;

    rgb = clamp(rgb, 0.0, 1.0);
    outTex.write(float4(rgb, 1.0), gid);
}

// Contrast-adaptive-style sharpen: adds a fraction of the high-frequency
// AMD FidelityFX CAS-style sharpen. Unlike a plain unsharp mask (centre minus
// neighbourhood), CAS derives a per-pixel sharpening weight from the local
// min/max contrast, so flat/near-clipped regions are sharpened far less. That
// suppresses the halos and ringing a fixed unsharp mask produces around
// high-contrast edges (UI, subtitles) — especially visible at 4K.
kernel void sharpen(texture2d<float, access::read>  inTex  [[texture(0)]],
                    texture2d<float, access::write> outTex [[texture(1)]],
                    constant float&                 amount [[buffer(0)]],
                    uint2                           gid    [[thread_position_in_grid]]) {
    uint w = inTex.get_width();
    uint h = inTex.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }

    int2 p = int2(gid);
    int2 maxXY = int2(w - 1, h - 1);
    // 3x3 neighbourhood (clamped at borders).
    float3 a = inTex.read((uint2)clamp(p + int2(-1, -1), int2(0), maxXY)).rgb;
    float3 b = inTex.read((uint2)clamp(p + int2( 0, -1), int2(0), maxXY)).rgb;
    float3 c = inTex.read((uint2)clamp(p + int2( 1, -1), int2(0), maxXY)).rgb;
    float3 d = inTex.read((uint2)clamp(p + int2(-1,  0), int2(0), maxXY)).rgb;
    float3 e = inTex.read((uint2)gid).rgb;                                   // centre
    float3 f = inTex.read((uint2)clamp(p + int2( 1,  0), int2(0), maxXY)).rgb;
    float3 g = inTex.read((uint2)clamp(p + int2(-1,  1), int2(0), maxXY)).rgb;
    float3 hh = inTex.read((uint2)clamp(p + int2( 0,  1), int2(0), maxXY)).rgb;
    float3 i = inTex.read((uint2)clamp(p + int2( 1,  1), int2(0), maxXY)).rgb;

    // Per-channel local min/max over the cross ("+") neighbourhood.
    float3 mn = min(min(min(d, e), min(f, b)), hh);
    float3 mx = max(max(max(d, e), max(f, b)), hh);
    // Include diagonals with half weight (CAS uses the ring for contrast).
    mn += min(min(a, c), min(g, i));
    mx += max(max(a, c), max(g, i));

    // Sharpening amount from local contrast: darker/high-contrast areas get
    // less to avoid clipping and ringing. rcp of max, clamped.
    float3 rcpMx = 1.0 / max(mx, 1e-4);
    float3 amp = clamp(min(mn, 2.0 - mx) * rcpMx, 0.0, 1.0);
    amp = sqrt(amp);

    // CAS peak: strength dialed by `amount` (0 = none, 1 = full).
    float peak = -1.0 / mix(8.0, 5.0, clamp(amount, 0.0, 1.0));
    float3 wgt = amp * peak;
    float3 rcpW = 1.0 / (1.0 + 4.0 * wgt);
    // Weighted blend of the cross neighbours with the centre.
    float3 result = (b * wgt + d * wgt + f * wgt + hh * wgt + e) * rcpW;

    outTex.write(float4(clamp(result, 0.0, 1.0), 1.0), gid);
}

// MARK: - iPhone Duo tabletop: water reflection

/// Laid out as plain float4s so the Swift side can fill it as
/// [SIMD4<Float>] without layout surprises.
struct WaterParams {
    float4 misc;          // x time (s), y strength 0...1, z waves 0...1, w aspect (w/h)
    float4 videoRect;     // reflected picture in output UV (x, y, w, h)
    float4 base;          // rgb water colour, a = number of drops
    float4 drops[6];      // x, y centre (UV), z start time, w amplitude
};

/// Draws the lower half of the screen as a water surface reflecting the
/// picture above the fold: flipped, distorted by gentle waves and by rings
/// from taps, softened with distance and fading into the water colour.
kernel void waterReflection(texture2d<float, access::sample> inTex  [[texture(0)]],
                            texture2d<float, access::write>  outTex [[texture(1)]],
                            constant WaterParams& p                 [[buffer(0)]],
                            uint2 gid                               [[thread_position_in_grid]])
{
    uint w = outTex.get_width(), h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float depth = uv.y;                       // 0 at the fold, 1 at the bottom edge

    // Ambient waves: horizontal ripples that grow away from the fold.
    float2 offset = float2(0.0);
    float t = p.misc.x;
    float strength = p.misc.y, waves = p.misc.z, aspect = p.misc.w;
    float amb = sin(uv.y * 38.0 / (0.35 + depth) - t * 3.0 + sin(uv.x * 5.0 + t * 1.0) * 1.8)
              + 0.6 * sin(uv.x * 23.0 + uv.y * 11.0 - t * 2.2);
    offset += float2(amb * 0.006, amb * 0.010) * (0.25 + depth) * waves;

    // Rings from taps.
    float highlight = 0.0;
    int count = min(int(p.base.a), 6);
    for (int i = 0; i < count; i++) {
        float4 d = p.drops[i];
        float age = t - d.z;
        if (age < 0.0 || age > 2.0) continue;
        float2 delta = (uv - d.xy) * float2(aspect, 1.0);
        float dist = length(delta);
        // Local ring: travels slowly and dies out within ~0.12 of the touch,
        // so only the area around the pressed button ripples.
        float front = age * 0.13;
        float envelope = exp(-abs(dist - front) * 22.0) * exp(-age * 1.9) * d.w
                       * saturate(1.0 - dist / 0.16);
        float ring = sin((dist - front) * 70.0) * envelope;
        float2 dir = dist > 1e-4 ? delta / dist : float2(0.0);
        offset += dir * ring * 0.03 * float2(1.0 / aspect, 1.0);
        highlight += max(0.0, ring) * 0.4;
    }

    float3 color = p.base.rgb;
    float2 local = (uv + offset - p.videoRect.xy) / p.videoRect.zw;
    if (local.x >= 0.0 && local.x <= 1.0 && local.y >= 0.0 && local.y <= 1.0) {
        // Mirror: the row next to the fold is the bottom row of the picture.
        float2 src = float2(local.x, 1.0 - local.y);
        // Softer further away: a small cross of taps, spread with depth.
        float2 px = float2(1.0 / inTex.get_width(), 1.0 / inTex.get_height()) * (1.0 + depth * 6.0);
        float3 c = inTex.sample(s, src).rgb * 0.4
                 + inTex.sample(s, src + float2(px.x, 0)).rgb * 0.15
                 + inTex.sample(s, src - float2(px.x, 0)).rgb * 0.15
                 + inTex.sample(s, src + float2(0, px.y)).rgb * 0.15
                 + inTex.sample(s, src - float2(0, px.y)).rgb * 0.15;
        float fade = strength * 0.6 * pow(saturate(1.0 - local.y), 1.4);
        color = mix(p.base.rgb, c, fade);
    }
    color += highlight * waves * strength;
    outTex.write(float4(saturate(color), 1.0), gid);
}
