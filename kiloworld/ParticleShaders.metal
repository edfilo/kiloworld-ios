#include <metal_stdlib>
using namespace metal;

// Particle state structures
struct ParticleParams {
    float time;
    float dt;
    float release;          // R(t) from 0-1
    float softness;         // w
    float pop;              // impulse P
    float drift;            // flow amplitude A  
    float drag;             // drag lambda
    float flowScale;        // flow scale s
    float windY;
    float gravityY;
    float life;             // particle lifetime
    float fogDensity;       // k
    float3 fogColor;
    float softSize;
    float sharpSize;
    float sharpMix;
    float mbStretch;        // motion blur stretch M
    float dither;           // dither amplitude D
    float edgeBias;         // alpha_e
    uint seed;
    bool nearFirst;
    bool twoPass;
    float wipeDuration;     // T_w
    float depthAmount;      // Controls how much Z depth to apply from depth texture
    float globalSize;       // Global size multiplier for all particles
    float userScale;        // User zoom level
    float userRotationY;    // User Y rotation (horizontal drag)
    float userRotationX;    // User X rotation (vertical drag)
};

// Hash function for stable per-particle randomness
float hash(uint2 id, uint seed) {
    uint h = (id.x * 374761393U + id.y * 668265263U + seed * 1664525U) + 1013904223U;
    h ^= h >> 16;
    h *= 0x85ebca6bU;
    h ^= h >> 13;
    h *= 0xc2b2ae35U;
    h ^= h >> 16;
    return float(h) * (1.0/4294967296.0);
}

float3 hash3(uint2 id, uint seed) {
    return float3(
        hash(id, seed),
        hash(id, seed + 1U),
        hash(id, seed + 2U)
    ) * 2.0 - 1.0; // [-1,1]^3
}

