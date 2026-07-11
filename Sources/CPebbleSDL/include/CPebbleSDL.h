#ifndef CPEBBLESDL_H
#define CPEBBLESDL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PBWindow PBWindow;

typedef enum PBWindowEventType {
    PB_WINDOW_EVENT_NONE = 0,
    PB_WINDOW_EVENT_QUIT = 1,
    PB_WINDOW_EVENT_RESIZED = 2,
    PB_WINDOW_EVENT_KEY_DOWN = 3,
    PB_WINDOW_EVENT_KEY_UP = 4,
    PB_WINDOW_EVENT_MOUSE_MOTION = 5,
    PB_WINDOW_EVENT_MOUSE_BUTTON_DOWN = 6,
    PB_WINDOW_EVENT_MOUSE_BUTTON_UP = 7,
    PB_WINDOW_EVENT_MOUSE_WHEEL = 8,
    PB_WINDOW_EVENT_TEXT = 9,
    PB_WINDOW_EVENT_FOCUS_GAINED = 10,
    PB_WINDOW_EVENT_FOCUS_LOST = 11
} PBWindowEventType;

typedef struct PBWindowEvent {
    uint32_t struct_size;
    PBWindowEventType type;
    int32_t a;
    int32_t b;
    float x;
    float y;
    char text[32];
} PBWindowEvent;

int32_t pb_window_create(const char *title, int32_t width, int32_t height, PBWindow **out_window);
void pb_window_destroy(PBWindow *window);
int32_t pb_window_poll_event(PBWindow *window, PBWindowEvent *out_event);
void pb_window_size_pixels(PBWindow *window, int32_t *out_width, int32_t *out_height);
void pb_window_set_relative_mouse(PBWindow *window, uint32_t enabled);
int32_t pb_window_set_fullscreen(PBWindow *window, uint32_t enabled);
uint32_t pb_window_is_fullscreen(PBWindow *window);
void pb_window_set_text_input(PBWindow *window, uint32_t enabled);
void pb_window_set_title(PBWindow *window, const char *title);
int32_t pb_window_set_clipboard_text(const char *text);
char *pb_window_get_clipboard_text(void);
void pb_window_free(void *pointer);
const char * const *pb_window_vulkan_extensions(uint32_t *out_count);
int32_t pb_window_create_vulkan_surface(PBWindow *window, uintptr_t instance, uint64_t *out_surface);
void pb_window_destroy_vulkan_surface(uintptr_t instance, uint64_t surface);
const char *pb_window_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
