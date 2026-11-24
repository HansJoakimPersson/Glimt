#include <upc.h>
#include <stdio.h>

/* UPC */
int main(void) {
    printf("Hej från tråd %d av %d\n", MYTHREAD, THREADS);
    upc_barrier;
    return 0;
}
