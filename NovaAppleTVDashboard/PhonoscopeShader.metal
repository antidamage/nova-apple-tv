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

struct PhonoscopeCentreImageUniforms {
    // Half-extents in normalised frame coordinates, from
    // PhonoscopeCentreImage/centre_image_reference.h. Contain-fit and scale are
    // resolved on the CPU so the conformance corpus can lock them.
    float2 halfExtentTo;
    float2 halfExtentFrom;
    // The transition's progress, 0 to 1, already shaped by the authored ramp.
    float progress;
    float frameAspect;
    float axisRadians;
    // Divisions + 1, resolved on the CPU so the shader never adds one on the
    // hot path.
    int segments;
    // 0 cross-fade, 1 flip, 2 slide.
    int mode;
    int hasFrom;
    int returnFromOrigin;
};

// Centre-image composite.
//
// Port of nova-visualiser/src/shaders/centre_image.frag, uv flip aside: GL's
// fullscreen triangle hands out a bottom-up uv and Metal's a top-down one, so
// the very first line converts and everything after it is the same arithmetic
// on the same numbers. The geometry itself is stated once in
// PhonoscopeCentreTransition.swift / core/centre_image_transition.h, and the
// `centre-image` conformance case is what proves the three agree.
//
// Drawn between the composite and the glow overlay, so an image blooms with the
// rest of the picture exactly as the message does.
static float4 phonoscope_centre_plane(
    float2 glUV,
    texture2d<float> image,
    float2 halfExtent,
    bool incoming,
    constant PhonoscopeCentreImageUniforms &uniforms
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    if (halfExtent.x <= 0.0 || halfExtent.y <= 0.0) { return float4(0.0); }

    float2 centred = (glUV - float2(0.5)) * float2(uniforms.frameAspect, 1.0);
    if (uniforms.mode != 0) {
        float2 along = float2(cos(uniforms.axisRadians), sin(uniforms.axisRadians));
        float2 across = float2(-along.y, along.x);
        float2 local = float2(dot(centred, along), dot(centred, across));

        if (uniforms.mode == 1) {
            // Collapse to nothing at the midpoint and back out again. Below the
            // epsilon the plane is edge-on: there is no image left to sample,
            // and dividing by it would smear one column of texels across the
            // frame.
            float scale = abs(cos(M_PI_F * clamp(uniforms.progress, 0.0, 1.0)));
            if (scale < 1e-4) { return float4(0.0); }
            local.x /= scale;
        } else {
            // The segment index comes from the ACROSS coordinate, which
            // displacement never changes -- so a fragment can be asked which
            // segment it belongs to before knowing where that segment has moved
            // to, and no search is needed.
            float2 halfLocal = float2(
                abs(halfExtent.x * uniforms.frameAspect * along.x) + abs(halfExtent.y * along.y),
                abs(halfExtent.x * uniforms.frameAspect * across.x) + abs(halfExtent.y * across.y));
            int index = 0;
            if (halfLocal.y > 0.0) {
                float position = (local.y / halfLocal.y) * 0.5 + 0.5;
                index = clamp(int(floor(position * float(uniforms.segments))), 0, uniforms.segments - 1);
            }
            // Alternating by parity: 0 divisions is a solid image, 1 pushes the
            // two halves apart, 2 sends the outer sections one way and the
            // middle the other.
            float direction = (index % 2 == 0) ? 1.0 : -1.0;
            float frameSpan = 0.5 * (abs(along.x) * uniforms.frameAspect + abs(along.y));
            float clearDistance = frameSpan + halfLocal.x;

            float clamped = clamp(uniforms.progress, 0.0, 1.0);
            float offset;
            if (!incoming) {
                offset = direction * clearDistance * (clamped * 2.0);
            } else {
                float arriving = clamped * 2.0 - 1.0;
                // Opposite edge carries on the way it left and enters from the
                // far side; origin edge reverses and comes back the way it went.
                float travel = uniforms.returnFromOrigin != 0 ? -direction : direction;
                offset = travel * clearDistance * (arriving - 1.0);
            }
            local.x -= offset;
        }

        centred = along * local.x + across * local.y;
    }

    float2 texel = centred / float2(uniforms.frameAspect, 1.0) / (halfExtent * 2.0) + float2(0.5);
    // Outside the fitted rectangle there is no image, which is what makes a
    // scale above 1 read as a crop rather than a squash -- and what carries a
    // slid segment off frame rather than wrapping it.
    if (any(texel < float2(0.0)) || any(texel > float2(1.0))) { return float4(0.0); }
    // Texture rows are top-down; this coordinate is bottom-up.
    return image.sample(linearSampler, float2(texel.x, 1.0 - texel.y));
}

fragment float4 phonoscope_centre_image(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> imageTo [[texture(0)]],
    texture2d<float> imageFrom [[texture(1)]],
    constant PhonoscopeCentreImageUniforms &uniforms [[buffer(0)]]
) {
    // GL hands its fullscreen triangle a bottom-up uv and Metal a top-down one.
    // Converting here and nowhere else is what lets the rest of this be a
    // line-for-line port.
    float2 glUV = float2(in.uv.x, 1.0 - in.uv.y);
    float weight = clamp(uniforms.progress, 0.0, 1.0);
    bool hasFrom = uniforms.hasFrom != 0;
    float4 accumulated = float4(0.0);

    if ((uniforms.mode == 1 || uniforms.mode == 2) && hasFrom) {
        // Exactly one plane at a time. For the flip the swap IS the midpoint,
        // which is what makes it read as one object turning over rather than as
        // two images blending through each other; for the slide the outgoing
        // image is off frame by the time the incoming one starts arriving, so
        // the two legs never overlap and neither needs fading.
        accumulated = weight >= 0.5
            ? phonoscope_centre_plane(glUV, imageTo, uniforms.halfExtentTo, true, uniforms)
            : phonoscope_centre_plane(glUV, imageFrom, uniforms.halfExtentFrom, false, uniforms);
    } else {
        accumulated = phonoscope_centre_plane(glUV, imageTo, uniforms.halfExtentTo, true, uniforms) * weight;
        if (hasFrom) {
            // Both sides are premultiplied and the weights sum to 1, so a
            // straight weighted sum is the cross-dissolve -- no over-composite,
            // which would make the outgoing image show through the incoming
            // one's transparent parts at full strength for the whole transition.
            accumulated += phonoscope_centre_plane(glUV, imageFrom, uniforms.halfExtentFrom, false, uniforms)
                * (1.0 - weight);
        }
    }
    return accumulated;
}

struct PhonoscopeGlowUniforms {
    // Texel size on the blur axis only; the other component is zero. Unused by
    // the overlay pass.
    float2 axisTexel;
    // Gaussian sigma, in texels of the quarter-resolution blur target.
    float sigma;
    // 0-1.
    float opacity;
    // 1-10. Multiplies the glow's RGB.
    float overdrive;
    // 1 brings the overdriven glow back into 0-1; 0 lets it run to white.
    int glowClamped;
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
    // Overdrive multiplies the glow's RGB. Clamped, that saturates it;
    // unclamped the excess carries into the blend and blows out to white.
    float3 driven = max(glow.sample(linearSampler, in.uv).rgb
                            * clamp(uniforms.overdrive, 1.0, 10.0),
                        float3(0.0));
    float3 glowColor = uniforms.glowClamped != 0 ? min(driven, float3(1.0)) : driven;
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
