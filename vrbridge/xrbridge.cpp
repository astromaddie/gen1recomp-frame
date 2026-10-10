#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#if defined(_WIN32)
#include <windows.h>
#include <unknwn.h>
#include <GL/gl.h>
#define XR_USE_PLATFORM_WIN32
#elif defined(__linux__)
#define GL_GLEXT_PROTOTYPES
#include <X11/Xlib.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <GL/glx.h>
#define XR_USE_PLATFORM_XLIB
#else
#error "xrbridge supports Windows/WGL and Linux/GLX"
#endif

#define XR_USE_GRAPHICS_API_OPENGL
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
}

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#if defined(__linux__)
#include <cerrno>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#include "common/runtime.h"
#include "modules/graphics/Canvas.h"
#include "Telemetry.h"
#include "modules/data/ByteData.h"
#include "VisibilitySelection.h"
#endif

namespace {

// The Linux native copy path submits already gamma-encoded LOVE canvases, so
// its OpenXR images must be sRGB and framebuffer conversion stays disabled.
constexpr int64_t kGlSrgb8Alpha8 = 0x8C43;
constexpr uint32_t kMaxTextureDimension = 16384;
constexpr uint32_t kMaxExtensionCount = 256;
constexpr XrDuration kFrameViewLongPress = 1000000000;
constexpr char kFrameControllerExtensionName[] =
    "XR_VALVE_frame_controller_interaction";
constexpr char kFrameControllerProfilePath[] =
    "/interaction_profiles/valve/frame_controller_valve";
// Monoscopic 2D content is presented as a floating quad instead of being sent
// through both perspective eyes. The Lua caller can request a compact scale
// for menus; the default remains full-frustum so a fallback world is not
// accidentally reduced to a small panel.
constexpr float kUiQuadDistanceMeters = 1.8f;
constexpr float kUiQuadHeightMeters = 1.0f;
constexpr float kUiQuadDefaultScale = 1.0f;
#if defined(__linux__)
constexpr uint64_t kMaxSwapchainDumpPixels = 8u * 1024u * 1024u;
constexpr uint32_t kMaxSwapchainDumpSubmitDelay = 3600;
constexpr size_t kGpuTimestampRingCapacity = 64;
#endif

#if defined(__linux__)
class OpenGlTimestampBackend final : public vrtelemetry::TimestampBackend {
public:
    bool supported() override {
        GLint bits = 0;
        glGetQueryiv(GL_TIMESTAMP, GL_QUERY_COUNTER_BITS, &bits);
        return bits > 0;
    }

    uint32_t create() override {
        GLuint query = 0;
        glGenQueries(1, &query);
        return query;
    }

    void timestamp(uint32_t query) override {
        glQueryCounter(query, GL_TIMESTAMP);
    }

    bool available(uint32_t query) override {
        GLint ready = GL_FALSE;
        glGetQueryObjectiv(query, GL_QUERY_RESULT_AVAILABLE, &ready);
        return ready == GL_TRUE;
    }

    bool result(uint32_t query, uint64_t* value) override {
        GLuint64 timestamp = 0;
        glGetQueryObjectui64v(query, GL_QUERY_RESULT, &timestamp);
        *value = static_cast<uint64_t>(timestamp);
        return true;
    }

    void destroy(uint32_t query) override {
        const GLuint name = query;
        glDeleteQueries(1, &name);
    }
};

static uint64_t clockNanoseconds(clockid_t clock) {
    timespec value{};
    if (clock_gettime(clock, &value) != 0) return 0;
    return static_cast<uint64_t>(value.tv_sec) * 1000000000ull +
           static_cast<uint64_t>(value.tv_nsec);
}

static uint64_t forceRenderDurationSeconds() {
    constexpr uint64_t maximum = vrtelemetry::ForcedRenderWindow::kMaxDurationSeconds;
    const char* raw = std::getenv("POKEPORT_XR_FORCE_RENDER_SECONDS");
    if (!raw || !*raw) return maximum;
    if (*raw == '-') return maximum;
    errno = 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(raw, &end, 10);
    if (errno || end == raw || *end != '\0') return maximum;
    return std::min<uint64_t>(static_cast<uint64_t>(parsed), maximum);
}

using DrmGpuCounters = vrtelemetry::DrmClientCounters;

struct DrmGpuClientSample {
    std::string driver;
    std::string key;
    uint64_t clientId = 0;
    uint64_t busyNs = 0;
    uint64_t cycles = 0;
    uint64_t maxFreqHz = 0;
    bool comparable = false;
    bool cyclesAvailable = false;
};

struct CpuStageSample {
    std::string name, scene;
    uint64_t frame = 0, wallNs = 0, processCpuNs = 0, mainCpuNs = 0;
};

struct TelemetrySnapshot {
    std::vector<CpuStageSample> cpuStages;
    uint64_t cpuStagesDropped = 0;
    uint64_t wallNs = 0;
    uint64_t processCpuNs = 0;
    uint64_t mainCpuNs = 0;
    uint64_t gpuBusyNs = 0;
    uint64_t gpuCycles = 0;
    uint64_t gpuMaxFreqHz = 0;
    uint64_t gpuCurrentFreqHz = 0;
    uint64_t gpuClientCount = 0;
    uint64_t gpuAddedClients = 0;
    uint64_t gpuRemovedClients = 0;
    uint64_t gpuCounterRegressions = 0;
    bool gpuBusyAvailable = false;
    bool gpuCyclesAvailable = false;
    bool gpuMaxFreqAvailable = false;
    bool gpuCurrentFreqAvailable = false;
    std::string gpuBusyStatus = "unavailable";
    uint64_t gpuTimestampResultsDropped = 0;
    std::vector<DrmGpuClientSample> gpuClients;
    std::vector<vrtelemetry::TimestampResult> gpuTimestamps;
};

static std::map<std::string, DrmGpuCounters> readDrmGpuCounters() {
    std::map<std::string, DrmGpuCounters> counters;
    std::error_code error;
    std::filesystem::directory_iterator it("/proc/self/fd", error), end;
    while (!error && it != end) {
        const auto entry = *it;
        const std::string path = "/proc/self/fdinfo/" + entry.path().filename().string();
        std::ifstream input(path);
        if (input) {
            std::ostringstream contents;
            contents << input.rdbuf();
            DrmGpuCounters current;
            if (vrtelemetry::parseDrmFdInfo(contents.str(), &current))
                vrtelemetry::mergeDrmClient(counters, current);
        }
        it.increment(error);
    }
    return counters;
}

static uint64_t readGpuFrequencyHz() {
    std::ifstream input("/sys/class/devfreq/3d00000.gpu/cur_freq");
    std::string value;
    uint64_t hz = 0;
    if (!input || !std::getline(input, value) ||
        !vrtelemetry::parseUnsignedField(value, &hz))
        return 0;
    return hz;
}
#endif

// These unpack-state enums are available in the OpenGL versions supported by
// LÖVE, but older Windows SDK headers do not always expose all of them.
#ifndef GL_UNPACK_ROW_LENGTH
#define GL_UNPACK_ROW_LENGTH 0x0CF2
#endif
#ifndef GL_UNPACK_SKIP_ROWS
#define GL_UNPACK_SKIP_ROWS 0x0CF3
#endif
#ifndef GL_UNPACK_SKIP_PIXELS
#define GL_UNPACK_SKIP_PIXELS 0x0CF4
#endif
#ifndef GL_PACK_IMAGE_HEIGHT
#define GL_PACK_IMAGE_HEIGHT 0x806C
#endif
#ifndef GL_PACK_SKIP_IMAGES
#define GL_PACK_SKIP_IMAGES 0x806B
#endif

struct Config {
    uint32_t width = 0;
    uint32_t height = 0;
};

struct Swapchain {
    XrSwapchain handle = XR_NULL_HANDLE;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<XrSwapchainImageOpenGLKHR> images;
};

static std::string lowerAscii(const char* value) {
    std::string result = value ? value : "";
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) {
        return static_cast<char>(c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c);
    });
    return result;
}

static bool containsAsciiInsensitive(const char* haystack, const char* needle) {
    return lowerAscii(haystack).find(lowerAscii(needle)) != std::string::npos;
}

static std::string xrVersionString(XrVersion version) {
    return std::to_string(XR_VERSION_MAJOR(version)) + "." +
           std::to_string(XR_VERSION_MINOR(version)) + "." +
           std::to_string(XR_VERSION_PATCH(version));
}

class Bridge {
public:
    ~Bridge() { cleanup(); }

    bool initialize(const Config& config) {
        m_config = config;
        m_beginCount = 0;
        m_submitCount = 0;
        m_lastSubmitWidth = 0;
        m_lastSubmitHeight = 0;
        m_swapchainDumpCount = 0;
        m_swapchainDumpMessage.clear();
#if defined(__linux__)
        m_swapchainDumpDirectory.clear();
        m_swapchainDumpMask = 0;
        m_swapchainDumpConfigLoaded = false;
        m_swapchainDumpAfterSubmits = 0;
        loadSwapchainDumpConfig();
        m_telemetryEnabled = std::getenv("POKEPORT_VR_TELEMETRY") &&
                             std::strcmp(std::getenv("POKEPORT_VR_TELEMETRY"), "1") == 0;
        const char* forceRender = std::getenv("POKEPORT_XR_FORCE_RENDER");
        m_forceRenderRequested = m_telemetryEnabled && forceRender &&
            std::strcmp(forceRender, "1") == 0;
        m_forceRenderDurationSeconds = forceRenderDurationSeconds();
        m_forceRenderWindow.arm(false, false, 0, 0);
        m_forceRenderTimeoutReported = false;
        m_forceRenderIpdReported = false;
        m_forceRenderThisFrame = false;
        m_forceRenderBlockedThisFrame = false;
        m_poseSource = "unavailable";
        m_ipdSource = "unavailable";
        m_syntheticPoseThisFrame = false;
        m_poseUsableThisFrame = false;
        m_hasIpd = false;
        m_haveRuntimeCenter = false;
        m_haveSyntheticCenter = false;
        m_ipdFromCurrentFrame = false;
        m_havePreviousPose = false;
        m_haveStableRuntimePose = false;
        m_stablePoseSamples = 0;
        m_telemetryFrame = 0;
        m_telemetryScene = "unknown";
        m_lastWaitWallNs = 0;
        m_lastWaitCpuNs = 0;
        m_lastTelemetryWallNs = 0;
        m_lastTelemetryProcessCpuNs = 0;
        m_lastTelemetryMainCpuNs = 0;
        m_gpuCounterTracker.clear();
        m_completedGpuTimestamps.clear();
        m_completedCpuStages.clear();
        m_cpuStagesDropped = 0;
        m_timestampResultsDropped = 0;
        m_timestampRing.release(m_timestampBackend);
#endif

#if defined(_WIN32)
        m_hdc = wglGetCurrentDC();
        m_glrc = wglGetCurrentContext();
        if (!m_hdc || !m_glrc) {
            return fail("xrbridge.create requires an active WGL/OpenGL context");
        }
        const auto* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
        const auto* vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
        const auto* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
        m_glVersion = version ? version : "unavailable";
        m_glVendor = vendor ? vendor : "unavailable";
        m_glRenderer = renderer ? renderer : "unavailable";

        m_loader = LoadLibraryW(L"openxr_loader.dll");
        if (!m_loader) {
            return failWin32("could not load openxr_loader.dll");
        }

        m_getInstanceProcAddr = reinterpret_cast<PFN_xrGetInstanceProcAddr>(
            GetProcAddress(m_loader, "xrGetInstanceProcAddr"));
        if (!m_getInstanceProcAddr) {
            return fail("openxr_loader.dll does not export xrGetInstanceProcAddr");
        }
#else
        if (!captureCurrentContext()) return false;
        // Linux packages use the static OpenXR SDK loader. It selects the
        // active SteamVR runtime through the standard loader configuration.
        m_getInstanceProcAddr = xrGetInstanceProcAddr;
#endif

        if (!loadGlobal(m_enumerateInstanceExtensionProperties,
                        "xrEnumerateInstanceExtensionProperties") ||
            !loadGlobal(m_createInstance, "xrCreateInstance")) {
            return false;
        }

        if (!enumerateExtensions()) {
            return fail("the active OpenXR runtime does not advertise XR_KHR_opengl_enable");
        }

        XrInstanceCreateInfo instanceInfo{XR_TYPE_INSTANCE_CREATE_INFO};
        std::strncpy(instanceInfo.applicationInfo.applicationName, "xrbridge",
                     XR_MAX_APPLICATION_NAME_SIZE - 1);
        instanceInfo.applicationInfo.applicationName[XR_MAX_APPLICATION_NAME_SIZE - 1] = '\0';
        instanceInfo.applicationInfo.applicationVersion = 1;
        std::strncpy(instanceInfo.applicationInfo.engineName, "LOVE",
                     XR_MAX_ENGINE_NAME_SIZE - 1);
        instanceInfo.applicationInfo.engineName[XR_MAX_ENGINE_NAME_SIZE - 1] = '\0';
        instanceInfo.applicationInfo.engineVersion = 1;
        instanceInfo.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);

        std::vector<const char*> enabledExtensions{XR_KHR_OPENGL_ENABLE_EXTENSION_NAME};
        if (m_frameControllerExtensionAvailable)
            enabledExtensions.push_back(kFrameControllerExtensionName);
        configureFoveationExtensions(enabledExtensions);
        instanceInfo.enabledExtensionCount = static_cast<uint32_t>(enabledExtensions.size());
        instanceInfo.enabledExtensionNames = enabledExtensions.data();

        XrResult result = m_createInstance(&instanceInfo, &m_instance);
        if (XR_FAILED(result)) {
            return failResult("xrCreateInstance", result);
        }

        if (!loadInstance(m_destroyInstance, "xrDestroyInstance") ||
            !loadInstance(m_resultToString, "xrResultToString") ||
            !loadInstance(m_getInstanceProperties, "xrGetInstanceProperties") ||
            !loadInstance(m_getSystem, "xrGetSystem") ||
            !loadInstance(m_pollEvent, "xrPollEvent") ||
            !loadInstance(m_getCurrentInteractionProfile,
                          "xrGetCurrentInteractionProfile") ||
            !loadInstance(m_pathToString, "xrPathToString") ||
            !loadInstance(m_getSystemProperties, "xrGetSystemProperties") ||
            !loadInstance(m_enumerateViewConfigurations, "xrEnumerateViewConfigurations") ||
            !loadInstance(m_enumerateViewConfigurationViews,
                          "xrEnumerateViewConfigurationViews") ||
            !loadInstance(m_enumerateEnvironmentBlendModes,
                          "xrEnumerateEnvironmentBlendModes") ||
            !loadInstance(m_createSession, "xrCreateSession") ||
            !loadInstance(m_destroySession, "xrDestroySession") ||
            !loadInstance(m_stringToPath, "xrStringToPath") ||
            !loadInstance(m_createActionSet, "xrCreateActionSet") ||
            !loadInstance(m_destroyActionSet, "xrDestroyActionSet") ||
            !loadInstance(m_createAction, "xrCreateAction") ||
            !loadInstance(m_destroyAction, "xrDestroyAction") ||
            !loadInstance(m_suggestInteractionProfileBindings,
                          "xrSuggestInteractionProfileBindings") ||
            !loadInstance(m_attachSessionActionSets, "xrAttachSessionActionSets") ||
            !loadInstance(m_syncActions, "xrSyncActions") ||
            !loadInstance(m_getActionStateBoolean, "xrGetActionStateBoolean") ||
            !loadInstance(m_getActionStateFloat, "xrGetActionStateFloat") ||
            !loadInstance(m_getActionStatePose, "xrGetActionStatePose") ||
            !loadInstance(m_createActionSpace, "xrCreateActionSpace") ||
            !loadInstance(m_locateSpace, "xrLocateSpace") ||
            !loadInstance(m_getActionStateVector2f, "xrGetActionStateVector2f") ||
            !loadInstance(m_beginSession, "xrBeginSession") ||
            !loadInstance(m_endSession, "xrEndSession") ||
            !loadInstance(m_waitFrame, "xrWaitFrame") ||
            !loadInstance(m_beginFrame, "xrBeginFrame") ||
            !loadInstance(m_endFrame, "xrEndFrame") ||
            !loadInstance(m_locateViews, "xrLocateViews") ||
            !loadInstance(m_createReferenceSpace, "xrCreateReferenceSpace") ||
            !loadInstance(m_destroySpace, "xrDestroySpace") ||
            !loadInstance(m_enumerateSwapchainFormats, "xrEnumerateSwapchainFormats") ||
            !loadInstance(m_createSwapchain, "xrCreateSwapchain") ||
            !loadInstance(m_destroySwapchain, "xrDestroySwapchain") ||
            !loadInstance(m_enumerateSwapchainImages, "xrEnumerateSwapchainImages") ||
            !loadInstance(m_acquireSwapchainImage, "xrAcquireSwapchainImage") ||
            !loadInstance(m_waitSwapchainImage, "xrWaitSwapchainImage") ||
            !loadInstance(m_releaseSwapchainImage, "xrReleaseSwapchainImage") ||
            !loadInstance(m_getOpenGLGraphicsRequirements,
                          "xrGetOpenGLGraphicsRequirementsKHR")) {
            return false;
        }

        XrInstanceProperties instanceProperties{XR_TYPE_INSTANCE_PROPERTIES};
        result = m_getInstanceProperties(m_instance, &instanceProperties);
        if (XR_FAILED(result)) {
            return failResult("xrGetInstanceProperties", result);
        }
        m_runtimeName = instanceProperties.runtimeName;

        // The runtime is selected by the system OpenXR loader. This module
        // deliberately does not locate, launch, or link against SteamVR.
        if (!containsAsciiInsensitive(instanceProperties.runtimeName, "steamvr")) {
            return fail(std::string("the active OpenXR runtime is '") +
                        instanceProperties.runtimeName +
                        "'; xrbridge requires SteamVR to be the active runtime");
        }

        XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
        systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        result = m_getSystem(m_instance, &systemInfo, &m_systemId);
        if (XR_FAILED(result)) {
            return failResult("xrGetSystem", result);
        }

        loadFoveationFunctions();
        XrSystemFoveationEyeTrackedPropertiesMETA eyeFoveation{
            XR_TYPE_SYSTEM_FOVEATION_EYE_TRACKED_PROPERTIES_META};
        XrSystemProperties systemProperties{XR_TYPE_SYSTEM_PROPERTIES};
        if (m_eyeFoveationEnabled) systemProperties.next = &eyeFoveation;
        result = m_getSystemProperties(m_instance, m_systemId, &systemProperties);
        if (XR_FAILED(result)) {
            return failResult("xrGetSystemProperties", result);
        }

        m_eyeFoveationSupported = eyeFoveation.supportsFoveationEyeTracked == XR_TRUE;

        XrGraphicsRequirementsOpenGLKHR graphicsRequirements{
            XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_KHR};
        result = m_getOpenGLGraphicsRequirements(m_instance, m_systemId, &graphicsRequirements);
        if (XR_FAILED(result)) {
            return failResult("xrGetOpenGLGraphicsRequirementsKHR", result);
        }
        m_minOpenGlVersion = graphicsRequirements.minApiVersionSupported;
        m_maxOpenGlVersion = graphicsRequirements.maxApiVersionSupported;
        if (!validateOpenGlVersion()) return false;

        if (!selectViewConfiguration() || !selectBlendMode() || !createSession() ||
            !createActions() || !createReferenceSpace() || !createAimSpaces() || !createSwapchains()) {
            return false;
        }

        m_initialized = true;
        if (!pumpEvents()) {
            return false;
        }
#if defined(__linux__)
        if (m_forceRenderRequested) {
            const uint64_t startNs = clockNanoseconds(CLOCK_MONOTONIC);
            m_forceRenderWindow.arm(true, true, startNs,
                                    m_forceRenderDurationSeconds);
            std::fprintf(stderr,
                "[xrbridge] unattended force-render armed duration_s=%llu; "
                "OpenXR focused/shouldRender status remains raw\n",
                static_cast<unsigned long long>(
                    m_forceRenderWindow.durationNs() / 1000000000ull));
        }
#endif
        return true;
    }

    void destroy() {
        cleanup();
        m_lastError.clear();
    }

    bool isInitialized() const { return m_initialized; }

    bool isReady() const {
        return m_initialized && m_session != XR_NULL_HANDLE && m_sessionRunning &&
               !m_quitRequested && !m_instanceLossPending;
    }

    bool beginFrame() {
        resetFoveationFrame();
        if (!m_initialized) {
            return failIfEmpty("xrbridge is not initialized");
        }
        if (!sameCurrentContext()) {
            return fail("the current OpenGL context changed after xrbridge.create");
        }
        if (!pumpEvents()) {
            return false;
        }
        if (!isReady()) {
            return failIfEmpty("the OpenXR session is not ready for frames");
        }
        if (m_frameActive) {
            return fail("beginFrame called twice without submit");
        }

        XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
        m_frameState = {XR_TYPE_FRAME_STATE};
#if defined(__linux__)
        const uint64_t waitWallBefore = m_telemetryEnabled
            ? clockNanoseconds(CLOCK_MONOTONIC) : 0;
        const uint64_t waitCpuBefore = m_telemetryEnabled
            ? clockNanoseconds(CLOCK_THREAD_CPUTIME_ID) : 0;
#endif
        XrResult result = m_waitFrame(m_session, &waitInfo, &m_frameState);
#if defined(__linux__)
        if (m_telemetryEnabled) {
            const uint64_t waitWallAfter = clockNanoseconds(CLOCK_MONOTONIC);
            const uint64_t waitCpuAfter = clockNanoseconds(CLOCK_THREAD_CPUTIME_ID);
            m_lastWaitWallNs = waitWallAfter >= waitWallBefore
                ? waitWallAfter - waitWallBefore : 0;
            m_lastWaitCpuNs = waitCpuAfter >= waitCpuBefore
                ? waitCpuAfter - waitCpuBefore : 0;
        }
#endif
        if (XR_FAILED(result)) {
            return failResult("xrWaitFrame", result);
        }

        XrFrameBeginInfo beginInfo{XR_TYPE_FRAME_BEGIN_INFO};
        result = m_beginFrame(m_session, &beginInfo);
        if (XR_FAILED(result)) {
            return failResult("xrBeginFrame", result);
        }
        m_frameActive = true;

        XrViewLocateInfo locateInfo{XR_TYPE_VIEW_LOCATE_INFO};
        locateInfo.viewConfigurationType = m_viewConfigurationType;
        locateInfo.displayTime = m_frameState.predictedDisplayTime;
        locateInfo.space = m_referenceSpace;
        XrViewState viewState{XR_TYPE_VIEW_STATE};
        uint32_t viewCount = 0;
        for (XrView& view : m_views) {
            view = {XR_TYPE_VIEW};
        }
        result = m_locateViews(m_session, &locateInfo, &viewState,
                               static_cast<uint32_t>(m_views.size()), &viewCount,
                               m_views.data());
        if (XR_FAILED(result) || viewCount != m_views.size()) {
            endEmptyFrame();
            if (XR_FAILED(result)) {
                return failResult("xrLocateViews", result);
            }
            return fail("xrLocateViews returned an unexpected number of eyes");
        }

        m_viewStateFlags = viewState.viewStateFlags;
#if defined(__linux__)
        if (m_forceRenderRequested)
            updateRuntimePoseCache(m_views, m_viewStateFlags);
        m_forceRenderThisFrame = false;
        m_forceRenderBlockedThisFrame = false;
        m_syntheticPoseThisFrame = false;
        m_poseUsableThisFrame =
            (m_viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0 &&
            (m_viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
        m_poseSource = m_poseUsableThisFrame ? "runtime-current" : "unavailable";
        if (m_hasIpd)
            m_ipdSource = m_ipdFromCurrentFrame ? "runtime" : "runtime-cached";
        else
            m_ipdSource = "unavailable";
        if (forceRenderActive() && m_frameState.shouldRender != XR_TRUE) {
            if (m_hasIpd) {
                m_forceRenderThisFrame = applyUnattendedPose();
                m_forceRenderBlockedThisFrame = !m_forceRenderThisFrame;
            } else {
                m_forceRenderBlockedThisFrame = true;
                if (!m_forceRenderIpdReported) {
                    std::fprintf(stderr,
                        "[xrbridge] unattended force-render blocked: no valid runtime "
                        "eye separation is available yet; no IPD will be invented\n");
                    m_forceRenderIpdReported = true;
                }
            }
        }
#endif
        refreshEyeFoveation();
        ++m_beginCount;
        m_lastError.clear();
        return true;
    }

    bool submit(uint32_t width, uint32_t height, const char* left, size_t leftLength,
                const char* right, size_t rightLength) {
        if (!m_initialized) {
            return failIfEmpty("xrbridge is not initialized");
        }
        if (!m_frameActive) {
            return fail("submit called without a successful beginFrame");
        }
        if (!sameCurrentContext()) {
            endEmptyFrame();
            return fail("the current OpenGL context changed before submit");
        }
        if (width == 0 || height == 0 || width != m_swapchains[0].width ||
            height != m_swapchains[0].height) {
            endEmptyFrame();
            return fail("submit dimensions must exactly match the OpenXR swapchains; "
                        "set create({width=..., height=...}) if needed");
        }
        if (!renderAllowedForCurrentFrame()) {
            endEmptyFrame();
            return fail("submit requires raw OpenXR shouldRender or an active bounded diagnostic authorization");
        }

        const uint64_t expectedBytes = static_cast<uint64_t>(width) * height * 4u;
        if (expectedBytes > std::numeric_limits<size_t>::max() ||
            leftLength != expectedBytes || rightLength != expectedBytes) {
            endEmptyFrame();
            return fail("submit expects two raw RGBA8 strings of width * height * 4 bytes");
        }

        if (!uploadSwapchain(m_swapchains[0], left, width, height) ||
            !uploadSwapchain(m_swapchains[1], right, width, height)) {
            endEmptyFrame();
            return false;
        }

        XrCompositionLayerProjectionView projectionViews[2]{};
        for (size_t i = 0; i < 2; ++i) {
            projectionViews[i] = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
            projectionViews[i].pose = m_views[i].pose;
            projectionViews[i].fov = m_views[i].fov;
            projectionViews[i].subImage.swapchain = m_swapchains[i].handle;
            projectionViews[i].subImage.imageRect.offset = {0, 0};
            projectionViews[i].subImage.imageRect.extent = {
                static_cast<int32_t>(m_swapchains[i].width),
                static_cast<int32_t>(m_swapchains[i].height)};
            projectionViews[i].subImage.imageArrayIndex = 0;
        }

        XrCompositionLayerProjection projectionLayer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        projectionLayer.space = m_referenceSpace;
        projectionLayer.viewCount = 2;
        projectionLayer.views = projectionViews;

        const XrCompositionLayerBaseHeader* layers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer)};
        XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
        endInfo.displayTime = m_frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = m_environmentBlendMode;
        endInfo.layerCount = 1;
        endInfo.layers = layers;

        XrResult result = m_endFrame(m_session, &endInfo);
        m_frameActive = false;
        if (XR_FAILED(result)) {
            return failResult("xrEndFrame", result);
        }
        ++m_submitCount;
        m_lastSubmitWidth = width;
        m_lastSubmitHeight = height;
        m_lastError.clear();
        return true;
    }

