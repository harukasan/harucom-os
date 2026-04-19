/*
 * picoruby-env POSIX bridge stubs.
 *
 * ENV[]= / ENV.delete on mruby store into an internal Hash before
 * calling these hooks to sync with POSIX environ.  On bare-metal
 * RP2350 + newlib that sync path malloc-grows an environ array from
 * the C heap and corrupts unrelated memory, so we stub it out.
 * ENV[] / ENV[]= / ENV.delete stay fully functional via the Hash.
 */

#include <stddef.h>

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
  (void)name;
  return 0;
}

int
ENV_setenv(const char *name, const char *value, int override)
{
  (void)name;
  (void)value;
  (void)override;
  return 0;
}
