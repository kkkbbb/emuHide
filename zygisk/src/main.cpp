#include <android/log.h>
#include <ctype.h>
#include <fcntl.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "zygisk.hpp"

#define LOG_TAG "emuHideZygisk"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

constexpr const char *kOriginalPropsFile = "/data/adb/modules/hunter_env_stealth/system-server-original-props.env";
constexpr const char *kOriginalPropsName = "system-server-original-props.env";
constexpr int kMaxProps = 256;
constexpr int kMaxKey = 96;
constexpr int kMaxValue = 256;
constexpr int kMaxHandles = 256;

struct PropEntry {
    char key[kMaxKey];
    char value[kMaxValue];
};

struct HandleEntry {
    jlong handle;
    int prop_index;
};

static PropEntry g_props[kMaxProps];
static int g_prop_count = 0;
static HandleEntry g_handles[kMaxHandles];
static int g_handle_count = 0;

using NativeGet1 = jstring (*)(JNIEnv *, jclass, jstring);
using NativeGet2 = jstring (*)(JNIEnv *, jclass, jstring, jstring);
using NativeGetHandle = jstring (*)(JNIEnv *, jclass, jlong);
using NativeGetInt = jint (*)(JNIEnv *, jclass, jstring, jint);
using NativeGetIntHandle = jint (*)(JNIEnv *, jclass, jlong, jint);
using NativeGetLong = jlong (*)(JNIEnv *, jclass, jstring, jlong);
using NativeGetLongHandle = jlong (*)(JNIEnv *, jclass, jlong, jlong);
using NativeGetBool = jboolean (*)(JNIEnv *, jclass, jstring, jboolean);
using NativeGetBoolHandle = jboolean (*)(JNIEnv *, jclass, jlong, jboolean);
using NativeFind = jlong (*)(JNIEnv *, jclass, jstring);

static NativeGet1 orig_get1 = nullptr;
static NativeGet2 orig_get2 = nullptr;
static NativeGetHandle orig_get_handle = nullptr;
static NativeGetInt orig_get_int = nullptr;
static NativeGetIntHandle orig_get_int_handle = nullptr;
static NativeGetLong orig_get_long = nullptr;
static NativeGetLongHandle orig_get_long_handle = nullptr;
static NativeGetBool orig_get_bool = nullptr;
static NativeGetBoolHandle orig_get_bool_handle = nullptr;
static NativeFind orig_find = nullptr;

void trim(char *s) {
    char *start = s;
    while (*start && isspace(static_cast<unsigned char>(*start))) start++;
    if (start != s) memmove(s, start, strlen(start) + 1);

    size_t len = strlen(s);
    while (len > 0 && isspace(static_cast<unsigned char>(s[len - 1]))) {
        s[--len] = '\0';
    }
}

bool add_prop(const char *key, const char *value) {
    if (!key || !value || !*key || g_prop_count >= kMaxProps) return false;
    strlcpy(g_props[g_prop_count].key, key, sizeof(g_props[g_prop_count].key));
    strlcpy(g_props[g_prop_count].value, value, sizeof(g_props[g_prop_count].value));
    g_prop_count++;
    return true;
}

void reset_props() {
    g_prop_count = 0;
    g_handle_count = 0;
}

int find_prop(const char *key) {
    if (!key) return -1;
    for (int i = 0; i < g_prop_count; ++i) {
        if (strcmp(g_props[i].key, key) == 0) return i;
    }
    return -1;
}

int find_prop_from_jstring(JNIEnv *env, jstring key) {
    if (!key) return -1;
    const char *chars = env->GetStringUTFChars(key, nullptr);
    if (!chars) return -1;
    int index = find_prop(chars);
    env->ReleaseStringUTFChars(key, chars);
    return index;
}

void add_handle(jlong handle, int prop_index) {
    if (handle == 0 || prop_index < 0) return;
    for (int i = 0; i < g_handle_count; ++i) {
        if (g_handles[i].handle == handle) {
            g_handles[i].prop_index = prop_index;
            return;
        }
    }
    if (g_handle_count >= kMaxHandles) return;
    g_handles[g_handle_count++] = {handle, prop_index};
}

int find_handle(jlong handle) {
    for (int i = 0; i < g_handle_count; ++i) {
        if (g_handles[i].handle == handle) return g_handles[i].prop_index;
    }
    return -1;
}

jstring new_prop_string(JNIEnv *env, int index) {
    if (index < 0 || index >= g_prop_count) return nullptr;
    return env->NewStringUTF(g_props[index].value);
}

jint parse_int(const char *value, jint def) {
    if (!value || !*value) return def;
    char *end = nullptr;
    long parsed = strtol(value, &end, 0);
    return end == value ? def : static_cast<jint>(parsed);
}

