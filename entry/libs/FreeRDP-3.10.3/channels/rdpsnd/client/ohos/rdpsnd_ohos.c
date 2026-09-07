/**
 * FreeRDP: A Remote Desktop Protocol Implementation
 * Audio Output Virtual Channel - OpenHarmony OHAudio backend
 *
 * Copyright 2025 <your name>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * OpenHarmony OHAudio (AudioKit C API) based rdpsnd backend.
 *
 * The OHAudio renderer works in callback (pull) mode: the audio service
 * invokes OH_AudioRenderer_OnWriteDataCallback from its own thread and
 * expects the buffer to be completely filled. rdpsnd pushes PCM data
 * from the virtual channel thread, so a small ring buffer decouples both
 * ends. When no data is available the callback emits silence.
 *
 * Threading: all renderer/builder pointers are only touched from the
 * rdpsnd channel thread (open/play/close/free). The critical section
 * exclusively guards the ring buffer, which is shared with the audio
 * callback thread. Renderer Stop/Release is never called while holding
 * the lock to avoid deadlocking against an in-flight callback.
 *
 * All APIs used here are @since 10 or @since 12 to stay compatible with
 * targetSdkVersion 5.0.0(12).
 */

#include <freerdp/config.h>

#include <stdlib.h>
#include <string.h>

#include <winpr/crt.h>
#include <winpr/wtypes.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>

#include <freerdp/types.h>
#include <freerdp/codec/audio.h>
#include <freerdp/client/rdpsnd.h>

#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

#include "rdpsnd_main.h"

/* 128 KiB ~= 341ms @ 48kHz stereo S16LE - enough to absorb network jitter
 * while keeping the end to end latency low. */
#define RDPSND_OHOS_RING_CAPACITY (128 * 1024)

typedef struct
{
	rdpsndDevicePlugin device;

	/* Guarded by lock: ring buffer state and counters. */
	CRITICAL_SECTION lock;
	BYTE* ring;
	size_t ringHead; /* write position */
	size_t ringTail; /* read position */
	size_t ringUsed;
	UINT32 overflow; /* number of dropped (overwritten) bytes on write */

	/* Channel thread only. */
	OH_AudioStreamBuilder* builder;
	OH_AudioRenderer* renderer;
	int32_t sampleRate;
	int32_t channels;
	BOOL started;
	UINT32 volume; /* low word left, high word right, 0xFFFF = 100% */
} rdpsndOhosPlugin;

static void rdpsnd_ohos_ring_reset(rdpsndOhosPlugin* ohos)
{
	ohos->ringHead = 0;
	ohos->ringTail = 0;
	ohos->ringUsed = 0;
}

/* Overwrite oldest data when full to keep latency bounded. */
static void rdpsnd_ohos_ring_write(rdpsndOhosPlugin* ohos, const BYTE* src, size_t size)
{
	if (!ohos->ring)
		return;

	if (size > RDPSND_OHOS_RING_CAPACITY)
	{
		/* chunk larger than the whole ring: keep the newest tail */
		src += size - RDPSND_OHOS_RING_CAPACITY;
		size = RDPSND_OHOS_RING_CAPACITY;
		rdpsnd_ohos_ring_reset(ohos);
		ohos->overflow++;
	}
	else if (size > RDPSND_OHOS_RING_CAPACITY - ohos->ringUsed)
	{
		/* drop oldest data to make room */
		const size_t need = size - (RDPSND_OHOS_RING_CAPACITY - ohos->ringUsed);
		ohos->ringTail = (ohos->ringTail + need) % RDPSND_OHOS_RING_CAPACITY;
		ohos->ringUsed -= need;
		ohos->overflow++;
	}

	while (size > 0)
	{
		const size_t chunk =
		    (ohos->ringHead + size > RDPSND_OHOS_RING_CAPACITY) ? RDPSND_OHOS_RING_CAPACITY - ohos->ringHead
		                                                        : size;
		memcpy(ohos->ring + ohos->ringHead, src, chunk);
		ohos->ringHead = (ohos->ringHead + chunk) % RDPSND_OHOS_RING_CAPACITY;
		src += chunk;
		size -= chunk;
		ohos->ringUsed += chunk;
	}
}

