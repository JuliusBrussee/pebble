#include "CPebbleSDL.h"

#include <string.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

struct PBWindow { SDL_Window *window; uint32_t fullscreen; SDL_Gamepad *gamepads[8]; };

static int pb_sdl_users = 0;

int32_t pb_window_create(const char *title, int32_t width, int32_t height, PBWindow **out_window) {
    if (title == NULL || width <= 0 || height <= 0 || out_window == NULL) return -1;
    *out_window = NULL;
    if (pb_sdl_users == 0 && !SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_GAMEPAD)) return -2;
    PBWindow *window = (PBWindow *)SDL_calloc(1, sizeof(PBWindow));
    if (window == NULL) return -3;
    window->window = SDL_CreateWindow(title, width, height,
                                      SDL_WINDOW_VULKAN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (window->window == NULL) { SDL_free(window); if (pb_sdl_users == 0) SDL_Quit(); return -4; }
    pb_sdl_users++;
    *out_window = window;
    return 0;
}

void pb_window_destroy(PBWindow *window) {
    if (window == NULL) return;
    for (int i = 0; i < 8; i++) if (window->gamepads[i] != NULL) SDL_CloseGamepad(window->gamepads[i]);
    SDL_DestroyWindow(window->window);
    SDL_free(window);
    if (pb_sdl_users > 0) pb_sdl_users--;
    if (pb_sdl_users == 0) SDL_Quit();
}

int32_t pb_window_poll_event(PBWindow *window, PBWindowEvent *out_event) {
    (void)window;
    if (out_event == NULL || out_event->struct_size < sizeof(PBWindowEvent)) return -1;
    SDL_Event event;
    if (!SDL_PollEvent(&event)) { out_event->type = PB_WINDOW_EVENT_NONE; return 0; }
    memset(out_event, 0, sizeof(PBWindowEvent));
    out_event->struct_size = sizeof(PBWindowEvent);
    switch (event.type) {
        case SDL_EVENT_GAMEPAD_ADDED:
            if (window != NULL) {
                for (int i = 0; i < 8; i++) if (window->gamepads[i] == NULL) {
                    window->gamepads[i] = SDL_OpenGamepad(event.gdevice.which);
                    break;
                }
            }
            out_event->type = PB_WINDOW_EVENT_NONE;
            break;
        case SDL_EVENT_GAMEPAD_REMOVED:
            if (window != NULL) {
                for (int i = 0; i < 8; i++) if (window->gamepads[i] != NULL &&
                    SDL_GetGamepadID(window->gamepads[i]) == event.gdevice.which) {
                    SDL_CloseGamepad(window->gamepads[i]); window->gamepads[i] = NULL;
                }
            }
            out_event->type = PB_WINDOW_EVENT_NONE;
            break;
        case SDL_EVENT_QUIT: out_event->type = PB_WINDOW_EVENT_QUIT; break;
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_RESIZED:
            out_event->type = PB_WINDOW_EVENT_RESIZED;
            out_event->a = event.window.data1; out_event->b = event.window.data2; break;
        case SDL_EVENT_KEY_DOWN:
            out_event->type = PB_WINDOW_EVENT_KEY_DOWN; out_event->a = (int32_t)event.key.scancode; out_event->b = event.key.repeat; break;
        case SDL_EVENT_KEY_UP:
            out_event->type = PB_WINDOW_EVENT_KEY_UP; out_event->a = (int32_t)event.key.scancode; break;
        case SDL_EVENT_MOUSE_MOTION:
            out_event->type = PB_WINDOW_EVENT_MOUSE_MOTION;
            out_event->a = (int32_t)event.motion.x; out_event->b = (int32_t)event.motion.y;
            out_event->x = event.motion.xrel; out_event->y = event.motion.yrel; break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            out_event->type = PB_WINDOW_EVENT_MOUSE_BUTTON_DOWN; out_event->a = event.button.button; break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            out_event->type = PB_WINDOW_EVENT_MOUSE_BUTTON_UP; out_event->a = event.button.button; break;
        case SDL_EVENT_MOUSE_WHEEL:
            out_event->type = PB_WINDOW_EVENT_MOUSE_WHEEL; out_event->x = event.wheel.x; out_event->y = event.wheel.y; break;
        case SDL_EVENT_TEXT_INPUT:
            out_event->type = PB_WINDOW_EVENT_TEXT;
            strncpy(out_event->text, event.text.text, sizeof(out_event->text) - 1); break;
        case SDL_EVENT_WINDOW_FOCUS_GAINED: out_event->type = PB_WINDOW_EVENT_FOCUS_GAINED; break;
        case SDL_EVENT_WINDOW_FOCUS_LOST: out_event->type = PB_WINDOW_EVENT_FOCUS_LOST; break;
        case SDL_EVENT_GAMEPAD_AXIS_MOTION:
            out_event->type = PB_WINDOW_EVENT_GAMEPAD_AXIS;
            out_event->a = (int32_t)event.gaxis.axis;
            out_event->x = (float)event.gaxis.value / 32767.0f;
            break;
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            out_event->type = PB_WINDOW_EVENT_GAMEPAD_BUTTON_DOWN;
            out_event->a = (int32_t)event.gbutton.button;
            break;
        case SDL_EVENT_GAMEPAD_BUTTON_UP:
            out_event->type = PB_WINDOW_EVENT_GAMEPAD_BUTTON_UP;
            out_event->a = (int32_t)event.gbutton.button;
            break;
        default: out_event->type = PB_WINDOW_EVENT_NONE; break;
    }
    return 1;
}

