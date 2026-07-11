#version 450

layout(location = 0) in vec2 uv;
layout(set = 0, binding = 0) uniform sampler2D sceneTexture;
layout(set = 0, binding = 1) uniform sampler2D bloomTexture;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 scene = texture(sceneTexture, uv).rgb;
    vec3 bloom = texture(bloomTexture, uv).rgb;
    vec3 mapped = vec3(1.0) - exp(-(scene + bloom));
    outColor = vec4(mapped, 1.0);
}