/* Fill dst completely: pending data first, silence for the remainder. */
static void rdpsnd_ohos_ring_read(rdpsndOhosPlugin* ohos, BYTE* dst, size_t size)
{
	size_t silence = 0;

	if (!ohos->ring || (ohos->ringUsed == 0))
	{
		memset(dst, 0, size);
		return;
	}

	if (size > ohos->ringUsed)
	{
		silence = size - ohos->ringUsed;
		size = ohos->ringUsed;
	}

	while (size > 0)
	{
		const size_t chunk =
		    (ohos->ringTail + size > RDPSND_OHOS_RING_CAPACITY) ? RDPSND_OHOS_RING_CAPACITY - ohos->ringTail
		                                                        : size;
		memcpy(dst, ohos->ring + ohos->ringTail, chunk);
		ohos->ringTail = (ohos->ringTail + chunk) % RDPSND_OHOS_RING_CAPACITY;
		dst += chunk;
		size -= chunk;
		ohos->ringUsed -= chunk;
	}

	if (silence > 0)
	{
		memset(dst, 0, silence);
		DEBUG_SND("underflow: filled %" PRIuz " bytes with silence", silence);
	}
}

/* Called from the audio service thread: copy from ring buffer, must not block. */
static OH_AudioData_Callback_Result rdpsnd_ohos_write_cb(OH_AudioRenderer* renderer, void* userData,
                                                         void* audioData, int32_t audioDataSize)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)userData;

	WINPR_UNUSED(renderer);

	if (!ohos || !audioData || (audioDataSize <= 0))
		return AUDIO_DATA_CALLBACK_RESULT_INVALID;

	EnterCriticalSection(&ohos->lock);
	rdpsnd_ohos_ring_read(ohos, (BYTE*)audioData, (size_t)audioDataSize);
	LeaveCriticalSection(&ohos->lock);
	return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

static BOOL rdpsnd_ohos_format_supported(rdpsndDevicePlugin* device, const AUDIO_FORMAT* format)
{
	if (!device || !format)
		return FALSE;

	if (format->wFormatTag != WAVE_FORMAT_PCM)
		return FALSE;

	if (format->wBitsPerSample != 16)
		return FALSE;

	if ((format->nChannels != 1) && (format->nChannels != 2))
		return FALSE;

	if ((format->nSamplesPerSec != 44100) && (format->nSamplesPerSec != 48000))
		return FALSE;

	return TRUE;
}

static BOOL rdpsnd_ohos_default_format(rdpsndDevicePlugin* device, const AUDIO_FORMAT* desired,
                                       AUDIO_FORMAT* defaultFormat)
{
	WINPR_UNUSED(device);
	WINPR_UNUSED(desired);

	if (!defaultFormat)
		return FALSE;

	defaultFormat->wFormatTag = WAVE_FORMAT_PCM;
	defaultFormat->nChannels = 2;
	defaultFormat->nSamplesPerSec = 44100;
	defaultFormat->wBitsPerSample = 16;
	return TRUE;
}

/* Channel thread only - never call while holding the lock (Release must not
 * wait on an audio callback that is blocked on the same lock). */
static void rdpsnd_ohos_destroy_renderer(rdpsndOhosPlugin* ohos)
{
	if (ohos->renderer)
	{
		OH_AudioRenderer_Stop(ohos->renderer);
		OH_AudioRenderer_Release(ohos->renderer);
		ohos->renderer = NULL;
	}

	if (ohos->builder)
	{
		OH_AudioStreamBuilder_Destroy(ohos->builder);
		ohos->builder = NULL;
	}

	ohos->started = FALSE;
}

