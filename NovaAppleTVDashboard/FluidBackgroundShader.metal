#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct FluidBackgroundUniforms {
    float time;
    float2 resolution;
    float4 background;
    float4 accent;
    float4 highlight;
    float peakIntensity;
    float falloffPower;
    float warpAmplitude;
    float hueSpread;
    float apexGlow;
    float textureScale;
    float uiScaleMultiplier;
    float hasMosaicTexture;
    float blobScale;
    float blobSoftness;
    // Band geometry, as fractions of the drawable. The Phonoscope surface used
    // to get these as a SwiftUI `.frame(height: geometry.size.height / 3)` with
    // a `PhonoscopeEdgeVignette` overlay; both are driven parameters now, and a
    // driven value changes every frame, so a SwiftUI frame is the wrong
    // mechanism. The view is full-screen and the band is resolved here instead,
    // which is also what nova-visualiser's fluid_background.frag does.
    //
    // `bandEnabled == 0` means no band at all: the whole drawable is field,
    // with no clip and no vignette. That is the dashboard background's use of
    // this same shader, and it is the default. It is a separate flag rather
    // than `bandFraction <= 0`, because a height driven to zero is a band
    // closed down to nothing -- a frame of solid vignette colour, which is a
    // different picture from having no band.
    float bandFraction;
    float bandWidthFraction;
    float4 vignetteColor;
    float vignetteOpacity;
    float vignetteSize;
    float bandEnabled;
    float padding;
};

constexpr sampler mosaicSampler(address::clamp_to_edge, filter::linear);

// One SwiftUI LinearGradient stop pair, as coverage. Each of the four vignette
// gradients runs from `opacity` at the edge to fully clear over `extent` of the
// band, scaled by `size`. Mirrors `edge()` in
// nova-visualiser/src/shaders/fluid_background.frag and
// `backgroundBandEdge()` in core/background_band_reference.h.
static float bandEdge(float t, float extent, float opacity, float size) {
    return opacity * clamp(1.0 - t / max(0.0001, extent * size), 0.0, 1.0);
}

vertex VertexOut fluidBackgroundVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

static float3 hsvToRgb(float3 c) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
    return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

