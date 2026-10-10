#define XRBRIDGE_TESTING 1
#include "../../vrbridge/xrbridge.cpp"
#include <cassert>
#include <set>
namespace {
struct PointerTest {
 static inline uintptr_t serial=10;
 static inline std::map<XrPath,std::string> paths;
 static inline std::map<XrAction,XrActionType> actions;
 static inline std::set<std::string> names,labels,profiles;
 static inline std::set<XrSpace> spaces;
 static inline XrSpaceLocationFlags flags=XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
 static inline bool active=true;
 static inline int locateCount=0;
 static XrResult XRAPI_PTR path(XrInstance,const char* s,XrPath* out){*out=++serial;paths[*out]=s;return XR_SUCCESS;}
 static XrResult XRAPI_PTR set(XrInstance,const XrActionSetCreateInfo*,XrActionSet* out){*out=reinterpret_cast<XrActionSet>(++serial);return XR_SUCCESS;}
 static XrResult XRAPI_PTR action(XrActionSet,const XrActionCreateInfo* info,XrAction* out){
  assert(names.insert(info->actionName).second);assert(labels.insert(info->localizedActionName).second);
  assert(info->countSubactionPaths==2);*out=reinterpret_cast<XrAction>(++serial);actions[*out]=info->actionType;return XR_SUCCESS;
 }
 static XrResult XRAPI_PTR suggest(XrInstance,const XrInteractionProfileSuggestedBinding* info){
  auto profile=paths[info->interactionProfile];profiles.insert(profile);int aims=0,triggers=0;
  for(unsigned i=0;i<info->countSuggestedBindings;++i){auto& b=info->suggestedBindings[i];auto p=paths[b.binding];
   assert(p.find("squeeze/click")==std::string::npos);
   if(actions[b.action]==XR_ACTION_TYPE_POSE_INPUT){assert(p.find("/input/aim/pose")!=std::string::npos);++aims;}
   if(actions[b.action]==XR_ACTION_TYPE_FLOAT_INPUT){assert(p.find("/input/trigger/value")!=std::string::npos);++triggers;}
  }
  if(profile==kFrameControllerProfilePath || profile.find("touch_controller")!=std::string::npos || profile.find("index_controller")!=std::string::npos)assert(aims==2&&triggers==2);
  return XR_SUCCESS;
 }
 static XrResult XRAPI_PTR attach(XrSession,const XrSessionActionSetsAttachInfo*){return XR_SUCCESS;}
 static XrResult XRAPI_PTR space(XrSession,const XrActionSpaceCreateInfo* info,XrSpace* out){
  assert(actions[info->action]==XR_ACTION_TYPE_POSE_INPUT);assert(info->poseInActionSpace.orientation.w==1);
  *out=reinterpret_cast<XrSpace>(++serial);spaces.insert(*out);return XR_SUCCESS;
 }
 static XrResult XRAPI_PTR destroySpace(XrSpace s){assert(spaces.erase(s)==1);return XR_SUCCESS;}
 static XrResult XRAPI_PTR destroyAction(XrAction a){assert(spaces.empty());actions.erase(a);return XR_SUCCESS;}
 static XrResult XRAPI_PTR destroySet(XrActionSet){assert(actions.empty());return XR_SUCCESS;}
 static XrResult XRAPI_PTR sync(XrSession,const XrActionsSyncInfo*){return XR_SUCCESS;}
 static XrResult XRAPI_PTR boolean(XrSession,const XrActionStateGetInfo*,XrActionStateBoolean*){return XR_SUCCESS;}
 static XrResult XRAPI_PTR vec(XrSession,const XrActionStateGetInfo*,XrActionStateVector2f*){return XR_SUCCESS;}
 static XrResult XRAPI_PTR pose(XrSession,const XrActionStateGetInfo* i,XrActionStatePose* out){assert(actions[i->action]==XR_ACTION_TYPE_POSE_INPUT);out->isActive=active;return XR_SUCCESS;}
 static XrResult XRAPI_PTR trigger(XrSession,const XrActionStateGetInfo* i,XrActionStateFloat* out){assert(actions[i->action]==XR_ACTION_TYPE_FLOAT_INPUT);out->isActive=active;out->currentState=.75f;return XR_SUCCESS;}
 static XrResult XRAPI_PTR locate(XrSpace s,XrSpace base,XrTime time,XrSpaceLocation* out){assert(spaces.count(s));assert(base==reinterpret_cast<XrSpace>(3));assert(time==12345);++locateCount;out->locationFlags=flags;out->pose.orientation.w=1;out->pose.position.z=-.5f;return XR_SUCCESS;}
 static void run(){
  Bridge b;b.m_instance=reinterpret_cast<XrInstance>(1);b.m_session=reinterpret_cast<XrSession>(2);b.m_referenceSpace=reinterpret_cast<XrSpace>(3);
  b.m_stringToPath=path;b.m_createActionSet=set;b.m_createAction=action;b.m_suggestInteractionProfileBindings=suggest;b.m_attachSessionActionSets=attach;
  b.m_createActionSpace=space;b.m_destroySpace=destroySpace;b.m_destroyAction=destroyAction;b.m_destroyActionSet=destroySet;
  b.m_syncActions=sync;b.m_getActionStateBoolean=boolean;b.m_getActionStateVector2f=vec;b.m_getActionStatePose=pose;b.m_getActionStateFloat=trigger;b.m_locateSpace=locate;
  b.m_frameControllerExtensionAvailable=true;assert(b.createActions());assert(b.actionsSupported());assert(b.createAimSpaces());assert(spaces.size()==2);
  b.m_sessionRunning=true;b.m_sessionState=XR_SESSION_STATE_FOCUSED;b.m_frameActive=true;b.m_frameState.shouldRender=XR_TRUE;b.m_frameState.predictedDisplayTime=12345;
  b.updateActions();assert(locateCount==2);for(int i=0;i<2;++i){assert(b.aim(i).locationFlags==flags);assert(b.trigger(i)==.75f);}
  flags=XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;b.updateActions();assert(!b.aim(0).locationFlags&&!b.aim(1).locationFlags&&b.trigger(0)==0);
  flags|=XR_SPACE_LOCATION_POSITION_VALID_BIT;active=false;b.updateActions();assert(!b.aim(0).locationFlags);active=true;
  b.m_frameState.shouldRender=XR_FALSE;int n=locateCount;b.updateActions();assert(locateCount==n&&!b.aim(1).locationFlags);
  b.m_frameState.shouldRender=XR_TRUE;b.m_sessionState=XR_SESSION_STATE_VISIBLE;b.updateActions();assert(locateCount==n);
  b.m_sessionState=XR_SESSION_STATE_FOCUSED;b.m_frameActive=false;b.updateActions();assert(locateCount==n);
  b.cleanupActions();assert(spaces.empty()&&actions.empty());b.m_referenceSpace=XR_NULL_HANDLE;b.m_session=XR_NULL_HANDLE;b.m_instance=XR_NULL_HANDLE;b.m_sessionRunning=false;
  puts("native pointer action names, Frame/Touch/Index bindings, current-time pose validity/focus/render gates, and space/action cleanup passed");
 }
};
}
int main(){PointerTest::run();}