#if defined(__linux__)
    bool submitCanvases(love::graphics::Canvas* left, uint32_t leftWidth,
                        uint32_t leftHeight, bool leftReadable,
                        love::graphics::Canvas* right, uint32_t rightWidth,
                        uint32_t rightHeight, bool rightReadable,
                        bool timestampCanvasCopies) {
        if (!m_initialized) return failIfEmpty("xrbridge is not initialized");
        if (!m_frameActive) return fail("submitCanvases called without beginFrame");
        if (!sameCurrentContext()) {
            endEmptyFrame();
            return fail("the current OpenGL context changed before submitCanvases");
        }
        if (!renderAllowedForCurrentFrame()) {
            endEmptyFrame();
            return fail("submitCanvases requires raw OpenXR shouldRender or an active bounded diagnostic authorization");
        }
        if (!left || !right || leftWidth == 0 || leftHeight == 0 ||
            rightWidth == 0 || rightHeight == 0 ||
            leftWidth > kMaxTextureDimension || leftHeight > kMaxTextureDimension ||
            rightWidth > kMaxTextureDimension || rightHeight > kMaxTextureDimension) {
            endEmptyFrame();
            return fail("submitCanvases requires two live 2D Canvases with valid dimensions");
        }

        if (!copyCanvasToSwapchain(m_swapchains[0], left, leftWidth, leftHeight,
                                   leftReadable,
                                   timestampCanvasCopies ? "eye1" : nullptr) ||
            !copyCanvasToSwapchain(m_swapchains[1], right, rightWidth, rightHeight,
                                   rightReadable,
                                   timestampCanvasCopies ? "eye2" : nullptr)) {
            endEmptyFrame();
            return false;
        }

        XrCompositionLayerProjectionView projectionViews[2]{};
        for (size_t i = 0; i < 2; ++i) {
            projectionViews[i] = {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW};
            projectionViews[i].pose = m_views[i].pose;
            projectionViews[i].fov = m_views[i].fov;
            projectionViews[i].subImage.swapchain = m_swapchains[i].handle;
            projectionViews[i].subImage.imageRect.offset = {0, 0};
            projectionViews[i].subImage.imageRect.extent = {
                static_cast<int32_t>(m_swapchains[i].width),
                static_cast<int32_t>(m_swapchains[i].height)};
            projectionViews[i].subImage.imageArrayIndex = 0;
        }

        XrCompositionLayerProjection projectionLayer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        projectionLayer.space = m_referenceSpace;
        projectionLayer.viewCount = 2;
        projectionLayer.views = projectionViews;
        const XrCompositionLayerBaseHeader* layers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer)};
        XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
        endInfo.displayTime = m_frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = m_environmentBlendMode;
        endInfo.layerCount = 1;
        endInfo.layers = layers;
        const XrResult result = measureXrCall("xr_end_frame", [&] {
            return m_endFrame(m_session, &endInfo); });
        m_frameActive = false;
        if (XR_FAILED(result)) return failResult("xrEndFrame (Canvas)", result);
        ++m_submitCount;
        m_lastSubmitWidth = std::max(leftWidth, rightWidth);
        m_lastSubmitHeight = std::max(leftHeight, rightHeight);
        m_lastError.clear();
        return true;
    }
#endif

    bool submitQuad(uint32_t width, uint32_t height, const char* pixels,
                    size_t pixelLength, float scale = kUiQuadDefaultScale) {
        if (!m_initialized) {
            return failIfEmpty("xrbridge is not initialized");
        }
        if (!m_frameActive) {
            return fail("submitQuad called without a successful beginFrame");
        }
        if (!sameCurrentContext()) {
            endEmptyFrame();
            return fail("the current OpenGL context changed before submitQuad");
        }
        if (width == 0 || height == 0) {
            endEmptyFrame();
            return fail("submitQuad dimensions must be positive");
        }
        if (!std::isfinite(scale) || scale <= 0.0f || scale > 4.0f) {
            endEmptyFrame();
            return fail("submitQuad scale must be finite and within 0..4");
        }
        if (!renderAllowedForCurrentFrame()) {
            endEmptyFrame();
            return fail("submitQuad requires raw OpenXR shouldRender or an active bounded diagnostic authorization");
        }

        const uint64_t expectedBytes = static_cast<uint64_t>(width) * height * 4u;
        if (expectedBytes > std::numeric_limits<size_t>::max() ||
            pixelLength != expectedBytes) {
            endEmptyFrame();
            return fail("submitQuad expects one raw RGBA8 string of width * height * 4 bytes");
        }
        if (!uploadSwapchain(m_swapchains[0], pixels, width, height)) {
            endEmptyFrame();
            return false;
        }

        XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};
        quad.space = m_referenceSpace;
        quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
        quad.subImage.swapchain = m_swapchains[0].handle;
        quad.subImage.imageRect.offset = {0, 0};
        quad.subImage.imageRect.extent = {
            static_cast<int32_t>(m_swapchains[0].width),
            static_cast<int32_t>(m_swapchains[0].height)};
        quad.subImage.imageArrayIndex = 0;
        quad.pose.orientation.w = 1.0f;
        quad.pose.position.z = -kUiQuadDistanceMeters;
        // Size the floating mono layer to the active headset frustum. This
        // preserves the comfortable depth of a quad layer while removing the
        // desktop-sized rectangle and black border around menus and dialogue.
        // Start outside the valid range so the first real headset FOV always
        // becomes the accumulator. Initialising to +/-1 silently ignored
        // common 40-45 degree eye tangents and made the quad too large on
        // headsets whose FOV stayed inside that default box.
        float leftTan = std::numeric_limits<float>::infinity();
        float rightTan = -std::numeric_limits<float>::infinity();
        float downTan = std::numeric_limits<float>::infinity();
        float upTan = -std::numeric_limits<float>::infinity();
        for (const XrView& view : m_views) {
            leftTan = std::min(leftTan, std::tan(view.fov.angleLeft));
            rightTan = std::max(rightTan, std::tan(view.fov.angleRight));
            downTan = std::min(downTan, std::tan(view.fov.angleDown));
            upTan = std::max(upTan, std::tan(view.fov.angleUp));
        }
        const float distance = kUiQuadDistanceMeters;
        quad.pose.position.x = distance * (leftTan + rightTan) * 0.5f;
        quad.pose.position.y = distance * (downTan + upTan) * 0.5f;
        quad.size.width = distance * (rightTan - leftTan) * scale;
        quad.size.height = distance * (upTan - downTan) * scale;
        if (!(quad.size.width > 0.0f) || !(quad.size.height > 0.0f)) {
            quad.pose.position.x = 0.0f;
            quad.pose.position.y = 0.0f;
            quad.size.height = kUiQuadHeightMeters * scale;
            quad.size.width = kUiQuadHeightMeters *
                static_cast<float>(width) / static_cast<float>(height)
                * scale;
        }

        const XrCompositionLayerBaseHeader* layers[] = {
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad)};
        XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
        endInfo.displayTime = m_frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = m_environmentBlendMode;
        endInfo.layerCount = 1;
        endInfo.layers = layers;

        XrResult result = m_endFrame(m_session, &endInfo);
        m_frameActive = false;
        if (XR_FAILED(result)) {
            return failResult("xrEndFrame (quad)", result);
        }
        ++m_submitCount;
        m_lastSubmitWidth = width;
        m_lastSubmitHeight = height;
        m_lastError.clear();
        return true;
    }

    bool abortFrame() {
        endEmptyFrame();
        resetFoveationFrame();
        return true;
    }

    bool pumpEvents() {
        if (!m_instance || !m_pollEvent) {
            return true;
        }

        for (;;) {
            XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
            XrResult result = m_pollEvent(m_instance, &event);
            if (result == XR_EVENT_UNAVAILABLE) {
                break;
            }
            if (XR_FAILED(result)) {
                return failResult("xrPollEvent", result);
            }

            switch (event.type) {
            case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
                resetFoveationFrame();
                m_instanceLossPending = true;
                m_quitRequested = true;
                break;
            case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED: {
                const auto* stateEvent =
                    reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
                m_sessionState = stateEvent->state;
                if (m_sessionState != XR_SESSION_STATE_FOCUSED) resetFoveationFrame();
                switch (m_sessionState) {
                case XR_SESSION_STATE_READY:
                    if (!m_sessionRunning) {
                        XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO};
                        beginInfo.primaryViewConfigurationType = m_viewConfigurationType;
                        result = m_beginSession(m_session, &beginInfo);
                        if (XR_FAILED(result)) {
                            return failResult("xrBeginSession", result);
                        }
                        m_sessionRunning = true;
                    }
                    break;
                case XR_SESSION_STATE_STOPPING:
                    if (m_sessionRunning) {
                        if (m_frameActive) {
                            endEmptyFrame();
                        }
                        result = m_endSession(m_session);
                        if (XR_FAILED(result)) {
                            return failResult("xrEndSession", result);
                        }
                        m_sessionRunning = false;
                    }
                    break;
                case XR_SESSION_STATE_EXITING:
                    m_quitRequested = true;
                    if (m_sessionRunning) {
                        if (m_frameActive) {
                            endEmptyFrame();
                        }
                        // xrEndSession is only valid after STOPPING. In
                        // EXITING the host loop quits and destroys the session.
                        m_sessionRunning = false;
                    }
                    break;
                case XR_SESSION_STATE_LOSS_PENDING:
                    m_instanceLossPending = true;
                    m_quitRequested = true;
                    break;
                default:
                    break;
                }
                break;
            }
            default:
                // Input state is synchronized by updateActions() after the
                // event queue is drained; no event type needs special casing
                // here beyond session lifecycle transitions.
                break;
            }
        }
        return true;
    }

    bool foveationAvailable() const { return m_foveationAvailable; }
    bool eyeFoveationSupported() const { return m_eyeFoveationSupported; }
    const std::string& foveationRequested() const { return m_foveationRequested; }
    const std::string& foveationApplied() const { return m_foveationApplied; }
    const std::string& foveationMessage() const { return m_foveationMessage; }
    bool foveationFrameAttempted() const { return m_foveationFrameAttempted; }
    bool foveationFrameUpdated() const { return m_foveationFrameUpdated; }
    bool foveationQueryAttempted() const { return m_foveationQueryAttempted; }
    bool foveationEyeValid() const { return m_foveationEyeValid; }
    XrResult foveationUpdateResult(size_t eye) const { return m_foveationUpdateResults[eye]; }
    XrResult foveationQueryResult() const { return m_foveationQueryResult; }
    XrTime foveationDisplayTime() const { return m_foveationDisplayTime; }
    const XrFoveationEyeTrackedStateMETA& foveationEyeState() const { return m_foveationEyeState; }
    const std::string& lastError() const { return m_lastError; }
    bool focused() const { return m_sessionState == XR_SESSION_STATE_FOCUSED; }
    bool shouldRender() const { return m_frameState.shouldRender == XR_TRUE; }
