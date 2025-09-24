#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
    VertexOut out;
    
    // Create a fullscreen quad
    float2 positions[4] = {
        float2(-1, -1),  // bottom left
        float2( 1, -1),  // bottom right  
        float2(-1,  1),  // top left
        float2( 1,  1)   // top right
    };
    
    float2 texCoords[4] = {
        float2(0, 1),  // bottom left
        float2(1, 1),  // bottom right
        float2(0, 0),  // top left
        float2(1, 0)   // top right
    };
    
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                             texture2d<float> colorTexture [[texture(0)]],
                             texture2d<float> maskTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    if (colorTexture.get_width() == 0) {
        // Return transparent black if no texture
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    
    // Get texture dimensions and aspect ratio
    float textureWidth = float(colorTexture.get_width());
    float textureHeight = float(colorTexture.get_height());
    float textureAspect = textureWidth / textureHeight;
    
    // Calculate centered square coordinates
    float2 centeredCoord = in.texCoord;
    
    // Assume screen is wider than it is tall (landscape-ish)
    // Center the square image in the middle of the screen
    if (textureAspect > 1.0) {
        // Image is wider than tall - crop sides
        float cropAmount = (1.0 - (1.0 / textureAspect)) * 0.5;
        centeredCoord.x = centeredCoord.x * (1.0 / textureAspect) + cropAmount;
    } else if (textureAspect < 1.0) {
        // Image is taller than wide - crop top/bottom  
        float cropAmount = (1.0 - textureAspect) * 0.5;
        centeredCoord.y = centeredCoord.y * textureAspect + cropAmount;
    }
    
    // Check if we're outside the centered image bounds
    if (centeredCoord.x < 0.0 || centeredCoord.x > 1.0 || 
        centeredCoord.y < 0.0 || centeredCoord.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    
    // Sample the main color texture with centered coordinates
    float4 colorSample = colorTexture.sample(textureSampler, centeredCoord);
    
    // If we have a mask texture, use it for alpha cutoff
    if (maskTexture.get_width() > 0) {
        // Sample the mask texture (grayscale depth mask)
        float4 maskSample = maskTexture.sample(textureSampler, centeredCoord);
        float maskValue = (maskSample.r + maskSample.g + maskSample.b) / 3.0; // Average RGB for grayscale
        
        // Mask out very dark background pixels (close to black in the depth mask)
        if (maskValue < 0.1) {
            discard_fragment();
        }
        
        // Apply gradual alpha falloff for softer edges
        if (maskValue < 0.3) {
            colorSample.a *= (maskValue / 0.3);
        }
    }
    
    return colorSample;
}

// Simple test shaders for debugging particles
struct TestVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex TestVertexOut testParticleVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]]
) {
    TestVertexOut out;
    
    // Create a simple quad per instance
    float2 positions[4] = {
        float2(-0.05, -0.05), float2(0.05, -0.05), 
        float2(-0.05, 0.05), float2(0.05, 0.05)
    };
    
    uint quadVertex = vertexID % 4;
    
    // Offset each instance to a different position
    float x = float(instanceID % 10) * 0.15 - 0.7; // 10 across
    float y = float(instanceID / 10) * 0.15 - 0.7; // Multiple rows
    
    float2 instanceOffset = float2(x, y);
    out.position = float4(positions[quadVertex] + instanceOffset, 0.0, 1.0);
    
    // Color based on instance ID
    float r = float(instanceID % 255) / 255.0;
    float g = float((instanceID / 255) % 255) / 255.0;
    out.color = float4(r, g, 1.0, 1.0);
    
    return out;
}

fragment float4 testParticleFragment(TestVertexOut in [[stage_in]]) {
    return in.color;
}
