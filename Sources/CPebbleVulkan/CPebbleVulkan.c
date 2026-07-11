#include "CPebbleVulkan.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#if defined(_MSC_VER)
#define PBVK_THREAD_LOCAL __declspec(thread)
#else
#define PBVK_THREAD_LOCAL _Thread_local
#endif

struct PBVulkanContext {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue graphics_queue;
    uint32_t queue_family;
    uint32_t validation_enabled;
    uint32_t validation_message_count;
    uint32_t portability_enabled;
    VkDebugUtilsMessengerEXT debug_messenger;
    VkPhysicalDeviceProperties properties;
};

struct PBVulkanSwapchain {
    PBVulkanContext *context;
    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat format;
    VkExtent2D extent;
    uint32_t image_count;
    VkImage *images;
    VkImageView *views;
    VkFramebuffer *framebuffers;
    VkRenderPass present_render_pass;
    VkImage scene_image;
    VkDeviceMemory scene_memory;
    VkImageView scene_view;
    VkFramebuffer scene_framebuffer;
    VkImage depth_image;
    VkDeviceMemory depth_memory;
    VkImageView depth_view;
    VkRenderPass render_pass;
    VkCommandPool command_pool;
    VkCommandBuffer *commands;
    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence frame_fence;
};

struct PBVulkanMesh {
    PBVulkanContext *context;
    VkBuffer vertex_buffer;
    VkDeviceMemory vertex_memory;
    VkBuffer index_buffer;
    VkDeviceMemory index_memory;
    size_t vertex_size;
    size_t index_size;
    uint32_t index_stride;
};

struct PBVulkanTexture {
    PBVulkanContext *context;
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkSampler sampler;
    uint32_t width;
    uint32_t height;
    uint32_t layers;
};

struct PBVulkanChunkRenderer {
    PBVulkanSwapchain *swapchain;
    VkDescriptorSetLayout descriptor_layout;
    VkPipelineLayout pipeline_layout;
    VkPipeline pipelines[3];
    VkPipeline shadow_pipeline;
    VkRenderPass shadow_render_pass;
    VkFramebuffer shadow_framebuffer;
    VkImage shadow_image;
    VkDeviceMemory shadow_memory;
    VkImageView shadow_view;
    VkSampler shadow_sampler;
    uint32_t shadow_size;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptor_set;
    VkBuffer uniform_buffer;
    VkDeviceMemory uniform_memory;
    PBVulkanTexture *atlas;
    PBVulkanTexture *ui_texture;
    VkDescriptorSetLayout ui_descriptor_layout;
    VkPipelineLayout ui_pipeline_layout;
    VkPipeline ui_pipeline;
    VkDescriptorPool ui_descriptor_pool;
    VkDescriptorSet ui_descriptor_set;
    uint8_t *vertex_spirv;
    size_t vertex_spirv_size;
    uint8_t *fragment_spirv;
    size_t fragment_spirv_size;
    uint8_t *ui_vertex_spirv;
    size_t ui_vertex_spirv_size;
    uint8_t *ui_fragment_spirv;
    size_t ui_fragment_spirv_size;
    uint8_t *shadow_vertex_spirv;
    size_t shadow_vertex_spirv_size;
    VkDescriptorSetLayout entity_descriptor_layout;
    VkPipelineLayout entity_pipeline_layout;
    VkPipeline entity_pipelines[2];
    VkPipeline entity_shadow_pipeline;
    VkDescriptorPool entity_descriptor_pool;
    VkBuffer entity_frame_buffer;
    VkDeviceMemory entity_frame_memory;
    VkBuffer entity_parts_buffer;
    VkDeviceMemory entity_parts_memory;
    uint8_t *entity_vertex_spirv;
    size_t entity_vertex_spirv_size;
    uint8_t *entity_fragment_spirv;
    size_t entity_fragment_spirv_size;
    uint8_t *entity_shadow_vertex_spirv;
    size_t entity_shadow_vertex_spirv_size;
    VkPipelineLayout particle_pipeline_layout;
    VkPipeline particle_pipeline;
    uint8_t *particle_vertex_spirv;
    size_t particle_vertex_spirv_size;
    uint8_t *particle_fragment_spirv;
    size_t particle_fragment_spirv_size;
    VkDescriptorSetLayout composite_descriptor_layout;
    VkPipelineLayout composite_pipeline_layout;
    VkPipeline composite_pipeline;
    VkDescriptorPool composite_descriptor_pool;
    VkDescriptorSet composite_descriptor_set;
    VkSampler composite_sampler;
    uint8_t *composite_vertex_spirv;
    size_t composite_vertex_spirv_size;
    uint8_t *composite_fragment_spirv;
    size_t composite_fragment_spirv_size;
    VkPipelineLayout sky_pipeline_layout;
    VkPipeline sky_pipeline;
    uint8_t *sky_vertex_spirv;
    size_t sky_vertex_spirv_size;
    uint8_t *sky_fragment_spirv;
    size_t sky_fragment_spirv_size;
};

static PBVK_THREAD_LOCAL char pbvk_error[512];

static VKAPI_ATTR VkBool32 VKAPI_CALL pbvk_debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT types,
    const VkDebugUtilsMessengerCallbackDataEXT *data,
    void *user_data) {
    (void)severity; (void)types; (void)data;
    PBVulkanContext *context = (PBVulkanContext *)user_data;
    if (context != NULL) context->validation_message_count++;
    return VK_FALSE;
}

static PBVulkanStatus pbvk_fail(PBVulkanStatus status, const char *message, VkResult result) {
    snprintf(pbvk_error, sizeof(pbvk_error), "%s (VkResult %d)", message, (int)result);
    return status;
}

static int pbvk_has_instance_extension(const char *name) {
    uint32_t count = 0;
    if (vkEnumerateInstanceExtensionProperties(NULL, &count, NULL) != VK_SUCCESS) return 0;
    VkExtensionProperties *items = (VkExtensionProperties *)calloc(count, sizeof(VkExtensionProperties));
    if (items == NULL) return 0;
    int found = 0;
    if (vkEnumerateInstanceExtensionProperties(NULL, &count, items) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count; i++) {
            if (strcmp(items[i].extensionName, name) == 0) { found = 1; break; }
        }
    }
    free(items);
    return found;
}

static int pbvk_has_layer(const char *name) {
    uint32_t count = 0;
    if (vkEnumerateInstanceLayerProperties(&count, NULL) != VK_SUCCESS) return 0;
    VkLayerProperties *items = (VkLayerProperties *)calloc(count, sizeof(VkLayerProperties));
    if (items == NULL) return 0;
    int found = 0;
    if (vkEnumerateInstanceLayerProperties(&count, items) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count; i++) {
            if (strcmp(items[i].layerName, name) == 0) { found = 1; break; }
        }
    }
    free(items);
    return found;
}

static int pbvk_device_has_extension(VkPhysicalDevice device, const char *name) {
    uint32_t count = 0;
    if (vkEnumerateDeviceExtensionProperties(device, NULL, &count, NULL) != VK_SUCCESS) return 0;
    VkExtensionProperties *items = (VkExtensionProperties *)calloc(count, sizeof(VkExtensionProperties));
    if (items == NULL) return 0;
    int found = 0;
    if (vkEnumerateDeviceExtensionProperties(device, NULL, &count, items) == VK_SUCCESS) {
        for (uint32_t i = 0; i < count; i++) {
            if (strcmp(items[i].extensionName, name) == 0) { found = 1; break; }
        }
    }
    free(items);
    return found;
}

PBVulkanStatus pb_vulkan_create(uint32_t enable_validation, PBVulkanContext **out_context) {
    return pb_vulkan_create_with_extensions(enable_validation, NULL, 0, out_context);
}

