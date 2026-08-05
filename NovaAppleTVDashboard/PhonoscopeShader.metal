#include <metal_stdlib>
using namespace metal;

struct PhonoscopeParticle {
    float4 positionSize;
    float4 color;
    float4 colorEnd;
    float4 glowColor;
    float4 glowColorEnd;
    float4 meta;
    float4 trail;
};

struct PhonoscopeUniforms {
    float4 viewport;
    float4 boundsMin;
    float4 boundsMax;
    float4 signal;
};

struct PhonoscopeVertexOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float4 colorEnd;
    float4 glowColor;
    float4 glowColorEnd;
    float glow;
    float primitive;
    float material;
    float effectScale;
};

struct PhonoscopeFullscreenOut {
    float4 position [[position]];
    float2 uv;
};

struct PhonoscopeBloomUniforms {
    float2 texelStep;
    float intensity;
    float padding;
    float4 background;
};

vertex PhonoscopeVertexOut phonoscope_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PhonoscopeParticle *particles [[buffer(0)]],
    constant PhonoscopeUniforms &uniforms [[buffer(1)]]
) {
    constexpr float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    PhonoscopeParticle particle = particles[instanceID];
    float3 p = particle.positionSize.xyz;
    float is3D = uniforms.signal.z;
    if (is3D > 0.5) {
        float angle = uniforms.signal.x * 0.055;
        float c = cos(angle);
        float s = sin(angle);
        p.xz = float2(p.x * c - p.z * s, p.x * s + p.z * c);
        float depth = max(1.0, p.z + 3.2);
        p.xy /= depth * 0.62;
    } else {
        float2 center = (uniforms.boundsMin.xy + uniforms.boundsMax.xy) * 0.5;
        float2 extent = max(float2(0.0001), (uniforms.boundsMax.xy - uniforms.boundsMin.xy) * 0.5);
        p.xy = (p.xy - center) / extent;
    }
    float aspect = max(0.01, uniforms.viewport.x / max(1.0, uniforms.viewport.y));
    // The scene was authored against a 1080-line drawable. Only effects grow
    // with the output resolution: dot cores and grid-wire widths stay fixed.
    float effectScale = max(1.0, uniforms.viewport.y / 1080.0);

    PhonoscopeVertexOut out;
    if (particle.meta.y > 5.5 && particle.trail.w > 0.0) {
        float2 delta = particle.trail.xy;
        if (is3D <= 0.5) {
            float2 extent = max(float2(0.0001), (uniforms.boundsMax.xy - uniforms.boundsMin.xy) * 0.5);
            delta /= extent;
        }
        float2 screenDelta = float2(delta.x * aspect, delta.y);
        float deltaLength = length(screenDelta);
        float2 screenDirection = deltaLength > 0.00001
            ? screenDelta / deltaLength
            : float2(1.0, 0.0);
        float2 clipNormal = float2(-screenDirection.y / aspect, screenDirection.x);
        float progress = (corners[vertexID].x + 1.0) * 0.5;
        float2 lineCenter = p.xy - delta * (1.0 - progress);
        out.position = float4(
            lineCenter + clipNormal * corners[vertexID].y * particle.positionSize.w,
            0,
            1
        );
    } else if (particle.meta.y > 4.5 && particle.trail.w > 0.0) {
        float2 direction = particle.trail.xy;
        if (is3D <= 0.5) {
            float2 extent = max(float2(0.0001), (uniforms.boundsMax.xy - uniforms.boundsMin.xy) * 0.5);
            direction /= extent;
        }
        float2 screenDirection = float2(direction.x * aspect, direction.y);
        float directionLength = length(screenDirection);
        screenDirection = directionLength > 0.00001
            ? screenDirection / directionLength
            : float2(1.0, 0.0);
        float2 clipDirection = float2(screenDirection.x / aspect, screenDirection.y);
        float2 clipNormal = float2(-screenDirection.y / aspect, screenDirection.x);
        float progress = (corners[vertexID].x + 1.0) * 0.5;
        float sourceRadius = particle.positionSize.w;
        float2 trailHead = p.xy - clipDirection * sourceRadius * 0.9;
        float2 trailTail = trailHead - clipDirection * sourceRadius * particle.trail.w * effectScale;
        float2 trailCenter = mix(trailTail, trailHead, progress);
        float halfWidth = sourceRadius * progress * effectScale;
        out.position = float4(
            trailCenter + clipNormal * corners[vertexID].y * halfWidth,
            0,
            1
        );
    } else {
        float2 offset = corners[vertexID] * particle.positionSize.w * effectScale;
        offset.x /= aspect;
        out.position = float4(p.xy + offset, 0, 1);
    }
    // Expanding both the quad and local space keeps the core at its authored
    // radius while giving its exponential halo more pixels to occupy.
    out.local = particle.meta.y < 4.5 ? corners[vertexID] * effectScale : corners[vertexID];
    out.color = particle.color;
    out.colorEnd = particle.colorEnd;
    out.glowColor = particle.glowColor;
    out.glowColorEnd = particle.glowColorEnd;
    out.glow = particle.meta.x;
    out.primitive = particle.meta.y;
    out.material = particle.meta.z;
    out.effectScale = effectScale;
    return out;
}

