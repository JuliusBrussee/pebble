#ifndef CPEBBLEVULKAN_H
#define CPEBBLEVULKAN_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PBVulkanContext PBVulkanContext;
typedef struct PBVulkanSwapchain PBVulkanSwapchain;
typedef struct PBVulkanMesh PBVulkanMesh;
typedef struct PBVulkanTexture PBVulkanTexture;
typedef struct PBVulkanChunkRenderer PBVulkanChunkRenderer;

typedef struct PBVulkanChunkDraw {
    PBVulkanMesh *mesh;
    float origin[4];
    uint32_t pipeline;
    uint32_t index_count;
    uint32_t first_index;
    int32_t vertex_offset;
} PBVulkanChunkDraw;

typedef struct PBVulkanUIDraw {
    PBVulkanMesh *mesh;
    float screen[4];
    uint32_t vertex_count;
    uint32_t first_vertex;
} PBVulkanUIDraw;

typedef struct PBVulkanEntityDraw {
    PBVulkanMesh *mesh;
    PBVulkanTexture *texture;
    float constants[32];
    float parts[384];
    uint32_t vertex_count;
    uint32_t first_vertex;
    uint32_t depth_mode;
} PBVulkanEntityDraw;

typedef struct PBVulkanParticleDraw {
    PBVulkanMesh *mesh;
    float constants[24];
    uint32_t instance_offset;
    uint32_t instance_count;
} PBVulkanParticleDraw;

typedef enum PBVulkanStatus {
    PB_VULKAN_OK = 0,
    PB_VULKAN_BAD_ARGUMENT = -1,
    PB_VULKAN_UNAVAILABLE = -2,
    PB_VULKAN_VALIDATION_UNAVAILABLE = -3,
    PB_VULKAN_INSTANCE_FAILED = -4,
    PB_VULKAN_DEVICE_FAILED = -5,
    PB_VULKAN_OUT_OF_MEMORY = -6,
    PB_VULKAN_RENDER_FAILED = -7,
    PB_VULKAN_OUT_OF_DATE = -8
} PBVulkanStatus;

typedef struct PBVulkanInfo {
    uint32_t struct_size;
    uint32_t api_version;
    uint32_t vendor_id;
    uint32_t device_id;
    uint32_t queue_family;
    uint32_t validation_enabled;
    uint32_t validation_message_count;
    uint32_t portability_enabled;
    char device_name[256];
} PBVulkanInfo;

PBVulkanStatus pb_vulkan_create(uint32_t enable_validation, PBVulkanContext **out_context);
PBVulkanStatus pb_vulkan_create_with_extensions(uint32_t enable_validation,
                                                const char * const *required_extensions,
                                                uint32_t required_extension_count,
                                                PBVulkanContext **out_context);
uintptr_t pb_vulkan_native_instance(PBVulkanContext *context);
void pb_vulkan_destroy(PBVulkanContext *context);
PBVulkanStatus pb_vulkan_get_info(PBVulkanContext *context, PBVulkanInfo *out_info);
void pb_vulkan_wait_idle(PBVulkanContext *context);
PBVulkanStatus pb_vulkan_render_clear(PBVulkanContext *context,
                                      uint32_t width, uint32_t height,
                                      float red, float green, float blue, float alpha,
                                      uint8_t *out_rgba, size_t out_size);
const char *pb_vulkan_last_error(void);
PBVulkanStatus pb_vulkan_swapchain_create(PBVulkanContext *context, uint64_t surface,
                                          uint32_t width, uint32_t height,
                                          PBVulkanSwapchain **out_swapchain);
PBVulkanStatus pb_vulkan_swapchain_resize(PBVulkanSwapchain *swapchain,
                                          uint32_t width, uint32_t height);
PBVulkanStatus pb_vulkan_swapchain_present_clear(PBVulkanSwapchain *swapchain,
                                                 float red, float green, float blue, float alpha);
void pb_vulkan_swapchain_destroy(PBVulkanSwapchain *swapchain);
PBVulkanStatus pb_vulkan_mesh_create(PBVulkanContext *context,
                                     const uint8_t *vertex_bytes, size_t vertex_size,
                                     const uint8_t *index_bytes, size_t index_size,
                                     uint32_t index_stride, PBVulkanMesh **out_mesh);
PBVulkanStatus pb_vulkan_mesh_update(PBVulkanMesh *mesh,
                                     const uint8_t *vertex_bytes, size_t vertex_size,
                                     const uint8_t *index_bytes, size_t index_size,
                                     uint32_t index_stride);
void pb_vulkan_mesh_destroy(PBVulkanMesh *mesh);
PBVulkanStatus pb_vulkan_texture_create_rgba8(PBVulkanContext *context,
                                              uint32_t width, uint32_t height, uint32_t layers,
                                              const uint8_t *rgba_bytes, size_t byte_count,
                                              PBVulkanTexture **out_texture);
