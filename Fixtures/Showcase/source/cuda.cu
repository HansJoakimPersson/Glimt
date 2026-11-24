// Store the answer in device memory.
__global__ void answer(int *value) { const char *message = "return 42"; *value = 42; }
