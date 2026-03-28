#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_ARB_gpu_shader_int64 : require

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;

layout(location = 0) out vec3 outNormal;
layout(location = 1) out vec2 outUV;
layout(location = 2) out vec3 outFactor;
layout(location = 3) out vec3 outLightVec;
layout(location = 4) out vec3 outViewVec;
layout(location = 5) flat out uint outInstanceIndex;

struct ShaderData {
    mat4 proj;
    mat4 view;
    mat4 model[3];
    vec4 lightPos;
    uint selected;
};

layout(push_constant) uniform PushConstants {
    uint64_t shaderDataAddress;
} pc;

layout(buffer_reference, scalar) readonly buffer ShaderDataRef {
    ShaderData data;
};

void main() {
    ShaderDataRef sd = ShaderDataRef(pc.shaderDataAddress);
    mat4 modelMat = sd.data.model[gl_InstanceIndex];
    outNormal = mat3(sd.data.view * modelMat) * inNormal;
    outUV = inUV;
    outFactor = vec3(sd.data.selected == gl_InstanceIndex ? 3.0 : 1.0);
    outInstanceIndex = gl_InstanceIndex;
    vec4 fragPos = sd.data.view * modelMat * vec4(inPos, 1.0);
    outLightVec = sd.data.lightPos.xyz - fragPos.xyz;
    outViewVec = -fragPos.xyz;
    gl_Position = sd.data.proj * fragPos;
}
