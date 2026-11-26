#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int VGUnpackIPA(const char *ipa, const char *destination);
int VGPackIPA(const char *payload, const char *ipa);
int VGSignApp(const char *app, const char *p12, const char *profile, const char *entitlements,
              const char *password, const char *bundleID);
void *VGCopyProfile(const char *path, size_t *length);
void VGFree(void *buffer);

#ifdef __cplusplus
}
#endif