/* Channel thread only. */
static BOOL rdpsnd_ohos_create_renderer(rdpsndOhosPlugin* ohos, int32_t rate, int32_t channels)
{
	OH_AudioStream_Result rc = AUDIOSTREAM_ERROR_SYSTEM;
	int32_t frameSize = 0;

	rdpsnd_ohos_destroy_renderer(ohos);

	rc = OH_AudioStreamBuilder_Create(&ohos->builder, AUDIOSTREAM_TYPE_RENDERER);

	if (rc != AUDIOSTREAM_SUCCESS)
	{
		WLog_ERR(TAG, "OH_AudioStreamBuilder_Create failed: %d", (int)rc);
		return FALSE;
	}

	if ((OH_AudioStreamBuilder_SetSamplingRate(ohos->builder, rate) != AUDIOSTREAM_SUCCESS) ||
	    (OH_AudioStreamBuilder_SetChannelCount(ohos->builder, channels) != AUDIOSTREAM_SUCCESS) ||
	    (OH_AudioStreamBuilder_SetSampleFormat(ohos->builder, AUDIOSTREAM_SAMPLE_S16LE) !=
	     AUDIOSTREAM_SUCCESS) ||
	    (OH_AudioStreamBuilder_SetEncodingType(ohos->builder, AUDIOSTREAM_ENCODING_TYPE_RAW) !=
	     AUDIOSTREAM_SUCCESS) ||
	    (OH_AudioStreamBuilder_SetLatencyMode(ohos->builder, AUDIOSTREAM_LATENCY_MODE_NORMAL) !=
	     AUDIOSTREAM_SUCCESS) ||
	    (OH_AudioStreamBuilder_SetRendererInfo(ohos->builder, AUDIOSTREAM_USAGE_MUSIC) !=
	     AUDIOSTREAM_SUCCESS) ||
	    (OH_AudioStreamBuilder_SetRendererWriteDataCallback(ohos->builder, rdpsnd_ohos_write_cb, ohos) !=
	     AUDIOSTREAM_SUCCESS))
	{
		WLog_ERR(TAG, "failed to configure OHAudio stream builder");
		rdpsnd_ohos_destroy_renderer(ohos);
		return FALSE;
	}

	rc = OH_AudioStreamBuilder_GenerateRenderer(ohos->builder, &ohos->renderer);

	if ((rc != AUDIOSTREAM_SUCCESS) || !ohos->renderer)
	{
		WLog_ERR(TAG, "OH_AudioStreamBuilder_GenerateRenderer failed: %d", (int)rc);
		rdpsnd_ohos_destroy_renderer(ohos);
		return FALSE;
	}

	ohos->sampleRate = rate;
	ohos->channels = channels;

	/* Apply cached volume to the new renderer (left channel drives both). */
	if (ohos->volume != 0xFFFFFFFFUL)
	{
		const OH_AudioStream_Result vrc =
		    OH_AudioRenderer_SetVolume(ohos->renderer, (float)(ohos->volume & 0xFFFFUL) / 65535.0f);

		if (vrc != AUDIOSTREAM_SUCCESS)
			WLog_WARN(TAG, "OH_AudioRenderer_SetVolume failed: %d", (int)vrc);
	}

	{
		int32_t rate2 = 0;
		int32_t ch2 = 0;
		OH_AudioRenderer_GetSamplingRate(ohos->renderer, &rate2);
		OH_AudioRenderer_GetChannelCount(ohos->renderer, &ch2);
		WLog_INFO(TAG,
		          "rdpsnd-ohos: renderer created, requested rate=%d channels=%d, actual rate=%d channels=%d",
		          (int)rate, (int)channels, (int)rate2, (int)ch2);
	}

	if (OH_AudioRenderer_GetFrameSizeInCallback(ohos->renderer, &frameSize) == AUDIOSTREAM_SUCCESS)
		WLog_INFO(TAG, "rdpsnd-ohos: frameSizeInCallback=%d bytes", (int)frameSize);

	EnterCriticalSection(&ohos->lock);
	rdpsnd_ohos_ring_reset(ohos);
	LeaveCriticalSection(&ohos->lock);
	return TRUE;
}

static BOOL rdpsnd_ohos_open(rdpsndDevicePlugin* device, const AUDIO_FORMAT* format, UINT32 latency)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;

	if (!ohos || !format)
		return FALSE;

	WLog_INFO(TAG, "rdpsnd-ohos: open rate=%u channels=%u bits=%u latency=%u",
	          (unsigned)format->nSamplesPerSec, (unsigned)format->nChannels,
	          (unsigned)format->wBitsPerSample, (unsigned)latency);

	return rdpsnd_ohos_create_renderer(ohos, (int32_t)format->nSamplesPerSec,
	                                   (int32_t)format->nChannels);
}

static UINT32 rdpsnd_ohos_get_volume(rdpsndDevicePlugin* device)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;

	if (!ohos)
		return 0;

	return ohos->volume;
}

static BOOL rdpsnd_ohos_set_volume(rdpsndDevicePlugin* device, UINT32 value)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;
	float vol = 0.0f;

	if (!ohos)
		return FALSE;

	ohos->volume = value;
	/* RDP volume: low word = left, high word = right, 0xFFFF = 100%. */
	vol = (float)(value & 0xFFFFUL) / 65535.0f;

	if (ohos->renderer)
	{
		const OH_AudioStream_Result rc = OH_AudioRenderer_SetVolume(ohos->renderer, vol);

		if (rc != AUDIOSTREAM_SUCCESS)
			WLog_WARN(TAG, "OH_AudioRenderer_SetVolume failed: %d", (int)rc);
	}

	DEBUG_SND("set volume 0x%08X -> %.3f", (unsigned)value, (double)vol);
	return TRUE;
}