PBVulkanStatus pb_vulkan_create_with_extensions(uint32_t enable_validation,
                                                const char * const *required_extensions,
                                                uint32_t required_extension_count,
                                                PBVulkanContext **out_context) {
    if (out_context == NULL) return pbvk_fail(PB_VULKAN_BAD_ARGUMENT, "output context is null", VK_ERROR_UNKNOWN);
    if (required_extension_count > 0 && required_extensions == NULL) return pbvk_fail(PB_VULKAN_BAD_ARGUMENT, "extension array is null", VK_ERROR_UNKNOWN);
    *out_context = NULL;
    pbvk_error[0] = '\0';

    const char *validation_layer = "VK_LAYER_KHRONOS_validation";
    if (enable_validation && !pbvk_has_layer(validation_layer)) {
        return pbvk_fail(PB_VULKAN_VALIDATION_UNAVAILABLE, "VK_LAYER_KHRONOS_validation is unavailable", VK_ERROR_LAYER_NOT_PRESENT);
    }

    const int portability = pbvk_has_instance_extension(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    const uint32_t maximum_extensions = required_extension_count + 2;
    const char **instance_extensions = (const char **)calloc(maximum_extensions, sizeof(char *));
    if (instance_extensions == NULL) return pbvk_fail(PB_VULKAN_OUT_OF_MEMORY, "instance extension allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    uint32_t instance_extension_count = 0;
    for (uint32_t index = 0; index < required_extension_count; index++) {
        if (required_extensions[index] != NULL) instance_extensions[instance_extension_count++] = required_extensions[index];
    }
    if (portability) instance_extensions[instance_extension_count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
    if (enable_validation) {
        if (!pbvk_has_instance_extension(VK_EXT_DEBUG_UTILS_EXTENSION_NAME)) {
            free(instance_extensions);
            return pbvk_fail(PB_VULKAN_VALIDATION_UNAVAILABLE, "VK_EXT_debug_utils is unavailable", VK_ERROR_EXTENSION_NOT_PRESENT);
        }
        instance_extensions[instance_extension_count++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }

    VkApplicationInfo app = {0};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "Pebble";
    app.applicationVersion = VK_MAKE_API_VERSION(0, 1, 1, 0);
    app.pEngineName = "PebbleRendererVulkan";
    app.engineVersion = VK_MAKE_API_VERSION(0, 1, 0, 0);
    app.apiVersion = VK_API_VERSION_1_2;

    VkInstanceCreateInfo instance_info = {0};
    instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance_info.pApplicationInfo = &app;
    instance_info.flags = portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
    instance_info.enabledExtensionCount = instance_extension_count;
    instance_info.ppEnabledExtensionNames = instance_extensions;
    instance_info.enabledLayerCount = enable_validation ? 1 : 0;
    instance_info.ppEnabledLayerNames = enable_validation ? &validation_layer : NULL;

    PBVulkanContext *context = (PBVulkanContext *)calloc(1, sizeof(PBVulkanContext));
    if (context == NULL) {
        free(instance_extensions);
        return pbvk_fail(PB_VULKAN_OUT_OF_MEMORY, "context allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    }
    VkResult result = vkCreateInstance(&instance_info, NULL, &context->instance);
    free(instance_extensions);
    if (result != VK_SUCCESS) {
        free(context);
        return pbvk_fail(PB_VULKAN_INSTANCE_FAILED, "vkCreateInstance failed", result);
    }
    if (enable_validation) {
        PFN_vkCreateDebugUtilsMessengerEXT create_debug =
            (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(context->instance, "vkCreateDebugUtilsMessengerEXT");
        if (create_debug == NULL) {
            vkDestroyInstance(context->instance, NULL);
            free(context);
            return pbvk_fail(PB_VULKAN_VALIDATION_UNAVAILABLE, "vkCreateDebugUtilsMessengerEXT unavailable", VK_ERROR_EXTENSION_NOT_PRESENT);
        }
        VkDebugUtilsMessengerCreateInfoEXT debug_info = {0};
        debug_info.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
        debug_info.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                     VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        debug_info.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
        debug_info.pfnUserCallback = pbvk_debug_callback;
        debug_info.pUserData = context;
        result = create_debug(context->instance, &debug_info, NULL, &context->debug_messenger);
        if (result != VK_SUCCESS) {
            vkDestroyInstance(context->instance, NULL);
            free(context);
            return pbvk_fail(PB_VULKAN_VALIDATION_UNAVAILABLE, "debug messenger creation failed", result);
        }
    }

    uint32_t physical_count = 0;
    result = vkEnumeratePhysicalDevices(context->instance, &physical_count, NULL);
    if (result != VK_SUCCESS || physical_count == 0) {
        vkDestroyInstance(context->instance, NULL);
        free(context);
        return pbvk_fail(PB_VULKAN_UNAVAILABLE, "no Vulkan physical device", result);
    }
    VkPhysicalDevice *physical_devices = (VkPhysicalDevice *)calloc(physical_count, sizeof(VkPhysicalDevice));
    if (physical_devices == NULL) {
        vkDestroyInstance(context->instance, NULL);
        free(context);
        return pbvk_fail(PB_VULKAN_OUT_OF_MEMORY, "physical device allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    }
    vkEnumeratePhysicalDevices(context->instance, &physical_count, physical_devices);

    uint32_t queue_family = UINT32_MAX;
    for (uint32_t device_index = 0; device_index < physical_count && queue_family == UINT32_MAX; device_index++) {
        uint32_t queue_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(physical_devices[device_index], &queue_count, NULL);
        VkQueueFamilyProperties *queues = (VkQueueFamilyProperties *)calloc(queue_count, sizeof(VkQueueFamilyProperties));
        if (queues == NULL) continue;
        vkGetPhysicalDeviceQueueFamilyProperties(physical_devices[device_index], &queue_count, queues);
        for (uint32_t index = 0; index < queue_count; index++) {
            if ((queues[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                context->physical_device = physical_devices[device_index];
                queue_family = index;
                break;
            }
        }
        free(queues);
    }
    free(physical_devices);
    if (queue_family == UINT32_MAX) {
        vkDestroyInstance(context->instance, NULL);
        free(context);
        return pbvk_fail(PB_VULKAN_UNAVAILABLE, "no graphics queue family", VK_ERROR_FEATURE_NOT_PRESENT);
    }

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {0};
    queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = queue_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;

    const char *portability_subset_name = "VK_KHR_portability_subset";
    const int portability_subset = pbvk_device_has_extension(context->physical_device, portability_subset_name);
    const char *device_extensions[2];
    uint32_t device_extension_count = 0;
    if (portability_subset) device_extensions[device_extension_count++] = portability_subset_name;
    if (pbvk_device_has_extension(context->physical_device, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) {
        device_extensions[device_extension_count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    }

    VkDeviceCreateInfo device_info = {0};
    device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    device_info.enabledExtensionCount = device_extension_count;
    device_info.ppEnabledExtensionNames = device_extensions;
    result = vkCreateDevice(context->physical_device, &device_info, NULL, &context->device);
    if (result != VK_SUCCESS) {
        vkDestroyInstance(context->instance, NULL);
        free(context);
        return pbvk_fail(PB_VULKAN_DEVICE_FAILED, "vkCreateDevice failed", result);
    }
    vkGetDeviceQueue(context->device, queue_family, 0, &context->graphics_queue);
    if (enable_validation) {
        const uint32_t messages_before = context->validation_message_count;
        VkBuffer invalid_buffer = VK_NULL_HANDLE;
        VkBufferCreateInfo invalid_info = {0};
        invalid_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        invalid_info.size = 0;
        invalid_info.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        invalid_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        VkResult invalid_result = vkCreateBuffer(context->device, &invalid_info, NULL, &invalid_buffer);
        if (invalid_result == VK_SUCCESS) vkDestroyBuffer(context->device, invalid_buffer, NULL);
        if (context->validation_message_count == messages_before) {
            vkDestroyDevice(context->device, NULL);
            PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug =
                (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(context->instance, "vkDestroyDebugUtilsMessengerEXT");
            if (destroy_debug != NULL) destroy_debug(context->instance, context->debug_messenger, NULL);
            vkDestroyInstance(context->instance, NULL);
            free(context);
            return pbvk_fail(PB_VULKAN_VALIDATION_UNAVAILABLE,
                             "validation positive control emitted no VUID", VK_ERROR_VALIDATION_FAILED_EXT);
        }
    }
    context->queue_family = queue_family;
    context->validation_enabled = enable_validation ? 1u : 0u;
    context->portability_enabled = portability_subset ? 1u : 0u;
    vkGetPhysicalDeviceProperties(context->physical_device, &context->properties);
    *out_context = context;
    return PB_VULKAN_OK;
}

uintptr_t pb_vulkan_native_instance(PBVulkanContext *context) {
    return context == NULL ? 0 : (uintptr_t)context->instance;
}

void pb_vulkan_destroy(PBVulkanContext *context) {
    if (context == NULL) return;
    if (context->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(context->device);
        vkDestroyDevice(context->device, NULL);
    }
    if (context->debug_messenger != VK_NULL_HANDLE) {
        PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(context->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (destroy_debug != NULL) destroy_debug(context->instance, context->debug_messenger, NULL);
    }
    if (context->instance != VK_NULL_HANDLE) vkDestroyInstance(context->instance, NULL);
    free(context);
}

PBVulkanStatus pb_vulkan_get_info(PBVulkanContext *context, PBVulkanInfo *out_info) {
    if (context == NULL || out_info == NULL || out_info->struct_size < sizeof(PBVulkanInfo)) {
        return pbvk_fail(PB_VULKAN_BAD_ARGUMENT, "invalid info arguments", VK_ERROR_UNKNOWN);
    }
    memset(out_info, 0, sizeof(PBVulkanInfo));
    out_info->struct_size = (uint32_t)sizeof(PBVulkanInfo);
    out_info->api_version = context->properties.apiVersion;
    out_info->vendor_id = context->properties.vendorID;
    out_info->device_id = context->properties.deviceID;
    out_info->queue_family = context->queue_family;
    out_info->validation_enabled = context->validation_enabled;
    out_info->validation_message_count = context->validation_message_count;
    out_info->portability_enabled = context->portability_enabled;
    strncpy(out_info->device_name, context->properties.deviceName, sizeof(out_info->device_name) - 1);
    return PB_VULKAN_OK;
}

void pb_vulkan_wait_idle(PBVulkanContext *context) {
    if (context != NULL && context->device != VK_NULL_HANDLE) vkDeviceWaitIdle(context->device);
}

static uint32_t pbvk_memory_type(PBVulkanContext *context, uint32_t bits, VkMemoryPropertyFlags required) {
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(context->physical_device, &properties);
    for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
        if ((bits & (1u << index)) != 0 &&
            (properties.memoryTypes[index].propertyFlags & required) == required) return index;
    }
    return UINT32_MAX;
}

static VkResult pbvk_buffer_create(PBVulkanContext *context, VkDeviceSize size,
                                   VkBufferUsageFlags usage, VkMemoryPropertyFlags properties,
                                   VkBuffer *out_buffer, VkDeviceMemory *out_memory) {
    VkBufferCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = size;
    info.usage = usage;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult result = vkCreateBuffer(context->device, &info, NULL, out_buffer);
    if (result != VK_SUCCESS) return result;
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(context->device, *out_buffer, &requirements);
    uint32_t memory_type = pbvk_memory_type(context, requirements.memoryTypeBits, properties);
    if (memory_type == UINT32_MAX) {
        vkDestroyBuffer(context->device, *out_buffer, NULL);
        *out_buffer = VK_NULL_HANDLE;
        return VK_ERROR_FEATURE_NOT_PRESENT;
    }
    VkMemoryAllocateInfo allocation = {0};
    allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocation.allocationSize = requirements.size;
    allocation.memoryTypeIndex = memory_type;
    result = vkAllocateMemory(context->device, &allocation, NULL, out_memory);
    if (result != VK_SUCCESS) {
        vkDestroyBuffer(context->device, *out_buffer, NULL);
        *out_buffer = VK_NULL_HANDLE;
        return result;
    }
    result = vkBindBufferMemory(context->device, *out_buffer, *out_memory, 0);
    if (result != VK_SUCCESS) {
        vkFreeMemory(context->device, *out_memory, NULL);
        vkDestroyBuffer(context->device, *out_buffer, NULL);
        *out_memory = VK_NULL_HANDLE;
        *out_buffer = VK_NULL_HANDLE;
    }
    return result;
}

static VkResult pbvk_memory_write(PBVulkanContext *context, VkDeviceMemory memory,
                                  const uint8_t *bytes, size_t count) {
    void *mapped = NULL;
    VkResult result = vkMapMemory(context->device, memory, 0, count, 0, &mapped);
    if (result != VK_SUCCESS) return result;
    memcpy(mapped, bytes, count);
    vkUnmapMemory(context->device, memory);
    return VK_SUCCESS;
}

static VkResult pbvk_memory_write_at(PBVulkanContext *context, VkDeviceMemory memory,
                                     VkDeviceSize offset, const uint8_t *bytes, size_t count) {
    void *mapped = NULL;
    VkResult result = vkMapMemory(context->device, memory, offset, count, 0, &mapped);
    if (result != VK_SUCCESS) return result;
    memcpy(mapped, bytes, count);
    vkUnmapMemory(context->device, memory);
    return VK_SUCCESS;
}

static void pbvk_mesh_buffers_release(PBVulkanMesh *mesh) {
    VkDevice device = mesh->context->device;
    if (mesh->vertex_buffer != VK_NULL_HANDLE) vkDestroyBuffer(device, mesh->vertex_buffer, NULL);
    if (mesh->vertex_memory != VK_NULL_HANDLE) vkFreeMemory(device, mesh->vertex_memory, NULL);
    if (mesh->index_buffer != VK_NULL_HANDLE) vkDestroyBuffer(device, mesh->index_buffer, NULL);
    if (mesh->index_memory != VK_NULL_HANDLE) vkFreeMemory(device, mesh->index_memory, NULL);
    mesh->vertex_buffer = VK_NULL_HANDLE;
    mesh->vertex_memory = VK_NULL_HANDLE;
    mesh->index_buffer = VK_NULL_HANDLE;
    mesh->index_memory = VK_NULL_HANDLE;
    mesh->vertex_size = 0;
    mesh->index_size = 0;
}

static PBVulkanStatus pbvk_mesh_fill(PBVulkanMesh *mesh,
                                     const uint8_t *vertex_bytes, size_t vertex_size,
                                     const uint8_t *index_bytes, size_t index_size,
                                     uint32_t index_stride) {
    PBVulkanContext *context = mesh->context;
    VkResult result = pbvk_buffer_create(context, vertex_size, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                         &mesh->vertex_buffer, &mesh->vertex_memory);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "vertex buffer creation failed", result);
    result = pbvk_memory_write(context, mesh->vertex_memory, vertex_bytes, vertex_size);
    if (result != VK_SUCCESS) { pbvk_mesh_buffers_release(mesh); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "vertex upload failed", result); }
    if (index_size > 0) {
        result = pbvk_buffer_create(context, index_size, VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                    &mesh->index_buffer, &mesh->index_memory);
        if (result != VK_SUCCESS) { pbvk_mesh_buffers_release(mesh); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "index buffer creation failed", result); }
        result = pbvk_memory_write(context, mesh->index_memory, index_bytes, index_size);
        if (result != VK_SUCCESS) { pbvk_mesh_buffers_release(mesh); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "index upload failed", result); }
    }
    mesh->vertex_size = vertex_size;
    mesh->index_size = index_size;
    mesh->index_stride = index_stride;
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_mesh_create(PBVulkanContext *context,
                                     const uint8_t *vertex_bytes, size_t vertex_size,
                                     const uint8_t *index_bytes, size_t index_size,
                                     uint32_t index_stride, PBVulkanMesh **out_mesh) {
    if (context == NULL || vertex_bytes == NULL || vertex_size == 0 || out_mesh == NULL ||
        (index_size > 0 && index_bytes == NULL) || (index_size > 0 && index_stride != 2 && index_stride != 4)) {
        return PB_VULKAN_BAD_ARGUMENT;
    }
    *out_mesh = NULL;
    PBVulkanMesh *mesh = (PBVulkanMesh *)calloc(1, sizeof(PBVulkanMesh));
    if (mesh == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    mesh->context = context;
    PBVulkanStatus status = pbvk_mesh_fill(mesh, vertex_bytes, vertex_size, index_bytes, index_size, index_stride);
    if (status != PB_VULKAN_OK) { free(mesh); return status; }
    *out_mesh = mesh;
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_mesh_update(PBVulkanMesh *mesh,
                                     const uint8_t *vertex_bytes, size_t vertex_size,
                                     const uint8_t *index_bytes, size_t index_size,
                                     uint32_t index_stride) {
    if (mesh == NULL || vertex_bytes == NULL || vertex_size == 0 ||
        (index_size > 0 && index_bytes == NULL) || (index_size > 0 && index_stride != 2 && index_stride != 4)) return PB_VULKAN_BAD_ARGUMENT;
    vkDeviceWaitIdle(mesh->context->device);
    if (vertex_size <= mesh->vertex_size && index_size <= mesh->index_size && index_stride == mesh->index_stride) {
        VkResult result = pbvk_memory_write(mesh->context, mesh->vertex_memory, vertex_bytes, vertex_size);
        if (result == VK_SUCCESS && index_size > 0) result = pbvk_memory_write(mesh->context, mesh->index_memory, index_bytes, index_size);
        if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "mesh update failed", result);
        return PB_VULKAN_OK;
    }
    pbvk_mesh_buffers_release(mesh);
    return pbvk_mesh_fill(mesh, vertex_bytes, vertex_size, index_bytes, index_size, index_stride);
}

void pb_vulkan_mesh_destroy(PBVulkanMesh *mesh) {
    if (mesh == NULL) return;
    vkDeviceWaitIdle(mesh->context->device);
    pbvk_mesh_buffers_release(mesh);
    free(mesh);
}

static VkResult pbvk_begin_one_time(PBVulkanContext *context, VkCommandPool *out_pool, VkCommandBuffer *out_command) {
    VkCommandPoolCreateInfo pool = {0};
    pool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    pool.queueFamilyIndex = context->queue_family;
    VkResult result = vkCreateCommandPool(context->device, &pool, NULL, out_pool);
    if (result != VK_SUCCESS) return result;
    VkCommandBufferAllocateInfo allocation = {0};
    allocation.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocation.commandPool = *out_pool;
    allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocation.commandBufferCount = 1;
    result = vkAllocateCommandBuffers(context->device, &allocation, out_command);
    if (result != VK_SUCCESS) { vkDestroyCommandPool(context->device, *out_pool, NULL); return result; }
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    return vkBeginCommandBuffer(*out_command, &begin);
}

static VkResult pbvk_end_one_time(PBVulkanContext *context, VkCommandPool pool, VkCommandBuffer command) {
    VkResult result = vkEndCommandBuffer(command);
    if (result == VK_SUCCESS) {
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &command;
        result = vkQueueSubmit(context->graphics_queue, 1, &submit, VK_NULL_HANDLE);
        if (result == VK_SUCCESS) result = vkQueueWaitIdle(context->graphics_queue);
    }
    vkDestroyCommandPool(context->device, pool, NULL);
    return result;
}

static PBVulkanStatus pbvk_texture_upload(PBVulkanTexture *texture, const uint8_t *bytes,
                                          size_t count, VkImageLayout old_layout) {
    PBVulkanContext *context = texture->context;
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkResult result = pbvk_buffer_create(context, count, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                         &staging, &memory);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "texture staging creation failed", result);
    result = pbvk_memory_write(context, memory, bytes, count);
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    if (result == VK_SUCCESS) result = pbvk_begin_one_time(context, &pool, &command);
    if (result == VK_SUCCESS) {
        VkImageMemoryBarrier to_copy = {0};
        to_copy.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_copy.srcAccessMask = old_layout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL ? VK_ACCESS_SHADER_READ_BIT : 0;
        to_copy.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        to_copy.oldLayout = old_layout;
        to_copy.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_copy.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_copy.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_copy.image = texture->image;
        to_copy.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        to_copy.subresourceRange.levelCount = 1;
        to_copy.subresourceRange.layerCount = texture->layers;
        vkCmdPipelineBarrier(command,
                             old_layout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL ? VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_copy);
        VkBufferImageCopy copy = {0};
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = texture->layers;
        copy.imageExtent.width = texture->width;
        copy.imageExtent.height = texture->height;
        copy.imageExtent.depth = 1;
        vkCmdCopyBufferToImage(command, staging, texture->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        VkImageMemoryBarrier to_shader = to_copy;
        to_shader.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        to_shader.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        to_shader.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_shader.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, NULL, 0, NULL, 1, &to_shader);
        result = pbvk_end_one_time(context, pool, command);
    }
    vkDestroyBuffer(context->device, staging, NULL);
    vkFreeMemory(context->device, memory, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK : pbvk_fail(PB_VULKAN_RENDER_FAILED, "texture upload failed", result);
}

PBVulkanStatus pb_vulkan_texture_create_rgba8(PBVulkanContext *context,
                                              uint32_t width, uint32_t height, uint32_t layers,
                                              const uint8_t *rgba_bytes, size_t byte_count,
                                              PBVulkanTexture **out_texture) {
    const uint64_t required = (uint64_t)width * height * layers * 4u;
    if (context == NULL || width == 0 || height == 0 || layers == 0 || rgba_bytes == NULL ||
        required != byte_count || out_texture == NULL) return PB_VULKAN_BAD_ARGUMENT;
    *out_texture = NULL;
    PBVulkanTexture *texture = (PBVulkanTexture *)calloc(1, sizeof(PBVulkanTexture));
    if (texture == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    texture->context = context;
    texture->width = width;
    texture->height = height;
    texture->layers = layers;
    VkImageCreateInfo image = {0};
    image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image.imageType = VK_IMAGE_TYPE_2D;
    image.format = VK_FORMAT_R8G8B8A8_UNORM;
    image.extent.width = width; image.extent.height = height; image.extent.depth = 1;
    image.mipLevels = 1; image.arrayLayers = layers; image.samples = VK_SAMPLE_COUNT_1_BIT;
    image.tiling = VK_IMAGE_TILING_OPTIMAL;
    image.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult result = vkCreateImage(context->device, &image, NULL, &texture->image);
    if (result != VK_SUCCESS) { free(texture); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "texture image creation failed", result); }
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(context->device, texture->image, &requirements);
    uint32_t memory_type = pbvk_memory_type(context, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (memory_type == UINT32_MAX) memory_type = pbvk_memory_type(context, requirements.memoryTypeBits, 0);
    VkMemoryAllocateInfo allocation = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocation.allocationSize = requirements.size;
    allocation.memoryTypeIndex = memory_type;
    result = memory_type == UINT32_MAX ? VK_ERROR_FEATURE_NOT_PRESENT : vkAllocateMemory(context->device, &allocation, NULL, &texture->memory);
    if (result == VK_SUCCESS) result = vkBindImageMemory(context->device, texture->image, texture->memory, 0);
    if (result != VK_SUCCESS) { pb_vulkan_texture_destroy(texture); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "texture memory creation failed", result); }
    VkImageViewCreateInfo view = {0};
    view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view.image = texture->image;
    view.viewType = layers > 1 ? VK_IMAGE_VIEW_TYPE_2D_ARRAY : VK_IMAGE_VIEW_TYPE_2D;
    view.format = VK_FORMAT_R8G8B8A8_UNORM;
    view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view.subresourceRange.levelCount = 1;
    view.subresourceRange.layerCount = layers;
    result = vkCreateImageView(context->device, &view, NULL, &texture->view);
    VkSamplerCreateInfo sampler = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sampler.magFilter = VK_FILTER_NEAREST; sampler.minFilter = VK_FILTER_NEAREST;
    sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
    sampler.maxLod = 0;
    if (result == VK_SUCCESS) result = vkCreateSampler(context->device, &sampler, NULL, &texture->sampler);
    if (result != VK_SUCCESS) { pb_vulkan_texture_destroy(texture); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "texture view/sampler creation failed", result); }
    PBVulkanStatus status = pbvk_texture_upload(texture, rgba_bytes, byte_count, VK_IMAGE_LAYOUT_UNDEFINED);
    if (status != PB_VULKAN_OK) { pb_vulkan_texture_destroy(texture); return status; }
    *out_texture = texture;
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_texture_update_rgba8(PBVulkanTexture *texture,
                                              const uint8_t *rgba_bytes, size_t byte_count) {
    if (texture == NULL || rgba_bytes == NULL || byte_count != (size_t)texture->width * texture->height * texture->layers * 4u) return PB_VULKAN_BAD_ARGUMENT;
    vkDeviceWaitIdle(texture->context->device);
    return pbvk_texture_upload(texture, rgba_bytes, byte_count, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
}

void pb_vulkan_texture_destroy(PBVulkanTexture *texture) {
    if (texture == NULL) return;
    VkDevice device = texture->context->device;
    vkDeviceWaitIdle(device);
    if (texture->sampler != VK_NULL_HANDLE) vkDestroySampler(device, texture->sampler, NULL);
    if (texture->view != VK_NULL_HANDLE) vkDestroyImageView(device, texture->view, NULL);
    if (texture->image != VK_NULL_HANDLE) vkDestroyImage(device, texture->image, NULL);
    if (texture->memory != VK_NULL_HANDLE) vkFreeMemory(device, texture->memory, NULL);
    free(texture);
}

static VkShaderModule pbvk_shader_module(PBVulkanContext *context, const uint8_t *bytes, size_t count) {
    if (bytes == NULL || count == 0 || (count & 3u) != 0) return VK_NULL_HANDLE;
    VkShaderModuleCreateInfo info = {0};
    info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = count;
    info.pCode = (const uint32_t *)bytes;
    VkShaderModule module = VK_NULL_HANDLE;
    return vkCreateShaderModule(context->device, &info, NULL, &module) == VK_SUCCESS ? module : VK_NULL_HANDLE;
}

static void pbvk_chunk_pipelines_release(PBVulkanChunkRenderer *renderer) {
    VkDevice device = renderer->swapchain->context->device;
    for (uint32_t index = 0; index < 3; index++) {
        if (renderer->pipelines[index] != VK_NULL_HANDLE) vkDestroyPipeline(device, renderer->pipelines[index], NULL);
        renderer->pipelines[index] = VK_NULL_HANDLE;
    }
}

static void pbvk_ui_pipeline_release(PBVulkanChunkRenderer *renderer) {
    if (renderer->ui_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(renderer->swapchain->context->device, renderer->ui_pipeline, NULL);
        renderer->ui_pipeline = VK_NULL_HANDLE;
    }
}

static PBVulkanStatus pbvk_ui_pipeline_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->ui_vertex_spirv == NULL || renderer->ui_fragment_spirv == NULL) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->ui_vertex_spirv, renderer->ui_vertex_spirv_size);
    VkShaderModule fragment = pbvk_shader_module(context, renderer->ui_fragment_spirv, renderer->ui_fragment_spirv_size);
    if (vertex == VK_NULL_HANDLE || fragment == VK_NULL_HANDLE) {
        if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
        if (fragment != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, fragment, NULL);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "UI shader module creation failed", VK_ERROR_UNKNOWN);
    }
    VkPipelineShaderStageCreateInfo stages[2];
    memset(stages, 0, sizeof(stages));
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vertex; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fragment; stages[1].pName = "main";
    VkVertexInputBindingDescription binding = {0, 32, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[3] = {
        {0, 0, VK_FORMAT_R32G32_SFLOAT, 0},
        {1, 0, VK_FORMAT_R32G32_SFLOAT, 8},
        {2, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 16},
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertex_input.vertexBindingDescriptionCount = 1; vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 3; vertex_input.pVertexAttributeDescriptions = attributes;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_FALSE;
    VkPipelineColorBlendAttachmentState attachment = {0};
    attachment.blendEnable = VK_TRUE;
    attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.colorBlendOp = VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.alphaBlendOp = VK_BLEND_OP_ADD;
    attachment.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1; blend.pAttachments = &attachment;
    VkDynamicState states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2; pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pDepthStencilState = &depth;
    pipeline.pColorBlendState = &blend; pipeline.pDynamicState = &dynamic;
    pipeline.layout = renderer->ui_pipeline_layout;
    pipeline.renderPass = renderer->swapchain->render_pass;
    VkResult result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL, &renderer->ui_pipeline);
    vkDestroyShaderModule(context->device, vertex, NULL);
    vkDestroyShaderModule(context->device, fragment, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK : pbvk_fail(PB_VULKAN_RENDER_FAILED, "UI graphics pipeline creation failed", result);
}

static void pbvk_entity_pipeline_release(PBVulkanChunkRenderer *renderer) {
    for (uint32_t index = 0; index < 2; index++) {
        if (renderer->entity_pipelines[index] != VK_NULL_HANDLE) {
            vkDestroyPipeline(renderer->swapchain->context->device, renderer->entity_pipelines[index], NULL);
            renderer->entity_pipelines[index] = VK_NULL_HANDLE;
        }
    }
    if (renderer->entity_shadow_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(renderer->swapchain->context->device, renderer->entity_shadow_pipeline, NULL);
        renderer->entity_shadow_pipeline = VK_NULL_HANDLE;
    }
}

static PBVulkanStatus pbvk_entity_pipeline_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->entity_vertex_spirv == NULL || renderer->entity_fragment_spirv == NULL) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->entity_vertex_spirv,
                                                renderer->entity_vertex_spirv_size);
    VkShaderModule fragment = pbvk_shader_module(context, renderer->entity_fragment_spirv,
                                                  renderer->entity_fragment_spirv_size);
    if (vertex == VK_NULL_HANDLE || fragment == VK_NULL_HANDLE) {
        if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
        if (fragment != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, fragment, NULL);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "entity shader module creation failed", VK_ERROR_UNKNOWN);
    }
    VkPipelineShaderStageCreateInfo stages[2];
    memset(stages, 0, sizeof(stages));
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vertex; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fragment; stages[1].pName = "main";
    VkVertexInputBindingDescription binding = {0, 36, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[4] = {
        {0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0},
        {1, 0, VK_FORMAT_R32G32B32_SFLOAT, 12},
        {2, 0, VK_FORMAT_R32G32_SFLOAT, 24},
        {3, 0, VK_FORMAT_R32_SFLOAT, 32},
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertex_input.vertexBindingDescriptionCount = 1; vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 4; vertex_input.pVertexAttributeDescriptions = attributes;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_BACK_BIT;
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE; raster.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_TRUE; depth.depthWriteEnable = VK_TRUE;
    depth.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    VkPipelineColorBlendAttachmentState attachment = {0};
    attachment.blendEnable = VK_TRUE;
    attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.colorBlendOp = VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.alphaBlendOp = VK_BLEND_OP_ADD;
    attachment.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1; blend.pAttachments = &attachment;
    VkDynamicState states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2; pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pDepthStencilState = &depth;
    pipeline.pColorBlendState = &blend; pipeline.pDynamicState = &dynamic;
    pipeline.layout = renderer->entity_pipeline_layout;
    pipeline.renderPass = renderer->swapchain->render_pass;
    VkResult result = VK_SUCCESS;
    for (uint32_t index = 0; index < 2 && result == VK_SUCCESS; index++) {
        depth.depthTestEnable = index == 0 ? VK_TRUE : VK_FALSE;
        depth.depthWriteEnable = index == 0 ? VK_TRUE : VK_FALSE;
        result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL,
                                           &renderer->entity_pipelines[index]);
    }
    vkDestroyShaderModule(context->device, vertex, NULL);
    vkDestroyShaderModule(context->device, fragment, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK
        : pbvk_fail(PB_VULKAN_RENDER_FAILED, "entity graphics pipeline creation failed", result);
}

static PBVulkanStatus pbvk_entity_shadow_pipeline_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->entity_shadow_vertex_spirv == NULL || renderer->shadow_render_pass == VK_NULL_HANDLE) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->entity_shadow_vertex_spirv,
                                                renderer->entity_shadow_vertex_spirv_size);
    if (vertex == VK_NULL_HANDLE) return pbvk_fail(PB_VULKAN_RENDER_FAILED,
                                                   "entity shadow shader creation failed", VK_ERROR_UNKNOWN);
    VkPipelineShaderStageCreateInfo stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    stage.stage = VK_SHADER_STAGE_VERTEX_BIT; stage.module = vertex; stage.pName = "main";
    VkVertexInputBindingDescription binding = {0, 36, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[2] = {
        {0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0}, {3, 0, VK_FORMAT_R32_SFLOAT, 32}
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertex_input.vertexBindingDescriptionCount = 1; vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 2; vertex_input.pVertexAttributeDescriptions = attributes;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_BACK_BIT;
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE; raster.depthBiasEnable = VK_TRUE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_TRUE; depth.depthWriteEnable = VK_TRUE;
    depth.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    VkDynamicState states[3] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_DEPTH_BIAS};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 3; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 1; pipeline.pStages = &stage;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pDepthStencilState = &depth;
    pipeline.pDynamicState = &dynamic; pipeline.layout = renderer->entity_pipeline_layout;
    pipeline.renderPass = renderer->shadow_render_pass;
    VkResult result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL,
                                                 &renderer->entity_shadow_pipeline);
    vkDestroyShaderModule(context->device, vertex, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK
        : pbvk_fail(PB_VULKAN_RENDER_FAILED, "entity shadow pipeline creation failed", result);
}

static void pbvk_particle_pipeline_release(PBVulkanChunkRenderer *renderer) {
    if (renderer->particle_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(renderer->swapchain->context->device, renderer->particle_pipeline, NULL);
        renderer->particle_pipeline = VK_NULL_HANDLE;
    }
}

static PBVulkanStatus pbvk_particle_pipeline_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->particle_vertex_spirv == NULL || renderer->particle_fragment_spirv == NULL) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->particle_vertex_spirv,
                                                renderer->particle_vertex_spirv_size);
    VkShaderModule fragment = pbvk_shader_module(context, renderer->particle_fragment_spirv,
                                                  renderer->particle_fragment_spirv_size);
    if (vertex == VK_NULL_HANDLE || fragment == VK_NULL_HANDLE) {
        if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
        if (fragment != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, fragment, NULL);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "particle shader module creation failed", VK_ERROR_UNKNOWN);
    }
    VkPipelineShaderStageCreateInfo stages[2]; memset(stages, 0, sizeof(stages));
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vertex; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fragment; stages[1].pName = "main";
    VkVertexInputBindingDescription bindings[2] = {
        {0, 8, VK_VERTEX_INPUT_RATE_VERTEX}, {1, 48, VK_VERTEX_INPUT_RATE_INSTANCE}
    };
    VkVertexInputAttributeDescription attributes[5] = {
        {0, 0, VK_FORMAT_R32G32_SFLOAT, 0},
        {1, 1, VK_FORMAT_R32G32B32_SFLOAT, 0},
        {2, 1, VK_FORMAT_R32G32B32A32_SFLOAT, 12},
        {3, 1, VK_FORMAT_R32_SFLOAT, 28},
        {4, 1, VK_FORMAT_R32G32B32A32_SFLOAT, 32},
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertex_input.vertexBindingDescriptionCount = 2; vertex_input.pVertexBindingDescriptions = bindings;
    vertex_input.vertexAttributeDescriptionCount = 5; vertex_input.pVertexAttributeDescriptions = attributes;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_TRUE; depth.depthWriteEnable = VK_FALSE;
    depth.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    VkPipelineColorBlendAttachmentState attachment = {0};
    attachment.blendEnable = VK_TRUE; attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA; attachment.colorBlendOp = VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA; attachment.alphaBlendOp = VK_BLEND_OP_ADD;
    attachment.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1; blend.pAttachments = &attachment;
    VkDynamicState states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2; pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pDepthStencilState = &depth;
    pipeline.pColorBlendState = &blend; pipeline.pDynamicState = &dynamic;
    pipeline.layout = renderer->particle_pipeline_layout; pipeline.renderPass = renderer->swapchain->render_pass;
    VkResult result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL,
                                                 &renderer->particle_pipeline);
    vkDestroyShaderModule(context->device, vertex, NULL); vkDestroyShaderModule(context->device, fragment, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK
        : pbvk_fail(PB_VULKAN_RENDER_FAILED, "particle graphics pipeline creation failed", result);
}

static void pbvk_composite_pipeline_release(PBVulkanChunkRenderer *renderer) {
    if (renderer->composite_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(renderer->swapchain->context->device, renderer->composite_pipeline, NULL);
        renderer->composite_pipeline = VK_NULL_HANDLE;
    }
}

static void pbvk_composite_descriptor_update(PBVulkanChunkRenderer *renderer) {
    if (renderer->composite_descriptor_set == VK_NULL_HANDLE || renderer->swapchain->scene_view == VK_NULL_HANDLE) return;
    VkDescriptorImageInfo images[2] = {
        {renderer->composite_sampler, renderer->swapchain->scene_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        {renderer->composite_sampler, renderer->swapchain->scene_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
    };
    VkWriteDescriptorSet writes[2]; memset(writes, 0, sizeof(writes));
    for (uint32_t index = 0; index < 2; index++) {
        writes[index].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[index].dstSet = renderer->composite_descriptor_set;
        writes[index].dstBinding = index;
        writes[index].descriptorCount = 1;
        writes[index].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[index].pImageInfo = &images[index];
    }
    vkUpdateDescriptorSets(renderer->swapchain->context->device, 2, writes, 0, NULL);
}

static PBVulkanStatus pbvk_composite_pipeline_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->composite_vertex_spirv == NULL || renderer->composite_fragment_spirv == NULL) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->composite_vertex_spirv,
                                                renderer->composite_vertex_spirv_size);
    VkShaderModule fragment = pbvk_shader_module(context, renderer->composite_fragment_spirv,
                                                  renderer->composite_fragment_spirv_size);
    if (vertex == VK_NULL_HANDLE || fragment == VK_NULL_HANDLE) {
        if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
        if (fragment != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, fragment, NULL);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "composite shader module creation failed", VK_ERROR_UNKNOWN);
    }
    VkPipelineShaderStageCreateInfo stages[2]; memset(stages, 0, sizeof(stages));
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vertex; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fragment; stages[1].pName = "main";
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState attachment = {0}; attachment.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1; blend.pAttachments = &attachment;
    VkDynamicState states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2; pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pColorBlendState = &blend;
    pipeline.pDynamicState = &dynamic; pipeline.layout = renderer->composite_pipeline_layout;
    pipeline.renderPass = renderer->swapchain->present_render_pass;
    VkResult result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL,
                                                 &renderer->composite_pipeline);
    vkDestroyShaderModule(context->device, vertex, NULL); vkDestroyShaderModule(context->device, fragment, NULL);
    if (result == VK_SUCCESS) pbvk_composite_descriptor_update(renderer);
    return result == VK_SUCCESS ? PB_VULKAN_OK
        : pbvk_fail(PB_VULKAN_RENDER_FAILED, "composite graphics pipeline creation failed", result);
}

static void pbvk_sky_pipeline_release(PBVulkanChunkRenderer *renderer) {
    if (renderer->sky_pipeline != VK_NULL_HANDLE) {
        vkDestroyPipeline(renderer->swapchain->context->device, renderer->sky_pipeline, NULL);
        renderer->sky_pipeline = VK_NULL_HANDLE;
    }
}

static PBVulkanStatus pbvk_sky_pipeline_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->sky_vertex_spirv == NULL || renderer->sky_fragment_spirv == NULL) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->sky_vertex_spirv, renderer->sky_vertex_spirv_size);
    VkShaderModule fragment = pbvk_shader_module(context, renderer->sky_fragment_spirv, renderer->sky_fragment_spirv_size);
    if (vertex == VK_NULL_HANDLE || fragment == VK_NULL_HANDLE) {
        if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
        if (fragment != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, fragment, NULL);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "sky shader module creation failed", VK_ERROR_UNKNOWN);
    }
    VkPipelineShaderStageCreateInfo stages[2]; memset(stages, 0, sizeof(stages));
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT; stages[0].module = vertex; stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT; stages[1].module = fragment; stages[1].pName = "main";
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_NONE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_FALSE; depth.depthWriteEnable = VK_FALSE;
    VkPipelineColorBlendAttachmentState attachment = {0}; attachment.colorWriteMask = 0xf;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1; blend.pAttachments = &attachment;
    VkDynamicState states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2; pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pDepthStencilState = &depth;
    pipeline.pColorBlendState = &blend; pipeline.pDynamicState = &dynamic;
    pipeline.layout = renderer->sky_pipeline_layout; pipeline.renderPass = renderer->swapchain->render_pass;
    VkResult result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL,
                                                 &renderer->sky_pipeline);
    vkDestroyShaderModule(context->device, vertex, NULL); vkDestroyShaderModule(context->device, fragment, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK
        : pbvk_fail(PB_VULKAN_RENDER_FAILED, "sky graphics pipeline creation failed", result);
}

