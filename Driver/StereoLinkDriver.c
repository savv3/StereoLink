// SPDX-License-Identifier: GPL-3.0-or-later
//
// StereoLink virtual audio device (Core Audio AudioServerPlugIn).
//
// Publishes one stereo output device, "StereoLink", with a volume and mute
// control. It discards any audio written to it and has no input, so it records
// nothing. Its only job is to give macOS a volume control: the StereoLink app
// captures system audio with a process tap and applies this device's volume
// and mute itself, so the volume keys and menu bar slider work.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>

// MARK: - Constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_StreamOutput = 4,
    kObjectID_Volume = 5,
    kObjectID_Mute = 6,
};

#define kDeviceName         "StereoLink"
#define kDeviceUID          "StereoLink_UID"
#define kDeviceModelUID     "StereoLink_ModelUID"
#define kManufacturer       "StereoLink"
#define kChannels           2
#define kBytesPerFrame      (kChannels * sizeof(Float32))
#define kPeriodFrames       16384
#define kMinDB              (-64.0f)
#define kStorageKeyVolume   CFSTR("volume")
#define kStorageKeyRate     CFSTR("sampleRate")

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSampleRateCount (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

// MARK: - State

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;

static Float64 gSampleRate = 48000.0;
static _Atomic Float32 gVolumeScalar = 1.0f;
static _Atomic UInt32 gMuted = 0;

static UInt32 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimestampCount = 0;

// MARK: - Volume curve (gain = scalar², so dB = 40·log10(scalar))

static Float32 ScalarToDB(Float32 scalar) {
    if (scalar <= 0.0f) return kMinDB;
    Float32 db = 40.0f * log10f(scalar);
    return db < kMinDB ? kMinDB : (db > 0.0f ? 0.0f : db);
}

static Float32 DBToScalar(Float32 db) {
    if (db <= kMinDB) return 0.0f;
    if (db >= 0.0f) return 1.0f;
    return powf(10.0f, db / 40.0f);
}

static Float32 ClampScalar(Float32 v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }

static void UpdateTicksPerFrame(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = ticksPerSecond / gSampleRate;
}

static AudioStreamBasicDescription MakeFormat(Float64 rate) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) if (kSampleRates[i] == rate) return true;
    return false;
}

// MARK: - Storage

static void SaveSetting(CFStringRef key, Float64 value) {
    if (!gHost) return;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberFloat64Type, &value);
    if (n) { gHost->WriteToStorage(gHost, key, n); CFRelease(n); }
}

static Boolean LoadSetting(CFStringRef key, Float64 *out) {
    CFPropertyListRef value = NULL;
    if (!gHost || gHost->CopyFromStorage(gHost, key, &value) != 0 || !value) return false;
    Boolean ok = CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, out);
    CFRelease(value);
    return ok;
}

// MARK: - Forward declarations

static HRESULT  SL_QueryInterface(void*, REFIID, LPVOID*);
static ULONG    SL_AddRef(void*);
static ULONG    SL_Release(void*);
static OSStatus SL_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus SL_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus SL_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus SL_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus SL_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus SL_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus SL_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  SL_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus SL_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus SL_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus SL_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus SL_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus SL_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus SL_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus SL_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus SL_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus SL_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus SL_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus SL_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    SL_QueryInterface, SL_AddRef, SL_Release,
    SL_Initialize, SL_CreateDevice, SL_DestroyDevice,
    SL_AddDeviceClient, SL_RemoveDeviceClient,
    SL_PerformDeviceConfigurationChange, SL_AbortDeviceConfigurationChange,
    SL_HasProperty, SL_IsPropertySettable, SL_GetPropertyDataSize, SL_GetPropertyData, SL_SetPropertyData,
    SL_StartIO, SL_StopIO, SL_GetZeroTimeStamp,
    SL_WillDoIOOperation, SL_BeginIOOperation, SL_DoIOOperation, SL_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory & COM

