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
    static inline bool profileLive, rejectQuery, validEye = true, render = true;
    static inline int queries;
    static inline XrTime time = 1000000000;
    static inline std::vector<std::string> order;
    static XrResult XRAPI_PTR waitFrame(XrSession, const XrFrameWaitInfo*, XrFrameState* state) {
        order.push_back("wait");state->shouldRender=render;state->predictedDisplayTime=++time;
        state->predictedDisplayPeriod=13888889;return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR beginFrame(XrSession, const XrFrameBeginInfo*) {order.push_back("begin");return XR_SUCCESS;}
    static XrResult XRAPI_PTR locate(XrSession, const XrViewLocateInfo* info, XrViewState* state,
                                      uint32_t capacity,uint32_t* count,XrView* views) {
        order.push_back("locate");assert(info->displayTime==time);assert(capacity==2);*count=2;
        state->viewStateFlags=XR_VIEW_STATE_POSITION_VALID_BIT|XR_VIEW_STATE_ORIENTATION_VALID_BIT;
        for (int i=0;i<2;++i) {views[i].pose.orientation.w=1;views[i].pose.position.x=i==0?-0.032f:0.032f;}
        return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR endFrame(XrSession,const XrFrameEndInfo*) {order.push_back("end");return XR_SUCCESS;}
    static XrResult XRAPI_PTR query(XrSession,XrFoveationEyeTrackedStateMETA* state) {
        assert(profileLive && state->type==XR_TYPE_FOVEATION_EYE_TRACKED_STATE_META && !state->next);
        order.push_back("query");++queries;
        state->flags=validEye?XR_FOVEATION_EYE_TRACKED_STATE_VALID_BIT_META:0;
        state->foveationCenter[0]={-0.2f,0.1f};state->foveationCenter[1]={0.3f,-0.1f};
        return rejectQuery?XR_ERROR_RUNTIME_FAILURE:XR_SUCCESS;
    }
    static inline std::set<XrSwapchain> live, enumerated;
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
        assert(!profileLive);profileLive=true;
        *out = reinterpret_cast<XrFoveationProfileFB>(uintptr_t(99));
        return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR destroyProfile(XrFoveationProfileFB p) {
        assert(p && profileLive);profileLive=false; ++profilesDestroyed; return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR formats(XrSession, uint32_t capacity, uint32_t* count, int64_t* out) {
        *count = 1; if (capacity) *out = kGlSrgb8Alpha8; return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR create(XrSession, const XrSwapchainCreateInfo* info, XrSwapchain* out) {
        ++creates;
        order.push_back("create");
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
        assert(live.erase(s) == 1); enumerated.erase(s); return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR images(XrSwapchain s, uint32_t capacity, uint32_t* count,
                                     XrSwapchainImageBaseHeader* out) {
        assert(live.count(s));
        order.push_back(capacity ? "images" : "image-count");
        *count = 1;
        if (capacity) {
            assert(out->type == XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR);
            reinterpret_cast<XrSwapchainImageOpenGLKHR*>(out)->image = 1;
            enumerated.insert(s);
        }
        return XR_SUCCESS;
    }
    static XrResult XRAPI_PTR update(XrSwapchain s, const XrSwapchainStateBaseHeaderFB* base) {
        assert(live.count(s) && base->type == XR_TYPE_SWAPCHAIN_STATE_FOVEATION_FB);
        assert(live.size()==2 && enumerated==live); // Both full GL enumerations precede either update.
        auto* state = reinterpret_cast<const XrSwapchainStateFoveationFB*>(base);
        assert(state->flags == 0 && state->profile && !state->next && profileLive);
        order.push_back("update");
        ++updates;
        return updates == rejectUpdate ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
    }
    static XrResult XRAPI_PTR missingFunction(XrInstance, const char*, PFN_xrVoidFunction* out) {
        *out = nullptr; return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    static XrResult XRAPI_PTR withoutEyeQuery(XrInstance,const char* name,PFN_xrVoidFunction* out) {
        if (!std::strcmp(name,"xrCreateFoveationProfileFB")) *out=reinterpret_cast<PFN_xrVoidFunction>(profile);
        else if (!std::strcmp(name,"xrDestroyFoveationProfileFB")) *out=reinterpret_cast<PFN_xrVoidFunction>(destroyProfile);
        else if (!std::strcmp(name,"xrUpdateSwapchainFB")) *out=reinterpret_cast<PFN_xrVoidFunction>(update);
        else {*out=nullptr;return XR_ERROR_FUNCTION_UNSUPPORTED;}
        return XR_SUCCESS;
    }
    static void run() {
        for (int scenario = 0; scenario < 10; ++scenario) {
            order.clear();assert(live.empty() && enumerated.empty());
            eyeCreates = fixedCreates = profilesDestroyed = updates = creates = 0;
            rejectEye = scenario == 1 || scenario == 2;
            rejectFixed = scenario == 2;
            rejectUpdate = scenario == 3 ? 2 : scenario == 9 ? 1 : 0;
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
            b.m_getFoveationEyeTrackedState = query;
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
            assert((b.m_foveationProfile != XR_NULL_HANDLE) == (scenario == 0));
            const bool applied = scenario == 0 || scenario == 1 || scenario == 7 || scenario == 8;
            assert(b.foveationApplied() == (applied ? scenario == 0 ? "eye-medium" : "fixed-medium" : "none"));
            assert(profilesDestroyed == (scenario == 0 || scenario == 2 || scenario == 5 || scenario == 6 ? 0 : 1));
            assert(updates == (scenario == 2 || scenario == 4 || scenario == 5 || scenario == 6 ? 0 : scenario == 9 ? 1 : 2));
            assert(creates == (scenario == 3 || scenario == 4 || scenario == 9 ? 4 : 2));
            if (applied) assert((order==std::vector<std::string>{
                "create","image-count","images","create","image-count","images","update","update"}));
            assert(b.lastError().empty()); // Optional failure never poisons normal XR.
            if (scenario == 3 || scenario == 4 || scenario == 9) assert(b.foveationMessage().find("full-rate fallback") != std::string::npos);
            if (scenario == 0) {
                b.m_initialized=true;b.m_session=reinterpret_cast<XrSession>(uintptr_t(1));b.m_sessionRunning=true;
                b.m_sessionState=XR_SESSION_STATE_FOCUSED;
                b.m_waitFrame=waitFrame;b.m_beginFrame=beginFrame;b.m_locateViews=locate;b.m_endFrame=endFrame;
                for (int frame=0;frame<2;++frame) {
                    order.clear();assert(b.beginFrame());
                    assert((order==std::vector<std::string>{"wait","begin","locate","update","update","query"}));
                    assert(b.foveationFrameUpdated() && b.foveationEyeValid() && b.foveationDisplayTime()==time);
                    assert(b.foveationEyeState().foveationCenter[0].x==-0.2f);
                    order.push_back("source-render");b.abortFrame();
                }
                int previousQueries=queries;
                rejectUpdate=updates+2;assert(b.beginFrame());
                assert(!b.foveationFrameUpdated() && !b.foveationEyeValid() && !b.foveationQueryAttempted());
                assert(queries==previousQueries && b.foveationUpdateResult(1)==XR_ERROR_RUNTIME_FAILURE);
                b.abortFrame();rejectUpdate=0;
                rejectQuery=true;assert(b.beginFrame());
                assert(b.foveationFrameUpdated() && b.foveationQueryAttempted() && !b.foveationEyeValid());
                assert(b.foveationEyeState().foveationCenter[0].x==0 && b.foveationQueryResult()==XR_ERROR_RUNTIME_FAILURE);
                b.abortFrame();rejectQuery=false;
                validEye=false;assert(b.beginFrame());assert(!b.foveationEyeValid());b.abortFrame();validEye=true;
                b.m_sessionState=XR_SESSION_STATE_VISIBLE;
                int previousUpdates=updates;assert(b.beginFrame());assert(!b.foveationFrameAttempted() && updates==previousUpdates);b.abortFrame();
                b.m_sessionState=XR_SESSION_STATE_FOCUSED;render=false;
                assert(b.beginFrame());assert(!b.foveationFrameAttempted());b.abortFrame();render=true;
                // Explicit bounded off-head authorization exercises refresh but
                // an invalid runtime gaze stays invalid and centers stay blank.
                b.m_sessionState=XR_SESSION_STATE_VISIBLE;b.m_frameState.shouldRender=false;b.m_frameActive=true;
                b.m_forceRenderWindow.arm(true,true,clockNanoseconds(CLOCK_MONOTONIC),10);
                b.m_forceRenderThisFrame=true;validEye=false;b.refreshEyeFoveation();
                assert(b.foveationFrameUpdated() && !b.foveationEyeValid() && !b.focused() && !b.shouldRender());
                b.abortFrame();validEye=true;
                b.releaseSwapchains();assert(!profileLive && !b.foveationEyeValid());
                assert(profilesDestroyed==1);
            } else {
                b.m_frameActive=true;b.m_frameState.shouldRender=true;b.m_sessionState=XR_SESSION_STATE_FOCUSED;
                int previousUpdates=updates,previousQueries=queries;b.refreshEyeFoveation();
                assert(!b.foveationFrameAttempted() && updates==previousUpdates && queries==previousQueries);
            }
            b.destroy();
            assert(live.empty() && enumerated.empty() && b.foveationApplied() == "none" && !b.foveationEyeValid());
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
            Bridge b;b.m_foveationAvailable=b.m_eyeFoveationAvailable=true;
            setenv("POKEPORT_XR_FOVEATION","eye",1);std::vector<const char*> extensions;
            b.configureFoveationExtensions(extensions);b.m_getInstanceProcAddr=withoutEyeQuery;
            b.loadFoveationFunctions();assert(b.m_foveationEnabled && !b.m_eyeFoveationEnabled);
            b.m_eyeFoveationSupported=true;assert(b.createFoveationProfile());
            assert(b.m_foveationProfileMode=="fixed-medium");b.releaseFoveationProfile();
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
        puts("FOVEATION_PROTOCOL_PASS: real bridge profile chains, native dimensions, both GL enumerations before updates, eye/fixed/off/unsupported, first/second update failures, zero updates on second create failure, symmetric recreation, cleanup");
    }
};
}
int main() { FoveationTest::run(); }