#if defined(__linux__)
    bool unattended() const { return m_forceRenderWindow.requested(); }
    bool forcedRenderThisFrame() {
        return m_forceRenderThisFrame && forceRenderActive();
    }
    bool forceRenderActive() {
        if (!m_forceRenderWindow.requested()) return false;
        const bool active = m_forceRenderWindow.active(
            clockNanoseconds(CLOCK_MONOTONIC));
        if (!active && m_forceRenderWindow.expired() &&
            !m_forceRenderTimeoutReported) {
            std::fprintf(stderr,
                "[xrbridge] unattended force-render timed out after %llu seconds\n",
                static_cast<unsigned long long>(
                    m_forceRenderWindow.durationNs() / 1000000000ull));
            m_forceRenderTimeoutReported = true;
        }
        return active;
    }
    bool forceRenderExpired() {
        (void)forceRenderActive();
        return m_forceRenderWindow.expired();
    }
    bool forceRenderBlocked() const { return m_forceRenderBlockedThisFrame; }
    const char* poseSource() const { return m_poseSource; }
    const char* ipdSource() const { return m_ipdSource; }
    bool poseUsable() const { return m_poseUsableThisFrame; }
    bool syntheticPose() const { return m_syntheticPoseThisFrame; }
    bool runtimePositionValid() const {
        return (m_viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
    }
    bool runtimeOrientationValid() const {
        return (m_viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0;
    }
#else
    bool poseUsable() const {
        return (m_viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0 &&
               (m_viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
    }
    bool syntheticPose() const { return false; }
#endif
    bool effectiveShouldRender() {
#if defined(__linux__)
        return m_frameState.shouldRender == XR_TRUE || forcedRenderThisFrame();
#else
        return shouldRender();
#endif
    }
    bool renderAllowedForCurrentFrame() {
#if defined(__linux__)
        return m_frameState.shouldRender == XR_TRUE || forcedRenderThisFrame();
#else
        return m_frameState.shouldRender == XR_TRUE;
#endif
    }
    bool quitRequested() const { return m_quitRequested; }
    bool instanceLossPending() const { return m_instanceLossPending; }
    XrSessionState sessionState() const { return m_sessionState; }
    const std::string& runtimeName() const { return m_runtimeName; }
    const std::string& glVersion() const { return m_glVersion; }
    const std::string& glVendor() const { return m_glVendor; }
    const std::string& glRenderer() const { return m_glRenderer; }
    std::string minimumOpenGlVersion() const {
        return xrVersionString(m_minOpenGlVersion);
    }
    std::string maximumOpenGlVersion() const {
        return xrVersionString(m_maxOpenGlVersion);
    }
    const char* swapchainFormatName() const {
        return m_swapchainFormat == kGlSrgb8Alpha8 ? "GL_SRGB8_ALPHA8" : "unknown";
    }
    uint32_t recommendedViewWidth(size_t index) const {
        return index < m_viewConfigurationViews.size()
            ? m_viewConfigurationViews[index].recommendedImageRectWidth : 0;
    }
    uint32_t recommendedViewHeight(size_t index) const {
        return index < m_viewConfigurationViews.size()
            ? m_viewConfigurationViews[index].recommendedImageRectHeight : 0;
    }
    std::string interactionProfile(size_t index) {
        if (index >= m_handPaths.size() || m_handPaths[index] == XR_NULL_PATH ||
            !m_getCurrentInteractionProfile || !m_pathToString ||
            m_session == XR_NULL_HANDLE || m_instance == XR_NULL_HANDLE) {
            return "unavailable";
        }
        XrInteractionProfileState profileState{
            XR_TYPE_INTERACTION_PROFILE_STATE};
        if (XR_FAILED(m_getCurrentInteractionProfile(
                m_session, m_handPaths[index], &profileState)) ||
            profileState.interactionProfile == XR_NULL_PATH) {
            return "none";
        }
        uint32_t length = 0;
        if (XR_FAILED(m_pathToString(m_instance, profileState.interactionProfile,
                                     0, &length, nullptr)) || length == 0 ||
            length > 1024) {
            return "unavailable";
        }
        std::vector<char> text(length, '\0');
        if (XR_FAILED(m_pathToString(m_instance, profileState.interactionProfile,
                                     length, &length, text.data()))) {
            return "unavailable";
        }
        return std::string(text.data());
    }
    const std::array<XrView, 2>& views() const { return m_views; }
    XrViewStateFlags viewStateFlags() const { return m_viewStateFlags; }
    uint32_t swapchainWidth() const { return m_swapchains[0].width; }
    uint32_t swapchainHeight() const { return m_swapchains[0].height; }
    uint64_t beginCount() const { return m_beginCount; }
    uint64_t submitCount() const { return m_submitCount; }
    uint64_t swapchainDumpCount() const { return m_swapchainDumpCount; }
    uint32_t swapchainDumpAfterSubmits() const { return m_swapchainDumpAfterSubmits; }
    const std::string& swapchainDumpMessage() const { return m_swapchainDumpMessage; }
    uint32_t lastSubmitWidth() const { return m_lastSubmitWidth; }
    bool actionsSupported() const { return m_actionsSupported; }
    bool frameControllerProfileAvailable() const {
        return m_frameControllerExtensionAvailable;
    }
    bool frameControllerBindingsSuggested() const {
        return m_frameControllerBindingsSuggested;
    }
    XrTime predictedDisplayTime() const { return m_frameState.predictedDisplayTime; }
    XrDuration predictedDisplayPeriod() const { return m_frameState.predictedDisplayPeriod; }
    float moveX() const { return m_moveX; }
    float moveY() const { return m_moveY; }
    const XrSpaceLocation& aim(size_t hand) const { return m_aimLocations[hand]; }
    float trigger(size_t hand) const { return m_triggers[hand]; }
    float scrollY() const { return m_scrollY; }
    bool actionA() const { return m_actionA; }
    bool actionB() const { return m_actionB; }
    bool actionStart() const { return m_actionStart; }
    bool actionSelect() const { return m_actionSelect; }
    bool actionRecenter() const { return m_actionRecenter; }
    uint32_t lastSubmitHeight() const { return m_lastSubmitHeight; }

#if defined(__linux__)
    bool telemetryEnabled() const { return m_telemetryEnabled; }
    uint64_t lastWaitWallNs() const { return m_lastWaitWallNs; }
    uint64_t lastWaitCpuNs() const { return m_lastWaitCpuNs; }

    template<class Function>
    XrResult measureXrCall(const char* name, Function call) {
        if (!m_telemetryEnabled) return call();
        CpuStageSample sample;
        sample.name = name; sample.scene = m_telemetryScene; sample.frame = m_telemetryFrame;
        const uint64_t wall = clockNanoseconds(CLOCK_MONOTONIC);
        const uint64_t process = clockNanoseconds(CLOCK_PROCESS_CPUTIME_ID);
        const uint64_t thread = clockNanoseconds(CLOCK_THREAD_CPUTIME_ID);
        const XrResult result = call();
        sample.mainCpuNs = clockNanoseconds(CLOCK_THREAD_CPUTIME_ID) - thread;
        sample.processCpuNs = clockNanoseconds(CLOCK_PROCESS_CPUTIME_ID) - process;
        sample.wallNs = clockNanoseconds(CLOCK_MONOTONIC) - wall;
        if (m_completedCpuStages.size() < 2048) m_completedCpuStages.push_back(std::move(sample));
        else ++m_cpuStagesDropped;
        return result;
    }

    void setTelemetryContext(uint64_t frame, const std::string& scene) {
        if (!m_telemetryEnabled) return;
        m_telemetryFrame = frame;
        m_telemetryScene = scene.empty() ? "unknown" : scene;
    }

    bool beginGpuTimestamp(const char* name, uint64_t frame,
                           const std::string& scene) {
        if (!m_telemetryEnabled || !sameCurrentContext()) return false;
        if (!m_timestampRing.probe(m_timestampBackend)) return false;
        return m_timestampRing.begin(m_timestampBackend, name, frame,
                                      scene.c_str());
    }

    void endGpuTimestamp() {
        if (!m_telemetryEnabled || !sameCurrentContext()) return;
        m_timestampRing.end(m_timestampBackend);
    }

    void cancelGpuTimestamp() {
        if (m_telemetryEnabled) m_timestampRing.cancelActive();
    }

    void noteGpuTimestampError() {
        if (m_telemetryEnabled) m_timestampRing.noteError();
    }

    void setTimestampContext(uint64_t frame, const std::string& scene) {
        setTelemetryContext(frame, scene);
    }

    void pollTelemetryGpu() {
        if (!m_telemetryEnabled || !sameCurrentContext()) return;
        // Source eyes, nested shadow passes and copies issue up to eight
        // scopes per submitted frame. Check a bounded
        // number of pending slots every frame so the fixed ring does not fill
        // during the one-second DRM/sysfs sampling interval.
        auto ready = m_timestampRing.poll(m_timestampBackend, 16);
        for (auto& result : ready) {
            if (m_completedGpuTimestamps.size() < 1024)
                m_completedGpuTimestamps.push_back(std::move(result));
            else
                ++m_timestampResultsDropped;
        }
    }

    void resetTelemetryWindow() {
        if (!m_telemetryEnabled) return;
        m_timestampRing.resetCounters();
        m_completedGpuTimestamps.clear();
        m_completedCpuStages.clear();
        m_cpuStagesDropped = 0;
        m_timestampResultsDropped = 0;
    }

    TelemetrySnapshot sampleTelemetry() {
        TelemetrySnapshot sample;
        if (!m_telemetryEnabled) return sample;
        const uint64_t wall = clockNanoseconds(CLOCK_MONOTONIC);
        const uint64_t processCpu = clockNanoseconds(CLOCK_PROCESS_CPUTIME_ID);
        const uint64_t mainCpu = clockNanoseconds(CLOCK_THREAD_CPUTIME_ID);
        if (m_lastTelemetryWallNs && wall >= m_lastTelemetryWallNs) {
            sample.wallNs = wall - m_lastTelemetryWallNs;
            if (processCpu >= m_lastTelemetryProcessCpuNs)
                sample.processCpuNs = processCpu - m_lastTelemetryProcessCpuNs;
            if (mainCpu >= m_lastTelemetryMainCpuNs)
                sample.mainCpuNs = mainCpu - m_lastTelemetryMainCpuNs;
        }
        m_lastTelemetryWallNs = wall;
        m_lastTelemetryProcessCpuNs = processCpu;
        m_lastTelemetryMainCpuNs = mainCpu;

        const auto current = readDrmGpuCounters();
        sample.gpuCurrentFreqHz = readGpuFrequencyHz();
        sample.gpuCurrentFreqAvailable = sample.gpuCurrentFreqHz > 0;
        sample.gpuClientCount = current.size();
        const auto counterWindow = m_gpuCounterTracker.sample(current, sample.wallNs);
        sample.gpuBusyNs = counterWindow.busyNs;
        sample.gpuCycles = counterWindow.cycles;
        sample.gpuMaxFreqHz = counterWindow.maxFreqHz;
        sample.gpuCyclesAvailable = counterWindow.cyclesAvailable;
        sample.gpuMaxFreqAvailable = counterWindow.maxFreqAvailable;
        sample.gpuBusyStatus = counterWindow.status;
        sample.gpuBusyAvailable = counterWindow.busyAvailable;
        sample.gpuAddedClients = counterWindow.addedClients;
        sample.gpuRemovedClients = counterWindow.removedClients;
        sample.gpuCounterRegressions = counterWindow.regressions;
        for (const auto& delta : counterWindow.clients) {
            DrmGpuClientSample client;
            client.driver = delta.counters.driver;
            client.key = delta.counters.key;
            client.clientId = delta.counters.clientId;
            client.busyNs = delta.busyNs;
            client.cycles = delta.cycles;
            client.maxFreqHz = delta.counters.maxFreqHz;
            client.comparable = delta.comparable;
            client.cyclesAvailable = delta.cyclesAvailable;
            sample.gpuClients.push_back(client);
        }

        sample.gpuTimestamps.swap(m_completedGpuTimestamps);
        sample.cpuStages.swap(m_completedCpuStages);
        sample.cpuStagesDropped = m_cpuStagesDropped;
        m_cpuStagesDropped = 0;
        sample.gpuTimestampResultsDropped = m_timestampResultsDropped;
        m_timestampResultsDropped = 0;
        return sample;
    }

    const char* gpuTimestampStatus() const {
        switch (m_timestampRing.status()) {
        case vrtelemetry::TimestampRing<kGpuTimestampRingCapacity>::QueryStatus::Available:
            return "available";
        case vrtelemetry::TimestampRing<kGpuTimestampRingCapacity>::QueryStatus::Unsupported:
            return "unsupported";
        case vrtelemetry::TimestampRing<kGpuTimestampRingCapacity>::QueryStatus::Error:
            return "error";
        default:
            return "unknown";
        }
    }
    uint64_t gpuTimestampPending() const { return m_timestampRing.pending(); }
    uint64_t gpuTimestampDropped() const { return m_timestampRing.dropped(); }
    uint64_t gpuTimestampErrors() const { return m_timestampRing.errors(); }
#endif

    void setError(const std::string& message) { m_lastError = message; }
    void updateActions() { (void)syncActions(); }

#if defined(__linux__) && defined(XRBRIDGE_TESTING)
    bool testCanvasCopy(love::graphics::Canvas* source,
                        uint32_t sourceWidth, uint32_t sourceHeight,
                        bool sourceReadable, love::graphics::Canvas* target,
                        uint32_t targetWidth, uint32_t targetHeight,
                        size_t dumpEyeIndex) {
        const char* telemetry = std::getenv("POKEPORT_VR_TELEMETRY");
        m_telemetryEnabled = telemetry && std::strcmp(telemetry, "1") == 0;
        if (!m_glxContext && !captureCurrentContext()) return false;
        if (!sameCurrentContext()) return fail("testCanvasCopy requires the captured GLX context");
        const GLuint targetTexture = static_cast<GLuint>(target->getRenderTargetHandle());
        if (!targetTexture) return fail("test Canvas has no OpenGL texture handle");
        if (!copyCanvasGpu(targetTexture, targetWidth, targetHeight, source,
                           sourceWidth, sourceHeight, sourceReadable)) {
            return false;
        }
        loadSwapchainDumpConfig();
        if (m_swapchainDumpDirectory.empty()) return true;

        ReadbackState original;
        const GLint testRowLength = static_cast<GLint>(targetWidth) + 3;
        const GLint testImageHeight = static_cast<GLint>(targetHeight) + 4;
        GLuint testPackBuffer = 0;
        glGenBuffers(1, &testPackBuffer);
        if (!testPackBuffer) return fail("could not allocate a test pixel-pack buffer");
        glBindBuffer(GL_PIXEL_PACK_BUFFER, testPackBuffer);
        glBufferData(GL_PIXEL_PACK_BUFFER, 128, nullptr, GL_STREAM_READ);
        glPixelStorei(GL_PACK_ALIGNMENT, 8);
        glPixelStorei(GL_PACK_ROW_LENGTH, testRowLength);
        glPixelStorei(GL_PACK_SKIP_PIXELS, 1);
        glPixelStorei(GL_PACK_SKIP_ROWS, 1);
        glPixelStorei(GL_PACK_IMAGE_HEIGHT, testImageHeight);
        glPixelStorei(GL_PACK_SKIP_IMAGES, 2);
        glPixelStorei(GL_PACK_SWAP_BYTES, GL_TRUE);
        glPixelStorei(GL_PACK_LSB_FIRST, GL_TRUE);
        const bool dumped = dumpSwapchainImage(targetTexture, targetWidth,
                                               targetHeight, dumpEyeIndex);
        ReadbackState after;
        const bool restored = after.framebuffer == original.framebuffer &&
            after.readBuffer == original.readBuffer &&
            after.packBuffer == static_cast<GLint>(testPackBuffer) &&
            after.alignment == 8 &&
            after.rowLength == testRowLength && after.skipPixels == 1 &&
            after.skipRows == 1 && after.imageHeight == testImageHeight &&
            after.skipImages == 2 && after.swapBytes == GL_TRUE &&
            after.lsbFirst == GL_TRUE;
        after.restore();
        original.restore();
        glDeleteBuffers(1, &testPackBuffer);
        if (!restored) return fail("swapchain diagnostic changed OpenGL readback state");
        if (!dumped) return failIfEmpty("swapchain diagnostic dump failed");
        return true;
    }
#endif

private:
#if defined(__linux__)
    bool canvasType(lua_State* L) {
        if (m_loveCanvasType) return true;
        const int originalTop = lua_gettop(L);
        lua_getglobal(L, "love");
        if (!lua_istable(L, -1)) {
            lua_settop(L, originalTop);
            return fail("LOVE graphics is not initialized");
        }
        lua_getfield(L, -1, "graphics");
        if (!lua_istable(L, -1)) {
            lua_settop(L, originalTop);
            return fail("LOVE graphics is not initialized");
        }
        lua_getfield(L, -1, "newCanvas");
        if (!lua_isfunction(L, -1)) {
            lua_settop(L, originalTop);
            return fail("LOVE graphics.newCanvas is unavailable");
        }
        lua_pushinteger(L, 1);
        lua_pushinteger(L, 1);
        if (lua_pcall(L, 2, 1, 0) != 0) {
            const char* error = lua_tostring(L, -1);
            const std::string detail = error ? error : "unknown LOVE error";
            lua_settop(L, originalTop);
            return fail("could not inspect the LOVE Canvas type: " + detail);
        }
        if (lua_type(L, -1) != LUA_TUSERDATA ||
            lua_objlen(L, -1) < sizeof(love::Proxy)) {
            lua_settop(L, originalTop);
            return fail("LOVE graphics.newCanvas returned unexpected userdata");
        }
        auto* proxy = static_cast<love::Proxy*>(lua_touserdata(L, -1));
        m_loveCanvasType = proxy ? proxy->type : nullptr;
        lua_settop(L, originalTop);
        if (!m_loveCanvasType) return fail("LOVE Canvas type metadata is unavailable");
        return true;
    }

public:
    // Exact color + depth restore for the stereo terrain shadow cache. The
    // caller has bound the original destination and flushed LOVE's batches.
    bool restoreShadowCanvas(love::graphics::Canvas* color,
                             love::graphics::Canvas* depth,
                             love::graphics::Canvas* target,
                             uint32_t width, uint32_t height) {
        if (!m_glxContext && !captureCurrentContext()) return false;
        if (!sameCurrentContext()) return fail("shadow restore requires the captured GLX context");
        if (color == target || color == depth || depth == target)
            return fail("shadow restore canvases must not alias");
        if (color->getMSAA() > 1 || depth->getMSAA() > 1 || target->getMSAA() > 1)
            return fail("shadow restore requires non-MSAA canvases");
        GLint texture = 0, formats[3]{};
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
        love::graphics::Canvas* canvases[] = {color, depth, target};
        for (int i = 0; i < 3; ++i) {
            glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(canvases[i]->getRenderTargetHandle()));
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &formats[i]);
        }
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(texture));
        if (formats[0] != formats[2] ||
            (formats[1] != GL_DEPTH_COMPONENT24 && formats[1] != GL_DEPTH_COMPONENT16))
            return fail("shadow restore requires matching color and supported depth formats");
        GLint read = 0, draw = 0, targetName = 0, targetType = 0, depthBits = 0, depthType = 0, depthName = 0;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
        if (!draw) return fail("shadow restore requires a bound destination Canvas");
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &targetName);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
            GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &targetType);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
            GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, &depthBits);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
            GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &depthType);
        glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
            GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &depthName);
        if (depthType == GL_TEXTURE && depthName == static_cast<GLint>(depth->getRenderTargetHandle()))
            return fail("shadow restore depth attachments must not alias");
        const GLint expectedBits = formats[1] == GL_DEPTH_COMPONENT24 ? 24 : 16;
        if (targetType != GL_TEXTURE || targetName != static_cast<GLint>(target->getRenderTargetHandle()) ||
            depthBits != expectedBits || glGetError() != GL_NO_ERROR)
            return fail("shadow restore destination or depth precision does not match");
        const GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
        const GLboolean srgb = glIsEnabled(GL_FRAMEBUFFER_SRGB);
        if (!m_shadowReadFramebuffer) glGenFramebuffers(1, &m_shadowReadFramebuffer);
        if (!m_shadowReadFramebuffer) return fail("shadow restore framebuffer allocation failed");
        glBindFramebuffer(GL_READ_FRAMEBUFFER, m_shadowReadFramebuffer);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                              static_cast<GLuint>(color->getRenderTargetHandle()), 0);
        glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D,
                              static_cast<GLuint>(depth->getRenderTargetHandle()), 0);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        bool copied = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        if (copied) {
            glDisable(GL_SCISSOR_TEST);glDisable(GL_FRAMEBUFFER_SRGB);
            // Same canvas convention and dimensions: no flip, scaling, shader,
            // packed-depth conversion or CPU transfer. Preserve lequal ties.
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                              GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT, GL_NEAREST);
            copied = glGetError() == GL_NO_ERROR;
        }
        glBindFramebuffer(GL_READ_FRAMEBUFFER, static_cast<GLuint>(read));
        if (scissor) glEnable(GL_SCISSOR_TEST);
        if (srgb) glEnable(GL_FRAMEBUFFER_SRGB);
        return copied || fail("shadow color/depth restore failed");
    }

    bool canvasFromLua(lua_State* L, int index, love::graphics::Canvas** canvas,
                       uint32_t* width, uint32_t* height, bool* readable) {
        if (!canvasType(L)) return false;
        index = (index > 0 || index <= LUA_REGISTRYINDEX)
            ? index : lua_gettop(L) + index + 1;
        if (lua_type(L, index) != LUA_TUSERDATA ||
            lua_objlen(L, index) < sizeof(love::Proxy)) {
            return fail("submitCanvases requires LOVE Canvas userdata");
        }
        auto* proxy = static_cast<love::Proxy*>(lua_touserdata(L, index));
        if (!proxy || proxy->type != m_loveCanvasType || !proxy->object) {
            return fail("submitCanvases received userdata that is not a LOVE Canvas");
        }
        const int originalTop = lua_gettop(L);
        lua_getfield(L, index, "getTextureType");
        if (!lua_isfunction(L, -1)) {
            lua_settop(L, originalTop);
            return fail("LOVE Canvas:getTextureType is unavailable");
        }
        lua_pushvalue(L, index);
        if (lua_pcall(L, 1, 1, 0) != 0 || lua_type(L, -1) != LUA_TSTRING ||
            std::strcmp(lua_tostring(L, -1), "2d") != 0) {
            lua_settop(L, originalTop);
            return fail("submitCanvases only supports 2D LOVE Canvases");
        }
        lua_pop(L, 1);

        lua_getfield(L, index, "getPixelDimensions");
        if (!lua_isfunction(L, -1)) {
            lua_settop(L, originalTop);
            return fail("LOVE Canvas:getPixelDimensions is unavailable");
        }
        lua_pushvalue(L, index);
        if (lua_pcall(L, 1, 2, 0) != 0 || !lua_isnumber(L, -2) ||
            !lua_isnumber(L, -1)) {
            lua_settop(L, originalTop);
            return fail("could not read LOVE Canvas pixel dimensions");
        }
        const lua_Number w = lua_tonumber(L, -2);
        const lua_Number h = lua_tonumber(L, -1);
        lua_pop(L, 2);
        if (!std::isfinite(w) || !std::isfinite(h) || w < 1 || h < 1 ||
            w > kMaxTextureDimension || h > kMaxTextureDimension ||
            std::floor(w) != w || std::floor(h) != h) {
            lua_settop(L, originalTop);
            return fail("LOVE Canvas pixel dimensions are outside 1..16384");
        }

        lua_getfield(L, index, "isReadable");
        if (!lua_isfunction(L, -1)) {
            lua_settop(L, originalTop);
            return fail("LOVE Canvas:isReadable is unavailable");
        }
        lua_pushvalue(L, index);
        if (lua_pcall(L, 1, 1, 0) != 0 || !lua_isboolean(L, -1)) {
            lua_settop(L, originalTop);
            return fail("could not inspect LOVE Canvas readability");
        }
        *readable = lua_toboolean(L, -1) != 0;
        *width = static_cast<uint32_t>(w);
        *height = static_cast<uint32_t>(h);
        *canvas = static_cast<love::graphics::Canvas*>(proxy->object);
        lua_settop(L, originalTop);
        return true;
    }

private:
    bool captureCurrentContext() {
        m_display = glXGetCurrentDisplay();
        m_glxDrawable = glXGetCurrentDrawable();
        m_glxContext = glXGetCurrentContext();
        if (!m_display || m_glxDrawable == 0 || !m_glxContext) {
            return fail("xrbridge.create requires an active GLX/OpenGL context");
        }

        const auto* version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
        const auto* vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
        const auto* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
        m_glVersion = version ? version : "unavailable";
        m_glVendor = vendor ? vendor : "unavailable";
        m_glRenderer = renderer ? renderer : "unavailable";

        int framebufferConfigId = 0;
        if (glXQueryContext(m_display, m_glxContext, GLX_FBCONFIG_ID,
                            &framebufferConfigId) != Success) {
            return fail("could not query the current GLX framebuffer configuration");
        }

        int configCount = 0;
        GLXFBConfig* configs = glXGetFBConfigs(
            m_display, DefaultScreen(m_display), &configCount);
        if (!configs || configCount <= 0) {
            if (configs) XFree(configs);
            return fail("could not enumerate GLX framebuffer configurations");
        }

        bool found = false;
        for (int i = 0; i < configCount; ++i) {
            int candidateId = 0;
            if (glXGetFBConfigAttrib(m_display, configs[i], GLX_FBCONFIG_ID,
                                     &candidateId) == Success &&
                candidateId == framebufferConfigId) {
                int visualId = 0;
                if (glXGetFBConfigAttrib(m_display, configs[i], GLX_VISUAL_ID,
                                         &visualId) == Success && visualId > 0) {
                    m_glxFBConfig = configs[i];
                    m_visualId = static_cast<uint32_t>(visualId);
                    found = true;
                    break;
                }
            }
        }
        XFree(configs);
        if (!found) {
            return fail("could not match the active GLX context to its framebuffer configuration");
        }
        return true;
    }

    bool validateOpenGlVersion() {
        int major = 0;
        int minor = 0;
        int patch = 0;
        if (std::sscanf(m_glVersion.c_str(), "%d.%d.%d", &major, &minor,
                        &patch) < 2 || major <= 0 || minor < 0 || patch < 0) {
            return fail("could not parse the current GLX context version '" +
                        m_glVersion + "'");
        }
        const XrVersion version = XR_MAKE_VERSION(major, minor, patch);
        if (version < m_minOpenGlVersion || version > m_maxOpenGlVersion) {
            return fail("current GLX context version " + xrVersionString(version) +
                        " is outside OpenXR's required GL range " +
                        xrVersionString(m_minOpenGlVersion) + ".." +
                        xrVersionString(m_maxOpenGlVersion));
        }
        return true;
    }
