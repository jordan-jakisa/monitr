#include "CMonitr.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <string.h>

// Private IOKit HID event API (the same one Activity Monitor-style tools use on Apple Silicon).
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

#define kTempEvent 15
#define kMaxDie 64

static IOHIDEventSystemClientRef client;
static IOHIDServiceClientRef dieSensors[kMaxDie];
static int dieCount;

int monitr_temp_open(void) {
    if (client) return dieCount > 0 ? 0 : -1;
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return -1;
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *vals[] = {p, u};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match); CFRelease(p); CFRelease(u);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return -1;
    char name[128];
    for (CFIndex i = 0; i < CFArrayGetCount(services) && dieCount < kMaxDie; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef product = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        if (!product) continue;
        if (CFStringGetCString(product, name, sizeof name, kCFStringEncodingUTF8) &&
            (strstr(name, "tdie") || strstr(name, "CPU"))) {
            CFRetain(s);
            dieSensors[dieCount++] = s;
        }
        CFRelease(product);
    }
    CFRelease(services);
    return dieCount > 0 ? 0 : -1;
}

double monitr_cpu_temp(void) {
    double hottest = -1;
    for (int i = 0; i < dieCount; i++) {
        IOHIDEventRef e = IOHIDServiceClientCopyEvent(dieSensors[i], kTempEvent, 0, 0);
        if (!e) continue;
        double t = IOHIDEventGetFloatValue(e, kTempEvent << 16);
        CFRelease(e);
        if (t > 0 && t < 150 && t > hottest) hottest = t;
    }
    return hottest;
}

typedef pid_t (*resp_fn)(pid_t);

pid_t monitr_responsible_pid(pid_t pid) {
    static resp_fn fn;
    static int looked;
    if (!looked) {
        fn = (resp_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        looked = 1;
    }
    return fn ? fn(pid) : -1;
}
