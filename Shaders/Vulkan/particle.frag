#version 450

layout(location = 0) in vec3 atlasUV;
layout(location = 1) in vec4 colorLight;
layout(set = 0, binding = 3) uniform sampler2DArray atlasTexture;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 texel = texture(atlasTexture, atlasUV);
    if (texel.a < 0.05) discard;
    float illumination = max(0.08, colorLight.a);
    outColor = vec4(texel.rgb * colorLight.rgb * illumination, texel.a);
}
