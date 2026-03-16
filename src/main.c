/*
 * Harucom OS — PicoRuby firmware for Harucom Board
 *
 * Compiles and executes a Ruby script that blinks the on-board LED (GPIO 23).
 */

#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"
#include "picoruby.h"
#include "psram.h"

static const char ruby_code[] = "led = GPIO.new(23, GPIO::OUT)\n"
                                "loop do\n"
                                "  led.write 1\n"
                                "  sleep_ms 500\n"
                                "  led.write 0\n"
                                "  sleep_ms 500\n"
                                "end\n";

mrb_state *global_mrb = NULL;

int main(void) {
  stdio_init_all();
  sleep_ms(2000); /* Wait for UART to stabilize */

  printf("Harucom OS %s (built %s)\n", HARUCOM_VERSION, HARUCOM_BUILD_DATE);

  /* 1. Initialize PSRAM */
  size_t heap_size;
  void *heap_pool = psram_init(&heap_size);
  if (!heap_pool) {
    printf("PSRAM init failed\n");
    return 1;
  }
  printf("PSRAM heap: %u bytes at %p\n", (unsigned)heap_size, heap_pool);

  /* 2. Initialize VM */
  mrb_state *mrb = mrb_open_with_custom_alloc(heap_pool, heap_size);
  if (!mrb) {
    printf("mrb_open failed\n");
    return 1;
  }
  global_mrb = mrb;

  /* 3. Create compiler context */
  mrc_ccontext *cc = mrc_ccontext_new(mrb);

  /* 4. Compile Ruby code on-the-fly */
  const uint8_t *src = (const uint8_t *)ruby_code;
  mrc_irep *irep = mrc_load_string_cxt(cc, &src, strlen(ruby_code));
  if (!irep) {
    printf("compile failed\n");
    return 1;
  }

  printf("Compile OK\n");

  /* 5. Create task and run */
  mrb_value name = mrb_str_new_cstr(mrb, "blink");
  mrb_value task = mrc_create_task(cc, irep, name, mrb_nil_value(),
                                   mrb_obj_value(mrb->top_self));
  if (mrb_nil_p(task)) {
    printf("create_task failed\n");
    return 1;
  }

  printf("Starting Ruby task...\n");
  mrb_task_run(mrb);

  /* Should not reach here (infinite loop in Ruby) */
  mrb_close(mrb);
  mrc_ccontext_free(cc);
  return 0;
}
