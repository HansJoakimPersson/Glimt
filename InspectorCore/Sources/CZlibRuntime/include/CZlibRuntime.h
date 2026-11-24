#ifndef GLIMT_CZLIB_RUNTIME_H
#define GLIMT_CZLIB_RUNTIME_H

#include <zlib.h>

int glimtInflateGzipInit(z_streamp stream);
int glimtInflateStream(z_streamp stream, int flush);
int glimtInflateFinish(z_streamp stream);

#endif