fragment float4 phonoscope_fragment(PhonoscopeVertexOut in [[stage_in]]) {
    float radius = length(in.local);
    float gradientProgress = clamp(radius, 0.0, 1.0);
    float core;
    float halo;
    float haloRadius = radius / max(1.0, in.effectScale);
    if (in.primitive < 0.5) {
        if (radius > in.effectScale) discard_fragment();
        core = smoothstep(1.0, 0.08, radius);
        halo = exp(-haloRadius * haloRadius * 3.2) * in.glow;
    } else if (in.primitive < 1.5) {
        if (radius > in.effectScale) discard_fragment();
        core = smoothstep(0.16, 0.02, abs(radius - 0.70));
        halo = exp(-haloRadius * haloRadius * 3.2) * in.glow;
    } else if (in.primitive < 2.5) {
        core = smoothstep(1.0, 0.78, max(abs(in.local.x), abs(in.local.y)));
        halo = exp(-haloRadius * haloRadius * 3.2) * in.glow;
    } else if (in.primitive < 3.5) {
        float edge = 1.0 - abs(in.local.x);
        bool insideCore = in.local.y >= -1.0 && in.local.y <= edge * 2.0 - 1.0;
        core = insideCore
            ? smoothstep(0.08, 0.22, min(in.local.y + 1.0, edge * 2.0 - 1.0 - in.local.y))
            : 0.0;
        halo = exp(-haloRadius * haloRadius * 3.2) * in.glow;
    } else if (in.primitive < 4.5) {
        float edge = max(abs(in.local.x), abs(in.local.y));
        core = smoothstep(0.15, 0.015, abs(edge - 0.82));
        halo = exp(-haloRadius * haloRadius * 3.2) * in.glow;
    } else if (in.primitive < 5.5) {
        float progress = clamp((in.local.x + 1.0) * 0.5, 0.0, 1.0);
        // A trail starts at the dot (the quad's head at progress 1) and ends
        // at its tail, so Primary remains the start colour.
        gradientProgress = 1.0 - progress;
        float brightness = pow(progress, 1.45);
        core = smoothstep(1.0, 0.08, abs(in.local.y)) * brightness;
        halo = exp(-in.local.y * in.local.y * 3.2) * in.glow * brightness;
    } else {
        // Grid wires are emitted source-to-destination.
        gradientProgress = clamp((in.local.x + 1.0) * 0.5, 0.0, 1.0);
        // The wire is an alpha-shaped quad, so MSAA alone only smooths the
        // quad's geometry and cannot reliably soften this shader-defined
        // boundary. Convert one screen pixel into local coordinates with
        // fwidth and integrate coverage across that edge. This remains visible
        // when adaptive rendering drops the scene to a single sample.
        float signedEdgeDistance = 1.0 - abs(in.local.y);
        float edgePixelWidth = max(fwidth(in.local.y), 0.0001);
        core = smoothstep(
            -edgePixelWidth * 0.5,
            edgePixelWidth * 0.5,
            signedEdgeDistance
        );
        halo = 0.0;
    }
    float lighting = 1.0;
    if (in.material > 0.5 && in.material < 1.5 && radius <= 1.0) {
        float z = sqrt(max(0.0, 1.0 - radius * radius));
        lighting = 0.28 + 0.72 * max(0.0, dot(normalize(float3(in.local, z)), normalize(float3(-0.35, 0.45, 1.0))));
    }
    // All shader output is premultiplied because the Metal pipelines use
    // source-one blending. Slot opacity therefore affects both energy and
    // coverage without changing the selected hue.
    float4 coreColor = mix(in.color, in.colorEnd, gradientProgress);
    float4 glowColor = mix(in.glowColor, in.glowColorEnd, gradientProgress);
    float coreAlpha = coreColor.a * core;
    float glowAlpha = glowColor.a * halo * 0.38;
    float alpha = clamp(coreAlpha + glowAlpha, 0.0, 1.0);
    float3 rgb = coreColor.rgb * coreAlpha * lighting
        + glowColor.rgb * glowAlpha;
    return float4(rgb, alpha);
}