jlong parse_long(const char *value, jlong def) {
    if (!value || !*value) return def;
    char *end = nullptr;
    long long parsed = strtoll(value, &end, 0);
    return end == value ? def : static_cast<jlong>(parsed);
}

jboolean parse_bool(const char *value, jboolean def) {
    if (!value || !*value) return def;
    if (strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0 ||
        strcasecmp(value, "y") == 0 || strcasecmp(value, "yes") == 0 ||
        strcasecmp(value, "on") == 0) {
        return JNI_TRUE;
    }
    if (strcmp(value, "0") == 0 || strcasecmp(value, "false") == 0 ||
        strcasecmp(value, "n") == 0 || strcasecmp(value, "no") == 0 ||
        strcasecmp(value, "off") == 0) {
        return JNI_FALSE;
    }
    return def;
}

jstring hook_get1(JNIEnv *env, jclass clazz, jstring key) {
    int index = find_prop_from_jstring(env, key);
    if (index >= 0) return new_prop_string(env, index);
    return orig_get1 ? orig_get1(env, clazz, key) : env->NewStringUTF("");
}

jstring hook_get2(JNIEnv *env, jclass clazz, jstring key, jstring def) {
    int index = find_prop_from_jstring(env, key);
    if (index >= 0) return new_prop_string(env, index);
    return orig_get2 ? orig_get2(env, clazz, key, def) : def;
}

jstring hook_get_handle(JNIEnv *env, jclass clazz, jlong handle) {
    int index = find_handle(handle);
    if (index >= 0) return new_prop_string(env, index);
    return orig_get_handle ? orig_get_handle(env, clazz, handle) : env->NewStringUTF("");
}

jint hook_get_int(JNIEnv *env, jclass clazz, jstring key, jint def) {
    int index = find_prop_from_jstring(env, key);
    if (index >= 0) return parse_int(g_props[index].value, def);
    return orig_get_int ? orig_get_int(env, clazz, key, def) : def;
}

jint hook_get_int_handle(JNIEnv *env, jclass clazz, jlong handle, jint def) {
    int index = find_handle(handle);
    if (index >= 0) return parse_int(g_props[index].value, def);
    return orig_get_int_handle ? orig_get_int_handle(env, clazz, handle, def) : def;
}

jlong hook_get_long(JNIEnv *env, jclass clazz, jstring key, jlong def) {
    int index = find_prop_from_jstring(env, key);
    if (index >= 0) return parse_long(g_props[index].value, def);
    return orig_get_long ? orig_get_long(env, clazz, key, def) : def;
}

jlong hook_get_long_handle(JNIEnv *env, jclass clazz, jlong handle, jlong def) {
    int index = find_handle(handle);
    if (index >= 0) return parse_long(g_props[index].value, def);
    return orig_get_long_handle ? orig_get_long_handle(env, clazz, handle, def) : def;
}

jboolean hook_get_bool(JNIEnv *env, jclass clazz, jstring key, jboolean def) {
    int index = find_prop_from_jstring(env, key);
    if (index >= 0) return parse_bool(g_props[index].value, def);
    return orig_get_bool ? orig_get_bool(env, clazz, key, def) : def;
}

jboolean hook_get_bool_handle(JNIEnv *env, jclass clazz, jlong handle, jboolean def) {
    int index = find_handle(handle);
    if (index >= 0) return parse_bool(g_props[index].value, def);
    return orig_get_bool_handle ? orig_get_bool_handle(env, clazz, handle, def) : def;
}

jlong hook_find(JNIEnv *env, jclass clazz, jstring key) {
    jlong handle = orig_find ? orig_find(env, clazz, key) : 0;
    int index = find_prop_from_jstring(env, key);
    if (index >= 0) add_handle(handle, index);
    return handle;
}

void load_original_props(zygisk::Api *api) {
    reset_props();
    int fd = -1;
    int module_fd = api ? api->getModuleDir() : -1;
    if (module_fd >= 0) {
        fd = openat(module_fd, kOriginalPropsName, O_RDONLY | O_CLOEXEC);
        close(module_fd);
    }
    if (fd < 0) {
        fd = open(kOriginalPropsFile, O_RDONLY | O_CLOEXEC);
    }
    if (fd < 0) return;

    char data[32768];
    ssize_t n = read(fd, data, sizeof(data) - 1);
    close(fd);
    if (n <= 0) return;
    data[n] = '\0';

    char *save = nullptr;
    for (char *line = strtok_r(data, "\n", &save); line; line = strtok_r(nullptr, "\n", &save)) {
        trim(line);
        if (!*line || *line == '#') continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = line;
        char *value = eq + 1;
        trim(key);
        trim(value);
        add_prop(key, value);
    }
}