#endif

    template <typename Function>
    bool loadGlobal(Function& function, const char* name) {
        PFN_xrVoidFunction raw = nullptr;
        const XrResult result = m_getInstanceProcAddr(XR_NULL_HANDLE, name, &raw);
        if (XR_FAILED(result) || !raw) {
            return failResult(std::string("missing global OpenXR function ") + name, result);
        }
        function = reinterpret_cast<Function>(raw);
        return true;
    }

    template <typename Function>
    bool loadInstance(Function& function, const char* name) {
        function = nullptr;
        PFN_xrVoidFunction raw = nullptr;
        const XrResult result = m_getInstanceProcAddr(m_instance, name, &raw);
        if (XR_FAILED(result) || !raw) {
            return failResult(std::string("missing OpenXR function ") + name, result);
        }
        function = reinterpret_cast<Function>(raw);
        return true;
    }

    bool enumerateExtensions() {
        uint32_t count = 0;
        XrResult result = m_enumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr);
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateInstanceExtensionProperties", result);
        }
        if (count > kMaxExtensionCount) {
            return fail("OpenXR returned an invalid extension count");
        }

        std::vector<XrExtensionProperties> properties(count);
        for (XrExtensionProperties& property : properties) {
            property = {XR_TYPE_EXTENSION_PROPERTIES};
        }
        result = m_enumerateInstanceExtensionProperties(nullptr, count, &count,
                                                        properties.data());
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateInstanceExtensionProperties", result);
        }
        bool openGlAvailable = false;
        bool foveation = false, configuration = false, update = false;
        m_eyeFoveationAvailable = false;
        m_frameControllerExtensionAvailable = false;
        for (const XrExtensionProperties& property : properties) {
            const std::string name(property.extensionName);
            foveation |= name == XR_FB_FOVEATION_EXTENSION_NAME;
            configuration |= name == XR_FB_FOVEATION_CONFIGURATION_EXTENSION_NAME;
            update |= name == XR_FB_SWAPCHAIN_UPDATE_STATE_EXTENSION_NAME;
            m_eyeFoveationAvailable |= name == XR_META_FOVEATION_EYE_TRACKED_EXTENSION_NAME;
            if (std::strcmp(property.extensionName, XR_KHR_OPENGL_ENABLE_EXTENSION_NAME) == 0) {
                openGlAvailable = true;
            }
            if (std::strcmp(property.extensionName,
                            kFrameControllerExtensionName) == 0) {
                m_frameControllerExtensionAvailable = true;
            }
        }
        m_foveationAvailable = foveation && configuration && update;
        return openGlAvailable;
    }

    bool selectViewConfiguration() {
        uint32_t count = 0;
        XrResult result = m_enumerateViewConfigurations(m_instance, m_systemId, 0,
                                                        &count, nullptr);
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateViewConfigurations", result);
        }
        if (count == 0 || count > 32) {
            return fail("OpenXR returned an invalid view configuration count");
        }
        std::vector<XrViewConfigurationType> types(count);
        result = m_enumerateViewConfigurations(m_instance, m_systemId, count, &count,
                                                types.data());
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateViewConfigurations", result);
        }
        const auto found = std::find(types.begin(), types.end(),
                                     XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO);
        if (found == types.end()) {
            return fail("the OpenXR system does not provide primary stereo views");
        }
        m_viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;

        uint32_t viewCount = 0;
        result = m_enumerateViewConfigurationViews(m_instance, m_systemId,
                                                   m_viewConfigurationType, 0,
                                                   &viewCount, nullptr);
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateViewConfigurationViews", result);
        }
        if (viewCount != 2) {
            return fail("primary stereo must expose exactly two views");
        }
        m_viewConfigurationViews.resize(viewCount);
        for (XrViewConfigurationView& view : m_viewConfigurationViews) {
            view = {XR_TYPE_VIEW_CONFIGURATION_VIEW};
        }
        result = m_enumerateViewConfigurationViews(m_instance, m_systemId,
                                                   m_viewConfigurationType, viewCount,
                                                   &viewCount,
                                                   m_viewConfigurationViews.data());
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateViewConfigurationViews", result);
        }
        return true;
    }

    bool selectBlendMode() {
        uint32_t count = 0;
        XrResult result = m_enumerateEnvironmentBlendModes(
            m_instance, m_systemId, m_viewConfigurationType, 0, &count, nullptr);
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateEnvironmentBlendModes", result);
        }
        if (count == 0 || count > 16) {
            return fail("OpenXR returned an invalid environment blend mode count");
        }
        std::vector<XrEnvironmentBlendMode> modes(count);
        result = m_enumerateEnvironmentBlendModes(m_instance, m_systemId,
                                                  m_viewConfigurationType, count, &count,
                                                  modes.data());
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateEnvironmentBlendModes", result);
        }
        const auto opaque = std::find(modes.begin(), modes.end(),
                                      XR_ENVIRONMENT_BLEND_MODE_OPAQUE);
        m_environmentBlendMode = opaque != modes.end() ? *opaque : modes.front();
        return true;
    }

    bool createSession() {
#if defined(_WIN32)
        XrGraphicsBindingOpenGLWin32KHR graphicsBinding{
            XR_TYPE_GRAPHICS_BINDING_OPENGL_WIN32_KHR};
        graphicsBinding.hDC = m_hdc;
        graphicsBinding.hGLRC = m_glrc;
#else
        XrGraphicsBindingOpenGLXlibKHR graphicsBinding{
            XR_TYPE_GRAPHICS_BINDING_OPENGL_XLIB_KHR};
        graphicsBinding.xDisplay = m_display;
        graphicsBinding.visualid = m_visualId;
        graphicsBinding.glxFBConfig = m_glxFBConfig;
        graphicsBinding.glxDrawable = m_glxDrawable;
        graphicsBinding.glxContext = m_glxContext;
#endif

        XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
        sessionInfo.next = &graphicsBinding;
        sessionInfo.systemId = m_systemId;
        const XrResult result = m_createSession(m_instance, &sessionInfo, &m_session);
        if (XR_FAILED(result)) {
            return failResult("xrCreateSession", result);
        }
        return true;
    }

    bool pathFor(const char* path, XrPath* result) {
        const XrResult status = m_stringToPath(m_instance, path, result);
        return status == XR_SUCCESS;
    }

    bool createAction(XrAction* action, const char* name, const char* localized,
                      XrActionType type) {
        XrActionCreateInfo actionInfo{XR_TYPE_ACTION_CREATE_INFO};
        std::strncpy(actionInfo.actionName, name, XR_MAX_ACTION_NAME_SIZE - 1);
        actionInfo.actionName[XR_MAX_ACTION_NAME_SIZE - 1] = '\0';
        std::strncpy(actionInfo.localizedActionName, localized,
                     XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        actionInfo.localizedActionName[XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1] = '\0';
        actionInfo.actionType = type;
        actionInfo.countSubactionPaths = static_cast<uint32_t>(m_handPaths.size());
        actionInfo.subactionPaths = m_handPaths.data();
        const XrResult result = m_createAction(m_actionSet, &actionInfo, action);
        return result == XR_SUCCESS;
    }

    bool suggestBindings(const char* profile,
                         const std::vector<std::pair<XrAction, const char*>>& entries) {
        XrPath profilePath = XR_NULL_PATH;
        if (!pathFor(profile, &profilePath)) return false;

        std::vector<XrActionSuggestedBinding> bindings;
        bindings.reserve(entries.size());
        for (const auto& entry : entries) {
            XrPath bindingPath = XR_NULL_PATH;
            if (!pathFor(entry.second, &bindingPath)) return false;
            bindings.push_back({entry.first, bindingPath});
        }

        XrInteractionProfileSuggestedBinding suggestion{
            XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        suggestion.interactionProfile = profilePath;
        suggestion.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
        suggestion.suggestedBindings = bindings.data();
        return m_suggestInteractionProfileBindings(m_instance, &suggestion) == XR_SUCCESS;
    }

    bool createActions() {
        m_actionsSupported = false;
        m_moveX = 0.0f;
        m_moveY = 0.0f;
        m_actionA = false;
        m_actionB = false;
        m_actionStart = false;
        m_actionSelect = false;
        m_actionRecenter = false;
        m_frameViewWasDown = false;
        m_frameViewLongPressFired = false;
        m_frameViewPressTime = 0;

        if (!pathFor("/user/hand/left", &m_handPaths[0]) ||
            !pathFor("/user/hand/right", &m_handPaths[1])) {
            return true;
        }

        XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
        std::strncpy(setInfo.actionSetName, "pokemon",
                     XR_MAX_ACTION_SET_NAME_SIZE - 1);
        setInfo.actionSetName[XR_MAX_ACTION_SET_NAME_SIZE - 1] = '\0';
        std::strncpy(setInfo.localizedActionSetName, "Pokemon Red",
                     XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
        setInfo.localizedActionSetName[XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1] = '\0';
        setInfo.priority = 0;
        if (m_createActionSet(m_instance, &setInfo, &m_actionSet) != XR_SUCCESS) {
            return true;
        }

        if (!createAction(&m_moveAction, "move", "Move", XR_ACTION_TYPE_VECTOR2F_INPUT) ||
            !createAction(&m_aimAction, "launcher_aim", "Launcher aim", XR_ACTION_TYPE_POSE_INPUT) ||
            !createAction(&m_triggerAction, "launcher_trigger", "Launcher trigger", XR_ACTION_TYPE_FLOAT_INPUT) ||
            !createAction(&m_scrollAction, "launcher_scroll", "Launcher scroll", XR_ACTION_TYPE_VECTOR2F_INPUT) ||
            !createAction(&m_actionAHandle, "a", "A", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_actionBHandle, "b", "B", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_startAction, "start", "Start", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_selectAction, "select", "Select", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_recenterAction, "recenter", "Recenter view",
                          XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_frameViewAction, "frame_view", "View", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_dpadUpAction, "dpad_up", "D-pad up", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_dpadDownAction, "dpad_down", "D-pad down", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_dpadLeftAction, "dpad_left", "D-pad left", XR_ACTION_TYPE_BOOLEAN_INPUT) ||
            !createAction(&m_dpadRightAction, "dpad_right", "D-pad right", XR_ACTION_TYPE_BOOLEAN_INPUT)) {
            cleanupActions();
            return true;
        }

        // Bind the same left-stick movement and face actions for the generic
        // fallbacks. Steam Frame has a dedicated profile below when its
        // extension is advertised.
        (void)suggestBindings("/interaction_profiles/oculus/touch_controller", {
            {m_aimAction, "/user/hand/left/input/aim/pose"},
            {m_aimAction, "/user/hand/right/input/aim/pose"},
            {m_triggerAction, "/user/hand/left/input/trigger/value"},
            {m_triggerAction, "/user/hand/right/input/trigger/value"},
            {m_scrollAction, "/user/hand/right/input/thumbstick"},
            {m_moveAction, "/user/hand/left/input/thumbstick"},
            {m_actionAHandle, "/user/hand/right/input/a/click"},
            {m_actionBHandle, "/user/hand/right/input/b/click"},
            {m_startAction, "/user/hand/left/input/x/click"},
            {m_selectAction, "/user/hand/left/input/y/click"},
            {m_recenterAction, "/user/hand/left/input/thumbstick/click"},
        });
        (void)suggestBindings("/interaction_profiles/valve/index_controller", {
            {m_aimAction, "/user/hand/left/input/aim/pose"},
            {m_aimAction, "/user/hand/right/input/aim/pose"},
            {m_triggerAction, "/user/hand/left/input/trigger/value"},
            {m_triggerAction, "/user/hand/right/input/trigger/value"},
            {m_scrollAction, "/user/hand/right/input/thumbstick"},
            {m_moveAction, "/user/hand/left/input/thumbstick"},
            {m_actionAHandle, "/user/hand/right/input/a/click"},
            {m_actionBHandle, "/user/hand/right/input/b/click"},
            {m_startAction, "/user/hand/left/input/trackpad/click"},
            {m_selectAction, "/user/hand/right/input/trackpad/click"},
            {m_recenterAction, "/user/hand/left/input/thumbstick/click"},
        });
        (void)suggestBindings("/interaction_profiles/microsoft/motion_controller", {
            {m_moveAction, "/user/hand/left/input/thumbstick"},
            {m_actionAHandle, "/user/hand/left/input/a/click"},
            {m_actionAHandle, "/user/hand/right/input/a/click"},
            {m_actionBHandle, "/user/hand/left/input/b/click"},
            {m_actionBHandle, "/user/hand/right/input/b/click"},
            {m_startAction, "/user/hand/left/input/menu/click"},
            {m_startAction, "/user/hand/right/input/menu/click"},
            {m_selectAction, "/user/hand/left/input/thumbstick/click"},
            {m_selectAction, "/user/hand/right/input/thumbstick/click"},
        });
        (void)suggestBindings("/interaction_profiles/htc/vive_controller", {
            {m_moveAction, "/user/hand/left/input/trackpad"},
            {m_actionAHandle, "/user/hand/left/input/trigger/click"},
            {m_actionAHandle, "/user/hand/right/input/trigger/click"},
            {m_actionBHandle, "/user/hand/left/input/trackpad/click"},
            {m_actionBHandle, "/user/hand/right/input/trackpad/click"},
            {m_startAction, "/user/hand/left/input/menu/click"},
            {m_startAction, "/user/hand/right/input/menu/click"},
            {m_selectAction, "/user/hand/left/input/trackpad/click"},
            {m_selectAction, "/user/hand/right/input/trackpad/click"},
        });

        if (m_frameControllerExtensionAvailable) {
            m_frameControllerBindingsSuggested = suggestBindings(
                kFrameControllerProfilePath, {
            {m_aimAction, "/user/hand/left/input/aim/pose"},
            {m_aimAction, "/user/hand/right/input/aim/pose"},
            {m_triggerAction, "/user/hand/left/input/trigger/value"},
            {m_triggerAction, "/user/hand/right/input/trigger/value"},
            {m_scrollAction, "/user/hand/right/input/thumbstick"},
                    {m_moveAction, "/user/hand/left/input/thumbstick"},
                    {m_dpadUpAction, "/user/hand/left/input/dpad_up/click"},
                    {m_dpadDownAction, "/user/hand/left/input/dpad_down/click"},
                    {m_dpadLeftAction, "/user/hand/left/input/dpad_left/click"},
                    {m_dpadRightAction, "/user/hand/left/input/dpad_right/click"},
                    {m_frameViewAction, "/user/hand/left/input/view/click"},
                    {m_startAction, "/user/hand/right/input/menu/click"},
                    {m_actionAHandle, "/user/hand/right/input/a/click"},
                    {m_actionBHandle, "/user/hand/right/input/b/click"},
                });
        } else {
            m_frameControllerBindingsSuggested = false;
        }

        XrSessionActionSetsAttachInfo attachInfo{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
        attachInfo.countActionSets = 1;
        attachInfo.actionSets = &m_actionSet;
        if (m_attachSessionActionSets(m_session, &attachInfo) != XR_SUCCESS) {
            cleanupActions();
            return true;
        }
        m_actionsSupported = true;
        return true;
    }

    bool createAimSpaces() {
        if (!m_actionsSupported) return true;
        for (size_t i = 0; i < m_handPaths.size(); ++i) {
            XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO};
            info.action = m_aimAction;
            info.subactionPath = m_handPaths[i];
            info.poseInActionSpace.orientation.w = 1;
            const XrResult result = m_createActionSpace(m_session, &info, &m_aimSpaces[i]);
            if (XR_FAILED(result)) return failResult("xrCreateActionSpace", result);
        }
        return true;
    }

    void cleanupActions() {
        // Action spaces depend on both the pose action and the session.
        for (auto& space : m_aimSpaces) {
            if (space && m_destroySpace) (void)m_destroySpace(space);
            space = XR_NULL_HANDLE;
        }
        m_aimLocations = {};
        m_triggers = {};
        if (m_destroyAction) {
            for (XrAction* action : {&m_moveAction, &m_actionAHandle,
                                     &m_actionBHandle, &m_startAction,
                                     &m_selectAction, &m_recenterAction,
                                     &m_frameViewAction, &m_dpadUpAction,
                                     &m_dpadDownAction, &m_dpadLeftAction,
                                     &m_dpadRightAction, &m_aimAction, &m_triggerAction, &m_scrollAction}) {
                if (*action != XR_NULL_HANDLE) {
                    (void)m_destroyAction(*action);
                    *action = XR_NULL_HANDLE;
                }
            }
        }
        if (m_destroyActionSet && m_actionSet != XR_NULL_HANDLE) {
            (void)m_destroyActionSet(m_actionSet);
        }
        m_actionSet = XR_NULL_HANDLE;
        m_actionsSupported = false;
        m_frameControllerBindingsSuggested = false;
    }

    bool syncActions() {
        m_aimLocations = {};
        m_triggers = {};
        m_scrollY = 0;
        m_moveX = 0.0f;
        m_moveY = 0.0f;
        m_actionA = false;
        m_actionB = false;
        m_actionStart = false;
        m_actionSelect = false;
        m_actionRecenter = false;
        if (!m_actionsSupported || !m_sessionRunning || !focused()) {
            m_frameViewWasDown = false;
            m_frameViewLongPressFired = false;
            return false;
        }
        XrActiveActionSet activeSet{m_actionSet, XR_NULL_PATH};
        XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO};
        syncInfo.countActiveActionSets = 1;
        syncInfo.activeActionSets = &activeSet;
        if (m_syncActions(m_session, &syncInfo) != XR_SUCCESS) return false;

        float bestMagnitude = 0.0f;
        bool frameViewDown = false;
        bool dpadUp = false;
        bool dpadDown = false;
        bool dpadLeft = false;
        bool dpadRight = false;
        for (XrPath hand : m_handPaths) {
            XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO};
            getInfo.subactionPath = hand;
            // Locate aim with the same display time/reference space as this
            // frame's eyes. Never expose stale or partially valid tracking.
            const size_t index = hand == m_handPaths[0] ? 0 : 1;
            if (m_frameActive && shouldRender() && m_aimSpaces[index]) {
                XrActionStatePose pose{XR_TYPE_ACTION_STATE_POSE};
                getInfo.action = m_aimAction;
                XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
                const auto flags = XR_SPACE_LOCATION_POSITION_VALID_BIT |
                                   XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
                if (m_getActionStatePose(m_session, &getInfo, &pose) == XR_SUCCESS &&
                    pose.isActive && m_locateSpace(m_aimSpaces[index], m_referenceSpace,
                        m_frameState.predictedDisplayTime, &location) == XR_SUCCESS &&
                    (location.locationFlags & flags) == flags) {
                    XrActionStateFloat trigger{XR_TYPE_ACTION_STATE_FLOAT};
                    getInfo.action = m_triggerAction;
                    if (m_getActionStateFloat(m_session, &getInfo, &trigger) == XR_SUCCESS &&
                        trigger.isActive) {
                        m_aimLocations[index] = location;
                        m_triggers[index] = trigger.currentState;
                    }
                }
            }
            if (index == 1) {
                XrActionStateVector2f scroll{XR_TYPE_ACTION_STATE_VECTOR2F};
                getInfo.action = m_scrollAction;
                if (m_getActionStateVector2f(m_session, &getInfo, &scroll) == XR_SUCCESS &&
                    scroll.isActive) m_scrollY = scroll.currentState.y;
            }

            XrActionStateVector2f moveState{XR_TYPE_ACTION_STATE_VECTOR2F};
            getInfo.action = m_moveAction;
            if (m_getActionStateVector2f(m_session, &getInfo, &moveState) == XR_SUCCESS &&
                moveState.isActive == XR_TRUE) {
                const float magnitude = moveState.currentState.x * moveState.currentState.x +
                                        moveState.currentState.y * moveState.currentState.y;
                if (magnitude > bestMagnitude) {
                    bestMagnitude = magnitude;
                    m_moveX = moveState.currentState.x;
                    m_moveY = moveState.currentState.y;
                }
            }

            auto readButton = [&](XrAction action, bool* target) {
                XrActionStateBoolean buttonState{XR_TYPE_ACTION_STATE_BOOLEAN};
                getInfo.action = action;
                if (m_getActionStateBoolean(m_session, &getInfo, &buttonState) == XR_SUCCESS &&
                    buttonState.isActive == XR_TRUE) {
                    *target = *target || buttonState.currentState == XR_TRUE;
                }
            };
            readButton(m_actionAHandle, &m_actionA);
            readButton(m_actionBHandle, &m_actionB);
            readButton(m_startAction, &m_actionStart);
            readButton(m_selectAction, &m_actionSelect);
            readButton(m_recenterAction, &m_actionRecenter);
            auto readDpad = [&](XrAction action, bool* target) {
                XrActionStateBoolean buttonState{XR_TYPE_ACTION_STATE_BOOLEAN};
                getInfo.action = action;
                if (m_getActionStateBoolean(m_session, &getInfo, &buttonState) == XR_SUCCESS &&
                    buttonState.isActive == XR_TRUE) {
                    *target = *target || buttonState.currentState == XR_TRUE;
                }
            };
            readDpad(m_dpadUpAction, &dpadUp);
            readDpad(m_dpadDownAction, &dpadDown);
            readDpad(m_dpadLeftAction, &dpadLeft);
            readDpad(m_dpadRightAction, &dpadRight);
            if (hand == m_handPaths[0]) {
                XrActionStateBoolean viewState{XR_TYPE_ACTION_STATE_BOOLEAN};
                getInfo.action = m_frameViewAction;
                if (m_getActionStateBoolean(m_session, &getInfo, &viewState) == XR_SUCCESS &&
                    viewState.isActive == XR_TRUE) {
                    frameViewDown = viewState.currentState == XR_TRUE;
                }
            }
        }

        if (dpadLeft != dpadRight) m_moveX = dpadLeft ? -1.0f : 1.0f;
        if (dpadUp != dpadDown) m_moveY = dpadUp ? 1.0f : -1.0f;

        if (m_frameControllerBindingsSuggested) {
            if (frameViewDown && !m_frameViewWasDown) {
                m_frameViewPressTime = m_frameState.predictedDisplayTime;
                m_frameViewLongPressFired = false;
            } else if (frameViewDown && !m_frameViewLongPressFired &&
                       m_frameState.predictedDisplayTime >= m_frameViewPressTime &&
                       m_frameState.predictedDisplayTime - m_frameViewPressTime >=
                           kFrameViewLongPress) {
                m_actionRecenter = true;
                m_frameViewLongPressFired = true;
            } else if (!frameViewDown && m_frameViewWasDown &&
                       !m_frameViewLongPressFired) {
                m_actionSelect = true;
            }
            if (!frameViewDown) m_frameViewLongPressFired = false;
            m_frameViewWasDown = frameViewDown;
        }
        return true;
    }

    bool createReferenceSpace() {
        XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
        const XrResult result = m_createReferenceSpace(m_session, &spaceInfo,
                                                        &m_referenceSpace);
        if (XR_FAILED(result)) {
            return failResult("xrCreateReferenceSpace", result);
        }
        return true;
    }

    // The OpenGL binding cannot legally request the Vulkan FDM bit, nor the
    // QCOM scaled-bin bit without its GL extension. flags=0 is valid OpenXR;
    // Valve's implicit Vulkan layer may handle the underlying Zink passes.
    // A successful profile request does NOT prove those source passes benefit.
    void configureFoveationExtensions(std::vector<const char*>& extensions) {
        const char* value = std::getenv("POKEPORT_XR_FOVEATION");
        m_foveationRequested = value ? lowerAscii(value) : "eye";
        m_foveationApplied = "none";
        m_foveationMessage.clear();
        resetFoveationFrame();
        if (m_foveationRequested != "eye" && m_foveationRequested != "fixed" &&
            m_foveationRequested != "off") {
            m_foveationMessage = "invalid POKEPORT_XR_FOVEATION; expected eye, fixed or off";
            m_foveationRequested = "off";
        }
        m_foveationEnabled = m_foveationAvailable && m_foveationRequested != "off";
        m_eyeFoveationEnabled = m_foveationEnabled && m_eyeFoveationAvailable &&
                                m_foveationRequested == "eye";
        if (!m_foveationEnabled) {
            if (m_foveationRequested != "off")
                m_foveationMessage = "required FB foveation extensions unavailable; full-rate fallback";
            return;
        }
        extensions.push_back(XR_FB_SWAPCHAIN_UPDATE_STATE_EXTENSION_NAME);
        extensions.push_back(XR_FB_FOVEATION_EXTENSION_NAME);
        extensions.push_back(XR_FB_FOVEATION_CONFIGURATION_EXTENSION_NAME);
        if (m_eyeFoveationEnabled)
            extensions.push_back(XR_META_FOVEATION_EYE_TRACKED_EXTENSION_NAME);
    }

    void foveationFailure(const char* operation, XrResult result) {
        if (!m_foveationMessage.empty()) m_foveationMessage += "; ";
        m_foveationMessage += std::string(operation) + ": " + resultText(result);
    }

    template<typename Function>
    bool optionalFoveationFunction(Function& function, const char* name) {
        function = nullptr;
        PFN_xrVoidFunction raw = nullptr;
        const XrResult result = m_getInstanceProcAddr(m_instance, name, &raw);
        if (XR_FAILED(result) || !raw) {
            foveationFailure(name, XR_FAILED(result) ? result : XR_ERROR_FUNCTION_UNSUPPORTED);
            return false;
        }
        function = reinterpret_cast<Function>(raw);
        return true;
    }

    void loadFoveationFunctions() {
        if (!m_foveationEnabled) return;
        if (!optionalFoveationFunction(m_createFoveationProfile, "xrCreateFoveationProfileFB") ||
            !optionalFoveationFunction(m_destroyFoveationProfile, "xrDestroyFoveationProfileFB") ||
            !optionalFoveationFunction(m_updateSwapchain, "xrUpdateSwapchainFB"))
            m_foveationEnabled = false;
        if (m_foveationEnabled && m_eyeFoveationEnabled &&
            !optionalFoveationFunction(m_getFoveationEyeTrackedState, "xrGetFoveationEyeTrackedStateMETA"))
            m_eyeFoveationEnabled = false; // Existing fixed profile fallback.
    }

    void resetFoveationFrame() {
        m_foveationFrameAttempted = m_foveationFrameUpdated = m_foveationQueryAttempted = false;
        m_foveationEyeValid = false;
        m_foveationDisplayTime = 0;
        m_foveationUpdateResults = {XR_SUCCESS, XR_SUCCESS};
        m_foveationQueryResult = XR_SUCCESS;
        m_foveationEyeState = {XR_TYPE_FOVEATION_EYE_TRACKED_STATE_META};
    }

    void refreshEyeFoveation() {
        resetFoveationFrame();
        bool eligible = focused() && m_frameState.shouldRender == XR_TRUE;
#if defined(__linux__)
        // The existing bounded off-head authorization may exercise the API,
        // but it never fabricates a valid eye flag or gaze center.
        eligible = eligible || forcedRenderThisFrame();
#endif
        if (m_foveationApplied != "eye-medium" || !m_foveationProfile ||
            !m_updateSwapchain || !m_getFoveationEyeTrackedState || !eligible || !m_frameActive) return;
        m_foveationFrameAttempted = true;
        m_foveationDisplayTime = m_frameState.predictedDisplayTime;
        XrSwapchainStateFoveationFB profile{XR_TYPE_SWAPCHAIN_STATE_FOVEATION_FB};
        profile.profile = m_foveationProfile;
        for (size_t i = 0; i < m_swapchains.size(); ++i)
            m_foveationUpdateResults[i] = m_updateSwapchain(m_swapchains[i].handle,
                reinterpret_cast<const XrSwapchainStateBaseHeaderFB*>(&profile));
        m_foveationFrameUpdated = m_foveationUpdateResults[0] == XR_SUCCESS &&
                                  m_foveationUpdateResults[1] == XR_SUCCESS;
        if (!m_foveationFrameUpdated) return; // Never claim a partial refresh.
        // Khronos recommends update immediately before the query: request a
        // new pattern/capture timing BEFORE either expensive source-eye draw.
        m_foveationQueryAttempted = true;
        XrFoveationEyeTrackedStateMETA state{XR_TYPE_FOVEATION_EYE_TRACKED_STATE_META};
        m_foveationQueryResult = m_getFoveationEyeTrackedState(m_session, &state);
        if (m_foveationQueryResult != XR_SUCCESS) return;
        if (!(state.flags & XR_FOVEATION_EYE_TRACKED_STATE_VALID_BIT_META)) return;
        for (const auto& center : state.foveationCenter)
            if (!std::isfinite(center.x) || !std::isfinite(center.y) ||
                std::abs(center.x) > 1.0f || std::abs(center.y) > 1.0f) return;
        m_foveationEyeState = state;
        m_foveationEyeValid = true;
    }

    void releaseFoveationProfile() {
        if (m_foveationProfile && m_destroyFoveationProfile)
            (void)m_destroyFoveationProfile(m_foveationProfile);
        m_foveationProfile = XR_NULL_HANDLE;
        resetFoveationFrame();
    }

    bool createFoveationProfile() {
        if (!m_foveationEnabled) return false;
        bool eye = m_eyeFoveationEnabled && m_eyeFoveationSupported;
        if (m_foveationRequested == "eye" && !eye) {
            if (!m_foveationMessage.empty()) m_foveationMessage += "; ";
            m_foveationMessage += "eye-tracked foveation unsupported; requesting fixed fallback";
        }
        for (;;) {
            XrFoveationEyeTrackedProfileCreateInfoMETA eyeInfo{
                XR_TYPE_FOVEATION_EYE_TRACKED_PROFILE_CREATE_INFO_META};
            XrFoveationLevelProfileCreateInfoFB level{
                XR_TYPE_FOVEATION_LEVEL_PROFILE_CREATE_INFO_FB};
            level.level = XR_FOVEATION_LEVEL_MEDIUM_FB;
            level.dynamic = XR_FOVEATION_DYNAMIC_DISABLED_FB;
            level.next = eye ? &eyeInfo : nullptr;
            XrFoveationProfileCreateInfoFB info{XR_TYPE_FOVEATION_PROFILE_CREATE_INFO_FB};
            info.next = &level;
            const XrResult result = m_createFoveationProfile(m_session, &info, &m_foveationProfile);
            if (XR_SUCCEEDED(result)) {
                m_foveationProfileMode = eye ? "eye-medium" : "fixed-medium";
                return true;
            }
            m_foveationProfile = XR_NULL_HANDLE;
            foveationFailure(eye ? "create eye profile" : "create fixed profile", result);
            if (!eye) return false;
            eye = false;
        }
    }

    void releaseSwapchains() {
        for (Swapchain& swapchain : m_swapchains) {
            if (m_destroySwapchain && swapchain.handle)
                (void)m_destroySwapchain(swapchain.handle);
            swapchain.handle = XR_NULL_HANDLE;
            swapchain.images.clear();
        }
        releaseFoveationProfile(); // No swapchain can refer to it now.
    }

    bool fallbackSwapchains(const char* operation, XrResult result) {
        foveationFailure(operation, result);
        m_foveationMessage += "; full-rate fallback";
        // Recreate BOTH eyes, avoiding asymmetric foveation after a partial
        // update. This occurs only during initialization, before rendering.
        releaseSwapchains();
        releaseFoveationProfile();
        m_foveationApplied = "none";
        return createSwapchains(false);
    }

    bool createSwapchains(bool allowFoveation = true) {
        uint32_t formatCount = 0;
        XrResult result = m_enumerateSwapchainFormats(m_session, 0, &formatCount, nullptr);
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateSwapchainFormats", result);
        }
        if (formatCount == 0 || formatCount > 128) {
            return fail("OpenXR returned an invalid swapchain format count");
        }
        std::vector<int64_t> formats(formatCount);
        result = m_enumerateSwapchainFormats(m_session, formatCount, &formatCount,
                                             formats.data());
        if (XR_FAILED(result)) {
            return failResult("xrEnumerateSwapchainFormats", result);
        }

        if (std::find(formats.begin(), formats.end(), kGlSrgb8Alpha8) != formats.end()) {
            m_swapchainFormat = kGlSrgb8Alpha8;
        } else {
            return fail("the OpenXR runtime does not expose the required sRGB8-alpha8 swapchain format");
        }

        uint32_t width = m_config.width;
        uint32_t height = m_config.height;
        if (width == 0) {
            width = std::max(m_viewConfigurationViews[0].recommendedImageRectWidth,
                             m_viewConfigurationViews[1].recommendedImageRectWidth);
        }
        if (height == 0) {
            height = std::max(m_viewConfigurationViews[0].recommendedImageRectHeight,
                              m_viewConfigurationViews[1].recommendedImageRectHeight);
        }
        if (width == 0 || height == 0 || width > kMaxTextureDimension ||
            height > kMaxTextureDimension) {
            return fail("OpenXR reported invalid swapchain dimensions");
        }
        const uint32_t maxWidth = std::min(m_viewConfigurationViews[0].maxImageRectWidth,
                                           m_viewConfigurationViews[1].maxImageRectWidth);
        const uint32_t maxHeight = std::min(m_viewConfigurationViews[0].maxImageRectHeight,
                                            m_viewConfigurationViews[1].maxImageRectHeight);
        if (maxWidth == 0 || maxHeight == 0 || width > maxWidth || height > maxHeight) {
            return fail("requested swapchain dimensions exceed the OpenXR view limits");
        }

        const bool foveated = allowFoveation && createFoveationProfile();
        for (Swapchain& swapchain : m_swapchains) {
            XrSwapchainCreateInfoFoveationFB foveationInfo{
                XR_TYPE_SWAPCHAIN_CREATE_INFO_FOVEATION_FB};
            XrSwapchainCreateInfo swapchainInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
            // The bridge uploads pixels into the OpenGL texture and SteamVR
            // samples that texture when it composites the projection layer.
            // Keep both uses explicit for runtimes that use the declared
            // usage to choose the backing image capabilities.
            swapchainInfo.next = foveated ? &foveationInfo : nullptr;
            swapchainInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
                                       XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT |
                                       XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
            swapchainInfo.format = m_swapchainFormat;
            swapchainInfo.sampleCount = 1;
            swapchainInfo.width = width;
            swapchainInfo.height = height;
            swapchainInfo.faceCount = 1;
            swapchainInfo.arraySize = 1;
            swapchainInfo.mipCount = 1;
            result = m_createSwapchain(m_session, &swapchainInfo, &swapchain.handle);
            if (XR_FAILED(result)) {
                if (foveated) return fallbackSwapchains("create foveated GL swapchain", result);
                return failResult("xrCreateSwapchain", result);
            }
            swapchain.width = width;
            swapchain.height = height;

            uint32_t imageCount = 0;
            result = m_enumerateSwapchainImages(swapchain.handle, 0, &imageCount, nullptr);
            if (XR_FAILED(result)) {
                return failResult("xrEnumerateSwapchainImages", result);
            }
            if (imageCount == 0 || imageCount > 32) {
                return fail("OpenXR returned an invalid swapchain image count");
            }
            swapchain.images.resize(imageCount);
            for (XrSwapchainImageOpenGLKHR& image : swapchain.images) {
                image = {XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR};
            }
            result = m_enumerateSwapchainImages(
                swapchain.handle, imageCount, &imageCount,
                reinterpret_cast<XrSwapchainImageBaseHeader*>(swapchain.images.data()));
            if (XR_FAILED(result)) {
                return failResult("xrEnumerateSwapchainImages", result);
            }
        }
        if (foveated) {
            // Enumerate both GL image sets before applying mutable state, so
            // runtimes can finish materializing their graphics backing first.
            // A failed update still recreates both eyes at full rate.
            for (Swapchain& swapchain : m_swapchains) {
                XrSwapchainStateFoveationFB state{XR_TYPE_SWAPCHAIN_STATE_FOVEATION_FB};
                state.profile = m_foveationProfile;
                result = m_updateSwapchain(swapchain.handle,
                    reinterpret_cast<const XrSwapchainStateBaseHeaderFB*>(&state));
                if (XR_FAILED(result)) return fallbackSwapchains("apply foveation profile", result);
            }
            m_foveationApplied = m_foveationProfileMode;
        }
        // Fixed parameters are retained by the swapchains. Eye mode needs a
        // live profile for the recommended before-render update/query cadence.
        if (m_foveationApplied != "eye-medium") releaseFoveationProfile();
        return true;
    }