static void pbvk_shadow_release(PBVulkanChunkRenderer *renderer) {
    VkDevice device = renderer->swapchain->context->device;
    if (renderer->shadow_pipeline != VK_NULL_HANDLE) vkDestroyPipeline(device, renderer->shadow_pipeline, NULL);
    if (renderer->shadow_framebuffer != VK_NULL_HANDLE) vkDestroyFramebuffer(device, renderer->shadow_framebuffer, NULL);
    if (renderer->shadow_render_pass != VK_NULL_HANDLE) vkDestroyRenderPass(device, renderer->shadow_render_pass, NULL);
    if (renderer->shadow_sampler != VK_NULL_HANDLE) vkDestroySampler(device, renderer->shadow_sampler, NULL);
    if (renderer->shadow_view != VK_NULL_HANDLE) vkDestroyImageView(device, renderer->shadow_view, NULL);
    if (renderer->shadow_image != VK_NULL_HANDLE) vkDestroyImage(device, renderer->shadow_image, NULL);
    if (renderer->shadow_memory != VK_NULL_HANDLE) vkFreeMemory(device, renderer->shadow_memory, NULL);
    renderer->shadow_pipeline = VK_NULL_HANDLE;
    renderer->shadow_framebuffer = VK_NULL_HANDLE;
    renderer->shadow_render_pass = VK_NULL_HANDLE;
    renderer->shadow_sampler = VK_NULL_HANDLE;
    renderer->shadow_view = VK_NULL_HANDLE;
    renderer->shadow_image = VK_NULL_HANDLE;
    renderer->shadow_memory = VK_NULL_HANDLE;
}

