#include "platform.h"
#include <string.h>

void
Platform_name(char *buf, size_t size)
{
    (void)size;
    memcpy(buf, "RP2350", 7);
}
