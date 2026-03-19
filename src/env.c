/*
 * ENV HAL for Harucom OS.
 *
 * Minimal stub: environment variables are not persistent on this platform.
 * setenv/unsetenv from newlib are used for in-memory key-value storage.
 */

#include <stddef.h>
#include <stdlib.h>

void
ENV_get_key_value(char **key, size_t *key_len, char **value, size_t *value_len)
{
    *key = NULL;
    *key_len = 0;
    *value = NULL;
    *value_len = 0;
}

int
ENV_unsetenv(const char *name)
{
    return unsetenv(name);
}

int
ENV_setenv(const char *name, const char *value, int override)
{
    return setenv(name, value, override);
}