static PBVulkanStatus pbvk_shadow_build(PBVulkanChunkRenderer *renderer) {
    if (renderer->shadow_vertex_spirv == NULL || renderer->shadow_size == 0) return PB_VULKAN_OK;
    PBVulkanContext *context = renderer->swapchain->context;
    VkImageCreateInfo image = {0};
    image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image.imageType = VK_IMAGE_TYPE_2D;
    image.format = VK_FORMAT_D32_SFLOAT;
    image.extent.width = renderer->shadow_size;
    image.extent.height = renderer->shadow_size;
    image.extent.depth = 1;
    image.mipLevels = 1; image.arrayLayers = 1; image.samples = VK_SAMPLE_COUNT_1_BIT;
    image.tiling = VK_IMAGE_TILING_OPTIMAL;
    image.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkResult result = vkCreateImage(context->device, &image, NULL, &renderer->shadow_image);
    VkMemoryRequirements requirements;
    if (result == VK_SUCCESS) vkGetImageMemoryRequirements(context->device, renderer->shadow_image, &requirements);
    uint32_t memory_type = result == VK_SUCCESS
        ? pbvk_memory_type(context, requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) : UINT32_MAX;
    VkMemoryAllocateInfo allocation = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    if (result == VK_SUCCESS && memory_type != UINT32_MAX) {
        allocation.allocationSize = requirements.size; allocation.memoryTypeIndex = memory_type;
        result = vkAllocateMemory(context->device, &allocation, NULL, &renderer->shadow_memory);
    } else if (result == VK_SUCCESS) result = VK_ERROR_FEATURE_NOT_PRESENT;
    if (result == VK_SUCCESS) result = vkBindImageMemory(context->device, renderer->shadow_image, renderer->shadow_memory, 0);
    VkImageViewCreateInfo view = {0};
    view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view.image = renderer->shadow_image;
    view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view.format = VK_FORMAT_D32_SFLOAT;
    view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    view.subresourceRange.levelCount = 1; view.subresourceRange.layerCount = 1;
    if (result == VK_SUCCESS) result = vkCreateImageView(context->device, &view, NULL, &renderer->shadow_view);
    VkSamplerCreateInfo sampler = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sampler.magFilter = VK_FILTER_LINEAR; sampler.minFilter = VK_FILTER_LINEAR;
    sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER;
    sampler.borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE;
    sampler.compareEnable = VK_TRUE; sampler.compareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    sampler.maxLod = 0;
    if (result == VK_SUCCESS) result = vkCreateSampler(context->device, &sampler, NULL, &renderer->shadow_sampler);
    VkAttachmentDescription attachment = {0};
    attachment.format = VK_FORMAT_D32_SFLOAT; attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachment.finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
    VkAttachmentReference depth_reference = {0, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {0};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.pDepthStencilAttachment = &depth_reference;
    VkSubpassDependency dependencies[2];
    memset(dependencies, 0, sizeof(dependencies));
    dependencies[0].srcSubpass = VK_SUBPASS_EXTERNAL; dependencies[0].dstSubpass = 0;
    dependencies[0].srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dependencies[0].dstStageMask = VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
    dependencies[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    dependencies[0].dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    dependencies[1].srcSubpass = 0; dependencies[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    dependencies[1].srcStageMask = VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
    dependencies[1].dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dependencies[1].srcAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    dependencies[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    VkRenderPassCreateInfo render_pass = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    render_pass.attachmentCount = 1; render_pass.pAttachments = &attachment;
    render_pass.subpassCount = 1; render_pass.pSubpasses = &subpass;
    render_pass.dependencyCount = 2; render_pass.pDependencies = dependencies;
    if (result == VK_SUCCESS) result = vkCreateRenderPass(context->device, &render_pass, NULL, &renderer->shadow_render_pass);
    VkFramebufferCreateInfo framebuffer = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
    framebuffer.renderPass = renderer->shadow_render_pass;
    framebuffer.attachmentCount = 1; framebuffer.pAttachments = &renderer->shadow_view;
    framebuffer.width = renderer->shadow_size; framebuffer.height = renderer->shadow_size; framebuffer.layers = 1;
    if (result == VK_SUCCESS) result = vkCreateFramebuffer(context->device, &framebuffer, NULL, &renderer->shadow_framebuffer);

    VkShaderModule vertex = result == VK_SUCCESS
        ? pbvk_shader_module(context, renderer->shadow_vertex_spirv, renderer->shadow_vertex_spirv_size) : VK_NULL_HANDLE;
    if (result == VK_SUCCESS && vertex == VK_NULL_HANDLE) result = VK_ERROR_UNKNOWN;
    VkPipelineShaderStageCreateInfo stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
    stage.stage = VK_SHADER_STAGE_VERTEX_BIT; stage.module = vertex; stage.pName = "main";
    VkVertexInputBindingDescription binding = {0, 28, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription position = {0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0};
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertex_input.vertexBindingDescriptionCount = 1; vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 1; vertex_input.pVertexAttributeDescriptions = &position;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1; viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL; raster.cullMode = VK_CULL_MODE_BACK_BIT;
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE; raster.depthBiasEnable = VK_TRUE; raster.lineWidth = 1;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_TRUE; depth.depthWriteEnable = VK_TRUE; depth.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    VkDynamicState states[3] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_DEPTH_BIAS};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 3; dynamic.pDynamicStates = states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 1; pipeline.pStages = &stage;
    pipeline.pVertexInputState = &vertex_input; pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport; pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample; pipeline.pDepthStencilState = &depth;
    pipeline.pDynamicState = &dynamic; pipeline.layout = renderer->pipeline_layout;
    pipeline.renderPass = renderer->shadow_render_pass;
    if (result == VK_SUCCESS) result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL, &renderer->shadow_pipeline);
    if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
    if (result != VK_SUCCESS) { pbvk_shadow_release(renderer); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "shadow resources failed", result); }
    VkDescriptorImageInfo shadow = {renderer->shadow_sampler, renderer->shadow_view,
                                    VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = renderer->descriptor_set; write.dstBinding = 4;
    write.descriptorCount = 1; write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &shadow;
    vkUpdateDescriptorSets(context->device, 1, &write, 0, NULL);
    return PB_VULKAN_OK;
}

static PBVulkanStatus pbvk_chunk_pipelines_build(PBVulkanChunkRenderer *renderer) {
    PBVulkanContext *context = renderer->swapchain->context;
    VkShaderModule vertex = pbvk_shader_module(context, renderer->vertex_spirv, renderer->vertex_spirv_size);
    VkShaderModule fragment = pbvk_shader_module(context, renderer->fragment_spirv, renderer->fragment_spirv_size);
    if (vertex == VK_NULL_HANDLE || fragment == VK_NULL_HANDLE) {
        if (vertex != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, vertex, NULL);
        if (fragment != VK_NULL_HANDLE) vkDestroyShaderModule(context->device, fragment, NULL);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk shader module creation failed", VK_ERROR_UNKNOWN);
    }
    VkPipelineShaderStageCreateInfo stages[2];
    memset(stages, 0, sizeof(stages));
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vertex;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragment;
    stages[1].pName = "main";
    VkVertexInputBindingDescription binding = {0, 28, VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription attributes[4] = {
        {0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0},
        {1, 0, VK_FORMAT_R32G32_SFLOAT, 12},
        {2, 0, VK_FORMAT_R32_UINT, 20},
        {3, 0, VK_FORMAT_R32_UINT, 24},
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = {VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    vertex_input.vertexBindingDescriptionCount = 1;
    vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 4;
    vertex_input.pVertexAttributeDescriptions = attributes;
    VkPipelineInputAssemblyStateCreateInfo assembly = {VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo viewport = {VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo raster = {VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    raster.polygonMode = VK_POLYGON_MODE_FILL;
    raster.cullMode = VK_CULL_MODE_BACK_BIT;
    raster.frontFace = VK_FRONT_FACE_CLOCKWISE;
    raster.lineWidth = 1.0f;
    VkPipelineMultisampleStateCreateInfo multisample = {VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineDepthStencilStateCreateInfo depth = {VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
    depth.depthTestEnable = VK_TRUE;
    depth.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    VkPipelineColorBlendAttachmentState blend_attachment = {0};
    blend_attachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                      VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo blend = {VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    blend.attachmentCount = 1;
    blend.pAttachments = &blend_attachment;
    VkDynamicState dynamic_states[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic = {VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dynamic.dynamicStateCount = 2;
    dynamic.pDynamicStates = dynamic_states;
    VkGraphicsPipelineCreateInfo pipeline = {VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pipeline.stageCount = 2;
    pipeline.pStages = stages;
    pipeline.pVertexInputState = &vertex_input;
    pipeline.pInputAssemblyState = &assembly;
    pipeline.pViewportState = &viewport;
    pipeline.pRasterizationState = &raster;
    pipeline.pMultisampleState = &multisample;
    pipeline.pDepthStencilState = &depth;
    pipeline.pColorBlendState = &blend;
    pipeline.pDynamicState = &dynamic;
    pipeline.layout = renderer->pipeline_layout;
    pipeline.renderPass = renderer->swapchain->render_pass;
    for (uint32_t index = 0; index < 3; index++) {
        depth.depthWriteEnable = index == 2 ? VK_FALSE : VK_TRUE;
        blend_attachment.blendEnable = index == 2 ? VK_TRUE : VK_FALSE;
        blend_attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
        blend_attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = VK_BLEND_OP_ADD;
        blend_attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
        blend_attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_attachment.alphaBlendOp = VK_BLEND_OP_ADD;
        VkResult result = vkCreateGraphicsPipelines(context->device, VK_NULL_HANDLE, 1, &pipeline, NULL,
                                                     &renderer->pipelines[index]);
        if (result != VK_SUCCESS) {
            pbvk_chunk_pipelines_release(renderer);
            vkDestroyShaderModule(context->device, vertex, NULL);
            vkDestroyShaderModule(context->device, fragment, NULL);
            return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk graphics pipeline creation failed", result);
        }
    }
    vkDestroyShaderModule(context->device, vertex, NULL);
    vkDestroyShaderModule(context->device, fragment, NULL);
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_chunk_renderer_create(PBVulkanSwapchain *swapchain,
                                               const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                               const uint8_t *fragment_spirv, size_t fragment_spirv_size,
                                               PBVulkanChunkRenderer **out_renderer) {
    if (swapchain == NULL || vertex_spirv == NULL || fragment_spirv == NULL ||
        vertex_spirv_size == 0 || fragment_spirv_size == 0 || out_renderer == NULL) return PB_VULKAN_BAD_ARGUMENT;
    *out_renderer = NULL;
    PBVulkanChunkRenderer *renderer = (PBVulkanChunkRenderer *)calloc(1, sizeof(PBVulkanChunkRenderer));
    if (renderer == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    renderer->swapchain = swapchain;
    renderer->vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    renderer->fragment_spirv = (uint8_t *)malloc(fragment_spirv_size);
    if (renderer->vertex_spirv == NULL || renderer->fragment_spirv == NULL) {
        pb_vulkan_chunk_renderer_destroy(renderer);
        return PB_VULKAN_OUT_OF_MEMORY;
    }
    memcpy(renderer->vertex_spirv, vertex_spirv, vertex_spirv_size);
    memcpy(renderer->fragment_spirv, fragment_spirv, fragment_spirv_size);
    renderer->vertex_spirv_size = vertex_spirv_size;
    renderer->fragment_spirv_size = fragment_spirv_size;
    PBVulkanContext *context = swapchain->context;
    VkDescriptorSetLayoutBinding bindings[3];
    memset(bindings, 0, sizeof(bindings));
    bindings[0].binding = 1;
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[0].descriptorCount = 1;
    bindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    bindings[1].binding = 3;
    bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[1].descriptorCount = 1;
    bindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    bindings[2].binding = 4;
    bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[2].descriptorCount = 1;
    bindings[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo descriptor = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    descriptor.bindingCount = 3;
    descriptor.pBindings = bindings;
    VkResult result = vkCreateDescriptorSetLayout(context->device, &descriptor, NULL, &renderer->descriptor_layout);
    VkPushConstantRange push = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, 32};
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1;
    layout.pSetLayouts = &renderer->descriptor_layout;
    layout.pushConstantRangeCount = 1;
    layout.pPushConstantRanges = &push;
    if (result == VK_SUCCESS) result = vkCreatePipelineLayout(context->device, &layout, NULL, &renderer->pipeline_layout);
    if (result != VK_SUCCESS) { pb_vulkan_chunk_renderer_destroy(renderer); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk pipeline layout failed", result); }
    PBVulkanStatus status = pbvk_chunk_pipelines_build(renderer);
    if (status != PB_VULKAN_OK) { pb_vulkan_chunk_renderer_destroy(renderer); return status; }
    result = pbvk_buffer_create(context, 192, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                &renderer->uniform_buffer, &renderer->uniform_memory);
    VkDescriptorPoolSize pool_sizes[2] = {
        {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1}, {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2}
    };
    VkDescriptorPoolCreateInfo pool = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    pool.maxSets = 1;
    pool.poolSizeCount = 2;
    pool.pPoolSizes = pool_sizes;
    if (result == VK_SUCCESS) result = vkCreateDescriptorPool(context->device, &pool, NULL, &renderer->descriptor_pool);
    VkDescriptorSetAllocateInfo set = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    set.descriptorPool = renderer->descriptor_pool;
    set.descriptorSetCount = 1;
    set.pSetLayouts = &renderer->descriptor_layout;
    if (result == VK_SUCCESS) result = vkAllocateDescriptorSets(context->device, &set, &renderer->descriptor_set);
    if (result != VK_SUCCESS) { pb_vulkan_chunk_renderer_destroy(renderer); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk descriptor resources failed", result); }
    VkDescriptorBufferInfo uniform = {renderer->uniform_buffer, 0, 192};
    VkWriteDescriptorSet write = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = renderer->descriptor_set;
    write.dstBinding = 1;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    write.pBufferInfo = &uniform;
    vkUpdateDescriptorSets(context->device, 1, &write, 0, NULL);
    *out_renderer = renderer;
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_chunk_renderer_set_atlas(PBVulkanChunkRenderer *renderer,
                                                  PBVulkanTexture *atlas) {
    if (renderer == NULL || atlas == NULL || renderer->swapchain->context != atlas->context) return PB_VULKAN_BAD_ARGUMENT;
    renderer->atlas = atlas;
    VkDescriptorImageInfo image = {atlas->sampler, atlas->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = renderer->descriptor_set;
    write.dstBinding = 3;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &image;
    vkUpdateDescriptorSets(renderer->swapchain->context->device, 1, &write, 0, NULL);
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_chunk_renderer_rebuild(PBVulkanChunkRenderer *renderer) {
    if (renderer == NULL) return PB_VULKAN_BAD_ARGUMENT;
    vkDeviceWaitIdle(renderer->swapchain->context->device);
    pbvk_chunk_pipelines_release(renderer);
    pbvk_ui_pipeline_release(renderer);
    pbvk_entity_pipeline_release(renderer);
    pbvk_particle_pipeline_release(renderer);
    pbvk_composite_pipeline_release(renderer);
    pbvk_sky_pipeline_release(renderer);
    PBVulkanStatus status = pbvk_chunk_pipelines_build(renderer);
    if (status == PB_VULKAN_OK) status = pbvk_ui_pipeline_build(renderer);
    if (status == PB_VULKAN_OK) status = pbvk_entity_pipeline_build(renderer);
    if (status == PB_VULKAN_OK) status = pbvk_entity_shadow_pipeline_build(renderer);
    if (status == PB_VULKAN_OK) status = pbvk_particle_pipeline_build(renderer);
    if (status == PB_VULKAN_OK) status = pbvk_composite_pipeline_build(renderer);
    return status == PB_VULKAN_OK ? pbvk_sky_pipeline_build(renderer) : status;
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_ui(PBVulkanChunkRenderer *renderer,
                                                   const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                   const uint8_t *fragment_spirv, size_t fragment_spirv_size) {
    if (renderer == NULL || vertex_spirv == NULL || fragment_spirv == NULL ||
        vertex_spirv_size == 0 || fragment_spirv_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    PBVulkanContext *context = renderer->swapchain->context;
    renderer->ui_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    renderer->ui_fragment_spirv = (uint8_t *)malloc(fragment_spirv_size);
    if (renderer->ui_vertex_spirv == NULL || renderer->ui_fragment_spirv == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    memcpy(renderer->ui_vertex_spirv, vertex_spirv, vertex_spirv_size);
    memcpy(renderer->ui_fragment_spirv, fragment_spirv, fragment_spirv_size);
    renderer->ui_vertex_spirv_size = vertex_spirv_size;
    renderer->ui_fragment_spirv_size = fragment_spirv_size;
    VkDescriptorSetLayoutBinding binding = {0};
    binding.binding = 2;
    binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo descriptor = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    descriptor.bindingCount = 1; descriptor.pBindings = &binding;
    VkResult result = vkCreateDescriptorSetLayout(context->device, &descriptor, NULL, &renderer->ui_descriptor_layout);
    VkPushConstantRange push = {VK_SHADER_STAGE_VERTEX_BIT, 0, 16};
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1; layout.pSetLayouts = &renderer->ui_descriptor_layout;
    layout.pushConstantRangeCount = 1; layout.pPushConstantRanges = &push;
    if (result == VK_SUCCESS) result = vkCreatePipelineLayout(context->device, &layout, NULL, &renderer->ui_pipeline_layout);
    VkDescriptorPoolSize pool_size = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1};
    VkDescriptorPoolCreateInfo pool = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    pool.maxSets = 1; pool.poolSizeCount = 1; pool.pPoolSizes = &pool_size;
    if (result == VK_SUCCESS) result = vkCreateDescriptorPool(context->device, &pool, NULL, &renderer->ui_descriptor_pool);
    VkDescriptorSetAllocateInfo set = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    set.descriptorPool = renderer->ui_descriptor_pool; set.descriptorSetCount = 1;
    set.pSetLayouts = &renderer->ui_descriptor_layout;
    if (result == VK_SUCCESS) result = vkAllocateDescriptorSets(context->device, &set, &renderer->ui_descriptor_set);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "UI descriptor creation failed", result);
    return pbvk_ui_pipeline_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_shadow(PBVulkanChunkRenderer *renderer,
                                                       const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                       uint32_t shadow_size) {
    if (renderer == NULL || vertex_spirv == NULL || vertex_spirv_size == 0 || shadow_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    renderer->shadow_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    if (renderer->shadow_vertex_spirv == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    memcpy(renderer->shadow_vertex_spirv, vertex_spirv, vertex_spirv_size);
    renderer->shadow_vertex_spirv_size = vertex_spirv_size;
    renderer->shadow_size = shadow_size;
    return pbvk_shadow_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_entities(PBVulkanChunkRenderer *renderer,
                                                         const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                         const uint8_t *fragment_spirv, size_t fragment_spirv_size) {
    if (renderer == NULL || vertex_spirv == NULL || fragment_spirv == NULL ||
        vertex_spirv_size == 0 || fragment_spirv_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    PBVulkanContext *context = renderer->swapchain->context;
    renderer->entity_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    renderer->entity_fragment_spirv = (uint8_t *)malloc(fragment_spirv_size);
    if (renderer->entity_vertex_spirv == NULL || renderer->entity_fragment_spirv == NULL) {
        free(renderer->entity_vertex_spirv); renderer->entity_vertex_spirv = NULL;
        free(renderer->entity_fragment_spirv); renderer->entity_fragment_spirv = NULL;
        return PB_VULKAN_OUT_OF_MEMORY;
    }
    memcpy(renderer->entity_vertex_spirv, vertex_spirv, vertex_spirv_size);
    memcpy(renderer->entity_fragment_spirv, fragment_spirv, fragment_spirv_size);
    renderer->entity_vertex_spirv_size = vertex_spirv_size;
    renderer->entity_fragment_spirv_size = fragment_spirv_size;

    VkDescriptorSetLayoutBinding bindings[3];
    memset(bindings, 0, sizeof(bindings));
    bindings[0].binding = 0; bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[0].descriptorCount = 1; bindings[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    bindings[1].binding = 1; bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[1].descriptorCount = 1; bindings[1].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    bindings[2].binding = 2; bindings[2].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    bindings[2].descriptorCount = 1; bindings[2].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    VkDescriptorSetLayoutCreateInfo descriptor = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    descriptor.bindingCount = 3; descriptor.pBindings = bindings;
    VkResult result = vkCreateDescriptorSetLayout(context->device, &descriptor, NULL,
                                                   &renderer->entity_descriptor_layout);
    VkPushConstantRange push = {VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, 128};
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1; layout.pSetLayouts = &renderer->entity_descriptor_layout;
    layout.pushConstantRangeCount = 1; layout.pPushConstantRanges = &push;
    if (result == VK_SUCCESS) result = vkCreatePipelineLayout(context->device, &layout, NULL,
                                                               &renderer->entity_pipeline_layout);
    if (result == VK_SUCCESS) result = pbvk_buffer_create(context, 128, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &renderer->entity_frame_buffer, &renderer->entity_frame_memory);
    if (result == VK_SUCCESS) result = pbvk_buffer_create(context, 4096u * 1536u, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &renderer->entity_parts_buffer, &renderer->entity_parts_memory);
    VkDescriptorPoolSize sizes[2] = {
        {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 8192},
        {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 16384},
    };
    VkDescriptorPoolCreateInfo pool = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    pool.flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    pool.maxSets = 8192; pool.poolSizeCount = 2; pool.pPoolSizes = sizes;
    if (result == VK_SUCCESS) result = vkCreateDescriptorPool(context->device, &pool, NULL,
                                                               &renderer->entity_descriptor_pool);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "entity descriptor resources failed", result);
    return pbvk_entity_pipeline_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_entity_shadows(PBVulkanChunkRenderer *renderer,
                                                               const uint8_t *vertex_spirv,
                                                               size_t vertex_spirv_size) {
    if (renderer == NULL || vertex_spirv == NULL || vertex_spirv_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    renderer->entity_shadow_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    if (renderer->entity_shadow_vertex_spirv == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    memcpy(renderer->entity_shadow_vertex_spirv, vertex_spirv, vertex_spirv_size);
    renderer->entity_shadow_vertex_spirv_size = vertex_spirv_size;
    return pbvk_entity_shadow_pipeline_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_particles(PBVulkanChunkRenderer *renderer,
                                                          const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                          const uint8_t *fragment_spirv, size_t fragment_spirv_size) {
    if (renderer == NULL || vertex_spirv == NULL || fragment_spirv == NULL ||
        vertex_spirv_size == 0 || fragment_spirv_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    renderer->particle_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    renderer->particle_fragment_spirv = (uint8_t *)malloc(fragment_spirv_size);
    if (renderer->particle_vertex_spirv == NULL || renderer->particle_fragment_spirv == NULL) {
        free(renderer->particle_vertex_spirv); renderer->particle_vertex_spirv = NULL;
        free(renderer->particle_fragment_spirv); renderer->particle_fragment_spirv = NULL;
        return PB_VULKAN_OUT_OF_MEMORY;
    }
    memcpy(renderer->particle_vertex_spirv, vertex_spirv, vertex_spirv_size);
    memcpy(renderer->particle_fragment_spirv, fragment_spirv, fragment_spirv_size);
    renderer->particle_vertex_spirv_size = vertex_spirv_size;
    renderer->particle_fragment_spirv_size = fragment_spirv_size;
    VkPushConstantRange push = {VK_SHADER_STAGE_VERTEX_BIT, 0, 96};
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1; layout.pSetLayouts = &renderer->descriptor_layout;
    layout.pushConstantRangeCount = 1; layout.pPushConstantRanges = &push;
    VkResult result = vkCreatePipelineLayout(renderer->swapchain->context->device, &layout, NULL,
                                              &renderer->particle_pipeline_layout);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "particle pipeline layout failed", result);
    return pbvk_particle_pipeline_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_postprocess(PBVulkanChunkRenderer *renderer,
                                                            const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                            const uint8_t *fragment_spirv, size_t fragment_spirv_size) {
    if (renderer == NULL || vertex_spirv == NULL || fragment_spirv == NULL ||
        vertex_spirv_size == 0 || fragment_spirv_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    PBVulkanContext *context = renderer->swapchain->context;
    renderer->composite_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    renderer->composite_fragment_spirv = (uint8_t *)malloc(fragment_spirv_size);
    if (renderer->composite_vertex_spirv == NULL || renderer->composite_fragment_spirv == NULL) {
        free(renderer->composite_vertex_spirv); renderer->composite_vertex_spirv = NULL;
        free(renderer->composite_fragment_spirv); renderer->composite_fragment_spirv = NULL;
        return PB_VULKAN_OUT_OF_MEMORY;
    }
    memcpy(renderer->composite_vertex_spirv, vertex_spirv, vertex_spirv_size);
    memcpy(renderer->composite_fragment_spirv, fragment_spirv, fragment_spirv_size);
    renderer->composite_vertex_spirv_size = vertex_spirv_size;
    renderer->composite_fragment_spirv_size = fragment_spirv_size;
    VkDescriptorSetLayoutBinding bindings[2]; memset(bindings, 0, sizeof(bindings));
    for (uint32_t index = 0; index < 2; index++) {
        bindings[index].binding = index;
        bindings[index].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        bindings[index].descriptorCount = 1;
        bindings[index].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    }
    VkDescriptorSetLayoutCreateInfo descriptor = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    descriptor.bindingCount = 2; descriptor.pBindings = bindings;
    VkResult result = vkCreateDescriptorSetLayout(context->device, &descriptor, NULL,
                                                   &renderer->composite_descriptor_layout);
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.setLayoutCount = 1; layout.pSetLayouts = &renderer->composite_descriptor_layout;
    if (result == VK_SUCCESS) result = vkCreatePipelineLayout(context->device, &layout, NULL,
                                                               &renderer->composite_pipeline_layout);
    VkDescriptorPoolSize pool_size = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2};
    VkDescriptorPoolCreateInfo pool = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    pool.maxSets = 1; pool.poolSizeCount = 1; pool.pPoolSizes = &pool_size;
    if (result == VK_SUCCESS) result = vkCreateDescriptorPool(context->device, &pool, NULL,
                                                               &renderer->composite_descriptor_pool);
    VkDescriptorSetAllocateInfo set = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    set.descriptorPool = renderer->composite_descriptor_pool; set.descriptorSetCount = 1;
    set.pSetLayouts = &renderer->composite_descriptor_layout;
    if (result == VK_SUCCESS) result = vkAllocateDescriptorSets(context->device, &set,
                                                                 &renderer->composite_descriptor_set);
    VkSamplerCreateInfo sampler = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sampler.magFilter = VK_FILTER_LINEAR; sampler.minFilter = VK_FILTER_LINEAR;
    sampler.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sampler.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler.maxLod = 0;
    if (result == VK_SUCCESS) result = vkCreateSampler(context->device, &sampler, NULL,
                                                        &renderer->composite_sampler);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "composite resources failed", result);
    return pbvk_composite_pipeline_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_install_sky(PBVulkanChunkRenderer *renderer,
                                                    const uint8_t *vertex_spirv, size_t vertex_spirv_size,
                                                    const uint8_t *fragment_spirv, size_t fragment_spirv_size) {
    if (renderer == NULL || vertex_spirv == NULL || fragment_spirv == NULL ||
        vertex_spirv_size == 0 || fragment_spirv_size == 0) return PB_VULKAN_BAD_ARGUMENT;
    renderer->sky_vertex_spirv = (uint8_t *)malloc(vertex_spirv_size);
    renderer->sky_fragment_spirv = (uint8_t *)malloc(fragment_spirv_size);
    if (renderer->sky_vertex_spirv == NULL || renderer->sky_fragment_spirv == NULL) {
        free(renderer->sky_vertex_spirv); renderer->sky_vertex_spirv = NULL;
        free(renderer->sky_fragment_spirv); renderer->sky_fragment_spirv = NULL;
        return PB_VULKAN_OUT_OF_MEMORY;
    }
    memcpy(renderer->sky_vertex_spirv, vertex_spirv, vertex_spirv_size);
    memcpy(renderer->sky_fragment_spirv, fragment_spirv, fragment_spirv_size);
    renderer->sky_vertex_spirv_size = vertex_spirv_size;
    renderer->sky_fragment_spirv_size = fragment_spirv_size;
    VkPushConstantRange push = {VK_SHADER_STAGE_FRAGMENT_BIT, 0, 48};
    VkPipelineLayoutCreateInfo layout = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    layout.pushConstantRangeCount = 1; layout.pPushConstantRanges = &push;
    VkResult result = vkCreatePipelineLayout(renderer->swapchain->context->device, &layout, NULL,
                                              &renderer->sky_pipeline_layout);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "sky pipeline layout failed", result);
    return pbvk_sky_pipeline_build(renderer);
}

PBVulkanStatus pb_vulkan_chunk_renderer_set_ui_texture(PBVulkanChunkRenderer *renderer,
                                                       PBVulkanTexture *texture) {
    if (renderer == NULL || texture == NULL || renderer->ui_descriptor_set == VK_NULL_HANDLE) return PB_VULKAN_BAD_ARGUMENT;
    renderer->ui_texture = texture;
    VkDescriptorImageInfo image = {texture->sampler, texture->view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet write = {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    write.dstSet = renderer->ui_descriptor_set; write.dstBinding = 2;
    write.descriptorCount = 1; write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &image;
    vkUpdateDescriptorSets(renderer->swapchain->context->device, 1, &write, 0, NULL);
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_renderer_present_frame3(PBVulkanChunkRenderer *renderer,
                                                 const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                 const PBVulkanChunkDraw *draws, uint32_t draw_count,
                                                 const uint8_t *entity_view_projection, size_t entity_view_projection_size,
                                                 const PBVulkanEntityDraw *entity_draws, uint32_t entity_draw_count,
                                                 const PBVulkanParticleDraw *particle_draws, uint32_t particle_draw_count,
                                                 const PBVulkanUIDraw *ui_draws, uint32_t ui_draw_count,
                                                 float clear_red, float clear_green,
                                                 float clear_blue, float clear_alpha) {
    if (renderer == NULL || shared_uniforms == NULL || shared_uniform_size != 192 ||
        (draw_count > 0 && draws == NULL) || (ui_draw_count > 0 && ui_draws == NULL) ||
        (entity_draw_count > 0 && (entity_draws == NULL || entity_view_projection == NULL ||
                                   entity_view_projection_size != 128 || entity_draw_count > 4096 ||
                                   renderer->entity_pipelines[0] == VK_NULL_HANDLE)) ||
        (particle_draw_count > 0 && (particle_draws == NULL || renderer->particle_pipeline == VK_NULL_HANDLE)) ||
        renderer->composite_pipeline == VK_NULL_HANDLE ||
        renderer->sky_pipeline == VK_NULL_HANDLE ||
        renderer->atlas == NULL || (ui_draw_count > 0 && (renderer->ui_pipeline == VK_NULL_HANDLE || renderer->ui_texture == NULL))) {
        return PB_VULKAN_BAD_ARGUMENT;
    }
    PBVulkanSwapchain *swapchain = renderer->swapchain;
    PBVulkanContext *context = swapchain->context;
    vkWaitForFences(context->device, 1, &swapchain->frame_fence, VK_TRUE, UINT64_MAX);
    VkResult result = pbvk_memory_write(context, renderer->uniform_memory, shared_uniforms, 192);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk uniform upload failed", result);
    if (entity_draw_count > 0) {
        result = pbvk_memory_write(context, renderer->entity_frame_memory, entity_view_projection, 128);
        if (result == VK_SUCCESS) result = vkResetDescriptorPool(context->device,
                                                                 renderer->entity_descriptor_pool, 0);
        for (uint32_t index = 0; result == VK_SUCCESS && index < entity_draw_count; index++) {
            result = pbvk_memory_write_at(context, renderer->entity_parts_memory,
                                          (VkDeviceSize)index * 1536u,
                                          (const uint8_t *)entity_draws[index].parts, 1536);
        }
        if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "entity frame upload failed", result);
    }
    uint32_t image_index = 0;
    result = vkAcquireNextImageKHR(context->device, swapchain->swapchain, UINT64_MAX,
                                   swapchain->image_available, VK_NULL_HANDLE, &image_index);
    if (result == VK_ERROR_OUT_OF_DATE_KHR) return PB_VULKAN_OUT_OF_DATE;
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk frame acquisition failed", result);
    vkResetFences(context->device, 1, &swapchain->frame_fence);
    VkCommandBuffer command = swapchain->commands[image_index];
    vkResetCommandBuffer(command, 0);
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    result = vkBeginCommandBuffer(command, &begin);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk command begin failed", result);
    float shadow_enabled = 0;
    memcpy(&shadow_enabled, shared_uniforms + 140, sizeof(float));
    if (shadow_enabled > 0.5f && renderer->shadow_pipeline != VK_NULL_HANDLE) {
        VkClearValue shadow_clear;
        memset(&shadow_clear, 0, sizeof(shadow_clear));
        shadow_clear.depthStencil.depth = 1.0f;
        VkRenderPassBeginInfo shadow_pass = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        shadow_pass.renderPass = renderer->shadow_render_pass;
        shadow_pass.framebuffer = renderer->shadow_framebuffer;
        shadow_pass.renderArea.extent.width = renderer->shadow_size;
        shadow_pass.renderArea.extent.height = renderer->shadow_size;
        shadow_pass.clearValueCount = 1;
        shadow_pass.pClearValues = &shadow_clear;
        vkCmdBeginRenderPass(command, &shadow_pass, VK_SUBPASS_CONTENTS_INLINE);
        VkViewport shadow_viewport = {0, (float)renderer->shadow_size, (float)renderer->shadow_size,
                                      -(float)renderer->shadow_size, 0, 1};
        VkRect2D shadow_scissor = {{0, 0}, {renderer->shadow_size, renderer->shadow_size}};
        vkCmdSetViewport(command, 0, 1, &shadow_viewport);
        vkCmdSetScissor(command, 0, 1, &shadow_scissor);
        vkCmdSetDepthBias(command, 6.0f, 0.02f, 8.0f);
        vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->shadow_pipeline);
        vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->pipeline_layout,
                                0, 1, &renderer->descriptor_set, 0, NULL);
        for (uint32_t index = 0; index < draw_count; index++) {
            const PBVulkanChunkDraw *draw = &draws[index];
            if (draw->mesh == NULL || draw->pipeline == 2 || draw->index_count == 0) continue;
            float push[8] = {draw->origin[0], draw->origin[1], draw->origin[2], draw->origin[3], 0, 1, 0, 0};
            vkCmdPushConstants(command, renderer->pipeline_layout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push), push);
            VkDeviceSize offset = 0;
            vkCmdBindVertexBuffers(command, 0, 1, &draw->mesh->vertex_buffer, &offset);
            vkCmdBindIndexBuffer(command, draw->mesh->index_buffer, 0,
                                 draw->mesh->index_stride == 2 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32);
            vkCmdDrawIndexed(command, draw->index_count, 1, draw->first_index, draw->vertex_offset, 0);
        }
        if (renderer->entity_shadow_pipeline != VK_NULL_HANDLE) {
            vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->entity_shadow_pipeline);
            for (uint32_t index = 0; index < entity_draw_count; index++) {
                const PBVulkanEntityDraw *draw = &entity_draws[index];
                if (draw->depth_mode != 0 || draw->mesh == NULL || draw->vertex_count == 0) continue;
                VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
                VkDescriptorSetAllocateInfo allocation = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
                allocation.descriptorPool = renderer->entity_descriptor_pool;
                allocation.descriptorSetCount = 1;
                allocation.pSetLayouts = &renderer->entity_descriptor_layout;
                result = vkAllocateDescriptorSets(context->device, &allocation, &descriptor_set);
                if (result != VK_SUCCESS) break;
                VkDescriptorBufferInfo frame = {renderer->entity_frame_buffer, 0, 128};
                VkDescriptorBufferInfo parts = {renderer->entity_parts_buffer, (VkDeviceSize)index * 1536u, 1536};
                VkWriteDescriptorSet writes[2]; memset(writes, 0, sizeof(writes));
                writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[0].dstSet = descriptor_set; writes[0].dstBinding = 1;
                writes[0].descriptorCount = 1; writes[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                writes[0].pBufferInfo = &frame;
                writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[1].dstSet = descriptor_set; writes[1].dstBinding = 2;
                writes[1].descriptorCount = 1; writes[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
                writes[1].pBufferInfo = &parts;
                vkUpdateDescriptorSets(context->device, 2, writes, 0, NULL);
                vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->entity_pipeline_layout,
                                        0, 1, &descriptor_set, 0, NULL);
                vkCmdPushConstants(command, renderer->entity_pipeline_layout,
                                   VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                                   0, sizeof(draw->constants), draw->constants);
                VkDeviceSize offset = 0;
                vkCmdBindVertexBuffers(command, 0, 1, &draw->mesh->vertex_buffer, &offset);
                vkCmdDraw(command, draw->vertex_count, 1, draw->first_vertex, 0);
            }
        }
        vkCmdEndRenderPass(command);
    }
    VkClearValue clear[2];
    memset(clear, 0, sizeof(clear));
    clear[0].color.float32[0] = clear_red; clear[0].color.float32[1] = clear_green;
    clear[0].color.float32[2] = clear_blue; clear[0].color.float32[3] = clear_alpha;
    clear[1].depthStencil.depth = 1.0f;
    VkRenderPassBeginInfo pass = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
    pass.renderPass = swapchain->render_pass;
    pass.framebuffer = swapchain->scene_framebuffer;
    pass.renderArea.extent = swapchain->extent;
    pass.clearValueCount = 2;
    pass.pClearValues = clear;
    vkCmdBeginRenderPass(command, &pass, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport viewport = {0, (float)swapchain->extent.height, (float)swapchain->extent.width,
                           -(float)swapchain->extent.height, 0, 1};
    VkRect2D scissor = {{0, 0}, swapchain->extent};
    vkCmdSetViewport(command, 0, 1, &viewport);
    vkCmdSetScissor(command, 0, 1, &scissor);
    float sky_constants[12] = {0};
    memcpy(sky_constants, shared_uniforms + 160, 16);
    memcpy(&sky_constants[4], shared_uniforms + 128, 4);
    memcpy(&sky_constants[5], shared_uniforms + 176, 4);
    memcpy(&sky_constants[8], shared_uniforms + 180, 12);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->sky_pipeline);
    vkCmdPushConstants(command, renderer->sky_pipeline_layout, VK_SHADER_STAGE_FRAGMENT_BIT,
                       0, sizeof(sky_constants), sky_constants);
    vkCmdDraw(command, 3, 1, 0, 0);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->pipeline_layout,
                            0, 1, &renderer->descriptor_set, 0, NULL);
    uint32_t bound_pipeline = UINT32_MAX;
    for (uint32_t index = 0; index < draw_count; index++) {
        const PBVulkanChunkDraw *draw = &draws[index];
        if (draw->mesh == NULL || draw->pipeline > 2 || draw->index_count == 0) continue;
        if (bound_pipeline != draw->pipeline) {
            bound_pipeline = draw->pipeline;
            vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->pipelines[bound_pipeline]);
        }
        float push[8] = {draw->origin[0], draw->origin[1], draw->origin[2], draw->origin[3],
                         draw->pipeline == 1 ? 0.35f : 0.0f, draw->pipeline == 2 ? 0.82f : 1.0f, 0, 0};
        vkCmdPushConstants(command, renderer->pipeline_layout,
                           VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(push), push);
        VkDeviceSize offset = 0;
        vkCmdBindVertexBuffers(command, 0, 1, &draw->mesh->vertex_buffer, &offset);
        if (draw->mesh->index_buffer != VK_NULL_HANDLE) {
            vkCmdBindIndexBuffer(command, draw->mesh->index_buffer, 0,
                                 draw->mesh->index_stride == 2 ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32);
            vkCmdDrawIndexed(command, draw->index_count, 1, draw->first_index, draw->vertex_offset, 0);
        }
    }
    if (entity_draw_count > 0) {
        uint32_t bound_entity_pipeline = UINT32_MAX;
        for (uint32_t index = 0; index < entity_draw_count; index++) {
            const PBVulkanEntityDraw *draw = &entity_draws[index];
            if (draw->mesh == NULL || draw->texture == NULL || draw->vertex_count == 0) continue;
            uint32_t entity_pipeline = draw->depth_mode == 0 ? 0 : 1;
            if (bound_entity_pipeline != entity_pipeline) {
                bound_entity_pipeline = entity_pipeline;
                vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                  renderer->entity_pipelines[entity_pipeline]);
            }
            VkDescriptorSet descriptor_set = VK_NULL_HANDLE;
            VkDescriptorSetAllocateInfo allocation = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
            allocation.descriptorPool = renderer->entity_descriptor_pool;
            allocation.descriptorSetCount = 1;
            allocation.pSetLayouts = &renderer->entity_descriptor_layout;
            result = vkAllocateDescriptorSets(context->device, &allocation, &descriptor_set);
            if (result != VK_SUCCESS) {
                vkCmdEndRenderPass(command);
                vkEndCommandBuffer(command);
                return pbvk_fail(PB_VULKAN_RENDER_FAILED, "entity descriptor allocation failed", result);
            }
            VkDescriptorImageInfo image = {draw->texture->sampler, draw->texture->view,
                                            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
            VkDescriptorBufferInfo frame = {renderer->entity_frame_buffer, 0, 128};
            VkDescriptorBufferInfo parts = {renderer->entity_parts_buffer, (VkDeviceSize)index * 1536u, 1536};
            VkWriteDescriptorSet writes[3];
            memset(writes, 0, sizeof(writes));
            writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[0].dstSet = descriptor_set; writes[0].dstBinding = 0;
            writes[0].descriptorCount = 1; writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            writes[0].pImageInfo = &image;
            writes[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[1].dstSet = descriptor_set; writes[1].dstBinding = 1;
            writes[1].descriptorCount = 1; writes[1].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            writes[1].pBufferInfo = &frame;
            writes[2].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[2].dstSet = descriptor_set; writes[2].dstBinding = 2;
            writes[2].descriptorCount = 1; writes[2].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
            writes[2].pBufferInfo = &parts;
            vkUpdateDescriptorSets(context->device, 3, writes, 0, NULL);
            vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->entity_pipeline_layout,
                                    0, 1, &descriptor_set, 0, NULL);
            vkCmdPushConstants(command, renderer->entity_pipeline_layout,
                               VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
                               0, sizeof(draw->constants), draw->constants);
            VkDeviceSize offset = 0;
            vkCmdBindVertexBuffers(command, 0, 1, &draw->mesh->vertex_buffer, &offset);
            vkCmdDraw(command, draw->vertex_count, 1, draw->first_vertex, 0);
        }
    }
    if (particle_draw_count > 0) {
        vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->particle_pipeline);
        vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->particle_pipeline_layout,
                                0, 1, &renderer->descriptor_set, 0, NULL);
        for (uint32_t index = 0; index < particle_draw_count; index++) {
            const PBVulkanParticleDraw *draw = &particle_draws[index];
            if (draw->mesh == NULL || draw->instance_count == 0) continue;
            vkCmdPushConstants(command, renderer->particle_pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,
                               0, sizeof(draw->constants), draw->constants);
            VkBuffer buffers[2] = {draw->mesh->vertex_buffer, draw->mesh->vertex_buffer};
            VkDeviceSize offsets[2] = {0, draw->instance_offset};
            vkCmdBindVertexBuffers(command, 0, 2, buffers, offsets);
            vkCmdDraw(command, 6, draw->instance_count, 0, 0);
        }
    }
    if (ui_draw_count > 0) {
        vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->ui_pipeline);
        vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->ui_pipeline_layout,
                                0, 1, &renderer->ui_descriptor_set, 0, NULL);
        for (uint32_t index = 0; index < ui_draw_count; index++) {
            const PBVulkanUIDraw *draw = &ui_draws[index];
            if (draw->mesh == NULL || draw->vertex_count == 0) continue;
            vkCmdPushConstants(command, renderer->ui_pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT,
                               0, sizeof(draw->screen), draw->screen);
            VkDeviceSize offset = 0;
            vkCmdBindVertexBuffers(command, 0, 1, &draw->mesh->vertex_buffer, &offset);
            vkCmdDraw(command, draw->vertex_count, 1, draw->first_vertex, 0);
        }
    }
    vkCmdEndRenderPass(command);
    VkClearValue present_clear;
    memset(&present_clear, 0, sizeof(present_clear));
    VkRenderPassBeginInfo present_pass = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
    present_pass.renderPass = swapchain->present_render_pass;
    present_pass.framebuffer = swapchain->framebuffers[image_index];
    present_pass.renderArea.extent = swapchain->extent;
    present_pass.clearValueCount = 1;
    present_pass.pClearValues = &present_clear;
    vkCmdBeginRenderPass(command, &present_pass, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdSetViewport(command, 0, 1, &viewport);
    vkCmdSetScissor(command, 0, 1, &scissor);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->composite_pipeline);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, renderer->composite_pipeline_layout,
                            0, 1, &renderer->composite_descriptor_set, 0, NULL);
    vkCmdDraw(command, 3, 1, 0, 0);
    vkCmdEndRenderPass(command);
    result = vkEndCommandBuffer(command);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk command end failed", result);
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &swapchain->image_available;
    submit.pWaitDstStageMask = &wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &swapchain->render_finished;
    result = vkQueueSubmit(context->graphics_queue, 1, &submit, swapchain->frame_fence);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk frame submit failed", result);
    VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &swapchain->render_finished;
    present.swapchainCount = 1;
    present.pSwapchains = &swapchain->swapchain;
    present.pImageIndices = &image_index;
    result = vkQueuePresentKHR(context->graphics_queue, &present);
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) return PB_VULKAN_OUT_OF_DATE;
    return result == VK_SUCCESS ? PB_VULKAN_OK : pbvk_fail(PB_VULKAN_RENDER_FAILED, "chunk frame present failed", result);
}

PBVulkanStatus pb_vulkan_renderer_present_frame2(PBVulkanChunkRenderer *renderer,
                                                 const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                 const PBVulkanChunkDraw *draws, uint32_t draw_count,
                                                 const uint8_t *entity_view_projection, size_t entity_view_projection_size,
                                                 const PBVulkanEntityDraw *entity_draws, uint32_t entity_draw_count,
                                                 const PBVulkanUIDraw *ui_draws, uint32_t ui_draw_count,
                                                 float clear_red, float clear_green,
                                                 float clear_blue, float clear_alpha) {
    return pb_vulkan_renderer_present_frame3(renderer, shared_uniforms, shared_uniform_size,
                                             draws, draw_count,
                                             entity_view_projection, entity_view_projection_size,
                                             entity_draws, entity_draw_count, NULL, 0,
                                             ui_draws, ui_draw_count,
                                             clear_red, clear_green, clear_blue, clear_alpha);
}

PBVulkanStatus pb_vulkan_renderer_present_frame(PBVulkanChunkRenderer *renderer,
                                                const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                const PBVulkanChunkDraw *draws, uint32_t draw_count,
                                                const PBVulkanUIDraw *ui_draws, uint32_t ui_draw_count,
                                                float clear_red, float clear_green,
                                                float clear_blue, float clear_alpha) {
    return pb_vulkan_renderer_present_frame2(renderer, shared_uniforms, shared_uniform_size,
                                             draws, draw_count, NULL, 0, NULL, 0,
                                             ui_draws, ui_draw_count,
                                             clear_red, clear_green, clear_blue, clear_alpha);
}

PBVulkanStatus pb_vulkan_chunk_renderer_present(PBVulkanChunkRenderer *renderer,
                                                const uint8_t *shared_uniforms, size_t shared_uniform_size,
                                                const PBVulkanChunkDraw *draws, uint32_t draw_count,
                                                float clear_red, float clear_green,
                                                float clear_blue, float clear_alpha) {
    return pb_vulkan_renderer_present_frame(renderer, shared_uniforms, shared_uniform_size,
                                            draws, draw_count, NULL, 0,
                                            clear_red, clear_green, clear_blue, clear_alpha);
}

PBVulkanStatus pb_vulkan_chunk_renderer_capture_rgba8(PBVulkanChunkRenderer *renderer,
                                                      uint8_t *out_rgba, size_t out_size) {
    if (renderer == NULL || out_rgba == NULL) return PB_VULKAN_BAD_ARGUMENT;
    PBVulkanSwapchain *swapchain = renderer->swapchain;
    PBVulkanContext *context = swapchain->context;
    const size_t required = (size_t)swapchain->extent.width * swapchain->extent.height * 4u;
    if (out_size < required) return PB_VULKAN_BAD_ARGUMENT;
    vkWaitForFences(context->device, 1, &swapchain->frame_fence, VK_TRUE, UINT64_MAX);
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkResult result = pbvk_buffer_create(context, required, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                                         &buffer, &memory);
    if (result == VK_SUCCESS) result = pbvk_begin_one_time(context, &pool, &command);
    if (result == VK_SUCCESS) {
        VkImageMemoryBarrier to_transfer = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        to_transfer.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
        to_transfer.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        to_transfer.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        to_transfer.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        to_transfer.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_transfer.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        to_transfer.image = swapchain->scene_image;
        to_transfer.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        to_transfer.subresourceRange.levelCount = 1; to_transfer.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, NULL, 0, NULL, 1, &to_transfer);
        VkBufferImageCopy copy = {0};
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent.width = swapchain->extent.width;
        copy.imageExtent.height = swapchain->extent.height;
        copy.imageExtent.depth = 1;
        vkCmdCopyImageToBuffer(command, swapchain->scene_image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                               buffer, 1, &copy);
        VkImageMemoryBarrier to_sample = to_transfer;
        to_sample.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        to_sample.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        to_sample.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        to_sample.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             0, 0, NULL, 0, NULL, 1, &to_sample);
        result = pbvk_end_one_time(context, pool, command);
        pool = VK_NULL_HANDLE;
    }
    void *mapped = NULL;
    if (result == VK_SUCCESS) result = vkMapMemory(context->device, memory, 0, required, 0, &mapped);
    if (result == VK_SUCCESS) {
        const uint8_t *source = (const uint8_t *)mapped;
        const int bgra = swapchain->format == VK_FORMAT_B8G8R8A8_UNORM ||
                         swapchain->format == VK_FORMAT_B8G8R8A8_SRGB;
        for (size_t index = 0; index < required; index += 4) {
            out_rgba[index] = source[index + (bgra ? 2 : 0)];
            out_rgba[index + 1] = source[index + 1];
            out_rgba[index + 2] = source[index + (bgra ? 0 : 2)];
            out_rgba[index + 3] = source[index + 3];
        }
        vkUnmapMemory(context->device, memory);
    }
    if (pool != VK_NULL_HANDLE) vkDestroyCommandPool(context->device, pool, NULL);
    if (buffer != VK_NULL_HANDLE) vkDestroyBuffer(context->device, buffer, NULL);
    if (memory != VK_NULL_HANDLE) vkFreeMemory(context->device, memory, NULL);
    return result == VK_SUCCESS ? PB_VULKAN_OK
        : pbvk_fail(PB_VULKAN_RENDER_FAILED, "scene capture failed", result);
}

void pb_vulkan_chunk_renderer_destroy(PBVulkanChunkRenderer *renderer) {
    if (renderer == NULL) return;
    PBVulkanContext *context = renderer->swapchain == NULL ? NULL : renderer->swapchain->context;
    if (context != NULL) {
        vkDeviceWaitIdle(context->device);
        pbvk_chunk_pipelines_release(renderer);
        pbvk_ui_pipeline_release(renderer);
        pbvk_entity_pipeline_release(renderer);
        pbvk_particle_pipeline_release(renderer);
        pbvk_composite_pipeline_release(renderer);
        pbvk_sky_pipeline_release(renderer);
        pbvk_shadow_release(renderer);
        if (renderer->uniform_buffer != VK_NULL_HANDLE) vkDestroyBuffer(context->device, renderer->uniform_buffer, NULL);
        if (renderer->uniform_memory != VK_NULL_HANDLE) vkFreeMemory(context->device, renderer->uniform_memory, NULL);
        if (renderer->descriptor_pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(context->device, renderer->descriptor_pool, NULL);
        if (renderer->pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(context->device, renderer->pipeline_layout, NULL);
        if (renderer->descriptor_layout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(context->device, renderer->descriptor_layout, NULL);
        if (renderer->ui_descriptor_pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(context->device, renderer->ui_descriptor_pool, NULL);
        if (renderer->ui_pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(context->device, renderer->ui_pipeline_layout, NULL);
        if (renderer->ui_descriptor_layout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(context->device, renderer->ui_descriptor_layout, NULL);
        if (renderer->entity_frame_buffer != VK_NULL_HANDLE) vkDestroyBuffer(context->device, renderer->entity_frame_buffer, NULL);
        if (renderer->entity_frame_memory != VK_NULL_HANDLE) vkFreeMemory(context->device, renderer->entity_frame_memory, NULL);
        if (renderer->entity_parts_buffer != VK_NULL_HANDLE) vkDestroyBuffer(context->device, renderer->entity_parts_buffer, NULL);
        if (renderer->entity_parts_memory != VK_NULL_HANDLE) vkFreeMemory(context->device, renderer->entity_parts_memory, NULL);
        if (renderer->entity_descriptor_pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(context->device, renderer->entity_descriptor_pool, NULL);
        if (renderer->entity_pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(context->device, renderer->entity_pipeline_layout, NULL);
        if (renderer->entity_descriptor_layout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(context->device, renderer->entity_descriptor_layout, NULL);
        if (renderer->particle_pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(context->device, renderer->particle_pipeline_layout, NULL);
        if (renderer->composite_sampler != VK_NULL_HANDLE) vkDestroySampler(context->device, renderer->composite_sampler, NULL);
        if (renderer->composite_descriptor_pool != VK_NULL_HANDLE) vkDestroyDescriptorPool(context->device, renderer->composite_descriptor_pool, NULL);
        if (renderer->composite_pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(context->device, renderer->composite_pipeline_layout, NULL);
        if (renderer->composite_descriptor_layout != VK_NULL_HANDLE) vkDestroyDescriptorSetLayout(context->device, renderer->composite_descriptor_layout, NULL);
        if (renderer->sky_pipeline_layout != VK_NULL_HANDLE) vkDestroyPipelineLayout(context->device, renderer->sky_pipeline_layout, NULL);
    }
    free(renderer->vertex_spirv);
    free(renderer->fragment_spirv);
    free(renderer->ui_vertex_spirv);
    free(renderer->ui_fragment_spirv);
    free(renderer->shadow_vertex_spirv);
    free(renderer->entity_vertex_spirv);
    free(renderer->entity_fragment_spirv);
    free(renderer->entity_shadow_vertex_spirv);
    free(renderer->particle_vertex_spirv);
    free(renderer->particle_fragment_spirv);
    free(renderer->composite_vertex_spirv);
    free(renderer->composite_fragment_spirv);
    free(renderer->sky_vertex_spirv);
    free(renderer->sky_fragment_spirv);
    free(renderer);
}

PBVulkanStatus pb_vulkan_render_clear(PBVulkanContext *context,
                                      uint32_t width, uint32_t height,
                                      float red, float green, float blue, float alpha,
                                      uint8_t *out_rgba, size_t out_size) {
    if (context == NULL || width == 0 || height == 0 || out_rgba == NULL) {
        return pbvk_fail(PB_VULKAN_BAD_ARGUMENT, "invalid render-clear arguments", VK_ERROR_UNKNOWN);
    }
    const uint64_t required64 = (uint64_t)width * (uint64_t)height * 4u;
    if (required64 > SIZE_MAX || out_size < (size_t)required64) {
        return pbvk_fail(PB_VULKAN_BAD_ARGUMENT, "render-clear output buffer is too small", VK_ERROR_UNKNOWN);
    }
    const VkDeviceSize byte_count = (VkDeviceSize)required64;
    VkResult result;
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory image_memory = VK_NULL_HANDLE;
    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory staging_memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;

    VkImageCreateInfo image_info = {0};
    image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = VK_IMAGE_TYPE_2D;
    image_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    image_info.extent.width = width;
    image_info.extent.height = height;
    image_info.extent.depth = 1;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    result = vkCreateImage(context->device, &image_info, NULL, &image);
    if (result != VK_SUCCESS) goto fail;

    VkMemoryRequirements image_requirements;
    vkGetImageMemoryRequirements(context->device, image, &image_requirements);
    uint32_t image_memory_type = pbvk_memory_type(context, image_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (image_memory_type == UINT32_MAX) image_memory_type = pbvk_memory_type(context, image_requirements.memoryTypeBits, 0);
    if (image_memory_type == UINT32_MAX) { result = VK_ERROR_FEATURE_NOT_PRESENT; goto fail; }
    VkMemoryAllocateInfo image_allocation = {0};
    image_allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    image_allocation.allocationSize = image_requirements.size;
    image_allocation.memoryTypeIndex = image_memory_type;
    result = vkAllocateMemory(context->device, &image_allocation, NULL, &image_memory);
    if (result != VK_SUCCESS) goto fail;
    result = vkBindImageMemory(context->device, image, image_memory, 0);
    if (result != VK_SUCCESS) goto fail;

    VkBufferCreateInfo buffer_info = {0};
    buffer_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buffer_info.size = byte_count;
    buffer_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    buffer_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    result = vkCreateBuffer(context->device, &buffer_info, NULL, &staging);
    if (result != VK_SUCCESS) goto fail;
    VkMemoryRequirements buffer_requirements;
    vkGetBufferMemoryRequirements(context->device, staging, &buffer_requirements);
    uint32_t buffer_memory_type = pbvk_memory_type(
        context, buffer_requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (buffer_memory_type == UINT32_MAX) { result = VK_ERROR_FEATURE_NOT_PRESENT; goto fail; }
    VkMemoryAllocateInfo buffer_allocation = {0};
    buffer_allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    buffer_allocation.allocationSize = buffer_requirements.size;
    buffer_allocation.memoryTypeIndex = buffer_memory_type;
    result = vkAllocateMemory(context->device, &buffer_allocation, NULL, &staging_memory);
    if (result != VK_SUCCESS) goto fail;
    result = vkBindBufferMemory(context->device, staging, staging_memory, 0);
    if (result != VK_SUCCESS) goto fail;

    VkCommandPoolCreateInfo pool_info = {0};
    pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;
    pool_info.queueFamilyIndex = context->queue_family;
    result = vkCreateCommandPool(context->device, &pool_info, NULL, &pool);
    if (result != VK_SUCCESS) goto fail;
    VkCommandBufferAllocateInfo command_info = {0};
    command_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    command_info.commandPool = pool;
    command_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command_info.commandBufferCount = 1;
    result = vkAllocateCommandBuffers(context->device, &command_info, &command);
    if (result != VK_SUCCESS) goto fail;
    VkCommandBufferBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    result = vkBeginCommandBuffer(command, &begin);
    if (result != VK_SUCCESS) goto fail;

    VkImageMemoryBarrier to_clear = {0};
    to_clear.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    to_clear.srcAccessMask = 0;
    to_clear.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_clear.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    to_clear.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_clear.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_clear.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    to_clear.image = image;
    to_clear.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    to_clear.subresourceRange.levelCount = 1;
    to_clear.subresourceRange.layerCount = 1;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &to_clear);
    VkClearColorValue color = {{red, green, blue, alpha}};
    vkCmdClearColorImage(command, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &to_clear.subresourceRange);

    VkImageMemoryBarrier to_copy = to_clear;
    to_copy.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    to_copy.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    to_copy.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    to_copy.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &to_copy);
    VkBufferImageCopy copy = {0};
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = width;
    copy.imageExtent.height = height;
    copy.imageExtent.depth = 1;
    vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &copy);
    result = vkEndCommandBuffer(command);
    if (result != VK_SUCCESS) goto fail;
    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    result = vkQueueSubmit(context->graphics_queue, 1, &submit, VK_NULL_HANDLE);
    if (result != VK_SUCCESS) goto fail;
    result = vkQueueWaitIdle(context->graphics_queue);
    if (result != VK_SUCCESS) goto fail;
    void *mapped = NULL;
    result = vkMapMemory(context->device, staging_memory, 0, byte_count, 0, &mapped);
    if (result != VK_SUCCESS) goto fail;
    memcpy(out_rgba, mapped, (size_t)byte_count);
    vkUnmapMemory(context->device, staging_memory);

    vkDestroyCommandPool(context->device, pool, NULL);
    vkDestroyBuffer(context->device, staging, NULL);
    vkFreeMemory(context->device, staging_memory, NULL);
    vkDestroyImage(context->device, image, NULL);
    vkFreeMemory(context->device, image_memory, NULL);
    return PB_VULKAN_OK;

fail:
    if (pool != VK_NULL_HANDLE) vkDestroyCommandPool(context->device, pool, NULL);
    if (staging != VK_NULL_HANDLE) vkDestroyBuffer(context->device, staging, NULL);
    if (staging_memory != VK_NULL_HANDLE) vkFreeMemory(context->device, staging_memory, NULL);
    if (image != VK_NULL_HANDLE) vkDestroyImage(context->device, image, NULL);
    if (image_memory != VK_NULL_HANDLE) vkFreeMemory(context->device, image_memory, NULL);
    return pbvk_fail(PB_VULKAN_RENDER_FAILED, "offscreen clear/readback failed", result);
}

static void pbvk_swapchain_release(PBVulkanSwapchain *swapchain) {
    if (swapchain == NULL || swapchain->context == NULL) return;
    VkDevice device = swapchain->context->device;
    if (swapchain->frame_fence != VK_NULL_HANDLE) vkDestroyFence(device, swapchain->frame_fence, NULL);
    if (swapchain->image_available != VK_NULL_HANDLE) vkDestroySemaphore(device, swapchain->image_available, NULL);
    if (swapchain->render_finished != VK_NULL_HANDLE) vkDestroySemaphore(device, swapchain->render_finished, NULL);
    if (swapchain->command_pool != VK_NULL_HANDLE) vkDestroyCommandPool(device, swapchain->command_pool, NULL);
    if (swapchain->framebuffers != NULL) {
        for (uint32_t index = 0; index < swapchain->image_count; index++) {
            if (swapchain->framebuffers[index] != VK_NULL_HANDLE) vkDestroyFramebuffer(device, swapchain->framebuffers[index], NULL);
        }
    }
    if (swapchain->scene_framebuffer != VK_NULL_HANDLE) vkDestroyFramebuffer(device, swapchain->scene_framebuffer, NULL);
    if (swapchain->render_pass != VK_NULL_HANDLE) vkDestroyRenderPass(device, swapchain->render_pass, NULL);
    if (swapchain->present_render_pass != VK_NULL_HANDLE) vkDestroyRenderPass(device, swapchain->present_render_pass, NULL);
    if (swapchain->scene_view != VK_NULL_HANDLE) vkDestroyImageView(device, swapchain->scene_view, NULL);
    if (swapchain->scene_image != VK_NULL_HANDLE) vkDestroyImage(device, swapchain->scene_image, NULL);
    if (swapchain->scene_memory != VK_NULL_HANDLE) vkFreeMemory(device, swapchain->scene_memory, NULL);
    if (swapchain->depth_view != VK_NULL_HANDLE) vkDestroyImageView(device, swapchain->depth_view, NULL);
    if (swapchain->depth_image != VK_NULL_HANDLE) vkDestroyImage(device, swapchain->depth_image, NULL);
    if (swapchain->depth_memory != VK_NULL_HANDLE) vkFreeMemory(device, swapchain->depth_memory, NULL);
    if (swapchain->views != NULL) {
        for (uint32_t index = 0; index < swapchain->image_count; index++) {
            if (swapchain->views[index] != VK_NULL_HANDLE) vkDestroyImageView(device, swapchain->views[index], NULL);
        }
    }
    if (swapchain->swapchain != VK_NULL_HANDLE) vkDestroySwapchainKHR(device, swapchain->swapchain, NULL);
    free(swapchain->commands);
    free(swapchain->framebuffers);
    free(swapchain->views);
    free(swapchain->images);
    swapchain->commands = NULL;
    swapchain->framebuffers = NULL;
    swapchain->views = NULL;
    swapchain->images = NULL;
    swapchain->image_count = 0;
    swapchain->swapchain = VK_NULL_HANDLE;
    swapchain->render_pass = VK_NULL_HANDLE;
    swapchain->present_render_pass = VK_NULL_HANDLE;
    swapchain->scene_framebuffer = VK_NULL_HANDLE;
    swapchain->scene_view = VK_NULL_HANDLE;
    swapchain->scene_image = VK_NULL_HANDLE;
    swapchain->scene_memory = VK_NULL_HANDLE;
    swapchain->depth_view = VK_NULL_HANDLE;
    swapchain->depth_image = VK_NULL_HANDLE;
    swapchain->depth_memory = VK_NULL_HANDLE;
    swapchain->command_pool = VK_NULL_HANDLE;
    swapchain->image_available = VK_NULL_HANDLE;
    swapchain->render_finished = VK_NULL_HANDLE;
    swapchain->frame_fence = VK_NULL_HANDLE;
}

static PBVulkanStatus pbvk_swapchain_build(PBVulkanSwapchain *swapchain, uint32_t width, uint32_t height) {
    PBVulkanContext *context = swapchain->context;
    VkBool32 supported = VK_FALSE;
    VkResult result = vkGetPhysicalDeviceSurfaceSupportKHR(context->physical_device, context->queue_family,
                                                           swapchain->surface, &supported);
    if (result != VK_SUCCESS || !supported) return pbvk_fail(PB_VULKAN_UNAVAILABLE, "graphics queue cannot present to SDL surface", result);

    VkSurfaceCapabilitiesKHR capabilities;
    result = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(context->physical_device, swapchain->surface, &capabilities);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "surface capabilities query failed", result);
    uint32_t format_count = 0;
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(context->physical_device, swapchain->surface, &format_count, NULL);
    if (result != VK_SUCCESS || format_count == 0) return pbvk_fail(PB_VULKAN_UNAVAILABLE, "surface has no formats", result);
    VkSurfaceFormatKHR *formats = (VkSurfaceFormatKHR *)calloc(format_count, sizeof(VkSurfaceFormatKHR));
    if (formats == NULL) return pbvk_fail(PB_VULKAN_OUT_OF_MEMORY, "surface format allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    vkGetPhysicalDeviceSurfaceFormatsKHR(context->physical_device, swapchain->surface, &format_count, formats);
    VkSurfaceFormatKHR selected = formats[0];
    for (uint32_t index = 0; index < format_count; index++) {
        if ((formats[index].format == VK_FORMAT_B8G8R8A8_UNORM || formats[index].format == VK_FORMAT_B8G8R8A8_SRGB) &&
            formats[index].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            selected = formats[index];
            break;
        }
    }
    free(formats);
    VkExtent2D extent;
    if (capabilities.currentExtent.width != UINT32_MAX) {
        extent = capabilities.currentExtent;
    } else {
        extent.width = width < capabilities.minImageExtent.width ? capabilities.minImageExtent.width :
                       width > capabilities.maxImageExtent.width ? capabilities.maxImageExtent.width : width;
        extent.height = height < capabilities.minImageExtent.height ? capabilities.minImageExtent.height :
                        height > capabilities.maxImageExtent.height ? capabilities.maxImageExtent.height : height;
    }
    uint32_t image_count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount) image_count = capabilities.maxImageCount;

    VkSwapchainCreateInfoKHR create = {0};
    create.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    create.surface = swapchain->surface;
    create.minImageCount = image_count;
    create.imageFormat = selected.format;
    create.imageColorSpace = selected.colorSpace;
    create.imageExtent = extent;
    create.imageArrayLayers = 1;
    create.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    create.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    create.preTransform = capabilities.currentTransform;
    create.compositeAlpha = (capabilities.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
        ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR : (VkCompositeAlphaFlagBitsKHR)(capabilities.supportedCompositeAlpha & -capabilities.supportedCompositeAlpha);
    create.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    create.clipped = VK_TRUE;
    result = vkCreateSwapchainKHR(context->device, &create, NULL, &swapchain->swapchain);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "vkCreateSwapchainKHR failed", result);
    swapchain->format = selected.format;
    swapchain->extent = extent;
    vkGetSwapchainImagesKHR(context->device, swapchain->swapchain, &swapchain->image_count, NULL);
    swapchain->images = (VkImage *)calloc(swapchain->image_count, sizeof(VkImage));
    swapchain->views = (VkImageView *)calloc(swapchain->image_count, sizeof(VkImageView));
    swapchain->framebuffers = (VkFramebuffer *)calloc(swapchain->image_count, sizeof(VkFramebuffer));
    swapchain->commands = (VkCommandBuffer *)calloc(swapchain->image_count, sizeof(VkCommandBuffer));
    if (swapchain->images == NULL || swapchain->views == NULL || swapchain->framebuffers == NULL || swapchain->commands == NULL) {
        pbvk_swapchain_release(swapchain);
        return pbvk_fail(PB_VULKAN_OUT_OF_MEMORY, "swapchain resource allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    }
    vkGetSwapchainImagesKHR(context->device, swapchain->swapchain, &swapchain->image_count, swapchain->images);

    for (uint32_t index = 0; index < swapchain->image_count; index++) {
        VkImageViewCreateInfo view = {0};
        view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = swapchain->images[index];
        view.viewType = VK_IMAGE_VIEW_TYPE_2D;
        view.format = swapchain->format;
        view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        view.subresourceRange.levelCount = 1;
        view.subresourceRange.layerCount = 1;
        result = vkCreateImageView(context->device, &view, NULL, &swapchain->views[index]);
        if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain image view failed", result); }
    }

    VkImageCreateInfo scene_image = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    scene_image.imageType = VK_IMAGE_TYPE_2D;
    scene_image.format = swapchain->format;
    scene_image.extent.width = extent.width; scene_image.extent.height = extent.height; scene_image.extent.depth = 1;
    scene_image.mipLevels = 1; scene_image.arrayLayers = 1; scene_image.samples = VK_SAMPLE_COUNT_1_BIT;
    scene_image.tiling = VK_IMAGE_TILING_OPTIMAL;
    scene_image.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                        VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    scene_image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    result = vkCreateImage(context->device, &scene_image, NULL, &swapchain->scene_image);
    VkMemoryRequirements scene_requirements;
    if (result == VK_SUCCESS) vkGetImageMemoryRequirements(context->device, swapchain->scene_image, &scene_requirements);
    uint32_t scene_memory_type = result == VK_SUCCESS
        ? pbvk_memory_type(context, scene_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) : UINT32_MAX;
    VkMemoryAllocateInfo scene_allocation = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    if (result == VK_SUCCESS && scene_memory_type != UINT32_MAX) {
        scene_allocation.allocationSize = scene_requirements.size;
        scene_allocation.memoryTypeIndex = scene_memory_type;
        result = vkAllocateMemory(context->device, &scene_allocation, NULL, &swapchain->scene_memory);
    } else if (result == VK_SUCCESS) result = VK_ERROR_FEATURE_NOT_PRESENT;
    if (result == VK_SUCCESS) result = vkBindImageMemory(context->device, swapchain->scene_image, swapchain->scene_memory, 0);
    VkImageViewCreateInfo scene_view = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    scene_view.image = swapchain->scene_image; scene_view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    scene_view.format = swapchain->format; scene_view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    scene_view.subresourceRange.levelCount = 1; scene_view.subresourceRange.layerCount = 1;
    if (result == VK_SUCCESS) result = vkCreateImageView(context->device, &scene_view, NULL, &swapchain->scene_view);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "scene image creation failed", result); }

    VkImageCreateInfo depth_image = {0};
    depth_image.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    depth_image.imageType = VK_IMAGE_TYPE_2D;
    depth_image.format = VK_FORMAT_D32_SFLOAT;
    depth_image.extent.width = extent.width;
    depth_image.extent.height = extent.height;
    depth_image.extent.depth = 1;
    depth_image.mipLevels = 1;
    depth_image.arrayLayers = 1;
    depth_image.samples = VK_SAMPLE_COUNT_1_BIT;
    depth_image.tiling = VK_IMAGE_TILING_OPTIMAL;
    depth_image.usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    depth_image.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    result = vkCreateImage(context->device, &depth_image, NULL, &swapchain->depth_image);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "depth image creation failed", result); }
    VkMemoryRequirements depth_requirements;
    vkGetImageMemoryRequirements(context->device, swapchain->depth_image, &depth_requirements);
    uint32_t depth_memory_type = pbvk_memory_type(context, depth_requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    VkMemoryAllocateInfo depth_allocation = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    depth_allocation.allocationSize = depth_requirements.size;
    depth_allocation.memoryTypeIndex = depth_memory_type;
    result = depth_memory_type == UINT32_MAX ? VK_ERROR_FEATURE_NOT_PRESENT :
             vkAllocateMemory(context->device, &depth_allocation, NULL, &swapchain->depth_memory);
    if (result == VK_SUCCESS) result = vkBindImageMemory(context->device, swapchain->depth_image, swapchain->depth_memory, 0);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "depth memory creation failed", result); }
    VkImageViewCreateInfo depth_view = {0};
    depth_view.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    depth_view.image = swapchain->depth_image;
    depth_view.viewType = VK_IMAGE_VIEW_TYPE_2D;
    depth_view.format = VK_FORMAT_D32_SFLOAT;
    depth_view.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    depth_view.subresourceRange.levelCount = 1;
    depth_view.subresourceRange.layerCount = 1;
    result = vkCreateImageView(context->device, &depth_view, NULL, &swapchain->depth_view);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "depth view creation failed", result); }

    VkAttachmentDescription attachments[2];
    memset(attachments, 0, sizeof(attachments));
    attachments[0].format = swapchain->format;
    attachments[0].samples = VK_SAMPLE_COUNT_1_BIT;
    attachments[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachments[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachments[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachments[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachments[0].finalLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    attachments[1].format = VK_FORMAT_D32_SFLOAT;
    attachments[1].samples = VK_SAMPLE_COUNT_1_BIT;
    attachments[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachments[1].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachments[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachments[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachments[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachments[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    VkAttachmentReference reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkAttachmentReference depth_reference = {1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass = {0};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;
    subpass.pDepthStencilAttachment = &depth_reference;
    VkSubpassDependency dependencies[2]; memset(dependencies, 0, sizeof(dependencies));
    dependencies[0].srcSubpass = VK_SUBPASS_EXTERNAL;
    dependencies[0].dstSubpass = 0;
    dependencies[0].srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dependencies[0].dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[0].srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    dependencies[0].dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
    dependencies[1].srcSubpass = 0;
    dependencies[1].dstSubpass = VK_SUBPASS_EXTERNAL;
    dependencies[1].srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[1].dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dependencies[1].srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dependencies[1].dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    VkRenderPassCreateInfo render_pass = {0};
    render_pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    render_pass.attachmentCount = 2;
    render_pass.pAttachments = attachments;
    render_pass.subpassCount = 1;
    render_pass.pSubpasses = &subpass;
    render_pass.dependencyCount = 2;
    render_pass.pDependencies = dependencies;
    result = vkCreateRenderPass(context->device, &render_pass, NULL, &swapchain->render_pass);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain render pass failed", result); }
    VkFramebufferCreateInfo scene_framebuffer = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
    scene_framebuffer.renderPass = swapchain->render_pass;
    VkImageView scene_attachments[2] = {swapchain->scene_view, swapchain->depth_view};
    scene_framebuffer.attachmentCount = 2; scene_framebuffer.pAttachments = scene_attachments;
    scene_framebuffer.width = extent.width; scene_framebuffer.height = extent.height; scene_framebuffer.layers = 1;
    result = vkCreateFramebuffer(context->device, &scene_framebuffer, NULL, &swapchain->scene_framebuffer);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "scene framebuffer failed", result); }

    VkAttachmentDescription present_attachment = {0};
    present_attachment.format = swapchain->format; present_attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    present_attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; present_attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    present_attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    present_attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    present_attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    present_attachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference present_reference = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription present_subpass = {0};
    present_subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    present_subpass.colorAttachmentCount = 1; present_subpass.pColorAttachments = &present_reference;
    VkSubpassDependency present_dependency = {0};
    present_dependency.srcSubpass = VK_SUBPASS_EXTERNAL; present_dependency.dstSubpass = 0;
    present_dependency.srcStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    present_dependency.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    present_dependency.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    present_dependency.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    VkRenderPassCreateInfo present_pass = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    present_pass.attachmentCount = 1; present_pass.pAttachments = &present_attachment;
    present_pass.subpassCount = 1; present_pass.pSubpasses = &present_subpass;
    present_pass.dependencyCount = 1; present_pass.pDependencies = &present_dependency;
    result = vkCreateRenderPass(context->device, &present_pass, NULL, &swapchain->present_render_pass);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "present render pass failed", result); }
    for (uint32_t index = 0; index < swapchain->image_count; index++) {
        VkFramebufferCreateInfo framebuffer = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        framebuffer.renderPass = swapchain->present_render_pass;
        framebuffer.attachmentCount = 1; framebuffer.pAttachments = &swapchain->views[index];
        framebuffer.width = extent.width; framebuffer.height = extent.height; framebuffer.layers = 1;
        result = vkCreateFramebuffer(context->device, &framebuffer, NULL, &swapchain->framebuffers[index]);
        if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "present framebuffer failed", result); }
    }
    VkCommandPoolCreateInfo pool = {0};
    pool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = context->queue_family;
    result = vkCreateCommandPool(context->device, &pool, NULL, &swapchain->command_pool);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain command pool failed", result); }
    VkCommandBufferAllocateInfo commands = {0};
    commands.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    commands.commandPool = swapchain->command_pool;
    commands.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    commands.commandBufferCount = swapchain->image_count;
    result = vkAllocateCommandBuffers(context->device, &commands, swapchain->commands);
    if (result != VK_SUCCESS) { pbvk_swapchain_release(swapchain); return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain command allocation failed", result); }
    VkSemaphoreCreateInfo semaphore = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkFenceCreateInfo fence = {0};
    fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    if (vkCreateSemaphore(context->device, &semaphore, NULL, &swapchain->image_available) != VK_SUCCESS ||
        vkCreateSemaphore(context->device, &semaphore, NULL, &swapchain->render_finished) != VK_SUCCESS ||
        vkCreateFence(context->device, &fence, NULL, &swapchain->frame_fence) != VK_SUCCESS) {
        pbvk_swapchain_release(swapchain);
        return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain synchronization creation failed", VK_ERROR_INITIALIZATION_FAILED);
    }
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_swapchain_create(PBVulkanContext *context, uint64_t surface,
                                          uint32_t width, uint32_t height,
                                          PBVulkanSwapchain **out_swapchain) {
    if (context == NULL || surface == 0 || width == 0 || height == 0 || out_swapchain == NULL) return PB_VULKAN_BAD_ARGUMENT;
    *out_swapchain = NULL;
    PBVulkanSwapchain *swapchain = (PBVulkanSwapchain *)calloc(1, sizeof(PBVulkanSwapchain));
    if (swapchain == NULL) return PB_VULKAN_OUT_OF_MEMORY;
    swapchain->context = context;
    swapchain->surface = (VkSurfaceKHR)surface;
    PBVulkanStatus status = pbvk_swapchain_build(swapchain, width, height);
    if (status != PB_VULKAN_OK) { free(swapchain); return status; }
    *out_swapchain = swapchain;
    return PB_VULKAN_OK;
}

PBVulkanStatus pb_vulkan_swapchain_resize(PBVulkanSwapchain *swapchain, uint32_t width, uint32_t height) {
    if (swapchain == NULL || width == 0 || height == 0) return PB_VULKAN_BAD_ARGUMENT;
    vkDeviceWaitIdle(swapchain->context->device);
    pbvk_swapchain_release(swapchain);
    return pbvk_swapchain_build(swapchain, width, height);
}

PBVulkanStatus pb_vulkan_swapchain_present_clear(PBVulkanSwapchain *swapchain,
                                                 float red, float green, float blue, float alpha) {
    if (swapchain == NULL) return PB_VULKAN_BAD_ARGUMENT;
    PBVulkanContext *context = swapchain->context;
    vkWaitForFences(context->device, 1, &swapchain->frame_fence, VK_TRUE, UINT64_MAX);
    uint32_t image_index = 0;
    VkResult result = vkAcquireNextImageKHR(context->device, swapchain->swapchain, UINT64_MAX,
                                            swapchain->image_available, VK_NULL_HANDLE, &image_index);
    if (result == VK_ERROR_OUT_OF_DATE_KHR) return PB_VULKAN_OUT_OF_DATE;
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain image acquisition failed", result);
    vkResetFences(context->device, 1, &swapchain->frame_fence);
    VkCommandBuffer command = swapchain->commands[image_index];
    vkResetCommandBuffer(command, 0);
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    result = vkBeginCommandBuffer(command, &begin);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain command begin failed", result);
    VkClearValue clear[1];
    memset(clear, 0, sizeof(clear));
    clear[0].color.float32[0] = red;
    clear[0].color.float32[1] = green;
    clear[0].color.float32[2] = blue;
    clear[0].color.float32[3] = alpha;
    VkRenderPassBeginInfo pass = {0};
    pass.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass.renderPass = swapchain->present_render_pass;
    pass.framebuffer = swapchain->framebuffers[image_index];
    pass.renderArea.extent = swapchain->extent;
    pass.clearValueCount = 1;
    pass.pClearValues = clear;
    vkCmdBeginRenderPass(command, &pass, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdEndRenderPass(command);
    result = vkEndCommandBuffer(command);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain command end failed", result);
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &swapchain->image_available;
    submit.pWaitDstStageMask = &wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &swapchain->render_finished;
    result = vkQueueSubmit(context->graphics_queue, 1, &submit, swapchain->frame_fence);
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain queue submit failed", result);
    VkPresentInfoKHR present = {0};
    present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &swapchain->render_finished;
    present.swapchainCount = 1;
    present.pSwapchains = &swapchain->swapchain;
    present.pImageIndices = &image_index;
    result = vkQueuePresentKHR(context->graphics_queue, &present);
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) return PB_VULKAN_OUT_OF_DATE;
    if (result != VK_SUCCESS) return pbvk_fail(PB_VULKAN_RENDER_FAILED, "swapchain present failed", result);
    return PB_VULKAN_OK;
}

void pb_vulkan_swapchain_destroy(PBVulkanSwapchain *swapchain) {
    if (swapchain == NULL) return;
    vkDeviceWaitIdle(swapchain->context->device);
    pbvk_swapchain_release(swapchain);
    free(swapchain);
}

const char *pb_vulkan_last_error(void) { return pbvk_error; }
