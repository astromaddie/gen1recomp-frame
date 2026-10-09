// Runs the actual bridge negotiation/resource paths against a strict XR stub.
// This verifies protocol and fallback, not Valve's GPU injection effectiveness.
#define XRBRIDGE_TESTING 1
#include "../../vrbridge/xrbridge.cpp"
#include <cassert>
#include <set>

namespace {
struct FoveationTest {
    static inline int eyeCreates, fixedCreates, profilesDestroyed, updates, creates;
    static inline int rejectUpdate, rejectCreate;
    static inline bool rejectEye, rejectFixed;
    static inline uintptr_t serial;
    static inline std::set<XrSwapchain> live;
    static XrResult XRAPI_PTR profile(XrSession, const XrFoveationProfileCreateInfoFB* info,
                                      XrFoveationProfileFB* out) {
        assert(info->type == XR_TYPE_FOVEATION_PROFILE_CREATE_INFO_FB);
        auto* level = static_cast<const XrFoveationLevelProfileCreateInfoFB*>(info->next);
        assert(level && level->type == XR_TYPE_FOVEATION_LEVEL_PROFILE_CREATE_INFO_FB);
        assert(level->level == XR_FOVEATION_LEVEL_MEDIUM_FB && level->verticalOffset == 0);
        assert(level->dynamic == XR_FOVEATION_DYNAMIC_DISABLED_FB);
        if (level->next) {
            auto* eye = static_cast<const XrFoveationEyeTrackedProfileCreateInfoMETA*>(level->next);
            assert(eye->type == XR_TYPE_FOVEATION_EYE_TRACKED_PROFILE_CREATE_INFO_META);
            assert(eye->flags == 0 && !eye->next);
            ++eyeCreates;
            if (rejectEye) return XR_ERROR_FEATURE_UNSUPPORTED;
        } else {
            ++fixedCreates;
            if (rejectFixed) return XR_ERROR_FEATURE_UNSUPPORTED;
        }
        *out = reinterpret_cast<XrFoveationProfileFB>(uintptr_t(99));
        return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR destroyProfile(XrFoveationProfileFB p) {
        assert(p); ++profilesDestroyed; return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR formats(XrSession, uint32_t capacity, uint32_t* count, int64_t* out) {
        *count = 1; if (capacity) *out = kGlSrgb8Alpha8; return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR create(XrSession, const XrSwapchainCreateInfo* info, XrSwapchain* out) {
        ++creates;
        assert(info->width == 1728 && info->height == 1728);
        if (info->next) {
            auto* f = static_cast<const XrSwapchainCreateInfoFoveationFB*>(info->next);
            assert(f->type == XR_TYPE_SWAPCHAIN_CREATE_INFO_FOVEATION_FB);
            assert(f->flags == 0 && !f->next); // No illegal Vulkan/QCOM flags.
            if (creates == rejectCreate) return XR_ERROR_FEATURE_UNSUPPORTED;
        }
        *out = reinterpret_cast<XrSwapchain>(++serial); live.insert(*out); return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR destroySwapchain(XrSwapchain s) {
        assert(live.erase(s) == 1); return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR images(XrSwapchain, uint32_t capacity, uint32_t* count,
                                     XrSwapchainImageBaseHeader* out) {
        *count = 1;
        if (capacity) {
            assert(out->type == XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR);
            reinterpret_cast<XrSwapchainImageOpenGLKHR*>(out)->image = 1;
        }
        return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR update(XrSwapchain s, const XrSwapchainStateBaseHeaderFB* base) {
        assert(live.count(s) && base->type == XR_TYPE_SWAPCHAIN_STATE_FOVEATION_FB);
        auto* state = reinterpret_cast<const XrSwapchainStateFoveationFB*>(base);
        assert(state->flags == 0 && state->profile && !state->next);
        ++updates;
        return updates == rejectUpdate ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
    }
    static XrResult XRAPI_PTR missingFunction(XrInstance, const char*, PFN_xrVoidFunction* out) {
        *out = nullptr; return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    static void run() {
        for (int scenario = 0; scenario < 9; ++scenario) {
            eyeCreates = fixedCreates = profilesDestroyed = updates = creates = 0;
            rejectEye = scenario == 1 || scenario == 2;
            rejectFixed = scenario == 2;
            rejectUpdate = scenario == 3 ? 2 : 0;
            rejectCreate = scenario == 4 ? 2 : 0;
            Bridge b;
            b.m_foveationAvailable = scenario != 5;
            b.m_eyeFoveationAvailable = true;
            setenv("POKEPORT_XR_FOVEATION", scenario == 6 ? "off" : scenario == 7 ? "fixed" : "eye", 1);
            std::vector<const char*> extensions;
            b.configureFoveationExtensions(extensions);
            assert(extensions.size() == (scenario == 5 || scenario == 6 ? 0 : scenario == 7 ? 3 : 4));
            b.m_eyeFoveationSupported = scenario != 8;
            b.m_createFoveationProfile = profile;
            b.m_destroyFoveationProfile = destroyProfile;
            b.m_updateSwapchain = update;
            b.m_enumerateSwapchainFormats = formats;
            b.m_createSwapchain = create;
            b.m_destroySwapchain = destroySwapchain;
            b.m_enumerateSwapchainImages = images;
            b.m_viewConfigurationViews.resize(2);
            for (auto& view : b.m_viewConfigurationViews) {
                view.recommendedImageRectWidth = view.recommendedImageRectHeight = 1728;
                view.maxImageRectWidth = view.maxImageRectHeight = 4096;
            }
            assert(b.createSwapchains());
            assert(live.size() == 2);
            assert(b.m_foveationProfile == XR_NULL_HANDLE);
            const bool applied = scenario == 0 || scenario == 1 || scenario == 7 || scenario == 8;
            assert(b.foveationApplied() == (applied ? scenario == 0 ? "eye-medium" : "fixed-medium" : "none"));
            assert(profilesDestroyed == (scenario == 2 || scenario == 5 || scenario == 6 ? 0 : 1));
            assert(updates == (scenario == 2 || scenario == 5 || scenario == 6 ? 0 : scenario == 4 ? 1 : 2));
            assert(creates == (scenario == 3 || scenario == 4 ? 4 : 2));
            assert(b.lastError().empty()); // Optional failure never poisons normal XR.
            if (scenario == 3 || scenario == 4) assert(b.foveationMessage().find("full-rate fallback") != std::string::npos);
            b.destroy();
            assert(live.empty() && b.foveationApplied() == "none");
        }
        {
            Bridge b;
            b.m_foveationAvailable = true;
            setenv("POKEPORT_XR_FOVEATION", "eye", 1);
            std::vector<const char*> extensions;
            b.configureFoveationExtensions(extensions);
            b.m_getInstanceProcAddr = missingFunction;
            b.loadFoveationFunctions();
            assert(!b.m_foveationEnabled && !b.createFoveationProfile());
            assert(b.lastError().empty() && !b.foveationMessage().empty());
            setenv("POKEPORT_XR_FOVEATION", "invalid", 1);
            extensions.clear();
            b.configureFoveationExtensions(extensions);
            assert(extensions.empty() && b.foveationRequested() == "off");
        }
        {
            Bridge b;
            int calls = 0;
            assert(b.measureXrCall("disabled", [&] { ++calls; return XR_TIMEOUT_EXPIRED; }) == XR_TIMEOUT_EXPIRED);
            assert(calls == 1 && b.m_completedCpuStages.empty());
            b.m_telemetryEnabled = true;
            b.setTelemetryContext(42,"PEWTER_CITY/above");
            assert(b.measureXrCall("swapchain_wait_eye1", [&] { ++calls; return XR_SUCCESS; }) == XR_SUCCESS);
            assert(calls == 2 && b.m_completedCpuStages.size() == 1);
            auto stage = b.m_completedCpuStages.front();
            assert(stage.frame == 42 && stage.scene == "PEWTER_CITY/above" && stage.name == "swapchain_wait_eye1");
            for (int i=0; i<2050; ++i) b.measureXrCall("bounded", [] { return XR_SUCCESS; });
            assert(b.m_completedCpuStages.size() == 2048 && b.m_cpuStagesDropped == 3);
            auto sample = b.sampleTelemetry();
            assert(sample.cpuStages.size() == 2048 && sample.cpuStagesDropped == 3 && b.m_completedCpuStages.empty() && b.m_cpuStagesDropped == 0);
            b.resetTelemetryWindow();
            assert(b.m_completedCpuStages.empty() && b.m_cpuStagesDropped == 0);
            puts("NATIVE_CPU_STAGE_PASS: exact callback/result, scene/frame clocks, bounded collection, sample transfer, reset");
        }
        puts("FOVEATION_PROTOCOL_PASS: real bridge profile chains, native dimensions, eye/fixed/off/unsupported, partial second-eye failures, symmetric recreation, cleanup");
    }
};
}
int main() { FoveationTest::run(); }