PBVulkanStatus pb_vulkan_texture_update_rgba8(PBVulkanTexture *texture,
                                              const uint8_t *rgba_bytes, size_t byte_count);
void pb_vulkan_texture_destroy(PBVulkanTexture *texture);
PBVulkanStatus pb_vulkan_chunk_renderer_create(PBVulkanSwapchain *swapchain,
                                               const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                               const uint8_t *fragment_spirv, size_t fragment_spirv_size,
                                               PBVulkanChunkRenderer **out_renderer);
PBVulkanStatus pb_vulkan_chunk_renderer_set_atlas(PBVulkanChunkRenderer *renderer,
                                                  PBVulkanTexture *atlas);
PBVulkanStatus pb_vulkan_chunk_renderer_rebuild(PBVulkanChunkRenderer *renderer);
PBVulkanStatus pb_vulkan_chunk_renderer_install_ui(PBVulkanChunkRenderer *renderer,
                                                   const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                   const uint8_t *fragment_spirv, size_t fragment_spirv_size);
PBVulkanStatus pb_vulkan_chunk_renderer_install_shadow(PBVulkanChunkRenderer *renderer,
                                                       const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                       uint32_t shadow_size);
PBVulkanStatus pb_vulkan_chunk_renderer_install_entities(PBVulkanChunkRenderer *renderer,
                                                         const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                         const uint8_t *fragment_spirv, size_t fragment_spirv_size);
PBVulkanStatus pb_vulkan_chunk_renderer_install_particles(PBVulkanChunkRenderer *renderer,
                                                          const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                          const uint8_t *fragment_spirv, size_t fragment_spirv_size);
PBVulkanStatus pb_vulkan_chunk_renderer_install_postprocess(PBVulkanChunkRenderer *renderer,
                                                            const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                            const uint8_t *fragment_spirv, size_t fragment_spirv_size);
PBVulkanStatus pb_vulkan_chunk_renderer_install_sky(PBVulkanChunkRenderer *renderer,
                                                    const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                    const uint8_t *fragment_spirv, size_t fragment_spirv_size);
PBVulkanStatus pb_vulkan_chunk_renderer_set_ui_texture(PBVulkanChunkRenderer *renderer,
                                                       PBVulkanTexture *texture);
PBVulkanStatus pb_vulkan_chunk_renderer_present(PBVulkanChunkRenderer *renderer,
                                                const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                const PBVulkanChunkDraw *draws, uint32_t draw_count,
                                                float clear_red, float clear_green,
                                                float clear_blue, float clear_alpha);
PBVulkanStatus pb_vulkan_renderer_present_frame(PBVulkanChunkRenderer *renderer,
                                                const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                const PBVulkanChunkDraw *chunk_draws, uint32_t chunk_draw_count,
                                                const PBVulkanUIDraw *ui_draws, uint32_t ui_draw_count,
                                                float clear_red, float clear_green,
                                                float clear_blue, float clear_alpha);
PBVulkanStatus pb_vulkan_renderer_present_frame2(PBVulkanChunkRenderer *renderer,
                                                 const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                 const PBVulkanChunkDraw *chunk_draws, uint32_t chunk_draw_count,
                                                 const uint8_t *entity_view_projection, size_t entity_view_projection_size,
                                                 const PBVulkanEntityDraw *entity_draws, uint32_t entity_draw_count,
                                                 const PBVulkanUIDraw *ui_draws, uint32_t ui_draw_count,
                                                 float clear_red, float clear_green,
                                                 float clear_blue, float clear_alpha);
PBVulkanStatus pb_vulkan_renderer_present_frame3(PBVulkanChunkRenderer *renderer,
                                                 const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                 const PBVulkanChunkDraw *chunk_draws, uint32_t chunk_draw_count,
                                                 const uint8_t *entity_view_projection, size_t entity_view_projection_size,
                                                 const PBVulkanEntityDraw *entity_draws, uint32_t entity_draw_count,
                                                 const PBVulkanParticleDraw *particle_draws, uint32_t particle_draw_count,
                                                 const PBVulkanUIDraw *ui_draws, uint32_t ui_draw_count,
                                                 float clear_red, float clear_green,
                                                 float clear_blue, float clear_alpha);
PBVulkanStatus pb_vulkan_chunk_renderer_capture_rgba8(PBVulkanChunkRenderer *renderer,
                                                      uint8_t *out_rgba, size_t out_size);
void pb_vulkan_chunk_renderer_destroy(PBVulkanChunkRenderer *renderer);

#ifdef __cplusplus
}
#endif

#endif
