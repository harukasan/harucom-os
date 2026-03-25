# Sandbox: filename in backtrace

When an application loaded via `Sandbox#load_file` raises an exception,
the backtrace does not include the source filename or line number.
This makes it difficult to locate the error in the source file.

## Root cause

`Sandbox#compile` (in `picoruby-sandbox/src/mruby/sandbox.c`) calls
`sandbox_compile_sub`, which creates a new `mrc_ccontext` but never
sets the filename on it:

```c
static mrb_bool
sandbox_compile_sub(mrb_state *mrb, SandboxState *ss,
                    const uint8_t *script, const size_t size,
                    mrb_value remove_lv)
{
  free_ccontext(ss);
  init_options(ss->options);
  ss->cc = mrc_ccontext_new(mrb);    // filename is NULL
  ss->cc->options = ss->options;
  ss->irep = mrc_load_string_cxt(ss->cc, ...);
  ...
}
```

The compiler context has a `filename` field and the API
`mrc_ccontext_filename(cc, path)` exists in mruby-compiler2.
Other tools (microruby, picoruby-eval) already call it before
compilation:

```c
// picoruby-eval/src/mruby/eval.c
cc = mrc_ccontext_new(mrb);
cc->lineno = (uint16_t)line;
mrc_ccontext_filename(cc, file);
```

## Proposed change (picoruby-sandbox)

Add a `filename` parameter to `Sandbox#compile` so that `load_file`
can pass the source path to the compiler.

### C layer (`picoruby-sandbox/src/mruby/sandbox.c`)

1. Add a `set_filename` method that calls `mrc_ccontext_filename`:

```c
static mrb_value
mrb_sandbox_set_filename(mrb_state *mrb, mrb_value self)
{
  SS();
  const char *filename;
  mrb_get_args(mrb, "z", &filename);
  if (ss->cc) {
    mrc_ccontext_filename(ss->cc, filename);
  }
  return mrb_nil_value();
}
```

2. Register it in `mrb_picoruby_sandbox_gem_init`:

```c
mrb_define_method_id(mrb, class_Sandbox, MRB_SYM(set_filename),
                     mrb_sandbox_set_filename, MRB_ARGS_REQ(1));
```

3. Call `mrc_ccontext_filename` inside `sandbox_compile_sub` if
   `ss->cc->filename` is already set (so it persists across
   recompilations), or let `set_filename` be called before `compile`.

### Ruby layer (`picoruby-sandbox/mrblib/sandbox.rb`)

Call `set_filename` before `compile` in `load_file`:

```ruby
def load_file(path, join: true)
  ...
  unless is_rite
    set_filename(path)       # <-- add this
    unless compile(rb)
      raise RuntimeError, "#{path}: compile failed"
    end
    execute
  end
  ...
end
```

### Expected result

After the change, exception backtraces will include the source
filename and line number:

```
/app/test.rb:12: undefined method 'foo' (NoMethodError)
```