static void rdpsnd_ohos_start(rdpsndDevicePlugin* device)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;

	if (!ohos)
		return;

	/* Deferred start: only begin pulling audio once real data arrived, so we
	 * do not feed continuous silence (system may throttle such streams). */
	if (!ohos->started && ohos->renderer)
	{
		const OH_AudioStream_Result rc = OH_AudioRenderer_Start(ohos->renderer);

		if (rc == AUDIOSTREAM_SUCCESS)
			ohos->started = TRUE;
		else
			WLog_ERR(TAG, "OH_AudioRenderer_Start failed: %d", (int)rc);
	}
}

static UINT rdpsnd_ohos_play(rdpsndDevicePlugin* device, const BYTE* data, size_t size)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;

	if (!ohos || !data || (size == 0))
		return CHANNEL_RC_NULL_DATA;

	if (!ohos->renderer)
	{
		WLog_WARN(TAG, "rdpsnd-ohos: play before open, dropping %" PRIuz " bytes", size);
		return CHANNEL_RC_NOT_OPEN;
	}

	rdpsnd_ohos_start(device);

	EnterCriticalSection(&ohos->lock);
	DEBUG_SND("play: %" PRIuz " bytes (ring used: %" PRIuz ")", size, ohos->ringUsed);
	rdpsnd_ohos_ring_write(ohos, data, size);
	LeaveCriticalSection(&ohos->lock);
	return CHANNEL_RC_OK;
}

static void rdpsnd_ohos_close(rdpsndDevicePlugin* device)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;

	if (!ohos)
		return;

	if (ohos->renderer)
	{
		if (ohos->started)
		{
			const OH_AudioStream_Result rc = OH_AudioRenderer_Stop(ohos->renderer);

			if (rc == AUDIOSTREAM_SUCCESS)
				ohos->started = FALSE;
			else
				WLog_WARN(TAG, "OH_AudioRenderer_Stop failed: %d", (int)rc);

			OH_AudioRenderer_Flush(ohos->renderer);
		}

		{
			UINT32 underflow = 0;

			if (OH_AudioRenderer_GetUnderflowCount(ohos->renderer, &underflow) == AUDIOSTREAM_SUCCESS)
				WLog_INFO(TAG, "rdpsnd-ohos: close, underflowCount=%u overflowDrops=%u",
				          (unsigned)underflow, (unsigned)ohos->overflow);
		}
	}

	EnterCriticalSection(&ohos->lock);
	rdpsnd_ohos_ring_reset(ohos);
	LeaveCriticalSection(&ohos->lock);
}

static void rdpsnd_ohos_free(rdpsndDevicePlugin* device)
{
	rdpsndOhosPlugin* ohos = (rdpsndOhosPlugin*)device;

	if (!ohos)
		return;

	rdpsnd_ohos_destroy_renderer(ohos);
	DeleteCriticalSection(&ohos->lock);
	free(ohos->ring);
	free(ohos);
}

/**
 * Function description
 *
 * @return 0 on success, otherwise a Win32 error code
 */
FREERDP_ENTRY_POINT(UINT VCAPITYPE ohos_freerdp_rdpsnd_client_subsystem_entry(
    PFREERDP_RDPSND_DEVICE_ENTRY_POINTS pEntryPoints))
{
	rdpsndOhosPlugin* ohos = NULL;

	DEBUG_SND("pEntryPoints=%p", (void*)pEntryPoints);

	if (!pEntryPoints)
		return CHANNEL_RC_NULL_DATA;

	ohos = (rdpsndOhosPlugin*)calloc(1, sizeof(rdpsndOhosPlugin));

	if (!ohos)
		return CHANNEL_RC_NO_MEMORY;

	ohos->device.Open = rdpsnd_ohos_open;
	ohos->device.FormatSupported = rdpsnd_ohos_format_supported;
	ohos->device.DefaultFormat = rdpsnd_ohos_default_format;
	ohos->device.GetVolume = rdpsnd_ohos_get_volume;
	ohos->device.SetVolume = rdpsnd_ohos_set_volume;
	ohos->device.Start = rdpsnd_ohos_start;
	ohos->device.Play = rdpsnd_ohos_play;
	ohos->device.Close = rdpsnd_ohos_close;
	ohos->device.Free = rdpsnd_ohos_free;

	ohos->ring = (BYTE*)calloc(1, RDPSND_OHOS_RING_CAPACITY);

	if (!ohos->ring)
	{
		free(ohos);
		return CHANNEL_RC_NO_MEMORY;
	}

	InitializeCriticalSection(&ohos->lock);
	ohos->volume = 0xFFFFFFFF; /* 100% both channels until told otherwise */
	pEntryPoints->pRegisterRdpsndDevice(pEntryPoints->rdpsnd, (rdpsndDevicePlugin*)ohos);
	DEBUG_SND("success");
	return CHANNEL_RC_OK;
}