#if defined(__linux__)
    bool ensureCopyFramebuffers() {
        if (!m_copyReadFramebuffer) glGenFramebuffers(1, &m_copyReadFramebuffer);
        if (!m_copyDrawFramebuffer) glGenFramebuffers(1, &m_copyDrawFramebuffer);
        if (!m_copyResolveFramebuffer) glGenFramebuffers(1, &m_copyResolveFramebuffer);
        if (!m_copyReadFramebuffer || !m_copyDrawFramebuffer ||
            !m_copyResolveFramebuffer) {
            return fail("could not allocate OpenGL framebuffers for Canvas submission");
        }
        return true;
    }

    bool ensureResolveTexture(uint32_t width, uint32_t height) {
        if (!m_resolveTexture) glGenTextures(1, &m_resolveTexture);
        if (!m_resolveTexture) return fail("could not allocate an MSAA resolve texture");
        if (width == m_resolveWidth && height == m_resolveHeight) return true;

        GLint previousTexture = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
        glBindTexture(GL_TEXTURE_2D, m_resolveTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, static_cast<GLsizei>(width),
                     static_cast<GLsizei>(height), 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(previousTexture));
        const GLenum error = glGetError();
        if (error != GL_NO_ERROR) {
            return fail(std::string("could not allocate the MSAA resolve texture (OpenGL ") +
                        std::to_string(static_cast<unsigned int>(error)) + ")");
        }
        m_resolveWidth = width;
        m_resolveHeight = height;
        return true;
    }

    bool copyCanvasImage(GLuint targetTexture, uint32_t destinationWidth,
                         uint32_t destinationHeight,
                         love::graphics::Canvas* canvas,
                         uint32_t sourceWidth, uint32_t sourceHeight,
                         bool readable) {
        const int samples = canvas->getMSAA();
        const bool sourceIsRenderbuffer = samples > 1 || !readable;
        const GLuint sourceHandle = static_cast<GLuint>(canvas->getRenderTargetHandle());
        if (!sourceHandle) return fail("Canvas has no OpenGL render target handle");

        glBindFramebuffer(GL_READ_FRAMEBUFFER, m_copyReadFramebuffer);
        if (sourceIsRenderbuffer) {
            glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                      GL_RENDERBUFFER, sourceHandle);
        } else {
            glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                   GL_TEXTURE_2D, sourceHandle, 0);
        }
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        if (glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            return fail("Canvas render target is not a complete 2D color framebuffer");
        }

        if (samples > 1) {
            if (!ensureResolveTexture(sourceWidth, sourceHeight)) return false;
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, m_copyResolveFramebuffer);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                   GL_TEXTURE_2D, m_resolveTexture, 0);
            glDrawBuffer(GL_COLOR_ATTACHMENT0);
            if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                return fail("the MSAA resolve target is not a complete framebuffer");
            }
            glBlitFramebuffer(0, 0, static_cast<GLint>(sourceWidth),
                              static_cast<GLint>(sourceHeight), 0, 0,
                              static_cast<GLint>(sourceWidth),
                              static_cast<GLint>(sourceHeight), GL_COLOR_BUFFER_BIT,
                              GL_NEAREST);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, m_copyResolveFramebuffer);
        }

        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, m_copyDrawFramebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                               GL_TEXTURE_2D, targetTexture, 0);
        glDrawBuffer(GL_COLOR_ATTACHMENT0);
        if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            return fail("OpenXR swapchain image is not a complete color framebuffer");
        }
        // LOVE 11.5 Canvas row zero is its logical TOP (Graphics::setCanvas
        // uses an inverted projection relative to its window). OpenXR's GL
        // swapchain origin is BOTTOM-left. Convert once at this boundary,
        // including mono UI and resolved MSAA, just as uploadSwapchain does.
        glBlitFramebuffer(0, static_cast<GLint>(sourceHeight),
                          static_cast<GLint>(sourceWidth), 0, 0, 0,
                          static_cast<GLint>(destinationWidth),
                          static_cast<GLint>(destinationHeight), GL_COLOR_BUFFER_BIT,
                          (sourceWidth == destinationWidth &&
                           sourceHeight == destinationHeight)
                              ? GL_NEAREST : GL_LINEAR);
        return true;
    }

    bool copyCanvasGpu(GLuint targetTexture, uint32_t destinationWidth,
                       uint32_t destinationHeight,
                       love::graphics::Canvas* canvas,
                       uint32_t sourceWidth, uint32_t sourceHeight,
                       bool readable, const char* eyeLabel = nullptr) {
        if (!ensureCopyFramebuffers()) return false;
        GLint previousReadFramebuffer = 0;
        GLint previousDrawFramebuffer = 0;
        GLboolean previousScissor = glIsEnabled(GL_SCISSOR_TEST);
        GLboolean previousSrgb = glIsEnabled(GL_FRAMEBUFFER_SRGB);
        GLboolean previousColorMask[4] = {GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE};
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previousReadFramebuffer);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousDrawFramebuffer);
        glGetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);
#if defined(__linux__)
        bool timestampOpen = false;
        if (m_telemetryEnabled && eyeLabel) {
            const std::string label = std::string("canvas_copy_") + eyeLabel;
            timestampOpen = beginGpuTimestamp(label.c_str(), m_telemetryFrame,
                                                m_telemetryScene);
        }
#endif
        glDisable(GL_SCISSOR_TEST);
        glDisable(GL_FRAMEBUFFER_SRGB);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

        bool copied = false;
        std::string copyError;
        try {
            copied = copyCanvasImage(targetTexture, destinationWidth,
                                     destinationHeight, canvas, sourceWidth,
                                     sourceHeight, readable);
            if (!copied) copyError = m_lastError;
        } catch (...) {
            copyError = "Canvas OpenGL copy failed because allocation exhausted memory";
        }
        const GLenum copyGlError = glGetError();
        glBindFramebuffer(GL_READ_FRAMEBUFFER,
                          static_cast<GLuint>(previousReadFramebuffer));
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,
                          static_cast<GLuint>(previousDrawFramebuffer));
        glColorMask(previousColorMask[0], previousColorMask[1],
                    previousColorMask[2], previousColorMask[3]);
        if (previousScissor) glEnable(GL_SCISSOR_TEST);
        else glDisable(GL_SCISSOR_TEST);
        if (previousSrgb) glEnable(GL_FRAMEBUFFER_SRGB);
        else glDisable(GL_FRAMEBUFFER_SRGB);
        glFlush();
#if defined(__linux__)
        if (timestampOpen) endGpuTimestamp();
#endif

        if (!copied) return fail(copyError.empty() ? "Canvas OpenGL copy failed" : copyError);
        if (copyGlError != GL_NO_ERROR) {
            return fail(std::string("Canvas OpenGL copy failed with error ") +
                        std::to_string(static_cast<unsigned int>(copyGlError)));
        }
        return true;
    }

    void loadSwapchainDumpConfig() {
        if (m_swapchainDumpConfigLoaded) return;
        m_swapchainDumpConfigLoaded = true;
        const char* directory = std::getenv("POKEPORT_XR_SWAPCHAIN_DUMP_DIR");
        if (!directory || !*directory) {
            directory = std::getenv("POKEPORT_XR_PROBE_DUMP_DIR");
        }
        if (!directory || !*directory) return;

        try {
            const std::filesystem::path path(directory);
            if (!path.is_absolute() || !std::filesystem::is_directory(path)) {
                m_swapchainDumpMessage =
                    "dump directory must be an absolute existing directory";
                std::fprintf(stderr, "[xrbridge] swapchain dump disabled: %s\n",
                             m_swapchainDumpMessage.c_str());
                return;
            }
            uint32_t delay = 0;
            const char* rawDelay =
                std::getenv("POKEPORT_XR_SWAPCHAIN_DUMP_AFTER_SUBMITS");
            if (rawDelay && *rawDelay) {
                errno = 0;
                char* end = nullptr;
                const unsigned long parsed = std::strtoul(rawDelay, &end, 10);
                if (errno != 0 || end == rawDelay || *end != '\0') {
                    m_swapchainDumpMessage =
                        "dump submit delay must be an unsigned integer";
                    std::fprintf(stderr, "[xrbridge] swapchain dump disabled: %s\n",
                                 m_swapchainDumpMessage.c_str());
                    return;
                }
                delay = static_cast<uint32_t>(std::min<unsigned long>(
                    parsed, kMaxSwapchainDumpSubmitDelay));
                if (parsed > kMaxSwapchainDumpSubmitDelay) {
                    std::fprintf(stderr,
                        "[xrbridge] swapchain dump submit delay capped at %u\n",
                        kMaxSwapchainDumpSubmitDelay);
                }
            }
            m_swapchainDumpAfterSubmits = delay;
            m_swapchainDumpDirectory = path.string();
        } catch (const std::exception& error) {
            m_swapchainDumpMessage = std::string("could not inspect dump directory: ") +
                error.what();
            std::fprintf(stderr, "[xrbridge] swapchain dump disabled: %s\n",
                         m_swapchainDumpMessage.c_str());
        }
    }

    struct ReadbackState {
        GLint framebuffer = 0;
        GLint readBuffer = GL_BACK;
        GLint packBuffer = 0;
        GLint alignment = 4;
        GLint rowLength = 0;
        GLint skipPixels = 0;
        GLint skipRows = 0;
        GLint imageHeight = 0;
        GLint skipImages = 0;
        GLint swapBytes = GL_FALSE;
        GLint lsbFirst = GL_FALSE;
        bool restored = false;

        ReadbackState() {
            glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &framebuffer);
            glGetIntegerv(GL_READ_BUFFER, &readBuffer);
            glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &packBuffer);
            glGetIntegerv(GL_PACK_ALIGNMENT, &alignment);
            glGetIntegerv(GL_PACK_ROW_LENGTH, &rowLength);
            glGetIntegerv(GL_PACK_SKIP_PIXELS, &skipPixels);
            glGetIntegerv(GL_PACK_SKIP_ROWS, &skipRows);
            glGetIntegerv(GL_PACK_IMAGE_HEIGHT, &imageHeight);
            glGetIntegerv(GL_PACK_SKIP_IMAGES, &skipImages);
            glGetIntegerv(GL_PACK_SWAP_BYTES, &swapBytes);
            glGetIntegerv(GL_PACK_LSB_FIRST, &lsbFirst);
        }

        void restore() {
            if (restored) return;
            glBindFramebuffer(GL_READ_FRAMEBUFFER,
                              static_cast<GLuint>(framebuffer));
            glReadBuffer(static_cast<GLenum>(readBuffer));
            glBindBuffer(GL_PIXEL_PACK_BUFFER,
                         static_cast<GLuint>(packBuffer));
            glPixelStorei(GL_PACK_ALIGNMENT, alignment);
            glPixelStorei(GL_PACK_ROW_LENGTH, rowLength);
            glPixelStorei(GL_PACK_SKIP_PIXELS, skipPixels);
            glPixelStorei(GL_PACK_SKIP_ROWS, skipRows);
            glPixelStorei(GL_PACK_IMAGE_HEIGHT, imageHeight);
            glPixelStorei(GL_PACK_SKIP_IMAGES, skipImages);
            glPixelStorei(GL_PACK_SWAP_BYTES, swapBytes);
            glPixelStorei(GL_PACK_LSB_FIRST, lsbFirst);
            restored = true;
        }

        ~ReadbackState() { restore(); }
    };

    bool dumpSwapchainImage(GLuint texture, uint32_t width, uint32_t height,
                            size_t eyeIndex) {
        if (eyeIndex >= 2 || m_swapchainDumpDirectory.empty()) return false;
        const uint8_t eyeBit = static_cast<uint8_t>(1u << eyeIndex);
        if (m_swapchainDumpMask & eyeBit) return false;
        m_swapchainDumpMask |= eyeBit;

        const uint64_t pixels = static_cast<uint64_t>(width) * height;
        if (!texture || width == 0 || height == 0 ||
            pixels > kMaxSwapchainDumpPixels) {
            m_swapchainDumpMessage = "image exceeds the one-shot dump size limit";
            std::fprintf(stderr, "[xrbridge] swapchain dump eye=%s skipped: %s\n",
                         eyeIndex == 0 ? "left" : "right",
                         m_swapchainDumpMessage.c_str());
            return false;
        }

        try {
            std::vector<unsigned char> rgb(static_cast<size_t>(pixels) * 3u);
            while (glGetError() != GL_NO_ERROR) {
            }
            bool readSucceeded = false;
            GLenum readError = GL_NO_ERROR;
            {
                ReadbackState state;
                glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
                glPixelStorei(GL_PACK_ALIGNMENT, 1);
                glPixelStorei(GL_PACK_ROW_LENGTH, 0);
                glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
                glPixelStorei(GL_PACK_SKIP_ROWS, 0);
                glPixelStorei(GL_PACK_IMAGE_HEIGHT, 0);
                glPixelStorei(GL_PACK_SKIP_IMAGES, 0);
                glPixelStorei(GL_PACK_SWAP_BYTES, GL_FALSE);
                glPixelStorei(GL_PACK_LSB_FIRST, GL_FALSE);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, m_copyReadFramebuffer);
                glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                       GL_TEXTURE_2D, texture, 0);
                glReadBuffer(GL_COLOR_ATTACHMENT0);
                if (glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) ==
                    GL_FRAMEBUFFER_COMPLETE) {
                    glReadPixels(0, 0, static_cast<GLsizei>(width),
                                 static_cast<GLsizei>(height), GL_RGB,
                                 GL_UNSIGNED_BYTE, rgb.data());
                    readError = glGetError();
                    readSucceeded = readError == GL_NO_ERROR;
                }
                state.restore();
            }
            if (!readSucceeded) {
                m_swapchainDumpMessage = readError == GL_NO_ERROR
                    ? "swapchain image read framebuffer is incomplete"
                    : "glReadPixels failed with OpenGL error " +
                        std::to_string(static_cast<unsigned int>(readError));
                std::fprintf(stderr, "[xrbridge] swapchain dump eye=%s failed: %s\n",
                             eyeIndex == 0 ? "left" : "right",
                             m_swapchainDumpMessage.c_str());
                return false;
            }

            const char* eyeName = eyeIndex == 0 ? "left" : "right";
            const std::string path = m_swapchainDumpDirectory + "/xr-" + eyeName + ".ppm";
            const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                                  S_IRUSR | S_IWUSR);
            if (fd < 0) {
                m_swapchainDumpMessage = std::string("could not create ") + path +
                    ": " + std::strerror(errno);
                std::fprintf(stderr, "[xrbridge] swapchain dump eye=%s failed: %s\n",
                             eyeName, m_swapchainDumpMessage.c_str());
                return false;
            }

            char header[512];
            const int headerLength = std::snprintf(header, sizeof(header),
                "P6\n# eye=%s\n# source=OpenXR GL_SRGB8_ALPHA8 swapchain\n"
                "# readback=glReadPixels RGB8\n# row_order=top-left\n"
                "# predicted_display_time_ns=%lld\n%u %u\n255\n",
                eyeName, static_cast<long long>(m_frameState.predictedDisplayTime),
                width, height);
            bool writeOK = headerLength > 0 &&
                static_cast<size_t>(headerLength) < sizeof(header);
            auto writeAll = [&](const void* bytes, size_t length) {
                const auto* cursor = static_cast<const unsigned char*>(bytes);
                while (length > 0) {
                    const ssize_t written = ::write(fd, cursor, length);
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) return false;
                    cursor += written;
                    length -= static_cast<size_t>(written);
                }
                return true;
            };
            if (writeOK) writeOK = writeAll(header, static_cast<size_t>(headerLength));
            const size_t rowBytes = static_cast<size_t>(width) * 3u;
            for (uint32_t row = 0; writeOK && row < height; ++row) {
                // Read the compositor image in its OpenGL bottom-left
                // convention, then normalize to PPM's top-left row order.
                // Do not reinterpret it as a LOVE Canvas: that masks an
                // upside-down submission when comparing source and dump.
                const unsigned char* source = rgb.data() +
                    static_cast<size_t>(height - 1u - row) * rowBytes;
                writeOK = writeAll(source, rowBytes);
            }
            const int closeResult = ::close(fd);
            if (!writeOK || closeResult != 0) {
                const int savedError = errno;
                (void)::unlink(path.c_str());
                m_swapchainDumpMessage = std::string("could not write ") + path +
                    ": " + std::strerror(savedError);
                std::fprintf(stderr, "[xrbridge] swapchain dump eye=%s failed: %s\n",
                             eyeName, m_swapchainDumpMessage.c_str());
                return false;
            }

            ++m_swapchainDumpCount;
            m_swapchainDumpMessage = path;
            std::fprintf(stderr,
                "[xrbridge] swapchain dump eye=%s dimensions=%ux%u count=%llu file=%s\n",
                eyeName, width, height,
                static_cast<unsigned long long>(m_swapchainDumpCount), path.c_str());
            return true;
        } catch (const std::exception& error) {
            m_swapchainDumpMessage = std::string("swapchain dump failed: ") + error.what();
            std::fprintf(stderr, "[xrbridge] swapchain dump eye=%s failed: %s\n",
                         eyeIndex == 0 ? "left" : "right",
                         m_swapchainDumpMessage.c_str());
            return false;
        } catch (...) {
            m_swapchainDumpMessage = "swapchain dump failed due to allocation or I/O error";
            std::fprintf(stderr, "[xrbridge] swapchain dump eye=%s failed: %s\n",
                         eyeIndex == 0 ? "left" : "right",
                         m_swapchainDumpMessage.c_str());
            return false;
        }
    }

    void maybeDumpSwapchainImage(GLuint texture, uint32_t width,
                                 uint32_t height, size_t eyeIndex) {
        loadSwapchainDumpConfig();
        if (!m_swapchainDumpDirectory.empty() &&
            m_submitCount + 1u >= m_swapchainDumpAfterSubmits) {
            (void)dumpSwapchainImage(texture, width, height, eyeIndex);
        }
    }

    bool copyCanvasToSwapchain(Swapchain& swapchain,
                               love::graphics::Canvas* canvas,
                               uint32_t sourceWidth, uint32_t sourceHeight,
                               bool readable, const char* eyeLabel) {
        if (!ensureCopyFramebuffers()) return false;
        uint32_t imageIndex = 0;
        XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        XrResult result = measureXrCall(&swapchain == &m_swapchains[0] ? "swapchain_acquire_eye1" : "swapchain_acquire_eye2", [&] {
            return m_acquireSwapchainImage(swapchain.handle, &acquireInfo, &imageIndex); });
        if (XR_FAILED(result)) return failResult("xrAcquireSwapchainImage", result);
        XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
        waitInfo.timeout = XR_INFINITE_DURATION;
        result = measureXrCall(&swapchain == &m_swapchains[0] ? "swapchain_wait_eye1" : "swapchain_wait_eye2", [&] {
            return m_waitSwapchainImage(swapchain.handle, &waitInfo); });
        if (XR_FAILED(result)) {
            XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            (void)m_releaseSwapchainImage(swapchain.handle, &releaseInfo);
            return failResult("xrWaitSwapchainImage", result);
        }
        if (imageIndex >= swapchain.images.size()) {
            XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            (void)m_releaseSwapchainImage(swapchain.handle, &releaseInfo);
            return fail("xrAcquireSwapchainImage returned an invalid image index");
        }

        const bool copied = copyCanvasGpu(swapchain.images[imageIndex].image,
            swapchain.width, swapchain.height, canvas, sourceWidth, sourceHeight,
            readable, eyeLabel);
        const std::string copyError = m_lastError;

        if (copied) {
            const size_t eyeIndex = &swapchain == &m_swapchains[0] ? 0u : 1u;
            maybeDumpSwapchainImage(swapchain.images[imageIndex].image,
                                    swapchain.width, swapchain.height, eyeIndex);
        }

        XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        const XrResult releaseResult = m_releaseSwapchainImage(swapchain.handle,
                                                                &releaseInfo);
        if (XR_FAILED(releaseResult)) return failResult("xrReleaseSwapchainImage", releaseResult);
        if (!copied) return fail(copyError.empty() ? "Canvas OpenGL copy failed" : copyError);
        return true;
    }
