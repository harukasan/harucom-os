#include <mruby.h>
#include <mruby/presym.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/class.h>

#include "dict_region.h"

#define MAX_CANDIDATES 32

/*
 * InputMethod.dict_available? -> true/false
 *
 * Check whether the dictionary flash region contains valid data.
 */
static mrb_value
mrb_im_dict_available(mrb_state *mrb, mrb_value klass)
{
    return mrb_bool_value(dict_available());
}

/*
 * InputMethod.skk_lookup(reading) -> Array of String, or nil
 *
 * Look up an SKK reading in the flash dictionary.
 * Returns an Array of candidate strings, or nil if not found.
 */
static mrb_value
mrb_im_skk_lookup(mrb_state *mrb, mrb_value klass)
{
    const char *reading;
    mrb_int reading_len;
    mrb_get_args(mrb, "s", &reading, &reading_len);

    const char *candidates[MAX_CANDIDATES];
    int lengths[MAX_CANDIDATES];
    int count = dict_skk_lookup(reading, (int)reading_len,
                                candidates, lengths, MAX_CANDIDATES);
    if (count == 0)
        return mrb_nil_value();

    mrb_value ary = mrb_ary_new_capa(mrb, count);
    for (int i = 0; i < count; i++) {
        mrb_value s = mrb_str_new(mrb, candidates[i], lengths[i]);
        mrb_ary_push(mrb, ary, s);
    }
    return ary;
}

/*
 * InputMethod.tcode_lookup(key1, key2) -> String or nil
 *
 * Look up a T-Code two-stroke sequence in the flash table.
 * Returns a single-character String, or nil if no character is assigned.
 */
static mrb_value
mrb_im_tcode_lookup(mrb_state *mrb, mrb_value klass)
{
    mrb_int key1, key2;
    mrb_get_args(mrb, "ii", &key1, &key2);

    uint16_t cp = dict_tcode_lookup((int)key1, (int)key2);
    if (cp == 0)
        return mrb_nil_value();

    /* Encode Unicode codepoint as UTF-8 */
    char buf[4];
    int len;
    if (cp < 0x80) {
        buf[0] = (char)cp;
        len = 1;
    } else if (cp < 0x800) {
        buf[0] = (char)(0xC0 | (cp >> 6));
        buf[1] = (char)(0x80 | (cp & 0x3F));
        len = 2;
    } else {
        buf[0] = (char)(0xE0 | (cp >> 12));
        buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (cp & 0x3F));
        len = 3;
    }

    return mrb_str_new(mrb, buf, len);
}

void
mrb_harucom_os_dict_gem_init(mrb_state *mrb)
{
    struct RClass *class_IM =
        mrb_define_class_id(mrb, MRB_SYM(InputMethod), mrb->object_class);

    mrb_define_class_method_id(mrb, class_IM, MRB_SYM_Q(dict_available),
                               mrb_im_dict_available, MRB_ARGS_NONE());
    mrb_define_class_method_id(mrb, class_IM, MRB_SYM(skk_lookup),
                               mrb_im_skk_lookup, MRB_ARGS_REQ(1));
    mrb_define_class_method_id(mrb, class_IM, MRB_SYM(tcode_lookup),
                               mrb_im_tcode_lookup, MRB_ARGS_REQ(2));
}

void
mrb_harucom_os_dict_gem_final(mrb_state *mrb)
{
    (void)mrb;
}
