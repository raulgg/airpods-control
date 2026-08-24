#include "BypassProbe.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task,
                                                CFStringRef entitlement,
                                                CFErrorRef *error);

bool AirPodsControlBypassIsActive(void) {
  SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
  if (!task) {
    return false;
  }

  CFErrorRef error = NULL;
  CFTypeRef value = SecTaskCopyValueForEntitlement(
      task, CFSTR("com.apple.avfoundation.allow-system-wide-context"), &error);
  bool active = value && CFGetTypeID(value) == CFBooleanGetTypeID() &&
                CFBooleanGetValue((CFBooleanRef)value);

  if (value) {
    CFRelease(value);
  }
  if (error) {
    CFRelease(error);
  }
  CFRelease(task);
  return active;
}
