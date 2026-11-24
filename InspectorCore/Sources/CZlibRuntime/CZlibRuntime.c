#include "CZlibRuntime.h"

#include <dlfcn.h>
#include <pthread.h>

#define GLIMT_ZLIB_LIBRARY "libz.1.dylib"

typedef const char *(*GlimtZlibVersionFunction)(void);
typedef int (*GlimtInflateInitFunction)(z_streamp, int, const char *, int);
typedef int (*GlimtInflateFunction)(z_streamp, int);
typedef int (*GlimtInflateEndFunction)(z_streamp);

static pthread_once_t glimtZlibLoadOnce = PTHREAD_ONCE_INIT;
static void *glimtZlibHandle;
static GlimtZlibVersionFunction glimtZlibVersion;
static GlimtInflateInitFunction glimtZlibInflateInit;
static GlimtInflateFunction glimtZlibInflate;
static GlimtInflateEndFunction glimtZlibInflateEnd;

static void glimtLoadSystemZlib(void) {
    glimtZlibHandle = dlopen(GLIMT_ZLIB_LIBRARY, RTLD_NOW | RTLD_LOCAL);
    if (glimtZlibHandle == NULL) {
        return;
    }

    glimtZlibVersion = (GlimtZlibVersionFunction)dlsym(glimtZlibHandle, "zlibVersion");
    glimtZlibInflateInit = (GlimtInflateInitFunction)dlsym(glimtZlibHandle, "inflateInit2_");
    glimtZlibInflate = (GlimtInflateFunction)dlsym(glimtZlibHandle, "inflate");
    glimtZlibInflateEnd = (GlimtInflateEndFunction)dlsym(glimtZlibHandle, "inflateEnd");
}

static int glimtSystemZlibIsAvailable(void) {
    pthread_once(&glimtZlibLoadOnce, glimtLoadSystemZlib);
    return glimtZlibVersion != NULL && glimtZlibInflateInit != NULL &&
        glimtZlibInflate != NULL && glimtZlibInflateEnd != NULL;
}

int glimtInflateGzipInit(z_streamp stream) {
    if (!glimtSystemZlibIsAvailable()) {
        return Z_VERSION_ERROR;
    }
    return glimtZlibInflateInit(stream, MAX_WBITS + 16, glimtZlibVersion(), (int)sizeof(*stream));
}

int glimtInflateStream(z_streamp stream, int flush) {
    if (!glimtSystemZlibIsAvailable()) {
        return Z_VERSION_ERROR;
    }
    return glimtZlibInflate(stream, flush);
}

int glimtInflateFinish(z_streamp stream) {
    if (!glimtSystemZlibIsAvailable()) {
        return Z_VERSION_ERROR;
    }
    return glimtZlibInflateEnd(stream);
}