// Smootherstep function
float smootherstep(float edge0, float edge1, float x) {
    x = saturate((x - edge0) / (edge1 - edge0));
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

// Release function R(t) with 5-second hold
float releaseFunction(float t, float wipeDuration) {
    if (t <= 0.0) return 1.0; // For reverse time (forming phase)
    if (t <= 5.0) return 0.0;
    if (t >= 5.0 + wipeDuration) return 1.0;
    return smootherstep(0.0, 1.0, (t - 5.0) / wipeDuration);
}

// Enhanced curl noise for dramatic flowing turbulence
float3 curlNoise(float3 p, float scale) {
    p *= scale;
    
    // Multi-octave noise for more complex flow patterns
    float3 flow1 = float3(
        sin(p.y * 3.7 + p.z * 2.3) * cos(p.x * 4.1),
        sin(p.z * 2.9 + p.x * 3.1) * cos(p.y * 3.7),
        sin(p.x * 4.3 + p.y * 2.7) * cos(p.z * 3.3)
    );
    
    // Add second octave for more complex patterns
    float3 p2 = p * 2.3;
    float3 flow2 = float3(
        sin(p2.y * 5.1 + p2.z * 3.7) * cos(p2.x * 6.3),
        sin(p2.z * 4.7 + p2.x * 5.9) * cos(p2.y * 7.1),
        sin(p2.x * 6.1 + p2.y * 4.3) * cos(p2.z * 5.7)
    ) * 0.5;
    
    // Add third octave for fine detail
    float3 p3 = p * 5.7;
    float3 flow3 = float3(
        sin(p3.y * 7.3 + p3.z * 6.1) * cos(p3.x * 8.7),
        sin(p3.z * 6.9 + p3.x * 7.7) * cos(p3.y * 9.3),
        sin(p3.x * 8.1 + p3.y * 7.9) * cos(p3.z * 8.9)
    ) * 0.25;
    
    return flow1 + flow2 + flow3;
}

kernel void updateParticles(
    texture2d<float, access::read> photoTexture [[texture(0)]],
    texture2d<float, access::read> depthTexture [[texture(1)]],
    texture2d<float, access::read> blueNoiseTexture [[texture(2)]],
    texture2d<float, access::read> posTexIn [[texture(3)]],
    texture2d<float, access::read> velTexIn [[texture(4)]],
    texture2d<float, access::write> posTexOut [[texture(5)]],
    texture2d<float, access::write> velTexOut [[texture(6)]],
    constant ParticleParams& params [[buffer(0)]],
    uint2 id [[thread_position_in_grid]]
) {
    // Use position texture size for UV calculation, not photo texture
    uint2 texSize = uint2(posTexIn.get_width(), posTexIn.get_height());
    if (id.x >= texSize.x || id.y >= texSize.y) return;
    
    float2 uv = (float2(id) + 0.5) / float2(texSize);
    
    // Read current state
    float4 posAge = posTexIn.read(id);
    float4 velReleased = velTexIn.read(id);
    
    float3 pos = posAge.xyz;
    float age = posAge.w;
    float3 vel = velReleased.xyz;
    float releasedPrev = velReleased.w;
    
    // Sample depth from the corrected depth texture
    uint2 maskTexSize = uint2(depthTexture.get_width(), depthTexture.get_height());
    float2 normalizedCoord = (float2(id) + 0.5) / float2(texSize);
    uint2 sampleCoord = uint2(normalizedCoord * float2(maskTexSize));
    sampleCoord = min(sampleCoord, maskTexSize - 1);
    
    float depth = depthTexture.read(sampleCoord).r;
    float m = params.nearFirst ? depth : (1.0 - depth);
    
    // Ensure background/masked pixels (depth near 0) also dissolve
    // Give them a small metric value so they release early
    if (depth < 0.1) {
        m = 0.1; // Background pixels release early
    }
    
    // Edge bias from photo luminance gradient (simplified)
    // For now, just use a constant edge bias - could implement gradient detection later
    float edgeBias = 0.0; // Placeholder for now
    
    // Blue noise dither
    uint2 noiseId = id % uint2(blueNoiseTexture.get_width(), blueNoiseTexture.get_height());
    float noise = blueNoiseTexture.read(noiseId).r * 2.0 - 1.0;
    float epsilon = noise * params.dither;
    
    // Calculate release metric
    float metric = saturate(m + params.edgeBias * edgeBias + epsilon);
    
    // Clear lifecycle: 3s formation + 2s dissolve + 2s pause + 6s reverse + 1s stable  
    float cycleDuration = 14.0; // 14 second cycle with slow reverse for debugging
    
    // Calculate where this particle is in its personal cycle (no offset here)
    float particleTime = fmod(params.time, cycleDuration);
    
    // For exact reverse path, we need to determine the "simulation time" for physics
    float simTime;
    float releasedFraction;
    bool isReversing = false;
    
    // Use consistent random distribution for deterministic reversal
    // Generate stable random value per particle for consistent timing
    float randomValue = hash(id, params.seed);
    
    // Apply power curve to weight toward earlier emission
    float weightedRandom = pow(randomValue, 2.5);
    float startOffset = weightedRandom * 3.0; // 0-3 seconds weighted toward early emission
    
    // CRITICAL: Use the SAME offset for both dissolve AND return phases
    // This ensures perfect deterministic reversal
    float adjustedTime = particleTime - startOffset;
    
    // Simplified particle lifecycle based on adjusted time
    if (adjustedTime < 0.0) {
        // Pre-start: Formation
        releasedFraction = 0.0;
        simTime = 0.0;
    } else if (adjustedTime < 3.0) {
        // Phase 1: Formation (0-3s)
        releasedFraction = 0.0;
        simTime = 0.0;
    } else if (adjustedTime < 5.0) {
        // Phase 2: Dissolving (3-5s) - simTime goes 0 to 2
        simTime = adjustedTime - 3.0;
        releasedFraction = 1.0;
    } else if (adjustedTime < 7.0) {
        // Phase 3: Pause at dissolved position (5-7s) - simTime stays at 2
        simTime = 2.0; // FROZEN at maximum dissolve
        releasedFraction = 1.0;
    } else if (adjustedTime < 13.0) {
        // Phase 4: Perfect reverse dissolve - particles return to formation
        float reverseProgress = (adjustedTime - 7.0) / 6.0; // 0 to 1 over 6 seconds
        
        // CRITICAL: Use simple linear mapping for perfect deterministic reversal
        // simTime goes from 2.0 back to 0.0 linearly over 6 seconds
        simTime = 2.0 * (1.0 - reverseProgress);
        
        // As particles get closer to formation (simTime -> 0), transition to formation
        if (simTime < 0.1) {
            // Smooth transition to formation when very close
            releasedFraction = simTime / 0.1; // Gradually reduce from 1.0 to 0.0
        } else {
            releasedFraction = 1.0; // Still dissolving
        }
        isReversing = true;
    } else {
        // Phase 5: Stable formation (13-14s)
        releasedFraction = 0.0;
        simTime = 0.0;
    }
    
    float released = (releasedFraction > 0.5) ? 1.0 : 0.0;
    
    // On-release impulse (one-shot when transitioning from held to released)
    if (releasedPrev == 0.0 && released == 1.0) {
        // Calculate depth normal (simplified)
        float3 normal = float3(0.0, 0.0, 1.0); // Placeholder - would need proper gradient
        
        // Jitter for impulse variation
        float3 jitter = hash3(id, params.seed);
        
        // Apply impulse
        float3 impulseDir = normalize(normal + 0.3 * jitter);
        vel += impulseDir * params.pop;
        
        // Reset age on release
        age = 0.0;
    }
    
    // Calculate 2D turtle position with controllable Z depth
    float3 flatPosition = float3(uv.x - 0.5, 0.5 - uv.y, 0.0); // Keep Y flip for correct orientation
    
    // Apply controlled depth - frontmost pixels stay at Z=0, darker pixels go back
    float normalizedDepth = saturate(depth); // Ensure 0-1 range
    
    // Move particles much closer to camera for perspective projection
    // Put base at Z=-2 so particles appear much larger with perspective
    float baseZ = -2.0; // Much closer to camera for larger appearance
    float maxDepth = 1.0; // Increased depth variation for perspective
    float zPosition = baseZ - (1.0 - normalizedDepth) * params.depthAmount * maxDepth;
    
    float3 cubePosition = float3(flatPosition.xy, zPosition);
    
    // Create 3D position including depth from depth texture
    float depthOffset = (normalizedDepth - 0.5) * params.depthAmount * maxDepth; // Center depth around 0
    float3 position3D = float3(flatPosition.x, flatPosition.y, depthOffset);
    
    // Apply Y rotation (horizontal drag) - rotate around Y axis (fixed direction)
    float cosY = cos(params.userRotationY), sinY = sin(params.userRotationY);
    float3 rotatedY = float3(
        position3D.x * cosY - position3D.z * sinY,
        position3D.y,
        position3D.x * sinY + position3D.z * cosY
    );
    
    // Apply X rotation (vertical drag) - rotate around X axis (reversed direction)
    float cosX = cos(params.userRotationX), sinX = sin(params.userRotationX);
    float3 rotatedXY = float3(
        rotatedY.x,
        rotatedY.y * cosX + rotatedY.z * sinX,
        -rotatedY.y * sinX + rotatedY.z * cosX
    );
    
    // Apply scale and translate to close Z position for perspective
    float3 rotatedCube = rotatedXY * params.userScale;
    rotatedCube.z += baseZ; // Move to close Z position after rotation for perspective effect
    
    // TEMPORARY: Disable all motion - keep particles static for gesture testing
    float3 basePosition = rotatedCube;
    
    // Perfect reverse dissolve - calculate exact position based on simulation time
    if (releasedFraction > 0.5) {
        // CRITICAL: Use deterministic physics based ONLY on simTime and particle ID
        // Same calculations work for both forward and reverse phases
        float3 particleRandom = hash3(id, params.seed);
        
        // Calculate depth normal for impulse direction
        float3 normal = float3(0.0, 0.0, 1.0); // Simplified normal
        float3 impulseDir = normalize(normal + 0.3 * particleRandom);
        
        // Much slower initial velocity for gentle floating
        float3 initialVel = impulseDir * (params.pop * 0.1); // Even gentler initial impulse
        
        // Much gentler turbulence for slower floating
        float3 turbulence = curlNoise(basePosition, params.flowScale) * (params.drift * 0.3); // Much reduced turbulence
        
        // Add very gentle floating patterns for slow drift
        float3 floatingBias = float3(
            sin(basePosition.y * 2.0 + params.time * 0.2) * 0.08,  // Slower horizontal drift
            cos(basePosition.x * 1.5 + params.time * 0.15) * 0.1,  // Slower vertical floating  
            sin(basePosition.x * 1.2 + basePosition.y * 1.8 + params.time * 0.1) * 0.05  // Slower depth floating
        );
        turbulence += floatingBias * params.drift * 0.2;
        
        // Apply drag over time: v(t) = v0 * exp(-drag * t)
        float dragFactor = exp(-params.drag * simTime);
        
        // Position: analytical integration ensures perfect determinism
        float3 draggedDisplacement;
        if (params.drag > 0.0001) {
            // Analytical integration: x(t) = (v0/drag) * (1 - exp(-drag * t))
            draggedDisplacement = (initialVel / params.drag) * (1.0 - dragFactor);
        } else {
            // No drag case: x(t) = v0 * t
            draggedDisplacement = initialVel * simTime;
        }
        
        // Add deterministic turbulence displacement
        draggedDisplacement += turbulence * simTime * 0.5;
        
        // Apply gravity - analytical solution
        draggedDisplacement.y += -params.gravityY * simTime * simTime * 0.5;
        
        // PERFECT REVERSAL: Same physics calculation works for both directions
        // Forward: simTime 0->2 moves particles away from basePosition
        // Reverse: simTime 2->0 brings particles back to basePosition
        float3 dissolvedPos = basePosition + draggedDisplacement;
        float3 dissolvedVel = (initialVel + turbulence) * dragFactor;
        
        // Smooth blend between dissolved position and formation position
        // as releasedFraction decreases from 1.0 to 0.0
        float blendFactor = saturate(releasedFraction);
        pos = mix(basePosition, dissolvedPos, blendFactor);
        vel = mix(float3(0.0), dissolvedVel, blendFactor);
        
        age = simTime;
    } else {
        // Formation phase - stay in wavy position
        pos = basePosition;
        vel = float3(0.0);
        age = 0.0;
    }
    
    // Write output
    posTexOut.write(float4(pos, age), id);
    velTexOut.write(float4(vel, released), id);
}

// Vertex shader output
struct ParticleVertexOut {
    float4 position [[position]];
    float point_size [[point_size]];
    float2 texCoord;
    float3 worldPos;
    float4 color;
    float size;
    float alpha;
    float released; // Add released state to pass to fragment shader
    float depth; // Add depth value for debugging
    float instanceID; // Pass instanceID for debugging
};

// Vertex shader for particle rendering with instanced quads
vertex ParticleVertexOut particleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    texture2d<float> photoTexture [[texture(0)]],
    texture2d<float> posTexture [[texture(1)]],
    texture2d<float> velTexture [[texture(2)]],
    texture2d<float> depthTexture [[texture(3)]],
    constant ParticleParams& params [[buffer(0)]],
    constant float4x4& mvpMatrix [[buffer(1)]]
) {
    ParticleVertexOut out;
    
    // Create quad vertices (4 vertices per particle)
    // vertexID: 0=bottom-left, 1=bottom-right, 2=top-left, 3=top-right
    float2 quadOffsets[4] = {
        float2(-1, -1), // bottom-left
        float2( 1, -1), // bottom-right
        float2(-1,  1), // top-left  
        float2( 1,  1)  // top-right
    };
    
    // For triangle strip, vertices are ordered: 0=bottom-left, 1=bottom-right, 2=top-left, 3=top-right
    // UV coordinates should map each vertex to proper 0-1 texture space for THIS particle
    float2 texCoords[4] = {
        float2(0, 0), // vertexID 0: bottom-left → UV (0,0)
        float2(1, 0), // vertexID 1: bottom-right → UV (1,0)  
        float2(0, 1), // vertexID 2: top-left → UV (0,1)
        float2(1, 1)  // vertexID 3: top-right → UV (1,1)
    };
    
    out.texCoord = texCoords[vertexID];
    
    // Get particle grid position
    uint2 texSize = uint2(posTexture.get_width(), posTexture.get_height());
    uint2 particleID = uint2(instanceID % texSize.x, instanceID / texSize.x);
    
    // DEBUG: Check if we have the right texture size
    if (instanceID < 10) {
        // This won't actually print in Metal shader, but helps us understand the logic
        // We expect texSize to be 300x300 and particleID to spread across that range
    }
    
    if (particleID.y >= texSize.y) {
        // Invalid particle - clip it
        out.position = float4(-2, -2, -2, 1);
        out.alpha = 0.0;
        return out;
    }
    
    // Read particle state from textures
    float4 posAge = posTexture.read(particleID);
    float4 velReleased = velTexture.read(particleID);
    
    float3 worldPos = posAge.xyz;
    float age = posAge.w;
    float released = velReleased.w;
    
    out.worldPos = worldPos;
    out.released = released; // Pass released state to fragment shader
    
    // TEMP: Let's verify the texture coordinate mapping
    // Show the raw texture coordinates as colors to debug the mapping
    float2 texCoord = (float2(particleID) + 0.5) / float2(texSize); // This should be 0-1
    
    // Map particle coordinates directly to full mask texture
    uint2 maskTexSize = uint2(depthTexture.get_width(), depthTexture.get_height());
    
    // Map our 300x300 particle grid directly to the mask texture dimensions
    float2 normalizedCoord = (float2(particleID) + 0.5) / float2(texSize); // 0-1 range
    uint2 sampleCoord = uint2(normalizedCoord * float2(maskTexSize));
    sampleCoord = min(sampleCoord, maskTexSize - 1);
    
    float4 depthSample = depthTexture.read(sampleCoord);
    float depth = depthSample.r;
    out.depth = depth;
    out.instanceID = float(instanceID); // Pass instanceID for debugging
    
    // Keep the per-particle UV coordinates we set earlier with texCoords[vertexID]
    // DON'T overwrite out.texCoord here - we want per-particle UVs, not grid UVs
    
    // Sample color from source photo with same coordinate transform as background
    float2 baseUV = (float2(particleID) + 0.5) / float2(texSize);
    // Keep baseUV as-is since particles and background should match exactly
    
    // Apply same aspect ratio correction as the background fragment shader
    float textureWidth = float(photoTexture.get_width());
    float textureHeight = float(photoTexture.get_height());
    float textureAspect = textureWidth / textureHeight;
    
    float2 centeredCoord = baseUV;
    if (textureAspect > 1.0) {
        // Image is wider than tall - crop sides (match background shader)
        float cropAmount = (1.0 - (1.0 / textureAspect)) * 0.5;
        centeredCoord.x = centeredCoord.x * (1.0 / textureAspect) + cropAmount;
    } else if (textureAspect < 1.0) {
        // Image is taller than wide - crop top/bottom (match background shader)
        float cropAmount = (1.0 - textureAspect) * 0.5;
        centeredCoord.y = centeredCoord.y * textureAspect + cropAmount;
    }
    
    // Sample color from source photo with aspect ratio correction
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    out.color = photoTexture.sample(textureSampler, centeredCoord);
    
    // Star-like particle sizing with varied sizes
    float particleRandom1 = hash(uint2(instanceID, 0), params.seed);
    float particleRandom2 = hash(uint2(instanceID, 1), params.seed + 100U);
    float particleRandom3 = hash(uint2(instanceID, 2), params.seed + 200U);
    
    // Create different star types based on random values
    float starType = particleRandom1;
    float baseStarSize;
    
    if (starType < 0.4) {
        // 40% tiny spec particles
        baseStarSize = 2.0 + particleRandom2 * 3.0; // 2.0-5.0 pixels
    } else if (starType < 0.7) {
        // 30% medium starlike particles
        baseStarSize = 5.0 + particleRandom2 * 8.0; // 5.0-13.0 pixels
    } else if (starType < 0.9) {
        // 20% large bright stars with glow
        baseStarSize = 12.0 + particleRandom2 * 15.0; // 12.0-27.0 pixels
    } else {
        // 10% giant stellar objects
        baseStarSize = 25.0 + particleRandom2 * 25.0; // 25.0-50.0 pixels
    }
    
    // Enhanced star twinkling based on star size
    float twinkleIntensity = saturate((baseStarSize - 4.0) / 20.0); // Larger stars twinkle more dramatically
    
    if (released == 1.0) {
        // Dissolving particles - dramatic stellar twinkling
        float fastTwinkle = sin(params.time * 15.0 + particleRandom2 * 6.28) * 0.5 + 0.5;
        float slowTwinkle = sin(params.time * 6.0 + particleRandom3 * 6.28) * 0.3 + 0.7;
        float pulseTwinkle = sin(params.time * 3.0 + particleRandom1 * 6.28) * 0.4 + 0.6;
        
        // Large stars get more dramatic pulsing - make giant stars REALLY twinkle
        float stellarBlink = fastTwinkle * slowTwinkle * pulseTwinkle;
        stellarBlink = mix(0.7, stellarBlink, twinkleIntensity); // Small stars stay more stable
        
        // Dramatic size variation for small pixel particles
        float extraTwinkle = 1.0;
        if (baseStarSize > 5.0) {
            // Largest stars (5-7px) get massive twinkling
            float megaTwinkle = sin(params.time * 8.0 + particleRandom1 * 6.28) * 0.5 + 0.5;
            float superBlink = cos(params.time * 12.0 + particleRandom3 * 6.28) * 0.4 + 0.6;
            extraTwinkle = 0.3 + (stellarBlink * megaTwinkle * superBlink) * 4.0; // Can grow to 5x size (35px max!)
        } else if (baseStarSize > 3.0) {
            // Medium stars (3-5px) get good variation
            float megaTwinkle = sin(params.time * 8.0 + particleRandom1 * 6.28) * 0.5 + 0.5;
            extraTwinkle = 0.4 + (stellarBlink * megaTwinkle) * 3.0; // Can grow to 3.4x size (17px max)
        } else if (baseStarSize > 2.0) {
            // Small stars (2-4px) get moderate variation
            extraTwinkle = 0.5 + stellarBlink * 2.5; // Can grow to 3x size (12px max)
        } else {
            // Tiny stars (1-2px) get subtle variation
            extraTwinkle = 0.6 + stellarBlink * 2.0; // Can grow to 2.6x size (5px max)
        }
        
        baseStarSize *= extraTwinkle;
    } else {
        // Formation - gentle stellar breathing with extra variation for large stars
        float breathe = sin(params.time * 2.5 + particleRandom1 * 6.28) * 0.15 + 0.85; // 0.7-1.0
        
        // Giant stars breathe more dramatically even in formation
        if (baseStarSize > 30.0) {
            float giantBreathe = sin(params.time * 1.8 + particleRandom1 * 6.28) * 0.25 + 0.75; // 0.5-1.0
            baseStarSize *= giantBreathe;
        } else {
            baseStarSize *= breathe;
        }
    }
    
    out.size = baseStarSize;
    out.point_size = baseStarSize; // Keep for compatibility but not used in quad rendering
    
    // Opacity over age  
    float normalizedAge = age / params.life;
    float ageAlpha = saturate(1.0 - normalizedAge);
    out.alpha = ageAlpha;
    
    // Always render particles - show them during hold period too
    // During hold (released == 0), particles should still be visible as the original image
    
    // Convert pixel size to world space for perspective projection
    // At Z=-2, we need to scale based on perspective projection and screen size
    float2 quadOffset = quadOffsets[vertexID];
    float pixelToWorldScale = 0.001; // Base scale for pixel sizes
    
    // Apply global size multiplier, then enforce minimum 1 pixel
    float scaledSize = baseStarSize * params.globalSize;
    float finalSize = max(scaledSize, 1.0); // Minimum 1 pixel after scaling
    float particleScale = finalSize * pixelToWorldScale;
    
    // Create billboard quad in screen space
    float3 billboardPos = worldPos + float3(quadOffset * particleScale, 0.0);
    
    // Transform to clip space using MVP matrix
    float4 clipPosition = mvpMatrix * float4(billboardPos, 1.0);
    
    out.position = clipPosition;
    
    // Make sure particles are visible during hold period
    if (released == 0.0) {
        out.alpha = 1.0; // Fully visible during hold
    } else if (age > params.life) {
        out.position = float4(-2, -2, -2, 1); // Clip old particles
        out.alpha = 0.0;
        return out;
    }
    
    out.alpha = 1.0;
    
    return out;
}

