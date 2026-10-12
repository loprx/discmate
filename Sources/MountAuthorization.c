#include "DeviceBridge.h"
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

void *dm_authorize_mount(const char *helper, int32_t *status) {
    AuthorizationRef authorization = NULL;
    *status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authorization);
    if (*status) return NULL;
    AuthorizationItem item = { kAuthorizationRightExecute, (UInt32)strlen(helper), (void *)helper, 0 };
    AuthorizationRights rights = { 1, &item };
    *status = AuthorizationCopyRights(authorization, &rights, kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize, NULL);
    if (*status) { AuthorizationFree(authorization, kAuthorizationFlagDestroyRights); return NULL; }
    return (void *)authorization;
}
void dm_release_authorization(void *authorization) {
    if (authorization) AuthorizationFree(authorization, kAuthorizationFlagDestroyRights);
}
int32_t dm_authorized_mount(void *authorization, const char *helper, const char *bsd, const char *identity, const char *start, char *output, size_t capacity) {
    if (!authorization || capacity < 2) return EINVAL;
    char *arguments[] = {(char *)bsd, (char *)identity, (char *)start, NULL};
    FILE *pipe = NULL;
    // Compatibility bridge for this local prototype only. This API is deprecated
    // since macOS 10.7; distribution must migrate to a signed ServiceManagement
    // helper. No setuid bit, persistent daemon, shell, or stored password is used.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus status = AuthorizationExecuteWithPrivileges(authorization, helper, kAuthorizationFlagDefaults, arguments, &pipe);
#pragma clang diagnostic pop
    if (status) return status;
    if (!pipe) return EIO;
    size_t used = 0; int ch;
    while ((ch = fgetc(pipe)) != EOF) {
        if (used + 1 < capacity) output[used++] = (char)ch;
    }
    int readError = ferror(pipe);
    output[used] = '\0';
    fclose(pipe);
    return readError ? EIO : 0;
}
