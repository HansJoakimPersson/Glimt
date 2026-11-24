#include <stdio.h>
/* Print the build counter. */
int main(void) {
    const int count = 42;
    printf("Glimt %d\n", count);
    return 0;
}

/* Collections and nested control flow. */
static int enabled_count(const int values[], int length) {
    int total = 0;
    for (int index = 0; index < length; index++) {
        if (values[index] > 0) {
            total += 1;
        }
    }
    return total;
}
