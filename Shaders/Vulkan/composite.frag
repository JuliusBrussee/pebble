#version 450

layout(location = 0) in vec2 uv;
layout(set = 0, binding = 0) uniform sampler2D sceneTexture;
layout(set = 0, binding = 1) uniform sampler2D bloomTexture;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 scene = texture(sceneTexture, uv).rgb;
    vec3 bloom = max(texture(bloomTexture, uv).rgb - vec3(0.82), vec3(0.0)) * 0.22;
    vec3 color = scene + bloom;
    vec3 mapped = clamp((color * (2.51 * color + 0.03)) /
                        (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
    outColor = vec4(mapped, 1.0);
}
