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
    // The colour theme's background image, when it names one. Two planes so a
    // theme change can transition between them, on exactly the terms
    // `phonoscope_centre_image` already carries -- the arithmetic is stated once
    // in nova-visualiser/src/core/centre_image_transition.h and every port
    // mirrors it.
    //
    // This lives INSIDE the backdrop pass rather than in one of its own, which
    // is what puts it under the vignette: the band clip and the four edge
    // gradients at the bottom of this shader run over whatever the field
    // produced, and they do not care whether that was blobs or a photograph.
    // `hasImage == 0` is the original shader exactly, so a theme with no
    // background image pays nothing.
    // Scalars rather than float2s deliberately: a float2 carries 8-byte
    // alignment, so the compiler would insert padding here that the Swift
    // mirror has to reproduce exactly by luck. Four floats have no such trap,
    // and a silent layout mismatch would read the transition's parameters out
    // of the wrong words.
    float hasImage;
    float hasImageFrom;
    float imageHalfExtentToX;
    float imageHalfExtentToY;
    float imageHalfExtentFromX;
    float imageHalfExtentFromY;
    float imageProgress;
    float imageAxisRadians;
    float imageSegments;
    float imageReturnOrigin;
    float imageMode;
    float frameAspect;
    float padding;
};

constant int kImageModeCrossFade = 0;
constant int kImageModeFlip = 1;
constant float kImageFlipEpsilon = 1e-4;

constexpr sampler mosaicSampler(address::clamp_to_edge, filter::linear);

// One SwiftUI LinearGradient stop pair, as coverage. Each of the four vignette
// gradients runs from `opacity` at the edge to fully clear over `extent` of the
// band, scaled by `size`. Mirrors `edge()` in
// nova-visualiser/src/shaders/fluid_background.frag and
// `backgroundBandEdge()` in core/background_band_reference.h.
static float bandEdge(float t, float extent, float opacity, float size) {
    return opacity * clamp(1.0 - t / max(0.0001, extent * size), 0.0, 1.0);
}

// One plane of the background image, sampled inside its own rectangle and clear
// outside it.
//
// A port of `imagePlane()` in nova-visualiser/src/shaders/fluid_background.frag,
// which is itself the same transform `phonoscope_centre_image` runs. `uv` is the
// top-left-origin frame space both sides work in.
//
// `mode` is a parameter rather than `uniforms.imageMode` read directly, because
// the mode that applies is not always the one that was authored: a change whose
// other occupant is the procedural field is always a cross-fade, since a field
// has no rectangle to flip or slide. See
// nova-visualiser/specs/backdrop-transitions.md.
static float4 backgroundImagePlane(texture2d<float> image,
                                   float2 halfExtent,
                                   bool incoming,
                                   float2 frameUv,
                                   int mode,
                                   constant FluidBackgroundUniforms &uniforms) {
    if (halfExtent.x <= 0.0 || halfExtent.y <= 0.0) return float4(0.0);

    float frameAspect = uniforms.frameAspect;
    float2 centred = (frameUv - 0.5) * float2(frameAspect, 1.0);

    if (mode != kImageModeCrossFade) {
        float2 along = float2(cos(uniforms.imageAxisRadians), sin(uniforms.imageAxisRadians));
        float2 across = float2(-along.y, along.x);
        float2 local = float2(dot(centred, along), dot(centred, across));

        if (mode == kImageModeFlip) {
            // Collapse to nothing at the midpoint and back out again. Below the
            // epsilon the plane is edge-on: there is no image left to sample,
            // and dividing by it would smear one column of texels across the
            // frame.
            float collapse = abs(cos(M_PI_F * clamp(uniforms.imageProgress, 0.0, 1.0)));
            if (collapse < kImageFlipEpsilon) return float4(0.0);
            local.x /= collapse;
        } else {
            // The segment index comes from the ACROSS coordinate, which
            // displacement never changes, so a fragment can be asked which
            // segment it belongs to before knowing where that segment moved to.
            int segments = max(1, int(uniforms.imageSegments + 0.5));
            float2 halfLocal = float2(
                abs(halfExtent.x * frameAspect * along.x) + abs(halfExtent.y * along.y),
                abs(halfExtent.x * frameAspect * across.x) + abs(halfExtent.y * across.y));
            int index = 0;
            if (halfLocal.y > 0.0) {
                float position = (local.y / halfLocal.y) * 0.5 + 0.5;
                index = clamp(int(floor(position * float(segments))), 0, segments - 1);
            }
            // Alternating by parity: 0 divisions is a solid image, 1 pushes the
            // two halves apart, 2 sends the outer sections one way and the
            // middle the other.
            float direction = (index % 2 == 0) ? 1.0 : -1.0;
            float frameSpan = 0.5 * (abs(along.x) * frameAspect + abs(along.y));
            float clearDistance = frameSpan + halfLocal.x;

            float clamped = clamp(uniforms.imageProgress, 0.0, 1.0);
            float offset;
            if (!incoming) {
                offset = direction * clearDistance * (clamped * 2.0);
            } else {
                float arriving = clamped * 2.0 - 1.0;
                // Opposite edge carries on the way it left and enters from the
                // far side; origin edge reverses and comes back the way it went.
                float travel = (uniforms.imageReturnOrigin > 0.5) ? -direction : direction;
                offset = travel * clearDistance * (arriving - 1.0);
            }
            local.x -= offset;
        }

        centred = along * local.x + across * local.y;
    }

    float2 texel = centred / float2(frameAspect, 1.0) / (halfExtent * 2.0) + 0.5;
    // Outside the fitted rectangle there is no image, which is what makes a fill
    // read as a crop rather than a squash -- and what carries a slid segment off
    // frame rather than wrapping it.
    if (any(texel < 0.0) || any(texel > 1.0)) return float4(0.0);
    return image.sample(mosaicSampler, texel);
}

