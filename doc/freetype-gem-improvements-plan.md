# freetype gem Improvement Plan

The [freetype gem][gem] (v0.0.6) wraps libfreetype via FFI. It provides basic
font loading and outline access but lacks bitmap rendering support, which
forced us to access FFI structs directly in ttf2c.rb. Below are concrete
improvement areas with proposed API changes.

[gem]: https://github.com/ksss/freetype

## Missing: Bitmap Rendering Support

`Font#load_char` always uses `FT_LOAD_DEFAULT`, which loads outlines only.
There is no way to request monochrome bitmap rendering (`FT_LOAD_RENDER |
FT_LOAD_TARGET_MONO`).

### Proposed Changes

**Font#load_char**: accept a `load_flags` parameter.

```ruby
def load_char(char, load_flags = FT_LOAD_DEFAULT)
  err = FT_Load_Char(@face, char.ord, load_flags)
  ...
end
```

**Font#glyph**: accept optional `load_flags` and pass them through.

```ruby
def glyph(char, load_flags = FT_LOAD_DEFAULT)
  load_char(char, load_flags)
  Glyph.new(@face[:glyph])
end
```

**Expose `FT_LOAD_RENDER` and `FT_LOAD_TARGET_MONO`**: these constants
exist in `c.rb` but `FT_LOAD_TARGET_MONO` (`(1 << 16) | FT_LOAD_RENDER`)
is missing.

```ruby
FT_LOAD_TARGET_MONO = (1 << 16) | FT_LOAD_RENDER  # currently missing
```

## Missing: Glyph Bitmap Accessors

`Glyph` wraps `FT_GlyphSlotRec` but only exposes `metrics`, `outline`,
`char_width`, `bold`, and `oblique`. After rendering, the bitmap data in
`bitmap`, `bitmap_left`, and `bitmap_top` fields are only accessible via
the raw FFI struct (`glyph[:bitmap]`, `glyph[:bitmap_left]`).

### Proposed Changes

```ruby
class Glyph
  def bitmap
    @glyph[:bitmap]
  end

  def bitmap_left
    @glyph[:bitmap_left]
  end

  def bitmap_top
    @glyph[:bitmap_top]
  end

  def advance_x
    @glyph[:advance][:x] >> 6
  end

  def advance_y
    @glyph[:advance][:y] >> 6
  end
end
```

## Missing: FT_Set_Pixel_Sizes

The gem only exposes `FT_Set_Char_Size` (point size + DPI). For pixel
fonts, `FT_Set_Pixel_Sizes` is more natural and avoids the `size * 64`
conversion with a 72 DPI workaround.

### Proposed Changes

Add the FFI binding and a `Font#set_pixel_sizes` method:

```ruby
# c.rb
attach_function :FT_Set_Pixel_Sizes, [:pointer, :uint, :uint], :FT_Error

# api.rb
def set_pixel_sizes(width, height)
  err = FT_Set_Pixel_Sizes(@face, width, height)
  raise FreeType::Error.find(err) unless err == 0
end
```

## Missing: Character Map Enumeration

`FT_Get_First_Char` and `FT_Get_Next_Char` are not bound, so there is
no way to enumerate all characters in a font. Our ttf2c.rb works around
this by trying to load known codepoints and checking for errors.

### Proposed Changes

```ruby
# c.rb
attach_function :FT_Get_First_Char, [:pointer, :pointer], :ulong
attach_function :FT_Get_Next_Char, [:pointer, :ulong, :pointer], :ulong

# api.rb
def each_char
  return enum_for(:each_char) unless block_given?
  gindex = FFI::MemoryPointer.new(:uint)
  charcode = FT_Get_First_Char(@face, gindex)
  while gindex.get_uint(0) != 0
    yield charcode, gindex.get_uint(0)
    charcode = FT_Get_Next_Char(@face, charcode, gindex)
  end
end
```

## Minor: FT_Bitmap Wrapper

`FT_Bitmap` is an FFI struct with no Ruby convenience methods. Accessing
bitmap pixels requires manual pointer arithmetic
(`buf.get_uint8(y * pitch + x / 8)` with bit masking).

### Proposed Changes

```ruby
class Bitmap
  def initialize(ft_bitmap)
    @bm = ft_bitmap
  end

  def width;  @bm[:width]; end
  def rows;   @bm[:rows]; end
  def pitch;  @bm[:pitch]; end

  # Iterate pixels for monochrome bitmaps (pixel_mode == 1).
  def each_pixel
    return enum_for(:each_pixel) unless block_given?
    buf = @bm[:buffer]
    @bm[:rows].times do |y|
      @bm[:width].times do |x|
        byte = buf.get_uint8(y * @bm[:pitch] + x / 8)
        bit = (byte >> (7 - x % 8)) & 1
        yield x, y, bit
      end
    end
  end
end
```

## Summary

| Area | Status | Impact |
|------|--------|--------|
| Bitmap rendering (load_flags) | Missing | Must use raw FFI |
| Glyph bitmap accessors | Missing | Must use raw FFI |
| FT_Set_Pixel_Sizes | Missing | Workaround with 26.6 fixed point |
| Character enumeration | Missing | Must try known codepoints |
| FT_Bitmap wrapper | Missing | Manual pointer arithmetic |
| FT_LOAD_TARGET_MONO constant | Missing | Must compute manually |