// Fragment shader for particle rendering with varied noise shapes
fragment float4 particleFragment(
    ParticleVertexOut in [[stage_in]],
    constant ParticleParams& params [[buffer(0)]]
) {
    // PROPER TEXTURE UV APPROACH - each particle uses 0-1 UV coordinates
    // in.texCoord ranges from (0,0) at bottom-left to (1,1) at top-right of THIS particle
    //float2 uv = in.texCoord; // Keep as 0-1 coordinates
    
    // Center of THIS particle in UV space is at (0.5, 0.5)
    //float2 center = float2(0.5, 0.5);
    //float distanceFromCenter = length(uv - center);
    
    // In 0-1 UV space, distance from center (0.5,0.5) to edge is 0.5, to corner is ~0.707
   // float circleAlpha = 1.0;
   // if (distanceFromCenter > 0.5) {
       // circleAlpha = 0.0; // Outside circle - transparent
   // } else {
       // circleAlpha = 1.0; // Inside circle - opaque
   // }
    
    // ** Enhanced Starlike Shapes with Glow **
    float2 uv = in.texCoord; // This is the UV within the current particle's quad (0 to 1)
    float2 center = float2(0.5, 0.5);
    float dist = length(uv - center); // Distance from the center of THIS quad
    
    // Determine particle shape based on size and random value
    float particleShapeRandom = hash(uint2(in.instanceID, 2), params.seed + 200U);
    float circleAlpha = 1.0;
    
    if (in.size < 8.0) {
        // Small specs - simple circular with soft glow
        float coreRadius = 0.2; // Larger bright core
        float glowRadius = 0.5;  // Fill most of the quad
        
        if (dist <= coreRadius) {
            circleAlpha = 1.0; // Bright center
        } else if (dist <= glowRadius) {
            // Smooth falloff for glow
            float falloff = (glowRadius - dist) / (glowRadius - coreRadius);
            circleAlpha = falloff * falloff * 0.8; // Squared falloff with dimming
        } else {
            circleAlpha = 0.0;
        }
        
    } else if (in.size < 20.0) {
        // Medium stars - varied shapes with glow
        float coreRadius = 0.15;
        float glowRadius = 0.5; // Fill the quad
        
        if (particleShapeRandom < 0.3) {
            // Cross/plus shape for some medium stars
            float2 centeredUV = uv - center;
            bool inCross = (abs(centeredUV.x) < 0.08 && abs(centeredUV.y) < 0.3) || 
                          (abs(centeredUV.y) < 0.08 && abs(centeredUV.x) < 0.3);
            if (inCross) {
                circleAlpha = dist < coreRadius ? 1.0 : (1.0 - smoothstep(0.1, glowRadius, dist)) * 0.7;
            } else {
                circleAlpha = 0.0;
            }
        } else {
            // Regular circular with enhanced glow
            if (dist <= coreRadius) {
                circleAlpha = 1.0;
            } else if (dist <= glowRadius) {
                float falloff = (glowRadius - dist) / (glowRadius - coreRadius);
                circleAlpha = falloff * falloff * 0.6;
            } else {
                circleAlpha = 0.0;
            }
        }
    } else {
        // Large stellar objects - complex shapes with extended glow
        float coreRadius = 0.1;
        float glowRadius = 0.5; // Fill entire quad
        
        if (particleShapeRandom < 0.2) {
            // Organic oval/elliptical specs - more natural looking
            float2 centeredUV = uv - center;
            
            // Create slightly elongated shapes with random orientation
            float elongation = 1.3 + particleShapeRandom * 0.4; // 1.3-1.7x elongation
            float rotationAngle = particleShapeRandom * 6.28; // Random rotation
            
            // Rotate coordinates
            float cosRot = cos(rotationAngle);
            float sinRot = sin(rotationAngle);
            float2 rotatedUV = float2(
                centeredUV.x * cosRot - centeredUV.y * sinRot,
                centeredUV.x * sinRot + centeredUV.y * cosRot
            );
            
            // Apply elongation to create oval shape
            rotatedUV.x *= elongation;
            float ovalDist = length(rotatedUV);
            
            if (ovalDist <= coreRadius * 2.5) {
                circleAlpha = 1.0; // Bright core
            } else if (ovalDist <= glowRadius * 0.9) {
                float falloff = (glowRadius * 0.9 - ovalDist) / (glowRadius * 0.9 - coreRadius * 2.5);
                circleAlpha = falloff * falloff * 0.6; // Soft glow
            } else {
                circleAlpha = 0.0;
            }
        } else {
            // Large circular with extensive glow field
            if (dist <= coreRadius) {
                circleAlpha = 1.0; // Bright core
            } else if (dist <= glowRadius) {
                float falloff = (glowRadius - dist) / (glowRadius - coreRadius);
                circleAlpha = falloff * falloff * falloff * 0.4; // Cubic falloff for extended glow
            } else {
                circleAlpha = 0.0;
            }
        }
    }
    
    // Discard very transparent pixels but allow glow falloff
    if (circleAlpha < 0.15) {
        discard_fragment();
    }
    
    float shapeAlpha = 1.0;
    
    // Base color from particle
    float4 color = in.color;
    
    // Apply mystical twinkling to ALL particles (both stable and dissolving)
    float particleRandom = hash(uint2(in.instanceID, 0), params.seed);
    float particleRandom2 = hash(uint2(in.instanceID, 1), params.seed + 100U);
    
    // Slower, more varied blinking speeds for starlike effect
    float blinkSpeed1 = 0.2 + particleRandom * 0.8; // 0.2-1.0 much slower
    float blinkSpeed2 = 0.1 + particleRandom2 * 0.6; // 0.1-0.7 very slow, varied
    
    float blink1 = sin(params.time * blinkSpeed1 + particleRandom * 6.28) * 0.5 + 0.5;
    float blink2 = cos(params.time * blinkSpeed2 + particleRandom2 * 6.28) * 0.5 + 0.5;
    float blink3 = sin(params.time * 0.4 + particleRandom * 3.14) * 0.5 + 0.5; // Third layer
    
    // Combine blinks for ~50% visibility
    float blinkThreshold = 0.5; // Medium threshold for ~50% visibility
    float combinedBlink = blink1 * blink2; // Two layers should give us ~50%
    
    // Hard cutoff - either fully visible or completely invisible (alpha = 0)
    float visibility = combinedBlink > blinkThreshold ? 1.0 : 0.0;
    
    // Discard invisible particles to prevent blocking
    if (visibility < 0.1) {
        discard_fragment();
    }
    
   // if (in.released == 1.0) {
        // Dissolving particles - brilliant white stellar effects
        // Calculate brightness based on particle size for stellar hierarchy
        float brightness = saturate((in.size - 2.0) / 40.0); // Larger particles are brighter
        
        // Multi-layered stellar twinkling
        float stellarShimmer = sin(params.time * 12.0 + particleRandom * 6.28) * 0.5 + 0.5;
        float stellarPulse = sin(params.time * 4.0 + particleRandom * 3.14) * 0.3 + 0.7;
        float stellarFlare = sin(params.time * 20.0 + particleRandom2 * 6.28) * 0.4 + 0.6;
        
        float stellarIntensity = stellarShimmer * stellarPulse;
        
        // Create subtle glow effect - preserve original colors more
        float glowAmount = mix(0.2, 0.6, brightness); // Much less white mixing
        float glowIntensity = mix(1.0, 1.3, brightness); // Subtle brightness boost
        
        // Enhance original colors with warm glow instead of making them white
        float3 warmGlow = float3(1.1, 1.05, 1.0); // Very subtle warm tint
        float3 stellarColor = color.rgb * mix(1.0, 1.4, glowAmount * stellarIntensity) * warmGlow;
        
        // Add subtle flares for large particles - preserve color more
        if (brightness > 0.7) { // Higher threshold, less white flares
            float flareIntensity = (brightness - 0.7) / 0.3 * stellarFlare;
            float3 colorFlare = stellarColor * float3(1.3, 1.25, 1.2); // Brighten original colors instead of white
            stellarColor = mix(stellarColor, colorFlare, flareIntensity * 0.4); // Much less flare mixing
        }
        
        // Enhanced bloom-like effect by boosting alpha and brightness
        float bloomEffect = saturate(brightness * 1.5 + stellarIntensity * 0.8);
        float alpha = in.alpha * visibility * circleAlpha * (0.9 + bloomEffect * 0.6);
        
        // Boost overall brightness for bloom-like glow
        stellarColor *= (1.0 + bloomEffect * 0.5);
        
        // For additive blending, modulate color by alpha instead of using alpha channel
        return float4(stellarColor * alpha, 1.0);
   // } else {
        // Formation particles - use same cool starlike shapes and glow
      //  return float4(color.rgb, circleAlpha);
  //  }
    //return float4(in.color.rgb, 1.0);
}