vertex PhonoscopeFullscreenOut phonoscope_fullscreen_vertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[3] = {
        float2(-1, -1),
        float2(3, -1),
        float2(-1, 3)
    };
    constexpr float2 texCoords[3] = {
        float2(0, 1),
        float2(2, 1),
        float2(0, -1)
    };
    PhonoscopeFullscreenOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.uv = texCoords[vertexID];
    return out;
}

fragment float4 phonoscope_bloom_extract(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sample = source.sample(linearSampler, in.uv);
    float brightness = max(sample.r, max(sample.g, sample.b));
    float contribution = max(0.0, brightness - 0.16);
    // Alpha is coverage -- how much of the background this pixel hides -- and a
    // glow hides nothing: it is light added on top of whatever is behind it.
    // This used to carry `contribution`, an unbounded HDR value, which the
    // composite then read as coverage and saturated to 1, erasing the
    // background colour in a wide halo around everything bright. The scene pass
    // alone decides coverage; bloom only ever adds colour.
    //
    // Mirrors nova-visualiser/src/shaders/bloom_extract.frag. Both engines
    // implement PHONOSCOPE_MODULE_SPEC.md, so this pair must change together.
    return float4(sample.rgb * contribution * 1.45, 0.0);
}

fragment float4 phonoscope_bloom_blur(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant PhonoscopeBloomUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 color = source.sample(linearSampler, in.uv) * 0.227027;
    color += source.sample(linearSampler, in.uv + uniforms.texelStep * 1.384615) * 0.316216;
    color += source.sample(linearSampler, in.uv - uniforms.texelStep * 1.384615) * 0.316216;
    color += source.sample(linearSampler, in.uv + uniforms.texelStep * 3.230769) * 0.070270;
    color += source.sample(linearSampler, in.uv - uniforms.texelStep * 3.230769) * 0.070270;
    return color;
}

