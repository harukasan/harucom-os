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

/* A size in the top half of the address space is a negative length
 * that wrapped around, not a real request. Log the C call site before
 * mrb_realloc raises (the raise longjmps, so logging after the call
 * would never run). addr2line on the printed address names the
 * mruby-internal caller that computed the negative length. */

extern void *__real_mrb_realloc(void *mrb, void *p, size_t size);
extern void *__real_mrb_malloc(void *mrb, size_t size);

void *__wrap_mrb_realloc(void *mrb, void *p, size_t size) {
    if (size >= 0x80000000u) {
        printf("mrb_realloc size=%u (%d) of %p from %p\n",
               (unsigned)size, (int)size, p, __builtin_return_address(0));
    }
    return __real_mrb_realloc(mrb, p, size);
}

void *__wrap_mrb_malloc(void *mrb, size_t size) {
    if (size >= 0x80000000u) {
        printf("mrb_malloc size=%u (%d) from %p\n",
               (unsigned)size, (int)size, __builtin_return_address(0));
    }
    return __real_mrb_malloc(mrb, size);
}
