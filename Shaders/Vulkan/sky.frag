#version 450

layout(location = 0) in vec2 uv;
layout(push_constant) uniform SkyFrame {
    vec4 fogColor;
    vec4 lightTime;
    vec4 dimension;
} frame;
layout(location = 0) out vec4 outColor;

void main() {
    float day = clamp(frame.lightTime.x, 0.0, 1.0);
    float horizon = clamp(1.0 - abs(uv.y - 0.48) * 1.8, 0.0, 1.0);
    vec3 zenith = mix(vec3(0.008, 0.012, 0.035), vec3(0.18, 0.43, 0.82), day);
    vec3 sky = mix(zenith, frame.fogColor.rgb * 1.08, horizon);
    float angle = frame.lightTime.y * 0.006;
    vec2 sunPosition = vec2(0.5 + cos(angle) * 0.34, 0.52 - sin(angle) * 0.34);
    float sun = smoothstep(0.04, 0.0, distance(uv, sunPosition));
    sky += vec3(1.0, 0.72, 0.38) * sun * day;
    float stars = step(0.997, fract(sin(dot(floor(uv * vec2(480, 270)), vec2(12.9898, 78.233))) * 43758.5453));
    sky += vec3(stars * (1.0 - day) * 0.72);
    outColor = vec4(sky, 1.0);
}
