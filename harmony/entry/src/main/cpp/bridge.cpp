#include <napi/native_api.h>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>

extern "C" char *FlClashInspect(char *);
extern "C" char *FlClashStart(char *, int);
extern "C" void FlClashStop();
extern "C" void FlClashRefreshNetwork();

namespace {
struct AsyncCall {
 napi_deferred deferred = nullptr;
 napi_async_work work = nullptr;
 std::string input;
 int fd = -1;
 bool start = false;
 char *result = nullptr;
};

bool ReadString(napi_env env, napi_value value, std::string &out) {
 size_t length = 0;
 if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
 std::string buffer(length + 1, '\0');
 size_t written = 0;
 if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &written) != napi_ok) return false;
 buffer.resize(written);
 out = std::move(buffer);
 return true;
}

void Execute(napi_env, void *data) {
 auto *call = static_cast<AsyncCall *>(data);
 if (call->start) call->result = FlClashStart(const_cast<char *>(call->input.c_str()), call->fd);
 else call->result = FlClashInspect(const_cast<char *>(call->input.c_str()));
}

void Complete(napi_env env, napi_status status, void *data) {
 auto *call = static_cast<AsyncCall *>(data);
 if (status != napi_ok || call->result == nullptr) {
  napi_value error, message;
  const char *text = status == napi_ok ? "Native core returned no result" : "Native core operation was cancelled";
  napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &message);
  napi_create_error(env, nullptr, message, &error);
  napi_reject_deferred(env, call->deferred, error);
 } else {
  const char *result = call->result;
  const size_t length = std::strlen(result);
  if ((call->start && length != 0) || (!call->start && length >= 6 && std::memcmp(result, "ERROR:", 6) == 0)) {
   napi_value error, message;
   const char *detail = call->start ? result : result + 6;
   napi_create_string_utf8(env, detail, call->start ? length : length - 6, &message);
   napi_create_error(env, nullptr, message, &error);
   napi_reject_deferred(env, call->deferred, error);
  } else if (call->start) {
   napi_value value;
   napi_get_undefined(env, &value);
   napi_resolve_deferred(env, call->deferred, value);
  } else {
   napi_value value;
   napi_create_string_utf8(env, result, length, &value);
   napi_resolve_deferred(env, call->deferred, value);
  }
 }
 if (call->result != nullptr) std::free(call->result);
 napi_delete_async_work(env, call->work);
 delete call;
}

napi_value Queue(napi_env env, const char *name, std::string input, bool start, int fd) {
 auto *call = new AsyncCall;
 call->input = std::move(input);
 call->start = start;
 call->fd = fd;
 napi_value promise, resourceName;
 if (napi_create_promise(env, &call->deferred, &promise) != napi_ok ||
     napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resourceName) != napi_ok ||
     napi_create_async_work(env, nullptr, resourceName, Execute, Complete, call, &call->work) != napi_ok ||
     napi_queue_async_work(env, call->work) != napi_ok) {
  if (call->work != nullptr) napi_delete_async_work(env, call->work);
  delete call;
  napi_throw_error(env, nullptr, "Unable to queue native core operation");
  return nullptr;
 }
 return promise;
}

napi_value Inspect(napi_env env, napi_callback_info info) {
 size_t argc = 1;
 napi_value args[1];
 if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
  napi_throw_type_error(env, nullptr, "inspect expects configuration text");
  return nullptr;
 }
 std::string config;
 if (!ReadString(env, args[0], config)) {
  napi_throw_type_error(env, nullptr, "inspect expects configuration text");
  return nullptr;
 }
 return Queue(env, "FlClashInspect", std::move(config), false, -1);
}

napi_value Start(napi_env env, napi_callback_info info) {
 size_t argc = 2;
 napi_value args[2];
 if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2) {
  napi_throw_type_error(env, nullptr, "start expects options JSON and TUN fd");
  return nullptr;
 }
 std::string options;
 int32_t fd = -1;
 if (!ReadString(env, args[0], options) || napi_get_value_int32(env, args[1], &fd) != napi_ok || fd < 0) {
  napi_throw_type_error(env, nullptr, "start expects options JSON and a valid TUN fd");
  return nullptr;
 }
 return Queue(env, "FlClashStart", std::move(options), true, fd);
}

napi_value Stop(napi_env env, napi_callback_info) {
 FlClashStop();
 napi_value value;
 napi_get_undefined(env, &value);
 return value;
}

napi_value RefreshNetwork(napi_env env, napi_callback_info) {
 FlClashRefreshNetwork();
 napi_value value;
 napi_get_undefined(env, &value);
 return value;
}

napi_value Init(napi_env env, napi_value exports) {
 napi_property_descriptor properties[] = {
  {"inspect", nullptr, Inspect, nullptr, nullptr, nullptr, napi_default, nullptr},
  {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
  {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
  {"refreshNetwork", nullptr, RefreshNetwork, nullptr, nullptr, nullptr, napi_default, nullptr}
 };
 napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
 return exports;
}

napi_module module = {1, 0, nullptr, Init, "flclashcore", nullptr, {0}};
}

extern "C" __attribute__((constructor)) void RegisterFlClashCore() { napi_module_register(&module); }