#endif

    bool uploadSwapchain(Swapchain& swapchain, const char* pixels, uint32_t width,
                         uint32_t height) {
        uint32_t imageIndex = 0;
        XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        XrResult result = m_acquireSwapchainImage(swapchain.handle, &acquireInfo, &imageIndex);
        if (XR_FAILED(result)) {
            return failResult("xrAcquireSwapchainImage", result);
        }

        XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
        waitInfo.timeout = XR_INFINITE_DURATION;
        result = m_waitSwapchainImage(swapchain.handle, &waitInfo);
        if (XR_FAILED(result)) {
            XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            XrResult releaseResult = m_releaseSwapchainImage(swapchain.handle, &releaseInfo);
            if (XR_FAILED(releaseResult)) {
                return failResult("xrReleaseSwapchainImage", releaseResult);
            }
            return failResult("xrWaitSwapchainImage", result);
        }
        if (imageIndex >= swapchain.images.size()) {
            XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            (void)m_releaseSwapchainImage(swapchain.handle, &releaseInfo);
            return fail("xrAcquireSwapchainImage returned an invalid image index");
        }

        GLint previousTexture = 0;
        GLint previousUnpackAlignment = 4;
        GLint previousUnpackRowLength = 0;
        GLint previousUnpackSkipRows = 0;
        GLint previousUnpackSkipPixels = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
        glGetIntegerv(GL_UNPACK_ALIGNMENT, &previousUnpackAlignment);
        glGetIntegerv(GL_UNPACK_ROW_LENGTH, &previousUnpackRowLength);
        glGetIntegerv(GL_UNPACK_SKIP_ROWS, &previousUnpackSkipRows);
        glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &previousUnpackSkipPixels);
        while (glGetError() != GL_NO_ERROR) {
        }
        glBindTexture(GL_TEXTURE_2D, swapchain.images[imageIndex].image);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
        glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        const uint32_t destinationWidth = swapchain.width;
        const uint32_t destinationHeight = swapchain.height;
        const size_t sourceRowBytes = static_cast<size_t>(width) * 4u;
        const size_t destinationRowBytes = static_cast<size_t>(destinationWidth) * 4u;
        m_uploadBuffer.resize(destinationRowBytes * static_cast<size_t>(destinationHeight));
        for (uint32_t row = 0; row < destinationHeight; ++row) {
            // Projection eyes are already rendered at the swapchain size. A
            // mono UI/intro canvas is normally desktop-sized, so scale it
            // here instead of rejecting the frame after headset-sized
            // swapchains are enabled.
            const uint32_t sourceRow = std::min(
                height - 1u,
                static_cast<uint32_t>((static_cast<uint64_t>(row) * height) /
                                       destinationHeight));
            const char* source = pixels +
                static_cast<size_t>(height - 1u - sourceRow) * sourceRowBytes;
            char* destination = m_uploadBuffer.data() +
                static_cast<size_t>(row) * destinationRowBytes;
            if (width == destinationWidth && height == destinationHeight) {
                std::memcpy(destination, source, sourceRowBytes);
                continue;
            }
            for (uint32_t column = 0; column < destinationWidth; ++column) {
                const uint32_t sourceColumn = std::min(
                    width - 1u,
                    static_cast<uint32_t>((static_cast<uint64_t>(column) * width) /
                                           destinationWidth));
                std::memcpy(destination + static_cast<size_t>(column) * 4u,
                            source + static_cast<size_t>(sourceColumn) * 4u, 4u);
            }
        }
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                        static_cast<GLsizei>(destinationWidth),
                        static_cast<GLsizei>(destinationHeight), GL_RGBA, GL_UNSIGNED_BYTE,
                        m_uploadBuffer.data());
        const GLenum glError = glGetError();
        // The OpenXR runtime may composite from another GL context. Make the
        // texture upload visible before releasing the image to that runtime.
        glFlush();
        glBindTexture(GL_TEXTURE_2D, static_cast<GLuint>(previousTexture));
        glPixelStorei(GL_UNPACK_ALIGNMENT, previousUnpackAlignment);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, previousUnpackRowLength);
        glPixelStorei(GL_UNPACK_SKIP_ROWS, previousUnpackSkipRows);
        glPixelStorei(GL_UNPACK_SKIP_PIXELS, previousUnpackSkipPixels);

        XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        const XrResult releaseResult = m_releaseSwapchainImage(swapchain.handle, &releaseInfo);
        if (XR_FAILED(releaseResult)) {
            return failResult("xrReleaseSwapchainImage", releaseResult);
        }
        if (glError != GL_NO_ERROR) {
            char message[96];
            std::snprintf(message, sizeof(message),
                          "OpenGL rejected the RGBA8 swapchain upload (error 0x%04X)",
                          static_cast<unsigned int>(glError));
            return fail(message);
        }
        return true;
    }

    void endEmptyFrame() {
        if (!m_frameActive || !m_endFrame || !m_session) {
            m_frameActive = false;
            return;
        }
        XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
        endInfo.displayTime = m_frameState.predictedDisplayTime;
        endInfo.environmentBlendMode = m_environmentBlendMode;
        endInfo.layerCount = 0;
        endInfo.layers = nullptr;
        (void)m_endFrame(m_session, &endInfo);
        m_frameActive = false;
    }

#if defined(__linux__)
    void updateRuntimePoseCache(const std::array<XrView, 2>& views,
                                XrViewStateFlags flags) {
        m_ipdFromCurrentFrame = false;
        const bool positionValid = (flags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0;
        const bool orientationValid = (flags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0;
        if (positionValid) {
            const float dx = views[1].pose.position.x - views[0].pose.position.x;
            const float dy = views[1].pose.position.y - views[0].pose.position.y;
            const float dz = views[1].pose.position.z - views[0].pose.position.z;
            const float separation = std::sqrt(dx * dx + dy * dy + dz * dz);
            if (std::isfinite(separation) && separation >= 0.045f &&
                separation <= 0.09f) {
                m_eyeSeparationMeters = separation;
                m_hasIpd = true;
                m_ipdFromCurrentFrame = true;
            }
            m_runtimeCenter = {
                (views[0].pose.position.x + views[1].pose.position.x) * 0.5f,
                (views[0].pose.position.y + views[1].pose.position.y) * 0.5f,
                (views[0].pose.position.z + views[1].pose.position.z) * 0.5f};
            m_haveRuntimeCenter = std::isfinite(m_runtimeCenter.x) &&
                std::isfinite(m_runtimeCenter.y) && std::isfinite(m_runtimeCenter.z);
        }

        if (!positionValid || !orientationValid) {
            m_havePreviousPose = false;
            m_stablePoseSamples = 0;
            return;
        }

        const auto& orientation = views[0].pose.orientation;
        const double qLength = std::sqrt(
            static_cast<double>(orientation.x) * orientation.x +
            static_cast<double>(orientation.y) * orientation.y +
            static_cast<double>(orientation.z) * orientation.z +
            static_cast<double>(orientation.w) * orientation.w);
        if (!std::isfinite(qLength) || qLength < 0.5) {
            m_havePreviousPose = false;
            m_stablePoseSamples = 0;
            return;
        }

        bool stable = false;
        if (m_havePreviousPose) {
            const float cx = m_runtimeCenter.x - m_previousRuntimeCenter.x;
            const float cy = m_runtimeCenter.y - m_previousRuntimeCenter.y;
            const float cz = m_runtimeCenter.z - m_previousRuntimeCenter.z;
            const double distance = std::sqrt(static_cast<double>(cx) * cx +
                static_cast<double>(cy) * cy + static_cast<double>(cz) * cz);
            const auto& previous = m_previousRuntimeViews[0].pose.orientation;
            const double previousLength = std::sqrt(
                static_cast<double>(previous.x) * previous.x +
                static_cast<double>(previous.y) * previous.y +
                static_cast<double>(previous.z) * previous.z +
                static_cast<double>(previous.w) * previous.w);
            const double dot = std::abs(
                static_cast<double>(orientation.x) * previous.x +
                static_cast<double>(orientation.y) * previous.y +
                static_cast<double>(orientation.z) * previous.z +
                static_cast<double>(orientation.w) * previous.w) /
                (qLength * previousLength);
            // Require five consecutive runtime-valid poses within 1 cm and
            // about 2 degrees before freezing and reusing the real head pose.
            stable = distance <= 0.01 && dot >= 0.99985;
        }
        m_stablePoseSamples = stable ? m_stablePoseSamples + 1 : 1;
        m_previousRuntimeViews = views;
        m_previousRuntimeCenter = m_runtimeCenter;
        m_havePreviousPose = true;
        if (m_stablePoseSamples >= 5 && m_hasIpd) {
            m_stableRuntimeViews = views;
            m_haveStableRuntimePose = true;
        }
    }

    bool applyUnattendedPose() {
        if (m_haveStableRuntimePose) {
            m_views[0].pose = m_stableRuntimeViews[0].pose;
            m_views[1].pose = m_stableRuntimeViews[1].pose;
            m_poseUsableThisFrame = true;
            m_syntheticPoseThisFrame = false;
            m_poseSource = "runtime-stable";
            return true;
        }
        if (!m_hasIpd) return false;
        if (!m_haveSyntheticCenter) {
            if (!m_haveRuntimeCenter) return false;
            m_syntheticCenter = m_runtimeCenter;
            m_haveSyntheticCenter = true;
        }
        const float halfIpd = m_eyeSeparationMeters * 0.5f;
        for (size_t i = 0; i < m_views.size(); ++i) {
            m_views[i].pose.orientation = {0.0f, 0.0f, 0.0f, 1.0f};
            m_views[i].pose.position = m_syntheticCenter;
            m_views[i].pose.position.x += i == 0 ? -halfIpd : halfIpd;
        }
        m_poseUsableThisFrame = true;
        m_syntheticPoseThisFrame = true;
        m_poseSource = "synthetic-fixed-center";
        return true;
    }

#endif

    bool sameCurrentContext() const {
#if defined(_WIN32)
        return m_hdc == wglGetCurrentDC() && m_glrc == wglGetCurrentContext();
#else
        return m_display == glXGetCurrentDisplay() &&
               m_glxDrawable == glXGetCurrentDrawable() &&
               m_glxContext == glXGetCurrentContext();
#endif
    }

    std::string resultText(XrResult result) const {
        char buffer[XR_MAX_RESULT_STRING_SIZE] = {};
        if (m_resultToString && m_instance &&
            m_resultToString(m_instance, result, buffer) == XR_SUCCESS) {
            return buffer;
        }
        return std::string("XrResult ") + std::to_string(static_cast<int>(result));
    }

    bool fail(const std::string& message) {
        m_lastError = message;
        return false;
    }

    bool failIfEmpty(const std::string& message) {
        if (m_lastError.empty()) {
            m_lastError = message;
        }
        return false;
    }

#if defined(_WIN32)
    bool failWin32(const char* operation) {
        const DWORD error = GetLastError();
        char message[256];
        std::snprintf(message, sizeof(message), "%s (Win32 error %lu)", operation,
                      static_cast<unsigned long>(error));
        return fail(message);
    }
#endif

    bool failResult(const std::string& operation, XrResult result) {
        return fail(operation + " failed: " + resultText(result));
    }

    static const char* sessionStateName(XrSessionState state) {
        switch (state) {
        case XR_SESSION_STATE_UNKNOWN:
            return "unknown";
        case XR_SESSION_STATE_IDLE:
            return "idle";
        case XR_SESSION_STATE_READY:
            return "ready";
        case XR_SESSION_STATE_SYNCHRONIZED:
            return "synchronized";
        case XR_SESSION_STATE_VISIBLE:
            return "visible";
        case XR_SESSION_STATE_FOCUSED:
            return "focused";
        case XR_SESSION_STATE_STOPPING:
            return "stopping";
        case XR_SESSION_STATE_LOSS_PENDING:
            return "loss_pending";
        case XR_SESSION_STATE_EXITING:
            return "exiting";
        default:
            return "other";
        }
    }

    friend const char* sessionStateNameForLua(XrSessionState state);

    void cleanup() {
        endEmptyFrame();
#if defined(__linux__)
        if (m_glxContext && glXGetCurrentContext() == m_glxContext)
            m_timestampRing.release(m_timestampBackend);
        else
            m_timestampRing.abandon();
#endif
        if (m_sessionRunning && m_endSession && m_session) {
            (void)m_endSession(m_session);
            m_sessionRunning = false;
        }
        if (m_destroySpace && m_referenceSpace) {
            (void)m_destroySpace(m_referenceSpace);
        }
        m_referenceSpace = XR_NULL_HANDLE;
        releaseSwapchains();
        releaseFoveationProfile();
        m_foveationApplied = "none";
        cleanupActions();
        if (m_destroySession && m_session) {
            (void)m_destroySession(m_session);
        }
        m_session = XR_NULL_HANDLE;
        if (m_destroyInstance && m_instance) {
            (void)m_destroyInstance(m_instance);
        }
        m_instance = XR_NULL_HANDLE;
        m_systemId = XR_NULL_SYSTEM_ID;
        m_sessionRunning = false;
        m_frameActive = false;
        m_initialized = false;
        m_quitRequested = false;
        m_instanceLossPending = false;
        m_sessionState = XR_SESSION_STATE_UNKNOWN;
        m_runtimeName.clear();
#if defined(_WIN32)
        if (m_loader) {
            FreeLibrary(m_loader);
        }
        m_loader = nullptr;
        m_hdc = nullptr;
        m_glrc = nullptr;
#else
        if (m_glxContext && glXGetCurrentContext() == m_glxContext) {
            const GLuint framebuffers[] = {m_copyReadFramebuffer,
                m_copyDrawFramebuffer, m_copyResolveFramebuffer, m_shadowReadFramebuffer};
            glDeleteFramebuffers(4, framebuffers);
            if (m_resolveTexture) glDeleteTextures(1, &m_resolveTexture);
        }
        m_shadowReadFramebuffer = 0;
        m_copyReadFramebuffer = 0;
        m_copyDrawFramebuffer = 0;
        m_copyResolveFramebuffer = 0;
        m_resolveTexture = 0;
        m_resolveWidth = 0;
        m_resolveHeight = 0;
        m_loveCanvasType = nullptr;
        m_display = nullptr;
        m_glxDrawable = 0;
        m_glxContext = nullptr;
        m_glxFBConfig = nullptr;
        m_visualId = 0;
        m_getInstanceProcAddr = nullptr;
#endif
    }

#if defined(XRBRIDGE_TESTING)
    friend struct FoveationTest;
    friend struct PointerTest;
#endif
    bool m_foveationAvailable = false;
    bool m_eyeFoveationAvailable = false;
    bool m_foveationEnabled = false;
    bool m_eyeFoveationEnabled = false;
    bool m_eyeFoveationSupported = false;
    std::string m_foveationRequested = "off";
    std::string m_foveationApplied = "none";
    std::string m_foveationProfileMode;
    std::string m_foveationMessage;
    bool m_foveationFrameAttempted = false, m_foveationFrameUpdated = false;
    bool m_foveationQueryAttempted = false, m_foveationEyeValid = false;
    XrTime m_foveationDisplayTime = 0;
    std::array<XrResult, 2> m_foveationUpdateResults{XR_SUCCESS, XR_SUCCESS};
    XrResult m_foveationQueryResult = XR_SUCCESS;
    XrFoveationEyeTrackedStateMETA m_foveationEyeState{XR_TYPE_FOVEATION_EYE_TRACKED_STATE_META};
    PFN_xrGetFoveationEyeTrackedStateMETA m_getFoveationEyeTrackedState = nullptr;
    XrFoveationProfileFB m_foveationProfile = XR_NULL_HANDLE;
    PFN_xrCreateFoveationProfileFB m_createFoveationProfile = nullptr;
    PFN_xrDestroyFoveationProfileFB m_destroyFoveationProfile = nullptr;
    PFN_xrUpdateSwapchainFB m_updateSwapchain = nullptr;
    Config m_config;
#if defined(_WIN32)
    HMODULE m_loader = nullptr;
    HDC m_hdc = nullptr;
    HGLRC m_glrc = nullptr;
#else
    Display* m_display = nullptr;
    GLXDrawable m_glxDrawable = 0;
    GLXContext m_glxContext = nullptr;
    GLXFBConfig m_glxFBConfig = nullptr;
    uint32_t m_visualId = 0;
    GLuint m_shadowReadFramebuffer = 0;
    GLuint m_copyReadFramebuffer = 0;
    GLuint m_copyDrawFramebuffer = 0;
    GLuint m_copyResolveFramebuffer = 0;
    GLuint m_resolveTexture = 0;
    uint32_t m_resolveWidth = 0;
    uint32_t m_resolveHeight = 0;
    love::Type* m_loveCanvasType = nullptr;
    std::string m_swapchainDumpDirectory;
    uint32_t m_swapchainDumpAfterSubmits = 0;
    uint8_t m_swapchainDumpMask = 0;
    bool m_swapchainDumpConfigLoaded = false;
#if defined(__linux__)
    bool m_telemetryEnabled = false;
    bool m_forceRenderRequested = false;
    bool m_forceRenderTimeoutReported = false;
    bool m_forceRenderIpdReported = false;
    bool m_forceRenderThisFrame = false;
    bool m_forceRenderBlockedThisFrame = false;
    bool m_poseUsableThisFrame = false;
    bool m_syntheticPoseThisFrame = false;
    bool m_ipdFromCurrentFrame = false;
    bool m_hasIpd = false;
    bool m_haveRuntimeCenter = false;
    bool m_haveSyntheticCenter = false;
    bool m_havePreviousPose = false;
    bool m_haveStableRuntimePose = false;
    uint64_t m_forceRenderDurationSeconds = 120;
    uint32_t m_stablePoseSamples = 0;
    float m_eyeSeparationMeters = 0.0f;
    XrVector3f m_runtimeCenter{};
    XrVector3f m_previousRuntimeCenter{};
    XrVector3f m_syntheticCenter{};
    std::array<XrView, 2> m_previousRuntimeViews{};
    std::array<XrView, 2> m_stableRuntimeViews{};
    const char* m_poseSource = "unavailable";
    const char* m_ipdSource = "unavailable";
    vrtelemetry::ForcedRenderWindow m_forceRenderWindow;
    uint64_t m_telemetryFrame = 0;
    std::string m_telemetryScene = "unknown";
    uint64_t m_lastWaitWallNs = 0;
    uint64_t m_lastWaitCpuNs = 0;
    uint64_t m_lastTelemetryWallNs = 0;
    uint64_t m_lastTelemetryProcessCpuNs = 0;
    uint64_t m_lastTelemetryMainCpuNs = 0;
    OpenGlTimestampBackend m_timestampBackend;
    vrtelemetry::TimestampRing<kGpuTimestampRingCapacity> m_timestampRing;
    vrtelemetry::DrmCounterTracker m_gpuCounterTracker;
    std::vector<vrtelemetry::TimestampResult> m_completedGpuTimestamps;
    std::vector<CpuStageSample> m_completedCpuStages;
    uint64_t m_cpuStagesDropped = 0;
    uint64_t m_timestampResultsDropped = 0;
#endif
#endif

    PFN_xrGetInstanceProcAddr m_getInstanceProcAddr = nullptr;
    PFN_xrEnumerateInstanceExtensionProperties m_enumerateInstanceExtensionProperties = nullptr;
    PFN_xrCreateInstance m_createInstance = nullptr;
    PFN_xrGetSystem m_getSystem = nullptr;
    PFN_xrDestroyInstance m_destroyInstance = nullptr;
    PFN_xrResultToString m_resultToString = nullptr;
    PFN_xrGetInstanceProperties m_getInstanceProperties = nullptr;
    PFN_xrPollEvent m_pollEvent = nullptr;
    PFN_xrGetCurrentInteractionProfile m_getCurrentInteractionProfile = nullptr;
    PFN_xrPathToString m_pathToString = nullptr;
    PFN_xrGetSystemProperties m_getSystemProperties = nullptr;
    PFN_xrEnumerateViewConfigurations m_enumerateViewConfigurations = nullptr;
    PFN_xrEnumerateViewConfigurationViews m_enumerateViewConfigurationViews = nullptr;
    PFN_xrEnumerateEnvironmentBlendModes m_enumerateEnvironmentBlendModes = nullptr;
    PFN_xrCreateSession m_createSession = nullptr;
    PFN_xrDestroySession m_destroySession = nullptr;
    PFN_xrStringToPath m_stringToPath = nullptr;
    PFN_xrCreateActionSet m_createActionSet = nullptr;
    PFN_xrDestroyActionSet m_destroyActionSet = nullptr;
    PFN_xrCreateAction m_createAction = nullptr;
    PFN_xrDestroyAction m_destroyAction = nullptr;
    PFN_xrSuggestInteractionProfileBindings m_suggestInteractionProfileBindings = nullptr;
    PFN_xrAttachSessionActionSets m_attachSessionActionSets = nullptr;
    PFN_xrSyncActions m_syncActions = nullptr;
    PFN_xrGetActionStateBoolean m_getActionStateBoolean = nullptr;
    PFN_xrGetActionStateFloat m_getActionStateFloat = nullptr;
    PFN_xrGetActionStatePose m_getActionStatePose = nullptr;
    PFN_xrCreateActionSpace m_createActionSpace = nullptr;
    PFN_xrLocateSpace m_locateSpace = nullptr;
    PFN_xrGetActionStateVector2f m_getActionStateVector2f = nullptr;
    PFN_xrBeginSession m_beginSession = nullptr;
    PFN_xrEndSession m_endSession = nullptr;
    PFN_xrWaitFrame m_waitFrame = nullptr;
    PFN_xrBeginFrame m_beginFrame = nullptr;
    PFN_xrEndFrame m_endFrame = nullptr;
    PFN_xrLocateViews m_locateViews = nullptr;
    PFN_xrCreateReferenceSpace m_createReferenceSpace = nullptr;
    PFN_xrDestroySpace m_destroySpace = nullptr;
    PFN_xrEnumerateSwapchainFormats m_enumerateSwapchainFormats = nullptr;
    PFN_xrCreateSwapchain m_createSwapchain = nullptr;
    PFN_xrDestroySwapchain m_destroySwapchain = nullptr;
    PFN_xrEnumerateSwapchainImages m_enumerateSwapchainImages = nullptr;
    PFN_xrAcquireSwapchainImage m_acquireSwapchainImage = nullptr;
    PFN_xrWaitSwapchainImage m_waitSwapchainImage = nullptr;
    PFN_xrReleaseSwapchainImage m_releaseSwapchainImage = nullptr;
    PFN_xrGetOpenGLGraphicsRequirementsKHR m_getOpenGLGraphicsRequirements = nullptr;

    XrInstance m_instance = XR_NULL_HANDLE;
    XrSystemId m_systemId = XR_NULL_SYSTEM_ID;
    XrSession m_session = XR_NULL_HANDLE;
    XrSpace m_referenceSpace = XR_NULL_HANDLE;
    XrActionSet m_actionSet = XR_NULL_HANDLE;
    XrAction m_moveAction = XR_NULL_HANDLE;
    XrAction m_aimAction = XR_NULL_HANDLE;
    XrAction m_triggerAction = XR_NULL_HANDLE;
    XrAction m_scrollAction = XR_NULL_HANDLE;
    std::array<XrSpace, 2> m_aimSpaces{};
    std::array<XrSpaceLocation, 2> m_aimLocations{};
    std::array<float, 2> m_triggers{};
    float m_scrollY = 0;
    XrAction m_actionAHandle = XR_NULL_HANDLE;
    XrAction m_actionBHandle = XR_NULL_HANDLE;
    XrAction m_startAction = XR_NULL_HANDLE;
    XrAction m_selectAction = XR_NULL_HANDLE;
    XrAction m_recenterAction = XR_NULL_HANDLE;
    XrAction m_frameViewAction = XR_NULL_HANDLE;
    XrAction m_dpadUpAction = XR_NULL_HANDLE;
    XrAction m_dpadDownAction = XR_NULL_HANDLE;
    XrAction m_dpadLeftAction = XR_NULL_HANDLE;
    XrAction m_dpadRightAction = XR_NULL_HANDLE;
    std::array<XrPath, 2> m_handPaths{};
    XrViewConfigurationType m_viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    XrEnvironmentBlendMode m_environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    XrSessionState m_sessionState = XR_SESSION_STATE_UNKNOWN;
    XrViewStateFlags m_viewStateFlags = 0;
    XrFrameState m_frameState{XR_TYPE_FRAME_STATE};
    std::vector<XrViewConfigurationView> m_viewConfigurationViews;
    std::array<XrView, 2> m_views{};
    std::array<Swapchain, 2> m_swapchains{};
    std::vector<char> m_uploadBuffer;
    int64_t m_swapchainFormat = 0;
    std::string m_lastError;
    std::string m_runtimeName;
    std::string m_glVersion = "unavailable";
    std::string m_glVendor = "unavailable";
    std::string m_glRenderer = "unavailable";
    XrVersion m_minOpenGlVersion = 0;
    XrVersion m_maxOpenGlVersion = 0;
    uint64_t m_beginCount = 0;
    uint64_t m_submitCount = 0;
    uint32_t m_lastSubmitWidth = 0;
    uint32_t m_lastSubmitHeight = 0;
    uint64_t m_swapchainDumpCount = 0;
    std::string m_swapchainDumpMessage;
    bool m_initialized = false;
    bool m_sessionRunning = false;
    bool m_frameActive = false;
    bool m_quitRequested = false;
    bool m_instanceLossPending = false;
    bool m_actionsSupported = false;
    bool m_frameControllerExtensionAvailable = false;
    bool m_frameControllerBindingsSuggested = false;
    bool m_frameViewWasDown = false;
    bool m_frameViewLongPressFired = false;
    XrTime m_frameViewPressTime = 0;
    float m_moveX = 0.0f;
    float m_moveY = 0.0f;
    bool m_actionA = false;
    bool m_actionB = false;
    bool m_actionStart = false;
    bool m_actionSelect = false;
    bool m_actionRecenter = false;
};

Bridge g_bridge;

const char* sessionStateNameForLua(XrSessionState state) {
    return Bridge::sessionStateName(state);
}

static bool readConfigUInt(lua_State* L, int index, const char* name, uint32_t* value,
                           std::string* error) {
    lua_getfield(L, index, name);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return true;
    }
    if (!lua_isnumber(L, -1)) {
        lua_pop(L, 1);
        *error = std::string("create config field '") + name + "' must be a positive integer";
        return false;
    }
    const lua_Integer integerValue = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (integerValue <= 0
        || static_cast<uint64_t>(integerValue) > kMaxTextureDimension) {
        *error = std::string("create config field '") + name + "' is outside 1..16384";
        return false;
    }
    *value = static_cast<uint32_t>(integerValue);
    return true;
}

