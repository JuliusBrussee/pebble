#version 450

layout(location = 0) in vec2 uv;
layout(set = 0, binding = 0) uniform sampler2D sceneTexture;
layout(set = 0, binding = 1) uniform sampler2D bloomTexture;
layout(push_constant) uniform CompositeFrame { vec4 params; } frame;
layout(location = 0) out vec4 outColor;

void main() {
    float darkness = clamp(frame.params.z, 0.0, 1.0);
    float portalWarp = clamp(frame.params.w, 0.0, 1.0);
    vec2 centeredUV = uv - 0.5;
    float radius = length(centeredUV);
    vec2 sampleUV = clamp(uv + centeredUV * sin(radius * 36.0) * portalWarp * 0.035, 0.0, 1.0);
    vec3 scene = texture(sceneTexture, sampleUV).rgb;
    float ultra = mod(floor(frame.params.y / 2.0), 2.0);
    float bloomEnabled = mod(floor(frame.params.y / 4.0), 2.0);
    vec3 bloom = max(texture(bloomTexture, uv).rgb - vec3(0.82), vec3(0.0)) *
                 mix(0.08, 0.32, ultra) * bloomEnabled;
    vec3 color = scene + bloom;
    vec3 mapped = clamp((color * (2.51 * color + 0.03)) /
                        (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
    mapped = pow(mapped, vec3(1.0 / max(0.35, frame.params.x)));
    mapped *= 1.0 - darkness * 0.82;
    if (ultra > 0.5) {
        vec2 centered = uv - 0.5;
        float vignette = 1.0 - smoothstep(0.28, 0.78, dot(centered, centered));
        mapped *= mix(0.72, 1.0, vignette);
    }
    outColor = vec4(mapped, 1.0);
}