void *StereoLink_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void *StereoLink_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT SL_QueryInterface(void *driver, REFIID uuid, LPVOID *outInterface) {
    if (driver != gDriverRef || !outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    if (!requested) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG SL_AddRef(void *driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG SL_Release(void *driver) {
    if (driver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

// MARK: - Basic operations

static OSStatus SL_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (driver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = host;
    Float64 value;
    if (LoadSetting(kStorageKeyVolume, &value)) atomic_store(&gVolumeScalar, ClampScalar((Float32)value));
    if (LoadSetting(kStorageKeyRate, &value) && IsSupportedRate(value)) gSampleRate = value;
    UpdateTicksPerFrame();
    return 0;
}

static OSStatus SL_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SL_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SL_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return id == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus SL_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo *c) {
    (void)c;
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return id == kObjectID_Device ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus SL_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)info;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)action;
    if (!IsSupportedRate(rate)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = rate;
    UpdateTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    SaveSetting(kStorageKeyRate, rate);
    return 0;
}

static OSStatus SL_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 action, void *info) {
    (void)d; (void)id; (void)action; (void)info;
    return 0;
}

// MARK: - Properties
//
// One function answers both "how big?" (outData == NULL) and "what value?",
// so the size, data and has-property answers can't drift apart.

#define RETURN_VALUE(type, value) do { \
    if (outData) { \
        if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
        *(type *)outData = (value); \
    } \
    *outSize = sizeof(type); \
    return 0; \
} while (0)

#define RETURN_CFSTRING(str) RETURN_VALUE(CFStringRef, (CFStringRef)CFRetain(str))

/// Copy as many items as fit; report the full size when only sizing.
static OSStatus ReturnArray(const void *items, UInt32 itemSize, UInt32 count, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    if (!outData) { *outSize = itemSize * count; return 0; }
    UInt32 fit = inDataSize / itemSize;
    if (fit > count) fit = count;
    if (fit > 0) memcpy(outData, items, (size_t)fit * itemSize);
    *outSize = fit * itemSize;
    return 0;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                               UInt32 inDataSize, UInt32 *outSize, void *outData) {
    static const AudioObjectID devices[] = { kObjectID_Device };
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:     RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:         RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:         RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer:  RETURN_CFSTRING(CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            return ReturnArray(devices, sizeof(AudioObjectID), 1, inDataSize, outSize, outData);
        case kAudioPlugInPropertyBoxList:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if (outData && qualSize >= sizeof(CFStringRef) && qual) {
                CFStringRef uid = *(const CFStringRef *)qual;
                if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) result = kObjectID_Device;
            }
            RETURN_VALUE(AudioObjectID, result);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_CFSTRING(CFSTR(""));
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    const Boolean input = a->mScope == kAudioObjectPropertyScopeInput;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:     RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:         RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:         RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:          RETURN_CFSTRING(CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer:  RETURN_CFSTRING(CFSTR(kManufacturer));
        case kAudioDevicePropertyDeviceUID:     RETURN_CFSTRING(CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID:      RETURN_CFSTRING(CFSTR(kDeviceModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain:   RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:       RETURN_VALUE(UInt32, input ? 0 : 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, input ? 0 : 1);
        case kAudioDevicePropertyLatency:       RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset:  RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden:      RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyClockIsStable: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kPeriodFrames);
        case kAudioDevicePropertyNominalSampleRate: {
            pthread_mutex_lock(&gStateMutex);
            Float64 rate = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(Float64, rate);
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[kSampleRateCount];
            for (UInt32 i = 0; i < kSampleRateCount; i++) ranges[i] = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            return ReturnArray(ranges, sizeof(AudioValueRange), kSampleRateCount, inDataSize, outSize, outData);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            static const UInt32 channels[2] = { 1, 2 };
            return ReturnArray(channels, sizeof(UInt32), 2, inDataSize, outSize, outData);
        }
        case kAudioDevicePropertyRelatedDevices: {
            static const AudioObjectID related[] = { kObjectID_Device };
            return ReturnArray(related, sizeof(AudioObjectID), 1, inDataSize, outSize, outData);
        }
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[1]; UInt32 n = 0;
            if (!input) ids[n++] = kObjectID_StreamOutput;
            return ReturnArray(ids, sizeof(AudioObjectID), n, inDataSize, outSize, outData);
        }
        case kAudioObjectPropertyControlList: {
            static const AudioObjectID controls[] = { kObjectID_Volume, kObjectID_Mute };
            return ReturnArray(controls, sizeof(AudioObjectID), 2, inDataSize, outSize, outData);
        }
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID ids[3]; UInt32 n = 0;
            if (!input) { ids[n++] = kObjectID_StreamOutput; ids[n++] = kObjectID_Volume; ids[n++] = kObjectID_Mute; }
            return ReturnArray(ids, sizeof(AudioObjectID), n, inDataSize, outSize, outData);
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:      RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:          RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:          RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:   return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outSize, outData);
        case kAudioStreamPropertyIsActive:       RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection:      RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyTerminalType:   RETURN_VALUE(UInt32, kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency:        RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            pthread_mutex_lock(&gStateMutex);
            AudioStreamBasicDescription f = MakeFormat(gSampleRate);
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(AudioStreamBasicDescription, f);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription formats[kSampleRateCount];
            for (UInt32 i = 0; i < kSampleRateCount; i++) {
                formats[i].mFormat = MakeFormat(kSampleRates[i]);
                formats[i].mSampleRateRange = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            }
            return ReturnArray(formats, sizeof(AudioStreamRangedDescription), kSampleRateCount, inDataSize, outSize, outData);
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus VolumeProperty(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:     RETURN_VALUE(AudioClassID, kAudioLevelControlClassID);
        case kAudioObjectPropertyClass:         RETURN_VALUE(AudioClassID, kAudioVolumeControlClassID);
        case kAudioObjectPropertyOwner:         RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:  return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outSize, outData);
        case kAudioControlPropertyScope:        RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:      RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioLevelControlPropertyScalarValue:  RETURN_VALUE(Float32, atomic_load(&gVolumeScalar));
        case kAudioLevelControlPropertyDecibelValue: RETURN_VALUE(Float32, ScalarToDB(atomic_load(&gVolumeScalar)));
        case kAudioLevelControlPropertyDecibelRange: RETURN_VALUE(AudioValueRange, ((AudioValueRange){ kMinDB, 0.0 }));
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            // In/out: the caller passes the value to convert in outData.
            RETURN_VALUE(Float32, ScalarToDB(ClampScalar(*(Float32 *)outData)));
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            RETURN_VALUE(Float32, DBToScalar(*(Float32 *)outData));
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus MuteProperty(const AudioObjectPropertyAddress *a, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:     RETURN_VALUE(AudioClassID, kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass:         RETURN_VALUE(AudioClassID, kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner:         RETURN_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:  return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outSize, outData);
        case kAudioControlPropertyScope:        RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement:      RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioBooleanControlPropertyValue: RETURN_VALUE(UInt32, atomic_load(&gMuted));
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetProperty(AudioObjectID id, const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                            UInt32 inDataSize, UInt32 *outSize, void *outData) {
    switch (id) {
        case kObjectID_PlugIn:       return PlugInProperty(a, qualSize, qual, inDataSize, outSize, outData);
        case kObjectID_Device:       return DeviceProperty(a, inDataSize, outSize, outData);
        case kObjectID_StreamOutput: return StreamProperty(a, inDataSize, outSize, outData);
        case kObjectID_Volume:       return VolumeProperty(a, inDataSize, outSize, outData);
        case kObjectID_Mute:         return MuteProperty(a, inDataSize, outSize, outData);
        default:                     return kAudioHardwareBadObjectError;
    }
}

static Boolean SL_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (d != gDriverRef || !a) return false;
    UInt32 size = 0;
    return GetProperty(id, a, 0, NULL, UINT32_MAX, &size, NULL) == 0;
}

static OSStatus SL_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    (void)pid;
    if (d != gDriverRef || !a || !out) return kAudioHardwareIllegalOperationError;
    if (!SL_HasProperty(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (id) {
        case kObjectID_Device:
            *out = a->mSelector == kAudioDevicePropertyNominalSampleRate; break;
        case kObjectID_StreamOutput:
            *out = a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat; break;
        case kObjectID_Volume:
            *out = a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue; break;
        case kObjectID_Mute:
            *out = a->mSelector == kAudioBooleanControlPropertyValue; break;
        default:
            *out = false;
    }
    return 0;
}

static OSStatus SL_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress *a,
                                       UInt32 qualSize, const void *qual, UInt32 *outSize) {
    (void)pid;
    if (d != gDriverRef || !a || !outSize) return kAudioHardwareIllegalOperationError;
    return GetProperty(id, a, qualSize, qual, UINT32_MAX, outSize, NULL);
}

static OSStatus SL_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress *a,
                                   UInt32 qualSize, const void *qual, UInt32 inDataSize, UInt32 *outSize, void *outData) {
    (void)pid;
    if (d != gDriverRef || !a || !outSize || !outData) return kAudioHardwareIllegalOperationError;
    return GetProperty(id, a, qualSize, qual, inDataSize, outSize, outData);
}

static OSStatus RequestSampleRate(Float64 rate) {
    if (!IsSupportedRate(rate)) return kAudioDeviceUnsupportedFormatError;
    pthread_mutex_lock(&gStateMutex);
    Boolean same = rate == gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    if (same) return 0;
    // Rate changes must go through the host so it can stop IO first.
    return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, (UInt64)rate, NULL);
}

static void NotifyChanged(AudioObjectID id, AudioObjectPropertySelector s1, AudioObjectPropertySelector s2) {
    AudioObjectPropertyAddress addrs[2] = {
        { s1, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { s2, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    gHost->PropertiesChanged(gHost, id, s2 ? 2 : 1, addrs);
}

static OSStatus SL_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress *a,
                                   UInt32 qualSize, const void *qual, UInt32 inDataSize, const void *inData) {
    (void)pid; (void)qualSize; (void)qual;
    if (d != gDriverRef || !a || !inData) return kAudioHardwareIllegalOperationError;

    switch (id) {
        case kObjectID_Device:
            if (a->mSelector != kAudioDevicePropertyNominalSampleRate) break;
            if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            return RequestSampleRate(*(const Float64 *)inData);

        case kObjectID_StreamOutput: {
            if (a->mSelector != kAudioStreamPropertyVirtualFormat && a->mSelector != kAudioStreamPropertyPhysicalFormat) break;
            if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = inData;
            AudioStreamBasicDescription ours = MakeFormat(f->mSampleRate);
            if (f->mFormatID != ours.mFormatID || f->mChannelsPerFrame != ours.mChannelsPerFrame ||
                f->mBitsPerChannel != ours.mBitsPerChannel || f->mFormatFlags != ours.mFormatFlags)
                return kAudioDeviceUnsupportedFormatError;
            return RequestSampleRate(f->mSampleRate);
        }

        case kObjectID_Volume: {
            if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 value = *(const Float32 *)inData;
            Float32 scalar;
            if (a->mSelector == kAudioLevelControlPropertyScalarValue) scalar = ClampScalar(value);
            else if (a->mSelector == kAudioLevelControlPropertyDecibelValue) scalar = DBToScalar(value);
            else break;
            if (scalar != atomic_load(&gVolumeScalar)) {
                atomic_store(&gVolumeScalar, scalar);
                SaveSetting(kStorageKeyVolume, scalar);
                NotifyChanged(kObjectID_Volume, kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue);
            }
            return 0;
        }

        case kObjectID_Mute: {
            if (a->mSelector != kAudioBooleanControlPropertyValue) break;
            if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 muted = *(const UInt32 *)inData ? 1 : 0;
            if (muted != atomic_load(&gMuted)) {
                atomic_store(&gMuted, muted);
                NotifyChanged(kObjectID_Mute, kAudioBooleanControlPropertyValue, 0);
            }
            return 0;
        }

        default:
            return kAudioHardwareBadObjectError;
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus SL_StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        gTimestampCount = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus SL_StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus SL_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client,
                                    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    const Float64 ticksPerRing = gHostTicksPerFrame * kPeriodFrames;
    const UInt64 now = mach_absolute_time();
    const UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimestampCount + 1) * ticksPerRing);
    if (next <= now) gTimestampCount++;
    *outSampleTime = (Float64)(gTimestampCount * kPeriodFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimestampCount * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus SL_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 op,
                                     Boolean *outWillDo, Boolean *outInPlace) {
    (void)client;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    (void)op;
    // Audio sent here is discarded, so the driver takes part in no IO operations.
    *outWillDo = false;
    *outInPlace = true;
    return 0;
}

static OSStatus SL_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus SL_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *info) {
    (void)c; (void)op; (void)n; (void)info;
    return (d == gDriverRef && id == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus SL_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client,
                                 UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *mainBuffer, void *secondary) {
    (void)stream; (void)client; (void)op; (void)frames; (void)info; (void)mainBuffer; (void)secondary;
    return (d == gDriverRef && id == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}