void pb_window_size_pixels(PBWindow *window, int32_t *out_width, int32_t *out_height) {
    if (window == NULL || out_width == NULL || out_height == NULL) return;
    SDL_GetWindowSizeInPixels(window->window, out_width, out_height);
}

void pb_window_size_points(PBWindow *window, int32_t *out_width, int32_t *out_height) {
    if (window == NULL || out_width == NULL || out_height == NULL) return;
    SDL_GetWindowSize(window->window, out_width, out_height);
}

void pb_window_set_relative_mouse(PBWindow *window, uint32_t enabled) {
    if (window != NULL) SDL_SetWindowRelativeMouseMode(window->window, enabled != 0);
}

int32_t pb_window_set_fullscreen(PBWindow *window, uint32_t enabled) {
    if (window == NULL) return -1;
    if (!SDL_SetWindowFullscreen(window->window, enabled != 0)) return -2;
    window->fullscreen = enabled != 0;
    return 0;
}

uint32_t pb_window_is_fullscreen(PBWindow *window) {
    return window == NULL ? 0 : window->fullscreen;
}

void pb_window_set_text_input(PBWindow *window, uint32_t enabled) {
    if (window == NULL) return;
    if (enabled) SDL_StartTextInput(window->window); else SDL_StopTextInput(window->window);
}

void pb_window_set_title(PBWindow *window, const char *title) {
    if (window != NULL && title != NULL) SDL_SetWindowTitle(window->window, title);
}

int32_t pb_window_set_clipboard_text(const char *text) {
    return text != NULL && SDL_SetClipboardText(text) ? 0 : -1;
}

char *pb_window_get_clipboard_text(void) { return SDL_GetClipboardText(); }
void pb_window_free(void *pointer) { SDL_free(pointer); }

const char * const *pb_window_vulkan_extensions(uint32_t *out_count) {
    if (out_count == NULL) return NULL;
    Uint32 count = 0;
    const char * const *extensions = SDL_Vulkan_GetInstanceExtensions(&count);
    *out_count = count;
    return extensions;
}

int32_t pb_window_create_vulkan_surface(PBWindow *window, uintptr_t instance, uint64_t *out_surface) {
    if (window == NULL || instance == 0 || out_surface == NULL) return -1;
    VkSurfaceKHR surface = (VkSurfaceKHR)0;
    if (!SDL_Vulkan_CreateSurface(window->window, (VkInstance)instance, NULL, &surface)) return -2;
    *out_surface = (uint64_t)surface;
    return 0;
}

void pb_window_destroy_vulkan_surface(uintptr_t instance, uint64_t surface) {
    if (instance != 0 && surface != 0) SDL_Vulkan_DestroySurface((VkInstance)instance, (VkSurfaceKHR)surface, NULL);
}

const char *pb_window_last_error(void) { return SDL_GetError(); }
