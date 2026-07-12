#include "CPebblePlatform.h"

#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <AudioToolbox/AudioToolbox.h>

struct PBAudioDevice {
    AudioUnit unit;
    PBAudioRenderCallback callback;
    void *user_data;
    uint32_t channels;
    uint64_t underruns;
    int started;
};

static OSStatus pb_audio_render(void *user_data,
                                AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *timestamp,
                                UInt32 bus,
                                UInt32 frame_count,
                                AudioBufferList *buffers) {
    (void)flags; (void)timestamp; (void)bus;
    PBAudioDevice *device = (PBAudioDevice *)user_data;
    if (buffers->mNumberBuffers != 1 || buffers->mBuffers[0].mData == NULL) {
        device->underruns++;
        for (UInt32 index = 0; index < buffers->mNumberBuffers; index++) {
            if (buffers->mBuffers[index].mData != NULL) memset(buffers->mBuffers[index].mData, 0, buffers->mBuffers[index].mDataByteSize);
        }
        return noErr;
    }
    float *samples = (float *)buffers->mBuffers[0].mData;
    if (device->callback != NULL) device->callback(samples, frame_count, device->channels, device->user_data);
    else memset(samples, 0, (size_t)frame_count * device->channels * sizeof(float));
    return noErr;
}

PBPlatformStatus pb_audio_create(uint32_t sample_rate, uint32_t channels,
                                 uint32_t period_frames,
                                 PBAudioRenderCallback callback, void *user_data,
                                 PBAudioDevice **out_device) {
    (void)period_frames;
    if (sample_rate == 0 || channels != 2 || callback == NULL || out_device == NULL) return PB_PLATFORM_BAD_ARGUMENT;
    *out_device = NULL;
    PBAudioDevice *device = (PBAudioDevice *)calloc(1, sizeof(PBAudioDevice));
    if (device == NULL) return PB_PLATFORM_INTERNAL;
    AudioComponentDescription description = {0};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_DefaultOutput;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (component == NULL || AudioComponentInstanceNew(component, &device->unit) != noErr) { free(device); return PB_PLATFORM_UNAVAILABLE; }
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = sample_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = channels * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = channels * sizeof(float);
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    OSStatus status = AudioUnitSetProperty(device->unit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &format, sizeof(format));
    AURenderCallbackStruct render = {pb_audio_render, device};
    if (status == noErr) status = AudioUnitSetProperty(device->unit, kAudioUnitProperty_SetRenderCallback,
                                                       kAudioUnitScope_Input, 0, &render, sizeof(render));
    if (status == noErr) status = AudioUnitInitialize(device->unit);
    if (status != noErr) {
        AudioComponentInstanceDispose(device->unit);
        free(device);
        return PB_PLATFORM_UNAVAILABLE;
    }
    device->callback = callback;
    device->user_data = user_data;
    device->channels = channels;
    *out_device = device;
    return PB_PLATFORM_OK;
}

PBPlatformStatus pb_audio_start(PBAudioDevice *device) {
    if (device == NULL) return PB_PLATFORM_BAD_ARGUMENT;
    if (device->started) return PB_PLATFORM_OK;
    if (AudioOutputUnitStart(device->unit) != noErr) return PB_PLATFORM_UNAVAILABLE;
    device->started = 1;
    return PB_PLATFORM_OK;
}

PBPlatformStatus pb_audio_stop(PBAudioDevice *device) {
    if (device == NULL) return PB_PLATFORM_BAD_ARGUMENT;
    if (!device->started) return PB_PLATFORM_OK;
    AudioOutputUnitStop(device->unit);
    device->started = 0;
    return PB_PLATFORM_OK;
}

uint64_t pb_audio_underrun_count(PBAudioDevice *device) { return device == NULL ? 0 : device->underruns; }

void pb_audio_destroy(PBAudioDevice *device) {
    if (device == NULL) return;
    pb_audio_stop(device);
    AudioUnitUninitialize(device->unit);
    AudioComponentInstanceDispose(device->unit);
    free(device);
}

#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmreg.h>
#include <mmsystem.h>

#define PB_AUDIO_BUFFERS 3

struct PBAudioDevice {
    HWAVEOUT wave;
    HANDLE event;
    HANDLE thread;
    WAVEHDR headers[PB_AUDIO_BUFFERS];
    float *samples[PB_AUDIO_BUFFERS];
    PBAudioRenderCallback callback;
    void *user_data;
    uint32_t channels;
    uint32_t period_frames;
    volatile LONG stopping;
    volatile LONG started;
    volatile LONG64 underruns;
};

static DWORD WINAPI pb_audio_thread(void *user_data) {
    PBAudioDevice *device = (PBAudioDevice *)user_data;
    for (uint32_t index = 0; index < PB_AUDIO_BUFFERS; index++) {
        device->callback(device->samples[index], device->period_frames, device->channels, device->user_data);
        waveOutWrite(device->wave, &device->headers[index], sizeof(WAVEHDR));
    }
    while (InterlockedCompareExchange(&device->stopping, 0, 0) == 0) {
        DWORD wait = WaitForSingleObject(device->event, 1000);
        if (wait == WAIT_TIMEOUT) { InterlockedIncrement64(&device->underruns); continue; }
        for (uint32_t index = 0; index < PB_AUDIO_BUFFERS; index++) {
            if ((device->headers[index].dwFlags & WHDR_DONE) == 0) continue;
            device->callback(device->samples[index], device->period_frames, device->channels, device->user_data);
            device->headers[index].dwFlags &= ~WHDR_DONE;
            waveOutWrite(device->wave, &device->headers[index], sizeof(WAVEHDR));
        }
    }
    return 0;
}