static float3 rgbToHsv(float3 c) {
    float4 k = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, k.wz), float4(c.gb, k.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static float3 hueShift(float3 color, float amount) {
    float3 hsv = rgbToHsv(max(color, float3(0.0)));
    hsv.x = fract(hsv.x + amount);
    return hsvToRgb(hsv);
}

static float peakField(float2 p, float2 center, float radius, float time, float seed, float warpAmplitude, float falloffPower) {
    float2 warped = p;
    warped.x += sin(p.y * 4.4 + time * 0.18 + seed) * 0.056 * warpAmplitude;
    warped.y += cos(p.x * 3.8 - time * 0.15 + seed * 1.7) * 0.048 * warpAmplitude;

    float dist = length(warped - center);
    float peak = smoothstep(radius, 0.0, dist);
    float ridge = 0.5 + 0.5 * sin((p.x * 7.0 + p.y * 5.0) + time * 0.22 + seed);
    return pow(peak, max(0.4, falloffPower)) * (0.70 + ridge * 0.45);
}

// Mosaic texture sampling — mirrors the web FluidBackground shader. The tiling
// is normalized by uiScaleMultiplier (targetDPR / devicePixelRatio) so the
// texture reads at the same apparent scale across pixel densities.
static float2 mosaicTextureUv(float2 uv, float aspect, float textureScale, float uiScaleMultiplier) {
    return fract(float2(uv.x * aspect, uv.y) * max(0.25, textureScale) * uiScaleMultiplier);
}

static float mosaicGrout(float3 map) {
    float nearZeroRg = 1.0 - smoothstep(0.004, 0.025, max(map.r, map.g));
    float highZ = smoothstep(0.965, 0.995, map.b);
    return nearZeroRg * highZ;
}

static float2 mosaicMappedUv(float2 uv,
                             float aspect,
                             texture2d<float> mosaicTexture,
                             float hasMosaicTexture,
                             float textureScale,
                             float uiScaleMultiplier) {
    if (hasMosaicTexture < 0.5) {
        return uv;
    }

    float3 map = mosaicTexture.sample(mosaicSampler, mosaicTextureUv(uv, aspect, textureScale, uiScaleMultiplier)).rgb;
    float grout = mosaicGrout(map);
    float2 normalOffset = map.rg * 2.0 - 1.0;

    normalOffset *= (1.0 - grout);
    // Displacement tracks tile size so the refraction reads identically per-tile
    // across pixel densities (matches the uiScaleMultiplier texture tiling).
    return uv + normalOffset * float2(1.0 / max(aspect, 1.0), 1.0) * (0.034 / uiScaleMultiplier);
}

static float mosaicBackgroundOverlay(float2 uv,
                                     float aspect,
                                     texture2d<float> mosaicTexture,
                                     float hasMosaicTexture,
                                     float textureScale,
                                     float uiScaleMultiplier) {
    if (hasMosaicTexture < 0.5) {
        return 0.0;
    }

    float3 map = mosaicTexture.sample(mosaicSampler, mosaicTextureUv(uv, aspect, textureScale, uiScaleMultiplier)).rgb;
    return clamp(map.b, 0.0, 1.0);
}

fragment float4 fluidBackgroundFragment(VertexOut in [[stage_in]],
                                        constant FluidBackgroundUniforms &uniforms [[buffer(0)]],
                                        texture2d<float> mosaicTexture [[texture(0)]]) {
    float2 resolution = max(uniforms.resolution, float2(1.0, 1.0));
    float aspect = resolution.x / resolution.y;
    float textureScale = uniforms.textureScale;
    float uiScaleMultiplier = max(uniforms.uiScaleMultiplier, 0.0001);
    float2 uv = mosaicMappedUv(in.uv, aspect, mosaicTexture, uniforms.hasMosaicTexture, textureScale, uiScaleMultiplier);
    float backgroundOverlay = mosaicBackgroundOverlay(in.uv, aspect, mosaicTexture, uniforms.hasMosaicTexture, textureScale, uiScaleMultiplier);

    // Band geometry. Not banded is the dashboard background's case: no clip,
    // no vignette, and `uv` is left exactly as it was.
    bool banded = uniforms.bandEnabled > 0.5;
    float heightFraction = clamp(uniforms.bandFraction, 0.0, 1.0);
    float widthFraction = clamp(uniforms.bandWidthFraction, 0.0, 1.0);
    float vignetteOpacity = clamp(uniforms.vignetteOpacity, 0.0, 1.0);
    float vignetteSize = max(uniforms.vignetteSize, 0.0);
    float3 vignetteColor = uniforms.vignetteColor.rgb;

    float inBand = 1.0;
    float bandLocalX = uv.x;
    float bandLocalY = uv.y;
    if (banded) {
        // The band is centred on both axes.
        float bandTop = 0.5 - heightFraction * 0.5;
        float bandLeft = 0.5 - widthFraction * 0.5;
        bandLocalY = (uv.y - bandTop) / max(0.0001, heightFraction);
        bandLocalX = (uv.x - bandLeft) / max(0.0001, widthFraction);

        // Softened by about a pixel of the band's own size: at 4K a hard cut
        // here shimmers under the encoder, and the streamed engine softens it
        // identically.
        float2 softness = 1.0 / max(resolution, float2(1.0, 1.0));
        inBand = smoothstep(-softness.y, softness.y, bandLocalY)
            * smoothstep(-softness.y, softness.y, 1.0 - bandLocalY)
            * smoothstep(-softness.x, softness.x, bandLocalX)
            * smoothstep(-softness.x, softness.x, 1.0 - bandLocalX);
        if (inBand <= 0.0) {
            // Outside the band is the vignette colour at full coverage, not a
            // hole: the bars and the gradient inside the band are one surface.
            return float4(saturate(vignetteColor), 1.0);
        }
        uv = clamp(float2(bandLocalX, bandLocalY), 0.0, 1.0);
    }

    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float time = uniforms.time;
    float peakIntensity = clamp(uniforms.peakIntensity, 0.4, 2.6);
    float falloffPower = clamp(uniforms.falloffPower, 0.8, 3.2)
        * clamp(uniforms.blobSoftness, 0.25, 1.5);
    float warpAmplitude = clamp(uniforms.warpAmplitude, 0.4, 2.2);
    float hueSpread = clamp(uniforms.hueSpread, 0.0, 1.0);
    float apexGlow = clamp(uniforms.apexGlow, 0.0, 2.4);
    float blobScale = clamp(uniforms.blobScale, 0.5, 4.0);

    float3 color = uniforms.background.rgb;
    float seeds[4] = {0.0, 1.8, 3.4, 5.2};
    float radii[4] = {0.48, 0.43, 0.46, 0.38};

    for (int i = 0; i < 4; i++) {
        float seed = seeds[i];
        float2 center = float2(
            sin(time * 0.055 + seed) * 0.50 + sin(time * 0.019 + seed * 2.1) * 0.10,
            cos(time * 0.047 + seed * 1.3) * 0.31 + sin(time * 0.027 + seed) * 0.11
        );
        center.x *= aspect;

        float peak = peakField(p, center, radii[i] * blobScale, time, seed, warpAmplitude, falloffPower);
        float apex = smoothstep(0.62, 1.0, peak);
        float pulse = 0.5 + 0.5 * sin(time * 0.12 + seed);
        float3 tint = mix(uniforms.accent.rgb, uniforms.highlight.rgb, pulse);
        float hueOffset = (sin(seed * 12.9898 + time * 0.018) * 0.5 + sin(seed * 4.531) * 0.5) * 0.11 * hueSpread;
        tint = hueShift(tint, hueOffset);
        color += tint * peak * (0.22 + pulse * 0.16) * peakIntensity;
        color += tint * apex * 0.18 * apexGlow;
    }

    float grain = fract(sin(dot(uv * resolution + time, float2(12.9898, 78.233))) * 43758.5453);
    color += (grain - 0.5) * 0.006;

    float vignette = smoothstep(0.34, 1.16, length(p));
    color = mix(color, uniforms.background.rgb * 0.76, vignette * 0.42);
    float3 cap = max(uniforms.accent.rgb, uniforms.highlight.rgb) * (0.64 + peakIntensity * 0.12) + uniforms.background.rgb * 1.05;
    color = min(color, cap);
    color = mix(color, uniforms.background.rgb, backgroundOverlay);

    if (banded) {
        // PhonoscopeEdgeVignette, formerly four SwiftUI LinearGradients in a
        // ZStack. They composite source-over, so they combine as
        // 1 - prod(1 - a), not as a sum. The authored extents (0.18 across,
        // 0.28 down) keep their ratio under `vignetteSize`.
        color = saturate(color);
        float left = bandEdge(uv.x, 0.18, vignetteOpacity, vignetteSize);
        float right = bandEdge(1.0 - uv.x, 0.18, vignetteOpacity, vignetteSize);
        float top = bandEdge(uv.y, 0.28, vignetteOpacity, vignetteSize);
        float bottom = bandEdge(1.0 - uv.y, 0.28, vignetteOpacity, vignetteSize);
        float shade = 1.0 - (1.0 - left) * (1.0 - right) * (1.0 - top) * (1.0 - bottom);
        // Toward the vignette colour rather than a plain darken, so the
        // gradient meets the bars outside the band seamlessly. With the default
        // black slot this is exactly the original `color *= (1 - shade)`.
        color = mix(color, vignetteColor, shade);
        // The one-pixel clip edge fades the shaded band into the frame.
        color = mix(vignetteColor, color, inBand);
    }

    return float4(saturate(color), 1.0);
}
