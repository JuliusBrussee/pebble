#version 450

layout(location = 0) in vec2 uv;
layout(set = 0, binding = 0) uniform sampler2D sceneTexture;
layout(set = 0, binding = 1) uniform sampler2D bloomTexture;
layout(push_constant) uniform CompositeFrame { vec4 params; } frame;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 scene = texture(sceneTexture, uv).rgb;
    float ultra = frame.params.y;
    vec3 bloom = max(texture(bloomTexture, uv).rgb - vec3(0.82), vec3(0.0)) * mix(0.08, 0.32, ultra);
    vec3 color = scene + bloom;
    vec3 mapped = clamp((color * (2.51 * color + 0.03)) /
                        (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
    mapped = pow(mapped, vec3(1.0 / max(0.35, frame.params.x)));
    if (ultra > 0.5) {
        vec2 centered = uv - 0.5;
        float vignette = 1.0 - smoothstep(0.28, 0.78, dot(centered, centered));
        mapped *= mix(0.72, 1.0, vignette);
    }
    outColor = vec4(mapped, 1.0);
}
