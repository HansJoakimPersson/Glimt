// CUDA kernels use the C++ source presentation.
__global__ void answer(int *value) { const char *message = "return 42"; *value = 42; }
