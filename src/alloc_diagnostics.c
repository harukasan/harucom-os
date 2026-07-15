/* Diagnostic wrapper around the mruby heap allocator.
 *
 * Every mruby heap allocation reaches est_realloc (picoruby-mruby
 * alloc.c routes mrb_basic_alloc_func there, estalloc backend). When
 * it returns NULL the VM raises NoMemoryError with no record of the
 * request, so an oversized or runaway allocation is invisible. This
 * wrapper (linked with -Wl,--wrap=est_realloc) prints the failing
 * size to the UART before the VM raises.
 *
 * Wrapping mrb_basic_alloc_func itself is not possible: the __real_
 * reference would pull mruby core's default definition (allocf.o) out
 * of libmruby.a alongside the estalloc one and break the link.
 */

#include <stdio.h>
#include <stddef.h>

extern void *__real_est_realloc(void *est, void *ptr, unsigned int size);

void *__wrap_est_realloc(void *est, void *ptr, unsigned int size) {
    void *result = __real_est_realloc(est, ptr, size);
    if (result == NULL && size > 0) {
        printf("mruby alloc failed: %u bytes (realloc of %p)\n", size, ptr);
    }
    return result;
}