PBPlatformStatus pb_audio_create(uint32_t sample_rate, uint32_t channels,
                                 uint32_t period_frames,
                                 PBAudioRenderCallback callback, void *user_data,
                                 PBAudioDevice **out_device) {
    if (sample_rate == 0 || channels != 2 || period_frames == 0 || callback == NULL || out_device == NULL) return PB_PLATFORM_BAD_ARGUMENT;
    *out_device = NULL;
    PBAudioDevice *device = (PBAudioDevice *)calloc(1, sizeof(PBAudioDevice));
    if (device == NULL) return PB_PLATFORM_INTERNAL;
    device->event = CreateEvent(NULL, FALSE, FALSE, NULL);
    if (device->event == NULL) { free(device); return PB_PLATFORM_UNAVAILABLE; }
    WAVEFORMATEX format = {0};
    format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    format.nChannels = (WORD)channels;
    format.nSamplesPerSec = sample_rate;
    format.wBitsPerSample = 32;
    format.nBlockAlign = (WORD)(channels * sizeof(float));
    format.nAvgBytesPerSec = sample_rate * format.nBlockAlign;
    if (waveOutOpen(&device->wave, WAVE_MAPPER, &format, (DWORD_PTR)device->event, 0, CALLBACK_EVENT) != MMSYSERR_NOERROR) {
        CloseHandle(device->event); free(device); return PB_PLATFORM_UNAVAILABLE;
    }
    device->callback = callback;
    device->user_data = user_data;
    device->channels = channels;
    device->period_frames = period_frames;
    const size_t bytes = (size_t)period_frames * channels * sizeof(float);
    for (uint32_t index = 0; index < PB_AUDIO_BUFFERS; index++) {
        device->samples[index] = (float *)calloc(1, bytes);
        if (device->samples[index] == NULL) { pb_audio_destroy(device); return PB_PLATFORM_INTERNAL; }
        device->headers[index].lpData = (LPSTR)device->samples[index];
        device->headers[index].dwBufferLength = (DWORD)bytes;
        waveOutPrepareHeader(device->wave, &device->headers[index], sizeof(WAVEHDR));
    }
    *out_device = device;
    return PB_PLATFORM_OK;
}

PBPlatformStatus pb_audio_start(PBAudioDevice *device) {
    if (device == NULL) return PB_PLATFORM_BAD_ARGUMENT;
    if (InterlockedCompareExchange(&device->started, 1, 0) != 0) return PB_PLATFORM_OK;
    InterlockedExchange(&device->stopping, 0);
    device->thread = CreateThread(NULL, 0, pb_audio_thread, device, 0, NULL);
    if (device->thread == NULL) { InterlockedExchange(&device->started, 0); return PB_PLATFORM_UNAVAILABLE; }
    return PB_PLATFORM_OK;
}

PBPlatformStatus pb_audio_stop(PBAudioDevice *device) {
    if (device == NULL) return PB_PLATFORM_BAD_ARGUMENT;
    if (InterlockedCompareExchange(&device->started, 0, 1) == 0) return PB_PLATFORM_OK;
    InterlockedExchange(&device->stopping, 1);
    waveOutReset(device->wave);
    SetEvent(device->event);
    WaitForSingleObject(device->thread, INFINITE);
    CloseHandle(device->thread);
    device->thread = NULL;
    return PB_PLATFORM_OK;
}

uint64_t pb_audio_underrun_count(PBAudioDevice *device) { return device == NULL ? 0 : (uint64_t)device->underruns; }

void pb_audio_destroy(PBAudioDevice *device) {
    if (device == NULL) return;
    pb_audio_stop(device);
    if (device->wave != NULL) {
        for (uint32_t index = 0; index < PB_AUDIO_BUFFERS; index++) {
            if (device->headers[index].dwFlags & WHDR_PREPARED) waveOutUnprepareHeader(device->wave, &device->headers[index], sizeof(WAVEHDR));
            free(device->samples[index]);
        }
        waveOutClose(device->wave);
    }
    if (device->event != NULL) CloseHandle(device->event);
    free(device);
}

#else
struct PBAudioDevice { int unused; };
PBPlatformStatus pb_audio_create(uint32_t sample_rate, uint32_t channels, uint32_t period_frames,
                                 PBAudioRenderCallback callback, void *user_data, PBAudioDevice **out_device) {
    (void)sample_rate; (void)channels; (void)period_frames; (void)callback; (void)user_data; (void)out_device;
    return PB_PLATFORM_UNAVAILABLE;
}
PBPlatformStatus pb_audio_start(PBAudioDevice *device) { (void)device; return PB_PLATFORM_UNAVAILABLE; }
PBPlatformStatus pb_audio_stop(PBAudioDevice *device) { (void)device; return PB_PLATFORM_UNAVAILABLE; }
uint64_t pb_audio_underrun_count(PBAudioDevice *device) { (void)device; return 0; }
void pb_audio_destroy(PBAudioDevice *device) { (void)device; }
#endif