fragment float4 phonoscope_composite(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> scene [[texture(0)]],
    texture2d<float> bloom [[texture(1)]],
    constant PhonoscopeBloomUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 base = scene.sample(linearSampler, in.uv);
    float4 glow = bloom.sample(linearSampler, in.uv) * uniforms.intensity;
    float3 foreground = base.rgb + glow.rgb;
    // Coverage comes from the scene pass alone. Bloom is additive light and
    // occludes nothing, so folding its alpha in here (as `max(base.a, glow.a)`)
    // made every bright halo read as fully covered and cut the background out
    // around it. Mirrors nova-visualiser/src/shaders/composite.frag; the two
    // engines must agree, and tests/conformance/composite locks the formula.
    float foregroundAlpha = clamp(base.a, 0.0, 1.0);
    float backgroundAlpha = clamp(uniforms.background.a, 0.0, 1.0);
    float3 color = foreground
        + uniforms.background.rgb * backgroundAlpha * (1.0 - foregroundAlpha);
    float alpha = foregroundAlpha + backgroundAlpha * (1.0 - foregroundAlpha);
    return float4(clamp(color, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
}

struct PhonoscopeGlowUniforms {
    // Texel size on the blur axis only; the other component is zero. Unused by
    // the overlay pass.
    float2 axisTexel;
    // Gaussian sigma, in texels of the quarter-resolution blur target.
    float sigma;
    // 0-1.
    float opacity;
    // The `__glowBlend` axis itself: 0 screen, 1 multiply, 2 overlay.
    int blendMode;
};

// One axis of the glow overlay's separable Gaussian.
//
// Taps sit at i * (sigma/3) texels for i in -6...6, covering ±2σ at any width.
// Because the stride is proportional to sigma the weights are constant --
// exp(-i²/18) -- so a parameter driver can move the blur every frame without
// rebuilding a weight table. Mirrors nova-visualiser/src/shaders/glow_blur.frag
// and the tap contract in src/core/glow_overlay_reference.h.
fragment float4 phonoscope_glow_blur(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant PhonoscopeGlowUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 result = source.sample(linearSampler, in.uv);
    float weightSum = 1.0;
    // Sigma 0 collapses every tap onto the centre, so skip straight to the copy
    // rather than summing thirteen identical samples.
    if (uniforms.sigma > 0.0) {
        float stride = uniforms.sigma / 3.0;
        for (int tap = 1; tap <= 6; ++tap) {
            float weight = exp(-float(tap * tap) / 18.0);
            float2 offset = uniforms.axisTexel * (float(tap) * stride);
            result += (source.sample(linearSampler, in.uv + offset)
                       + source.sample(linearSampler, in.uv - offset)) * weight;
            weightSum += weight * 2.0;
        }
    }
    return result / weightSum;
}

// The last pass over the picture: a blurred copy of the finished frame laid
// back over itself with a Photoshop blend mode.
//
// Mirrors nova-visualiser/src/shaders/glow_overlay.frag; the arithmetic is
// locked by src/core/glow_overlay_reference.h and
// tests/conformance/glow-overlay.
fragment float4 phonoscope_glow_overlay(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> base [[texture(0)]],
    texture2d<float> glow [[texture(1)]],
    constant PhonoscopeGlowUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 baseColor = base.sample(linearSampler, in.uv);
    // Blend modes are defined on display-referred colour: an unclamped
    // highlight would saturate `screen` to white across the whole frame and
    // stop `multiply` from darkening anything.
    float3 glowColor = clamp(glow.sample(linearSampler, in.uv).rgb, 0.0, 1.0);
    float3 baseRgb = max(baseColor.rgb, float3(0.0));
    float amount = clamp(uniforms.opacity, 0.0, 1.0);

    // Photoshop overlay: multiply where the base is dark, screen where it is
    // light, with the base choosing which. `step` keeps that per channel.
    float3 overlaid = mix(2.0 * baseRgb * glowColor,
                          1.0 - 2.0 * (1.0 - baseRgb) * (1.0 - glowColor),
                          step(0.5, baseRgb));

    float3 blended = uniforms.blendMode == 1
        ? baseRgb * (1.0 - amount + glowColor * amount)
        : uniforms.blendMode == 2
            ? baseRgb + amount * (overlaid - baseRgb)
            : baseRgb + amount * (glowColor - baseRgb * glowColor);

    // Coverage passes through untouched: this is a look on the picture, not a
    // layer of its own, and the letterboxed modules composite over a separate
    // backdrop that must still show through.
    return float4(blended, baseColor.a);
}