// ONE image occupant of the backdrop slot, as a finished, framed picture.
//
// Mirrors `imageOccupant()` in the GLSL. The plane over the theme's backdrop
// colour, then the vignette closed over the whole frame -- with an image there
// is no band, so the fit IS the geometry. Where nothing covers, the backdrop
// colour shows through, so a fitted image smaller than the frame sits on the
// palette rather than on a hole.
//
// Returned finished rather than as a colour to be blended later, because the
// other occupant is framed on entirely different terms (band-local) and the two
// framings are cross-dissolved rather than reconciled. See
// nova-visualiser/specs/backdrop-transitions.md.
static float3 backgroundImageOccupant(texture2d<float> image,
                                      float2 halfExtent,
                                      bool incoming,
                                      int mode,
                                      float2 frameUv,
                                      bool banded,
                                      float vignetteOpacity,
                                      float vignetteSize,
                                      float3 vignetteColor,
                                      constant FluidBackgroundUniforms &uniforms) {
    float4 plane = backgroundImagePlane(image, halfExtent, incoming, frameUv, mode, uniforms);
    // The plane is premultiplied at decode time, so this IS the source-over
    // term -- not a mix, which would darken the image by its own coverage a
    // second time.
    float coverage = clamp(plane.a, 0.0, 1.0);
    float3 color = saturate(plane.rgb + uniforms.background.rgb * (1.0 - coverage));
    if (banded) {
        float left = bandEdge(frameUv.x, 0.18, vignetteOpacity, vignetteSize);
        float right = bandEdge(1.0 - frameUv.x, 0.18, vignetteOpacity, vignetteSize);
        float top = bandEdge(frameUv.y, 0.28, vignetteOpacity, vignetteSize);
        float bottom = bandEdge(1.0 - frameUv.y, 0.28, vignetteOpacity, vignetteSize);
        float shade = 1.0 - (1.0 - left) * (1.0 - right) * (1.0 - top) * (1.0 - bottom);
        color = mix(color, vignetteColor, shade);
    }
    return saturate(color);
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

// The OTHER occupant of the backdrop slot, as a finished, framed picture: the
// blob field, clipped into its band and framed by the edge gradients.
//
// Mirrors `fieldOccupant()` in the GLSL, with ONE deliberate divergence: the
// GLSL also carries a `hasField` branch for a module that never declared the
// blob field, where the backdrop is a flat colour the composite draws instead.
// This surface has no equivalent because the view itself is only in the tree
// when the module declares the field (`usesLetterboxedBackground` in
// PhonoscopeView.swift) -- there is no fieldless case to draw here.
static float3 backgroundFieldOccupant(float2 uv,
                                      float2 resolution,
                                      float aspect,
                                      bool banded,
                                      float backgroundOverlay,
                                      float heightFraction,
                                      float widthFraction,
                                      float vignetteOpacity,
                                      float vignetteSize,
                                      float3 vignetteColor,
                                      constant FluidBackgroundUniforms &uniforms) {
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
            return saturate(vignetteColor);
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

    return saturate(color);
}

fragment float4 fluidBackgroundFragment(VertexOut in [[stage_in]],
                                        constant FluidBackgroundUniforms &uniforms [[buffer(0)]],
                                        texture2d<float> mosaicTexture [[texture(0)]],
                                        texture2d<float> backgroundImageTo [[texture(1)]],
                                        texture2d<float> backgroundImageFrom [[texture(2)]]) {
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

    // The backdrop is ONE slot with two possible occupants, and a change
    // between any two of them is a transition on the authored ramp. A null
    // image on either side is the FIELD occupant, not an absence -- which is
    // what makes "no background" -> "a background" a real change rather than a
    // cut. nova-visualiser/specs/backdrop-transitions.md is the authority; this
    // mirrors main() in nova-visualiser/src/shaders/fluid_background.frag.
    bool toIsImage = uniforms.hasImage > 0.5;
    bool fromIsImage = uniforms.hasImageFrom > 0.5;
    int authoredMode = int(uniforms.imageMode + 0.5);
    float weight = clamp(uniforms.imageProgress, 0.0, 1.0);
    float2 extentTo = float2(uniforms.imageHalfExtentToX, uniforms.imageHalfExtentToY);
    float2 extentFrom = float2(uniforms.imageHalfExtentFromX, uniforms.imageHalfExtentFromY);

    // Image -> image under a flip or a slide draws exactly ONE plane, swapping
    // at the exact midpoint. That instant is what makes a flip read as one
    // object turning over rather than two images blending through each other.
    if (toIsImage && fromIsImage && authoredMode != kImageModeCrossFade) {
        float3 color = weight >= 0.5
            ? backgroundImageOccupant(backgroundImageTo, extentTo, true, authoredMode, in.uv,
                                      banded, vignetteOpacity, vignetteSize, vignetteColor, uniforms)
            : backgroundImageOccupant(backgroundImageFrom, extentFrom, false, authoredMode, in.uv,
                                      banded, vignetteOpacity, vignetteSize, vignetteColor, uniforms);
        return float4(color, 1.0);
    }

    // Everything else is a cross-dissolve of two finished, framed pictures. The
    // geometry is always the cross-fade's here: either both sides are images
    // under an authored cross-fade, or one side is the field -- and a field has
    // no rectangle to flip or slide, so the mode is ignored rather than
    // half-applied.
    //
    // Framings are dissolved, not reconciled: an image is framed whole-frame
    // and the band is framed band-locally, and mixing the two finished results
    // is what keeps both endpoints pixel-identical to the picture each occupant
    // draws on its own.
    //
    // The ends short-circuit so a steady backdrop costs exactly what it cost
    // before any of this existed -- one occupant, evaluated once.
    if (weight >= 1.0) {
        float3 color = toIsImage
            ? backgroundImageOccupant(backgroundImageTo, extentTo, true, kImageModeCrossFade, in.uv,
                                      banded, vignetteOpacity, vignetteSize, vignetteColor, uniforms)
            : backgroundFieldOccupant(uv, resolution, aspect, banded, backgroundOverlay,
                                      heightFraction, widthFraction, vignetteOpacity, vignetteSize,
                                      vignetteColor, uniforms);
        return float4(color, 1.0);
    }
    if (weight <= 0.0) {
        float3 color = fromIsImage
            ? backgroundImageOccupant(backgroundImageFrom, extentFrom, false, kImageModeCrossFade,
                                      in.uv, banded, vignetteOpacity, vignetteSize, vignetteColor,
                                      uniforms)
            : backgroundFieldOccupant(uv, resolution, aspect, banded, backgroundOverlay,
                                      heightFraction, widthFraction, vignetteOpacity, vignetteSize,
                                      vignetteColor, uniforms);
        return float4(color, 1.0);
    }

    float3 leaving = fromIsImage
        ? backgroundImageOccupant(backgroundImageFrom, extentFrom, false, kImageModeCrossFade,
                                  in.uv, banded, vignetteOpacity, vignetteSize, vignetteColor,
                                  uniforms)
        : backgroundFieldOccupant(uv, resolution, aspect, banded, backgroundOverlay,
                                  heightFraction, widthFraction, vignetteOpacity, vignetteSize,
                                  vignetteColor, uniforms);
    float3 arriving = toIsImage
        ? backgroundImageOccupant(backgroundImageTo, extentTo, true, kImageModeCrossFade, in.uv,
                                  banded, vignetteOpacity, vignetteSize, vignetteColor, uniforms)
        : backgroundFieldOccupant(uv, resolution, aspect, banded, backgroundOverlay,
                                  heightFraction, widthFraction, vignetteOpacity, vignetteSize,
                                  vignetteColor, uniforms);
    return float4(saturate(mix(leaving, arriving, weight)), 1.0);
}