void install_system_property_hooks(zygisk::Api *api, JNIEnv *env) {
    JNINativeMethod methods[] = {
        {"native_get", "(Ljava/lang/String;)Ljava/lang/String;", reinterpret_cast<void *>(hook_get1)},
        {"native_get", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", reinterpret_cast<void *>(hook_get2)},
        {"native_get", "(J)Ljava/lang/String;", reinterpret_cast<void *>(hook_get_handle)},
        {"native_get_int", "(Ljava/lang/String;I)I", reinterpret_cast<void *>(hook_get_int)},
        {"native_get_int", "(JI)I", reinterpret_cast<void *>(hook_get_int_handle)},
        {"native_get_long", "(Ljava/lang/String;J)J", reinterpret_cast<void *>(hook_get_long)},
        {"native_get_long", "(JJ)J", reinterpret_cast<void *>(hook_get_long_handle)},
        {"native_get_boolean", "(Ljava/lang/String;Z)Z", reinterpret_cast<void *>(hook_get_bool)},
        {"native_get_boolean", "(JZ)Z", reinterpret_cast<void *>(hook_get_bool_handle)},
        {"native_find", "(Ljava/lang/String;)J", reinterpret_cast<void *>(hook_find)},
    };
    api->hookJniNativeMethods(env, "android/os/SystemProperties", methods,
                              sizeof(methods) / sizeof(methods[0]));
    orig_get1 = reinterpret_cast<NativeGet1>(methods[0].fnPtr);
    orig_get2 = reinterpret_cast<NativeGet2>(methods[1].fnPtr);
    orig_get_handle = reinterpret_cast<NativeGetHandle>(methods[2].fnPtr);
    orig_get_int = reinterpret_cast<NativeGetInt>(methods[3].fnPtr);
    orig_get_int_handle = reinterpret_cast<NativeGetIntHandle>(methods[4].fnPtr);
    orig_get_long = reinterpret_cast<NativeGetLong>(methods[5].fnPtr);
    orig_get_long_handle = reinterpret_cast<NativeGetLongHandle>(methods[6].fnPtr);
    orig_get_bool = reinterpret_cast<NativeGetBool>(methods[7].fnPtr);
    orig_get_bool_handle = reinterpret_cast<NativeGetBoolHandle>(methods[8].fnPtr);
    orig_find = reinterpret_cast<NativeFind>(methods[9].fnPtr);
}

void set_static_string(JNIEnv *env, jclass clazz, const char *field, const char *value) {
    jfieldID field_id = env->GetStaticFieldID(clazz, field, "Ljava/lang/String;");
    if (!field_id) {
        env->ExceptionClear();
        return;
    }
    jstring string_value = env->NewStringUTF(value);
    if (!string_value) {
        env->ExceptionClear();
        return;
    }
    env->SetStaticObjectField(clazz, field_id, string_value);
    env->DeleteLocalRef(string_value);
    if (env->ExceptionCheck()) env->ExceptionClear();
}

void patch_build_fields(JNIEnv *env) {
    jclass build = env->FindClass("android/os/Build");
    if (!build) {
        env->ExceptionClear();
        return;
    }
    set_static_string(env, build, "BRAND", "google");
    set_static_string(env, build, "MANUFACTURER", "Google");
    set_static_string(env, build, "MODEL", "Pixel 7 Pro");
    set_static_string(env, build, "DEVICE", "cheetah");
    set_static_string(env, build, "PRODUCT", "cheetah");
    set_static_string(env, build, "BOARD", "cheetah");
    set_static_string(env, build, "HARDWARE", "gs201");
    set_static_string(env, build, "FINGERPRINT", "google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys");
    set_static_string(env, build, "ID", "AP1A.240505.005");
    set_static_string(env, build, "DISPLAY", "AP1A.240505.005.11677807");
    set_static_string(env, build, "TAGS", "release-keys");
    set_static_string(env, build, "TYPE", "user");
    set_static_string(env, build, "BOOTLOADER", "cloudripper-14.0-11200000");
    set_static_string(env, build, "SERIAL", "3A021JEHN02756");
    env->DeleteLocalRef(build);

    jclass version = env->FindClass("android/os/Build$VERSION");
    if (!version) {
        env->ExceptionClear();
        return;
    }
    set_static_string(env, version, "INCREMENTAL", "11677807");
    set_static_string(env, version, "SECURITY_PATCH", "2024-05-05");
    env->DeleteLocalRef(version);
}

class EmuHideModule : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *) override {
        patch_build_fields(env_);
        api_->setOption(zygisk::DLCLOSE_MODULE_LIBRARY);
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override {
        load_original_props(api_);
        if (g_prop_count <= 0) {
            LOGW("no original props loaded");
            return;
        }
        install_system_property_hooks(api_, env_);
        LOGI("installed system_server original prop hook: %d props", g_prop_count);
    }

private:
    zygisk::Api *api_{nullptr};
    JNIEnv *env_{nullptr};
};

void companion_handler(int) {}

}  // namespace

REGISTER_ZYGISK_MODULE(EmuHideModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
