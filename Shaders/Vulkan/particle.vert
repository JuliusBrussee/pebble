#version 450

layout(location = 0) in vec2 inCorner;
layout(location = 1) in vec3 inPosition;
layout(location = 2) in vec4 inUVRect;
layout(location = 3) in float inLayerSize;
layout(location = 4) in vec4 inColorLight;

layout(push_constant) uniform ParticleFrame {
    mat4 viewProj;
    vec4 right;
    vec4 up;
} frame;

layout(location = 0) out vec3 atlasUV;
layout(location = 1) out vec4 colorLight;

void main() {
    float layer = floor(inLayerSize / 256.0);
    float size = mod(inLayerSize, 256.0) / 100.0;
    vec3 position = inPosition + frame.right.xyz * inCorner.x * size + frame.up.xyz * inCorner.y * size;
    gl_Position = frame.viewProj * vec4(position, 1.0);
    vec2 cornerUV = inCorner * 0.5 + 0.5;
    atlasUV = vec3(mix(inUVRect.xy, inUVRect.zw, cornerUV), layer);
    colorLight = inColorLight;
}