static int pushFailure(lua_State* L, const std::string& message) {
    lua_pushboolean(L, 0);
    lua_pushlstring(L, message.data(), message.size());
    return 2;
}

static int l_create(lua_State* L) {
    Config config;
    if (!lua_isnoneornil(L, 1) && !lua_istable(L, 1)) {
        return pushFailure(L, "xrbridge.create expects an optional config table");
    }
    if (lua_istable(L, 1)) {
        std::string error;
        if (!readConfigUInt(L, 1, "width", &config.width, &error) ||
            !readConfigUInt(L, 1, "height", &config.height, &error)) {
            g_bridge.setError(error);
            return pushFailure(L, error);
        }
    }

    g_bridge.destroy();
    try {
        if (!g_bridge.initialize(config)) {
            const std::string error = g_bridge.lastError();
            g_bridge.destroy();
            g_bridge.setError(error.empty() ? "xrbridge.create failed" : error);
            return pushFailure(L, g_bridge.lastError());
        }
    } catch (...) {
        g_bridge.destroy();
        g_bridge.setError("xrbridge.create failed because native initialization exhausted memory");
        return pushFailure(L, g_bridge.lastError());
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_isReady(lua_State* L) {
    lua_pushboolean(L, g_bridge.isReady());
    return 1;
}

static void setBoolField(lua_State* L, int tableIndex, const char* name, bool value) {
    if (tableIndex < 0 && tableIndex > LUA_REGISTRYINDEX) {
        tableIndex = lua_gettop(L) + tableIndex + 1;
    }
    lua_pushboolean(L, value ? 1 : 0);
    lua_setfield(L, tableIndex, name);
}

static void setNumberField(lua_State* L, int tableIndex, const char* name, lua_Number value) {
    if (tableIndex < 0 && tableIndex > LUA_REGISTRYINDEX) {
        tableIndex = lua_gettop(L) + tableIndex + 1;
    }
    lua_pushnumber(L, value);
    lua_setfield(L, tableIndex, name);
}

static void setStringField(lua_State* L, int tableIndex, const char* name,
                           const std::string& value) {
    if (tableIndex < 0 && tableIndex > LUA_REGISTRYINDEX) {
        tableIndex = lua_gettop(L) + tableIndex + 1;
    }
    lua_pushlstring(L, value.data(), value.size());
    lua_setfield(L, tableIndex, name);
}

static void setVectorField(lua_State* L, int tableIndex, const char* name,
                           float x, float y, float z) {
    if (tableIndex < 0 && tableIndex > LUA_REGISTRYINDEX) {
        tableIndex = lua_gettop(L) + tableIndex + 1;
    }
    lua_newtable(L);
    setNumberField(L, -1, "x", x);
    setNumberField(L, -1, "y", y);
    setNumberField(L, -1, "z", z);
    lua_setfield(L, tableIndex, name);
}

static void setQuaternionField(lua_State* L, int tableIndex, const char* name,
                               float x, float y, float z, float w) {
    if (tableIndex < 0 && tableIndex > LUA_REGISTRYINDEX) {
        tableIndex = lua_gettop(L) + tableIndex + 1;
    }
    lua_newtable(L);
    setNumberField(L, -1, "x", x);
    setNumberField(L, -1, "y", y);
    setNumberField(L, -1, "z", z);
    setNumberField(L, -1, "w", w);
    lua_setfield(L, tableIndex, name);
}

static void pushEyeRecord(lua_State* L, const char* eyeName, const XrView& view,
                          bool focused, XrViewStateFlags stateFlags, uint32_t width,
                          uint32_t height, bool poseUsable,
                          bool syntheticPose) {
    lua_newtable(L);
    lua_pushstring(L, eyeName);
    lua_setfield(L, -2, "eyeName");
    setBoolField(L, -1, "focused", focused);
    setVectorField(L, -1, "position", view.pose.position.x,
                   view.pose.position.y, view.pose.position.z);
    setQuaternionField(L, -1, "orientation", view.pose.orientation.x,
                       view.pose.orientation.y, view.pose.orientation.z,
                       view.pose.orientation.w);

    lua_newtable(L);
    setNumberField(L, -1, "left", view.fov.angleLeft);
    setNumberField(L, -1, "right", view.fov.angleRight);
    setNumberField(L, -1, "up", view.fov.angleUp);
    setNumberField(L, -1, "down", view.fov.angleDown);
    lua_setfield(L, -2, "fov");

    setNumberField(L, -1, "width", static_cast<lua_Number>(width));
    setNumberField(L, -1, "height", static_cast<lua_Number>(height));
    setBoolField(L, -1, "orientationValid",
                 (stateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0);
    setBoolField(L, -1, "positionValid",
                 (stateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0);
    setBoolField(L, -1, "poseUsable", poseUsable);
    setBoolField(L, -1, "syntheticPose", syntheticPose);
}

static int l_beginFrame(lua_State* L) {
    try {
        if (!g_bridge.beginFrame()) {
            g_bridge.abortFrame();
            lua_pushnil(L);
            lua_pushnil(L);
            lua_pushboolean(L, 0);
            return 3;
        }
        const auto& views = g_bridge.views();
        pushEyeRecord(L, "left", views[0], g_bridge.focused(), g_bridge.viewStateFlags(),
                      g_bridge.swapchainWidth(), g_bridge.swapchainHeight(),
                      g_bridge.poseUsable(), g_bridge.syntheticPose());
        pushEyeRecord(L, "right", views[1], g_bridge.focused(), g_bridge.viewStateFlags(),
                      g_bridge.swapchainWidth(), g_bridge.swapchainHeight(),
                      g_bridge.poseUsable(), g_bridge.syntheticPose());
        lua_pushboolean(L, g_bridge.effectiveShouldRender() ? 1 : 0);
        return 3;
    } catch (...) {
        g_bridge.abortFrame();
        g_bridge.setError("xrbridge.beginFrame failed because native initialization exhausted memory");
        lua_pushnil(L);
        lua_pushnil(L);
        lua_pushboolean(L, 0);
        return 3;
    }
}

static int l_abortFrame(lua_State* L) {
    (void)L;
    try {
        g_bridge.abortFrame();
        lua_pushboolean(L, 1);
        return 1;
    } catch (...) {
        g_bridge.setError("xrbridge.abortFrame failed because native initialization exhausted memory");
        return pushFailure(L, g_bridge.lastError());
    }
}

static int l_submit(lua_State* L) {
    if (!lua_isnumber(L, 1) || !lua_isnumber(L, 2) ||
        lua_type(L, 3) != LUA_TSTRING || lua_type(L, 4) != LUA_TSTRING) {
        g_bridge.abortFrame();
        return pushFailure(L, "xrbridge.submit expects width, height, left_rgba, right_rgba");
    }
    const lua_Integer width = lua_tointeger(L, 1);
    const lua_Integer height = lua_tointeger(L, 2);
    if (width <= 0 || height <= 0 || width > kMaxTextureDimension ||
        height > kMaxTextureDimension) {
        g_bridge.abortFrame();
        return pushFailure(L, "xrbridge.submit dimensions are outside 1..16384");
    }
    size_t leftLength = 0;
    size_t rightLength = 0;
    const char* left = lua_tolstring(L, 3, &leftLength);
    const char* right = lua_tolstring(L, 4, &rightLength);
    try {
        const bool ok = g_bridge.submit(static_cast<uint32_t>(width),
                                        static_cast<uint32_t>(height), left, leftLength,
                                        right, rightLength);
        if (!ok) {
            return pushFailure(L, g_bridge.lastError());
        }
        lua_pushboolean(L, 1);
        return 1;
    } catch (...) {
        g_bridge.abortFrame();
        g_bridge.setError("xrbridge.submit failed because native initialization exhausted memory");
        return pushFailure(L, g_bridge.lastError());
    }
}

#if defined(__linux__)
static bool flushLoveBatch(lua_State* L);

#if defined(__linux__)
static love::Type* selectionByteType(lua_State* L) {
    static love::Type* type=nullptr;
    if(type)return type;
    const int top=lua_gettop(L);
    lua_getglobal(L,"love");
    if(lua_istable(L,-1))lua_getfield(L,-1,"data");
    if(lua_istable(L,-1))lua_getfield(L,-1,"newByteData");
    if(lua_isfunction(L,-1)) {
        lua_pushinteger(L,1);
        if(lua_pcall(L,1,1,0)==0 && lua_type(L,-1)==LUA_TUSERDATA && lua_objlen(L,-1)>=sizeof(love::Proxy)) {
            auto* p=static_cast<love::Proxy*>(lua_touserdata(L,-1));
            if(p && p->object)type=p->type;
        }
    }
    lua_settop(L,top);return type;
}
static love::data::ByteData* selectionBytes(lua_State* L,int index) {
    auto* type=selectionByteType(L);
    if(!type)return nullptr;
    if(lua_type(L,index)!=LUA_TUSERDATA || lua_objlen(L,index)<sizeof(love::Proxy))return nullptr;
    auto* p=static_cast<love::Proxy*>(lua_touserdata(L,index));
    if(!p || !p->object || p->type!=type)return nullptr;
    return static_cast<love::data::ByteData*>(p->object);
}
static const char* kSelectionType="xrbridge.VisibilitySelection";
static int l_selectionGc(lua_State* L) {
    auto** p=static_cast<visibility::Selection**>(luaL_checkudata(L,1,kSelectionType));
    delete *p;*p=nullptr;return 0;
}
static int l_createVisibilitySelection(lua_State* L) {
    auto* bounds=selectionBytes(L,1);auto* ranges=selectionBytes(L,2);auto* indices=selectionBytes(L,3);
    if(!bounds||!ranges||!indices || bounds->getSize()%sizeof(visibility::Bounds)
       ||ranges->getSize()%sizeof(visibility::Range)||indices->getSize()%sizeof(uint32_t))
        return pushFailure(L,"visibility selection requires packed LOVE ByteData");
    auto** p=static_cast<visibility::Selection**>(lua_newuserdata(L,sizeof(visibility::Selection*)));
    *p=nullptr;
    if(luaL_newmetatable(L,kSelectionType)) {lua_pushcfunction(L,l_selectionGc);lua_setfield(L,-2,"__gc");}
    lua_setmetatable(L,-2);
    try {
        *p=new visibility::Selection(static_cast<const visibility::Bounds*>(bounds->getData()),bounds->getSize()/sizeof(visibility::Bounds),
            static_cast<const visibility::Range*>(ranges->getData()),ranges->getSize()/sizeof(visibility::Range),
            static_cast<const uint32_t*>(indices->getData()),indices->getSize()/sizeof(uint32_t));
        return 1;
    } catch(const std::exception& e) {return pushFailure(L,e.what());}
}
static int l_selectVisibility(lua_State* L) {
    auto** p=static_cast<visibility::Selection**>(luaL_checkudata(L,1,kSelectionType));
    auto* output=selectionBytes(L,2);auto* planes=selectionBytes(L,3);
    visibility::View view;view.shadow=lua_toboolean(L,4)!=0;
    const size_t planeBytes=(view.shadow?6:8)*4*sizeof(double);
    if(!*p||!output||!planes||planes->getSize()!=planeBytes||output->getSize()<(*p)->size()*sizeof(uint32_t)
       ||output==planes)return pushFailure(L,"invalid visibility output/planes");
    std::memcpy(view.planes,planes->getData(),planeBytes);
    for(size_t i=0;i<planeBytes/sizeof(double);++i)
        if(!std::isfinite((&view.planes[0][0])[i]))return pushFailure(L,"nonfinite visibility plane");
    double* values[]={&view.ox,&view.oy,&view.oz,&view.pull,&view.k,&view.cx,&view.cz};
    for(int i=0;i<7;++i) {
        if(lua_type(L,5+i)!=LUA_TNUMBER || !std::isfinite(lua_tonumber(L,5+i)))
            return pushFailure(L,"invalid visibility parameter");
        *values[i]=lua_tonumber(L,5+i);
    }
    if(view.pull<0)return pushFailure(L,"negative visibility pull");
    const auto result=(*p)->select(view,static_cast<uint32_t*>(output->getData()));
    lua_pushnumber(L,static_cast<lua_Number>(result.count));lua_pushboolean(L,result.changed);return 2;
}
#endif

static int l_restoreShadowCanvas(lua_State* L) {
    try {
        love::graphics::Canvas* canvases[3]{};
        uint32_t widths[3]{}, heights[3]{};
        bool readable[3]{};
        for (int i = 0; i < 3; ++i) {
            if (!g_bridge.canvasFromLua(L, i + 1, &canvases[i], &widths[i], &heights[i], &readable[i]))
                return pushFailure(L, g_bridge.lastError());
            if (!readable[i] || widths[i] != widths[0] || heights[i] != heights[0])
                return pushFailure(L, "shadow restore requires equally sized readable canvases");
        }
        if (!flushLoveBatch(L)) return pushFailure(L, "shadow restore could not flush LOVE batches");
        if (!g_bridge.restoreShadowCanvas(canvases[0], canvases[1], canvases[2], widths[0], heights[0]))
            return pushFailure(L, g_bridge.lastError());
        lua_pushboolean(L, 1);return 1;
    } catch (...) { return pushFailure(L, "shadow restore allocation failed"); }
}

static int l_submitCanvases(lua_State* L) {
    try {
        love::graphics::Canvas* left = nullptr;
        love::graphics::Canvas* right = nullptr;
        uint32_t leftWidth = 0;
        uint32_t leftHeight = 0;
        uint32_t rightWidth = 0;
        uint32_t rightHeight = 0;
        bool leftReadable = false;
        bool rightReadable = false;
        if (!g_bridge.canvasFromLua(L, 1, &left, &leftWidth, &leftHeight,
                                    &leftReadable) ||
            !g_bridge.canvasFromLua(L, 2, &right, &rightWidth, &rightHeight,
                                    &rightReadable)) {
            return pushFailure(L, g_bridge.lastError());
        }
        const bool timestampCopies = !g_bridge.telemetryEnabled()
            || flushLoveBatch(L);
        if (!timestampCopies) g_bridge.noteGpuTimestampError();
        if (!g_bridge.submitCanvases(left, leftWidth, leftHeight, leftReadable,
                                     right, rightWidth, rightHeight, rightReadable,
                                     timestampCopies)) {
            return pushFailure(L, g_bridge.lastError());
        }
        lua_pushboolean(L, 1);
        return 1;
    } catch (...) {
        g_bridge.abortFrame();
        g_bridge.setError("xrbridge.submitCanvases failed because native allocation exhausted memory");
        return pushFailure(L, g_bridge.lastError());
    }
}
#endif

#if defined(__linux__) && defined(XRBRIDGE_TESTING)
static int l_testCanvasCopy(lua_State* L) {
    try {
        love::graphics::Canvas* source = nullptr;
        love::graphics::Canvas* target = nullptr;
        uint32_t sourceWidth = 0;
        uint32_t sourceHeight = 0;
        uint32_t targetWidth = 0;
        uint32_t targetHeight = 0;
        bool sourceReadable = false;
        bool targetReadable = false;
        size_t dumpEyeIndex = 0;
        if (!lua_isnoneornil(L, 3)) {
            if (lua_type(L, 3) != LUA_TSTRING) {
                return pushFailure(L, "testCanvasCopy optional eye must be 'left' or 'right'");
            }
            const char* eye = lua_tostring(L, 3);
            if (std::strcmp(eye, "right") == 0) dumpEyeIndex = 1;
            else if (std::strcmp(eye, "left") != 0) {
                return pushFailure(L, "testCanvasCopy optional eye must be 'left' or 'right'");
            }
        }
        if (!g_bridge.canvasFromLua(L, 1, &source, &sourceWidth, &sourceHeight,
                                    &sourceReadable) ||
            !g_bridge.canvasFromLua(L, 2, &target, &targetWidth, &targetHeight,
                                    &targetReadable)) {
            return pushFailure(L, g_bridge.lastError());
        }
        if (!targetReadable || target->getMSAA() > 1) {
            return pushFailure(L, "testCanvasCopy target must be a readable non-MSAA Canvas");
        }
        if (!g_bridge.testCanvasCopy(source, sourceWidth, sourceHeight,
                                     sourceReadable, target, targetWidth,
                                     targetHeight, dumpEyeIndex)) {
            return pushFailure(L, g_bridge.lastError());
        }
        lua_pushboolean(L, 1);
        return 1;
    } catch (...) {
        g_bridge.setError("xrbridge.testCanvasCopy failed because native allocation exhausted memory");
        return pushFailure(L, g_bridge.lastError());
    }
}
#endif

static int l_submitQuad(lua_State* L) {
    if (!lua_isnumber(L, 1) || !lua_isnumber(L, 2) ||
        lua_type(L, 3) != LUA_TSTRING) {
        g_bridge.abortFrame();
        return pushFailure(L, "xrbridge.submitQuad expects width, height, rgba");
    }
    float scale = kUiQuadDefaultScale;
    if (!lua_isnoneornil(L, 4)) {
        if (!lua_isnumber(L, 4)) {
            g_bridge.abortFrame();
            return pushFailure(L, "xrbridge.submitQuad scale must be numeric");
        }
        scale = static_cast<float>(lua_tonumber(L, 4));
    }
    const lua_Integer width = lua_tointeger(L, 1);
    const lua_Integer height = lua_tointeger(L, 2);
    if (width <= 0 || height <= 0 || width > kMaxTextureDimension ||
        height > kMaxTextureDimension) {
        g_bridge.abortFrame();
        return pushFailure(L, "xrbridge.submitQuad dimensions are outside 1..16384");
    }
    size_t pixelLength = 0;
    const char* pixels = lua_tolstring(L, 3, &pixelLength);
    try {
        const bool ok = g_bridge.submitQuad(static_cast<uint32_t>(width),
                                            static_cast<uint32_t>(height),
                                            pixels, pixelLength, scale);
        if (!ok) {
            return pushFailure(L, g_bridge.lastError());
        }
        lua_pushboolean(L, 1);
        return 1;
    } catch (...) {
        g_bridge.abortFrame();
        g_bridge.setError("xrbridge.submitQuad failed because native initialization exhausted memory");
        return pushFailure(L, g_bridge.lastError());
    }
}

static int l_pushStatus(lua_State* L) {
    try {
        lua_newtable(L);
        const int table = lua_gettop(L);
        setBoolField(L, table, "available", g_bridge.isInitialized());
        setBoolField(L, table, "ready", g_bridge.isReady());
        setBoolField(L, table, "foveationAvailable", g_bridge.foveationAvailable());
        setBoolField(L, table, "eyeFoveationSupported", g_bridge.eyeFoveationSupported());
        setStringField(L, table, "foveationRequested", g_bridge.foveationRequested());
        setStringField(L, table, "foveationApplied", g_bridge.foveationApplied());
        setStringField(L, table, "foveationMessage", g_bridge.foveationMessage());
        setStringField(L, table, "foveationSourceShading", "unverified-runtime-injection");
        setBoolField(L, table, "foveationFrameAttempted", g_bridge.foveationFrameAttempted());
        setBoolField(L, table, "foveationFrameUpdated", g_bridge.foveationFrameUpdated());
        setBoolField(L, table, "foveationQueryAttempted", g_bridge.foveationQueryAttempted());
        setBoolField(L, table, "foveationEyeValid", g_bridge.foveationEyeValid());
        setNumberField(L, table, "foveationDisplayTime", g_bridge.foveationDisplayTime());
        setNumberField(L, table, "foveationUpdateEye1Result", g_bridge.foveationUpdateResult(0));
        setNumberField(L, table, "foveationUpdateEye2Result", g_bridge.foveationUpdateResult(1));
        setNumberField(L, table, "foveationQueryResult", g_bridge.foveationQueryResult());
        const auto& foveationEye = g_bridge.foveationEyeState();
        setNumberField(L, table, "foveationEyeFlags", foveationEye.flags);
        setNumberField(L, table, "foveationCenterEye1X", foveationEye.foveationCenter[0].x);
        setNumberField(L, table, "foveationCenterEye1Y", foveationEye.foveationCenter[0].y);
        setNumberField(L, table, "foveationCenterEye2X", foveationEye.foveationCenter[1].x);
        setNumberField(L, table, "foveationCenterEye2Y", foveationEye.foveationCenter[1].y);
        setBoolField(L, table, "focused", g_bridge.focused());
        setBoolField(L, table, "shouldRender", g_bridge.shouldRender());
#if defined(__linux__)
        setBoolField(L, table, "effectiveShouldRender",
                     g_bridge.effectiveShouldRender());
        setBoolField(L, table, "unattended", g_bridge.unattended());
        setBoolField(L, table, "forceRenderActive", g_bridge.forceRenderActive());
        setBoolField(L, table, "forcedRender", g_bridge.forcedRenderThisFrame());
        setBoolField(L, table, "forceRenderExpired", g_bridge.forceRenderExpired());
        setBoolField(L, table, "forceRenderBlocked", g_bridge.forceRenderBlocked());
        setBoolField(L, table, "runtimePositionValid", g_bridge.runtimePositionValid());
        setBoolField(L, table, "runtimeOrientationValid", g_bridge.runtimeOrientationValid());
        setBoolField(L, table, "syntheticPose", g_bridge.syntheticPose());
        setStringField(L, table, "poseSource", g_bridge.poseSource());
        setStringField(L, table, "ipdSource", g_bridge.ipdSource());
#endif
        setBoolField(L, table, "quitRequested", g_bridge.quitRequested());
        setBoolField(L, table, "instanceLossPending", g_bridge.instanceLossPending());
        setBoolField(L, table, "frameControllerProfileAvailable",
                     g_bridge.frameControllerProfileAvailable());
        setBoolField(L, table, "frameControllerBindingsSuggested",
                     g_bridge.frameControllerBindingsSuggested());
        lua_pushstring(L, sessionStateNameForLua(g_bridge.sessionState()));
        lua_setfield(L, table, "sessionState");
        lua_pushlstring(L, g_bridge.runtimeName().data(),
                        g_bridge.runtimeName().size());
        lua_setfield(L, table, "runtimeName");
        setStringField(L, table, "glVersion", g_bridge.glVersion());
        setStringField(L, table, "glVendor", g_bridge.glVendor());
        setStringField(L, table, "glRenderer", g_bridge.glRenderer());
        setStringField(L, table, "openGlMinVersion",
                       g_bridge.minimumOpenGlVersion());
        setStringField(L, table, "openGlMaxVersion",
                       g_bridge.maximumOpenGlVersion());
        lua_pushstring(L, g_bridge.swapchainFormatName());
        lua_setfield(L, table, "swapchainFormat");
        lua_pushstring(L, "primary_stereo");
        lua_setfield(L, table, "viewConfiguration");
        lua_newtable(L);
        setNumberField(L, -1, "leftWidth",
                       static_cast<lua_Number>(g_bridge.recommendedViewWidth(0)));
        setNumberField(L, -1, "leftHeight",
                       static_cast<lua_Number>(g_bridge.recommendedViewHeight(0)));
        setNumberField(L, -1, "rightWidth",
                       static_cast<lua_Number>(g_bridge.recommendedViewWidth(1)));
        setNumberField(L, -1, "rightHeight",
                       static_cast<lua_Number>(g_bridge.recommendedViewHeight(1)));
        lua_setfield(L, table, "recommendedViewDimensions");
        lua_newtable(L);
        const std::string leftProfile = g_bridge.interactionProfile(0);
        const std::string rightProfile = g_bridge.interactionProfile(1);
        lua_pushlstring(L, leftProfile.data(), leftProfile.size());
        lua_setfield(L, -2, "left");
        lua_pushlstring(L, rightProfile.data(), rightProfile.size());
        lua_setfield(L, -2, "right");
        lua_setfield(L, table, "interactionProfiles");
        setNumberField(L, table, "beginCount",
                       static_cast<lua_Number>(g_bridge.beginCount()));
        setNumberField(L, table, "submitCount",
                       static_cast<lua_Number>(g_bridge.submitCount()));
        setNumberField(L, table, "swapchainDumpCount",
                       static_cast<lua_Number>(g_bridge.swapchainDumpCount()));
        setNumberField(L, table, "swapchainDumpAfterSubmits",
                       static_cast<lua_Number>(g_bridge.swapchainDumpAfterSubmits()));
        setStringField(L, table, "swapchainDumpMessage",
                       g_bridge.swapchainDumpMessage());
        setNumberField(L, table, "swapchainWidth",
                       static_cast<lua_Number>(g_bridge.swapchainWidth()));
        setNumberField(L, table, "swapchainHeight",
                       static_cast<lua_Number>(g_bridge.swapchainHeight()));
        setNumberField(L, table, "lastSubmitWidth",
                       static_cast<lua_Number>(g_bridge.lastSubmitWidth()));
        setNumberField(L, table, "lastSubmitHeight",
                       static_cast<lua_Number>(g_bridge.lastSubmitHeight()));
        setNumberField(L, table, "predictedDisplayTime",
                       static_cast<lua_Number>(g_bridge.predictedDisplayTime()));
        setNumberField(L, table, "predictedDisplayPeriod",
                       static_cast<lua_Number>(g_bridge.predictedDisplayPeriod()));
#if defined(__linux__)
        if (g_bridge.telemetryEnabled()) {
            setNumberField(L, table, "xrWaitWallNs",
                           static_cast<lua_Number>(g_bridge.lastWaitWallNs()));
            setNumberField(L, table, "xrWaitMainCpuNs",
                           static_cast<lua_Number>(g_bridge.lastWaitCpuNs()));
        }
#endif
        lua_newtable(L);
        setBoolField(L, -1, "available", g_bridge.actionsSupported());
        lua_newtable(L);
        setNumberField(L, -1, "x", g_bridge.moveX());
        setNumberField(L, -1, "y", g_bridge.moveY());
        lua_setfield(L, -2, "move");
        setNumberField(L, -1, "scrollY", g_bridge.scrollY());
        lua_newtable(L);
        for (size_t i = 0; i < 2; ++i) {
            const auto& aim = g_bridge.aim(i);
            lua_newtable(L);
            setBoolField(L, -1, "valid", aim.locationFlags != 0);
            setNumberField(L, -1, "trigger", g_bridge.trigger(i));
            lua_newtable(L);
            setNumberField(L, -1, "x", aim.pose.position.x);
            setNumberField(L, -1, "y", aim.pose.position.y);
            setNumberField(L, -1, "z", aim.pose.position.z);
            lua_setfield(L, -2, "position");
            lua_newtable(L);
            setNumberField(L, -1, "x", aim.pose.orientation.x);
            setNumberField(L, -1, "y", aim.pose.orientation.y);
            setNumberField(L, -1, "z", aim.pose.orientation.z);
            setNumberField(L, -1, "w", aim.pose.orientation.w);
            lua_setfield(L, -2, "orientation");
            lua_setfield(L, -2, i == 0 ? "left" : "right");
        }
        lua_setfield(L, -2, "hands");
        setBoolField(L, -1, "a", g_bridge.actionA());
        setBoolField(L, -1, "b", g_bridge.actionB());
        setBoolField(L, -1, "start", g_bridge.actionStart());
        setBoolField(L, -1, "select", g_bridge.actionSelect());
        setBoolField(L, -1, "recenter", g_bridge.actionRecenter());
        lua_setfield(L, table, "actions");
        return 1;
    } catch (...) {
        g_bridge.setError("xrbridge status query failed because native initialization exhausted memory");
        lua_pushnil(L);
        return 1;
    }
}

static int l_pollActions(lua_State* L) {
    try {
        if (g_bridge.isInitialized()) {
            (void)g_bridge.pumpEvents();
            g_bridge.updateActions();
        }
        return l_pushStatus(L);
    } catch (...) {
        g_bridge.setError("xrbridge.pollActions failed because native initialization exhausted memory");
        lua_pushnil(L);
        return 1;
    }
}

static int l_status(lua_State* L) {
    try {
        if (g_bridge.isInitialized()) (void)g_bridge.pumpEvents();
        return l_pushStatus(L);
    } catch (...) {
        g_bridge.setError("xrbridge.status failed because native initialization exhausted memory");
        lua_pushnil(L);
        return 1;
    }
}

#if defined(__linux__)
static bool flushLoveBatch(lua_State* L) {
    static bool warningReported = false;
    const int originalTop = lua_gettop(L);
    const char* failure = nullptr;
    std::string detail;

    lua_getglobal(L, "love");
    if (!lua_istable(L, -1)) {
        failure = "love table is unavailable";
    } else {
        lua_getfield(L, -1, "graphics");
        if (!lua_istable(L, -1)) {
            failure = "love.graphics is unavailable";
        } else {
            lua_getfield(L, -1, "flushBatch");
            if (!lua_isfunction(L, -1)) {
                failure = "love.graphics.flushBatch is unavailable";
            } else if (lua_pcall(L, 0, 0, 0) != 0) {
                const char* message = lua_tostring(L, -1);
                detail = message ? message : "non-string Lua error";
                failure = "love.graphics.flushBatch failed";
            }
        }
    }

    lua_settop(L, originalTop);
    if (!failure) return true;
    if (!warningReported) {
        std::fprintf(stderr, "[xrbridge] GPU telemetry scope skipped: %s%s%s\n",
            failure, detail.empty() ? "" : ": ", detail.c_str());
        warningReported = true;
    }
    return false;
}

static int l_telemetryClock(lua_State* L) {
    if (!g_bridge.telemetryEnabled()) {
        lua_pushnil(L);
        return 1;
    }
    lua_newtable(L);
    setNumberField(L, -1, "wallNs",
                   static_cast<lua_Number>(clockNanoseconds(CLOCK_MONOTONIC)));
    setNumberField(L, -1, "processCpuNs",
                   static_cast<lua_Number>(clockNanoseconds(CLOCK_PROCESS_CPUTIME_ID)));
    setNumberField(L, -1, "mainCpuNs",
                   static_cast<lua_Number>(clockNanoseconds(CLOCK_THREAD_CPUTIME_ID)));
    return 1;
}

static int l_telemetryContext(lua_State* L) {
    if (g_bridge.telemetryEnabled()) {
        uint64_t frame = 0;
        if (lua_isnumber(L, 1) && lua_tonumber(L, 1) >= 0)
            frame = static_cast<uint64_t>(lua_tonumber(L, 1));
        const char* scene = lua_type(L, 2) == LUA_TSTRING
            ? lua_tostring(L, 2) : "unknown";
        g_bridge.setTelemetryContext(frame, scene);
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_gpuScopeBegin(lua_State* L) {
    if (!g_bridge.telemetryEnabled()) {
        lua_pushboolean(L, 0);
        return 1;
    }
    const char* name = lua_type(L, 1) == LUA_TSTRING
        ? lua_tostring(L, 1) : "unnamed";
    uint64_t frame = 0;
    if (lua_isnumber(L, 2) && lua_tonumber(L, 2) >= 0)
        frame = static_cast<uint64_t>(lua_tonumber(L, 2));
    const char* scene = lua_type(L, 3) == LUA_TSTRING
        ? lua_tostring(L, 3) : "unknown";
    if (!flushLoveBatch(L)) {
        g_bridge.noteGpuTimestampError();
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, g_bridge.beginGpuTimestamp(name, frame, scene));
    return 1;
}

static int l_gpuScopeEnd(lua_State* L) {
    if (!flushLoveBatch(L)) g_bridge.cancelGpuTimestamp();
    else g_bridge.endGpuTimestamp();
    lua_pushboolean(L, 1);
    return 1;
}

static int l_telemetrySample(lua_State* L) {
    if (!g_bridge.telemetryEnabled()) {
        lua_pushnil(L);
        return 1;
    }
    const TelemetrySnapshot sample = g_bridge.sampleTelemetry();
    lua_newtable(L);
    const int table = lua_gettop(L);
    setNumberField(L, table, "intervalWallNs",
                   static_cast<lua_Number>(sample.wallNs));
    setNumberField(L, table, "processCpuNs",
                   static_cast<lua_Number>(sample.processCpuNs));
    setNumberField(L, table, "mainCpuNs",
                   static_cast<lua_Number>(sample.mainCpuNs));
    setStringField(L, table, "gpuBusyStatus", sample.gpuBusyStatus);
    setBoolField(L, table, "gpuBusyAvailable", sample.gpuBusyAvailable);
    if (sample.gpuBusyAvailable && sample.wallNs > 0) {
        setNumberField(L, table, "gpuBusyNs",
                       static_cast<lua_Number>(sample.gpuBusyNs));
        setNumberField(L, table, "gpuBusyPct",
                       static_cast<lua_Number>(sample.gpuBusyNs) * 100.0 /
                           static_cast<lua_Number>(sample.wallNs));
    }
    if (sample.gpuCyclesAvailable)
        setNumberField(L, table, "gpuCycles",
                       static_cast<lua_Number>(sample.gpuCycles));
    if (sample.gpuMaxFreqAvailable)
        setNumberField(L, table, "gpuMaxFreqHz",
                       static_cast<lua_Number>(sample.gpuMaxFreqHz));
    if (sample.gpuCurrentFreqAvailable)
        setNumberField(L, table, "gpuCurrentFreqHz",
                       static_cast<lua_Number>(sample.gpuCurrentFreqHz));
    setNumberField(L, table, "gpuClientCount",
                   static_cast<lua_Number>(sample.gpuClientCount));
    setNumberField(L, table, "gpuAddedClients",
                   static_cast<lua_Number>(sample.gpuAddedClients));
    setNumberField(L, table, "gpuRemovedClients",
                   static_cast<lua_Number>(sample.gpuRemovedClients));
    setNumberField(L, table, "gpuCounterRegressions",
                   static_cast<lua_Number>(sample.gpuCounterRegressions));

    lua_newtable(L);
    for (size_t i = 0; i < sample.gpuClients.size(); ++i) {
        const DrmGpuClientSample& client = sample.gpuClients[i];
        lua_newtable(L);
        setStringField(L, -1, "driver", client.driver);
        setStringField(L, -1, "identity", client.key);
        setNumberField(L, -1, "clientId",
                       static_cast<lua_Number>(client.clientId));
        setBoolField(L, -1, "comparable", client.comparable);
        if (client.comparable && sample.wallNs > 0) {
            setNumberField(L, -1, "busyNs",
                           static_cast<lua_Number>(client.busyNs));
            setNumberField(L, -1, "busyPct",
                           static_cast<lua_Number>(client.busyNs) * 100.0 /
                               static_cast<lua_Number>(sample.wallNs));
        }
        if (client.cyclesAvailable)
            setNumberField(L, -1, "cycles",
                           static_cast<lua_Number>(client.cycles));
        if (client.maxFreqHz)
            setNumberField(L, -1, "maxFreqHz",
                           static_cast<lua_Number>(client.maxFreqHz));
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, table, "gpuClients");

    setNumberField(L, table, "cpuStagesDropped", static_cast<lua_Number>(sample.cpuStagesDropped));
    lua_newtable(L);
    for (size_t i = 0; i < sample.cpuStages.size(); ++i) {
        const CpuStageSample& stage = sample.cpuStages[i];
        lua_newtable(L);
        setStringField(L, -1, "name", stage.name);
        setStringField(L, -1, "scene", stage.scene);
        setNumberField(L, -1, "frame", static_cast<lua_Number>(stage.frame));
        setNumberField(L, -1, "wallNs", static_cast<lua_Number>(stage.wallNs));
        setNumberField(L, -1, "processCpuNs", static_cast<lua_Number>(stage.processCpuNs));
        setNumberField(L, -1, "mainCpuNs", static_cast<lua_Number>(stage.mainCpuNs));
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, table, "cpuStages");

    setStringField(L, table, "gpuTimestampStatus", g_bridge.gpuTimestampStatus());
    setNumberField(L, table, "gpuTimestampPending",
                   static_cast<lua_Number>(g_bridge.gpuTimestampPending()));
    setNumberField(L, table, "gpuTimestampDropped",
                   static_cast<lua_Number>(g_bridge.gpuTimestampDropped()));
    setNumberField(L, table, "gpuTimestampErrors",
                   static_cast<lua_Number>(g_bridge.gpuTimestampErrors()));
    setNumberField(L, table, "gpuTimestampResultsDropped",
                   static_cast<lua_Number>(sample.gpuTimestampResultsDropped));
    lua_newtable(L);
    for (size_t i = 0; i < sample.gpuTimestamps.size(); ++i) {
        const vrtelemetry::TimestampResult& result = sample.gpuTimestamps[i];
        lua_newtable(L);
        setStringField(L, -1, "name", result.name);
        setStringField(L, -1, "scene", result.scene);
        setNumberField(L, -1, "frame", static_cast<lua_Number>(result.frame));
        setNumberField(L, -1, "durationNs",
                       static_cast<lua_Number>(result.durationNs));
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, table, "gpuTimestamps");
    return 1;
}

static int l_telemetryPollGpu(lua_State* L) {
    (void)L;
    g_bridge.pollTelemetryGpu();
    return 0;
}

static int l_telemetryResetWindow(lua_State* L) {
    (void)L;
    g_bridge.resetTelemetryWindow();
    return 0;
}
#endif

static int l_lastError(lua_State* L) {
    const std::string& error = g_bridge.lastError();
    if (error.empty()) {
        lua_pushnil(L);
    } else {
        lua_pushlstring(L, error.data(), error.size());
    }
    return 1;
}

static int l_destroy(lua_State* L) {
    (void)L;
    g_bridge.destroy();
    return 0;
}

} // namespace

#if defined(_WIN32)
extern "C" __declspec(dllexport) int luaopen_xrbridge(lua_State* L) {
#else
extern "C" __attribute__((visibility("default"))) int luaopen_xrbridge(lua_State* L) {
#endif
    static const luaL_Reg functions[] = {
        {"create", l_create},
        {"isReady", l_isReady},
        {"beginFrame", l_beginFrame},
        {"abortFrame", l_abortFrame},
        {"submit", l_submit},
        {"submitQuad", l_submitQuad},
#if defined(__linux__)
        {"submitCanvases", l_submitCanvases},
        {"restoreShadowCanvas", l_restoreShadowCanvas},
#if defined(__linux__)
        {"createVisibilitySelection", l_createVisibilitySelection},
        {"releaseVisibilitySelection", l_selectionGc},
        {"selectVisibility", l_selectVisibility},
#endif
        {"telemetryClock", l_telemetryClock},
        {"telemetryContext", l_telemetryContext},
        {"telemetrySample", l_telemetrySample},
        {"telemetryPollGpu", l_telemetryPollGpu},
        {"telemetryResetWindow", l_telemetryResetWindow},
        {"gpuScopeBegin", l_gpuScopeBegin},
        {"gpuScopeEnd", l_gpuScopeEnd},
#endif
#if defined(__linux__) && defined(XRBRIDGE_TESTING)
        {"testCanvasCopy", l_testCanvasCopy},
#endif
        {"pollActions", l_pollActions},
        {"status", l_status},
        {"lastError", l_lastError},
        {"destroy", l_destroy},
        {nullptr, nullptr},
    };

    lua_newtable(L);
    for (const luaL_Reg* function = functions; function->name; ++function) {
        lua_pushcfunction(L, function->func);
        lua_setfield(L, -2, function->name);
    }
    return 1;
}
