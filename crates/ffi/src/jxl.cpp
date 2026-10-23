// C wrapper over libjxl for jxl.rs.
//
// Decoding: every displayed frame, upright, at the image's depth (8-bit, 16-bit or float), with
// its colour profile. A still made of several layers comes back layer by layer (cropped, with
// its position, name and blend mode); an animation frame by frame, composited. CMYK (colour
// channels plus a Black extra channel) comes back as CMYK ink amounts. Extra channels other than
// the alpha and black (depth, masks, a second alpha…) come back by name for the first frame.
// EXIF and XMP boxes come back as they are.
//
// Encoding: one frame, gray/RGB/CMYK, 8-bit, 16-bit or float, optional alpha, an ICC profile,
// EXIF and XMP; lossless, or lossy at a distance; an effort.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "jxl/cms.h"
#include "jxl/decode.h"
#include "jxl/encode.h"
#include "jxl/resizable_parallel_runner.h"

namespace {

struct Frame {
  std::vector<unsigned char> pixels;
  std::vector<unsigned char> black;
  unsigned x0 = 0, y0 = 0, w = 0, h = 0;
  unsigned blend = 0;    // JxlBlendMode
  unsigned duration = 0; // milliseconds
  std::string name;
};

struct Extra {
  std::vector<unsigned char> pixels;
  std::string name;
  unsigned type = 0;
};

unsigned char *copy_out(const std::vector<unsigned char> &v) {
  if (v.empty()) return nullptr;
  auto *p = static_cast<unsigned char *>(std::malloc(v.size()));
  if (p) std::memcpy(p, v.data(), v.size());
  return p;
}

char *copy_str(const std::string &s) {
  auto *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

}  // namespace

extern "C" {

struct PcJxlFrame {
  unsigned char *data;  // w * h * channels samples
  unsigned int x0, y0, w, h;
  unsigned int blend;   // 0 replace, 1 add, 2 blend, 3 muladd, 4 mul
  unsigned int duration_ms;
  char *name;
};

struct PcJxlExtra {
  unsigned char *data;  // the first frame's w * h samples
  unsigned int type;    // JxlExtraChannelType
  char *name;
};

struct PcJxl {
  unsigned int width, height;  // the canvas, upright
  unsigned int channels;       // 1 gray, 2 gray + alpha, 3 RGB, 4 RGBA or CMYK, 5 CMYKA
  unsigned int cmyk;           // the colour is CMYK ink (0 none, 1 full)
  unsigned int bytes;          // 1 (u8), 2 (u16) or 4 (f32) a sample
  unsigned int animation;      // the frames are an animation, not layers
  unsigned int loops;          // 0: forever
  unsigned int frame_count;
  PcJxlFrame *frames;
  unsigned int extra_count;
  PcJxlExtra *extras;
  unsigned char *icc;
  size_t icc_len;
  unsigned char *exif;  // TIFF structure (the box's offset field skipped)
  size_t exif_len;
  unsigned char *xmp;
  size_t xmp_len;
};

void pc_jxl_free(void *p) { std::free(p); }

void pc_jxl_release(PcJxl *out) {
  for (unsigned i = 0; i < out->frame_count; i++) {
    std::free(out->frames[i].data);
    std::free(out->frames[i].name);
  }
  for (unsigned i = 0; i < out->extra_count; i++) {
    std::free(out->extras[i].data);
    std::free(out->extras[i].name);
  }
  std::free(out->frames);
  std::free(out->extras);
  std::free(out->icc);
  std::free(out->exif);
  std::free(out->xmp);
  std::memset(out, 0, sizeof *out);
}

// One decode. `want_layers`: keep a still's layers apart (cleared in `*exact` when a layer's
// blending has no exact match in a layered document); `original`: convert lossy files to the
// colour space they were made in.
static int decode_once(const void *data, size_t len, unsigned long long max_pixels, PcJxl *out, char *error, size_t error_len, bool want_layers, bool original, bool *exact) {
  std::memset(out, 0, sizeof *out);
  auto fail = [&](const char *msg) {
    std::snprintf(error, error_len, "%s", msg);
    return 1;
  };
  const auto *bytes = static_cast<const uint8_t *>(data);

  // A first look: layers are kept apart for stills, composited for animations (and for an
  // oriented still, where the decoder turns only the composite upright).
  JxlBasicInfo info{};
  {
    JxlDecoder *probe = JxlDecoderCreate(nullptr);
    if (!probe) return fail("out of memory");
    JxlDecoderSubscribeEvents(probe, JXL_DEC_BASIC_INFO);
    JxlDecoderSetInput(probe, bytes, len);
    JxlDecoderCloseInput(probe);
    JxlDecoderStatus s = JxlDecoderProcessInput(probe);
    bool ok = s == JXL_DEC_BASIC_INFO && JxlDecoderGetBasicInfo(probe, &info) == JXL_DEC_SUCCESS;
    JxlDecoderDestroy(probe);
    if (!ok) return fail(s == JXL_DEC_NEED_MORE_INPUT ? "the JPEG XL file is cut off" : "the JPEG XL data is malformed");
  }
  if (info.xsize == 0 || info.ysize == 0 || (unsigned long long)info.xsize * info.ysize > max_pixels) return fail("the image is too large");
  const bool layers = want_layers && !info.have_animation && info.orientation == JXL_ORIENT_IDENTITY;

  JxlDecoder *dec = JxlDecoderCreate(nullptr);
  if (!dec) return fail("out of memory");
  void *runner = JxlResizableParallelRunnerCreate(nullptr);
  struct Cleanup {
    JxlDecoder *dec;
    void *runner;
    ~Cleanup() {
      JxlDecoderDestroy(dec);
      if (runner) JxlResizableParallelRunnerDestroy(runner);
    }
  } cleanup{dec, runner};
  if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FRAME | JXL_DEC_FULL_IMAGE | JXL_DEC_BOX) != JXL_DEC_SUCCESS) return fail("decoder setup failed");
  if (runner) {
    JxlDecoderSetParallelRunner(dec, JxlResizableParallelRunner, runner);
    JxlResizableParallelRunnerSetThreads(runner, JxlResizableParallelRunnerSuggestThreads(info.xsize, info.ysize));
  }
  JxlDecoderSetCms(dec, *JxlGetDefaultCms());
  JxlDecoderSetUnpremultiplyAlpha(dec, JXL_TRUE);
  JxlDecoderSetCoalescing(dec, layers ? JXL_FALSE : JXL_TRUE);
  JxlDecoderSetDecompressBoxes(dec, JXL_TRUE);
  JxlDecoderSetInput(dec, bytes, len);
  JxlDecoderCloseInput(dec);

  // Set at the basic info: the main alpha and a Black make up the pixels; the rest are kept.
  int alpha_index = -1, black_index = -1;
  unsigned spots = 0;
  std::vector<unsigned> kept;
  bool cmyk = false;
  unsigned color = 0, has_alpha = 0, sample = 1;
  JxlPixelFormat format{}, one{};
  std::vector<Frame> frames;
  std::vector<Extra> extras;
  std::vector<unsigned char> icc, exif, xmp, box;
  std::string box_type;
  unsigned long long pixels_total = 0;
  JxlFrameHeader header{};
  std::string name;

  auto finish_box = [&]() {
    if (box_type.empty()) return;
    size_t left = JxlDecoderReleaseBoxBuffer(dec);
    box.resize(box.size() - left);
    if (box_type == "Exif" && box.size() > 4) {
      // A 4-byte offset to the TIFF header, then the TIFF structure.
      size_t off = 4 + ((size_t(box[0]) << 24) | (size_t(box[1]) << 16) | (size_t(box[2]) << 8) | box[3]);
      if (off < box.size()) exif.assign(box.begin() + off, box.end());
    } else if (box_type == "xml ") {
      xmp = box;
    }
    box_type.clear();
    box.clear();
  };

  for (;;) {
    JxlDecoderStatus status = JxlDecoderProcessInput(dec);
    if (status == JXL_DEC_ERROR) return fail("the JPEG XL data is malformed");
    if (status == JXL_DEC_NEED_MORE_INPUT) {
      if (!frames.empty()) break;  // trailing boxes cut off: the image is complete
      return fail("the JPEG XL file is cut off");
    }
    if (status == JXL_DEC_SUCCESS) {
      finish_box();
      break;
    }
    if (status == JXL_DEC_BASIC_INFO) {
      for (unsigned i = 0; i < info.num_extra_channels; i++) {
        JxlExtraChannelInfo ec{};
        if (JxlDecoderGetExtraChannelInfo(dec, i, &ec) != JXL_DEC_SUCCESS) continue;
        if (ec.type == JXL_CHANNEL_ALPHA && alpha_index < 0) {
          alpha_index = int(i);
        } else if (ec.type == JXL_CHANNEL_BLACK && black_index < 0) {
          black_index = int(i);
        } else if (ec.type == JXL_CHANNEL_SPOT_COLOR) {  // rendered into the colour
          spots++;
        } else {
          kept.push_back(i);
        }
      }
      // Spot colours are rendered only into the composite.
      if (layers && spots) {
        *exact = false;
        return fail("composite needed");
      }
      const bool gray = info.num_color_channels == 1;
      cmyk = black_index >= 0 && !gray;
      color = gray ? 1 : 3;
      has_alpha = alpha_index >= 0 ? 1 : 0;
      // Integers past 16 bits and floats of any size come back as 32-bit floats.
      const JxlDataType type = info.exponent_bits_per_sample || info.bits_per_sample > 16 ? JXL_TYPE_FLOAT : info.bits_per_sample > 8 ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
      sample = type == JXL_TYPE_FLOAT ? 4 : type == JXL_TYPE_UINT16 ? 2 : 1;
      format = {color + has_alpha, type, JXL_NATIVE_ENDIAN, 0};
      one = {1, type, JXL_NATIVE_ENDIAN, 0};
    } else if (status == JXL_DEC_BOX) {
      finish_box();
      JxlBoxType t;
      if (JxlDecoderGetBoxType(dec, t, JXL_TRUE) == JXL_DEC_SUCCESS) {
        std::string s(t, 4);
        if (s == "Exif" || s == "xml ") {
          box_type = s;
          box.resize(1 << 16);
          JxlDecoderSetBoxBuffer(dec, box.data(), box.size());
        }
      }
    } else if (status == JXL_DEC_BOX_NEED_MORE_OUTPUT) {
      size_t left = JxlDecoderReleaseBoxBuffer(dec);
      size_t used = box.size() - left;
      if (box.size() > (64u << 20)) return fail("a metadata box is too large");
      box.resize(box.size() * 2);
      JxlDecoderSetBoxBuffer(dec, box.data() + used, box.size() - used);
    } else if (status == JXL_DEC_COLOR_ENCODING) {
      // Lossy (XYB) files: back to the colour space they were made in, not linear sRGB; by its
      // enumerated encoding when it has one, else its ICC profile.
      size_t n = 0;
      if (original && !info.uses_original_profile) {
        JxlColorEncoding enc;
        if (JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &enc) == JXL_DEC_SUCCESS) {
          JxlDecoderSetOutputColorProfile(dec, &enc, nullptr, 0);
        } else if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, &n) == JXL_DEC_SUCCESS && n) {
          std::vector<uint8_t> icc_original(n);
          if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_ORIGINAL, icc_original.data(), n) == JXL_DEC_SUCCESS) {
            JxlDecoderSetOutputColorProfile(dec, nullptr, icc_original.data(), n);
          }
        }
      }
      if (JxlDecoderGetICCProfileSize(dec, JXL_COLOR_PROFILE_TARGET_DATA, &n) == JXL_DEC_SUCCESS && n) {
        icc.resize(n);
        if (JxlDecoderGetColorAsICCProfile(dec, JXL_COLOR_PROFILE_TARGET_DATA, icc.data(), n) != JXL_DEC_SUCCESS) icc.clear();
      }
    } else if (status == JXL_DEC_FRAME) {
      if (JxlDecoderGetFrameHeader(dec, &header) != JXL_DEC_SUCCESS) return fail("unreadable frame header");
      name.assign(header.name_length, '\0');
      if (header.name_length) JxlDecoderGetFrameName(dec, name.data(), header.name_length + 1);
      // A layered document matches plain alpha blending onto what is below, and replacing only for
      // the bottom layer or an opaque one.
      if (layers) {
        const JxlBlendInfo &b = header.layer_info.blend_info;
        bool plain = b.blendmode == JXL_BLEND_BLEND && b.alpha == unsigned(std::max(alpha_index, 0));
        bool replace = b.blendmode == JXL_BLEND_REPLACE && (frames.empty() || alpha_index < 0);
        if (!(plain || replace) || (b.source != 0 && !frames.empty())) {
          *exact = false;
          return fail("composite needed");
        }
      }
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      Frame f;
      const JxlLayerInfo &l = header.layer_info;
      bool crop = layers && l.have_crop;
      f.w = layers ? l.xsize : (info.orientation >= JXL_ORIENT_TRANSPOSE ? info.ysize : info.xsize);
      f.h = layers ? l.ysize : (info.orientation >= JXL_ORIENT_TRANSPOSE ? info.xsize : info.ysize);
      f.x0 = crop ? unsigned(std::max(0, l.crop_x0)) : 0;
      f.y0 = crop ? unsigned(std::max(0, l.crop_y0)) : 0;
      f.blend = layers ? unsigned(l.blend_info.blendmode) : JXL_BLEND_REPLACE;
      if (info.have_animation && info.animation.tps_numerator) {
        f.duration = unsigned((unsigned long long)header.duration * 1000 * info.animation.tps_denominator / info.animation.tps_numerator);
      }
      f.name = name;
      pixels_total += (unsigned long long)f.w * f.h;
      if (pixels_total > max_pixels * 4) return fail("too many frames or layers");
      size_t n = 0;
      if (JxlDecoderImageOutBufferSize(dec, &format, &n) != JXL_DEC_SUCCESS) return fail("no output size");
      try {
        f.pixels.resize(n);
        if (cmyk) f.black.resize(size_t(f.w) * f.h * sample);
        if (frames.empty()) {
          for (size_t k = 0; k < kept.size(); k++) {
            Extra e;
            e.pixels.resize(size_t(f.w) * f.h * sample);
            extras.push_back(std::move(e));
          }
        }
      } catch (...) {
        return fail("out of memory");
      }
      frames.push_back(std::move(f));
      Frame &cur = frames.back();
      if (JxlDecoderSetImageOutBuffer(dec, &format, cur.pixels.data(), cur.pixels.size()) != JXL_DEC_SUCCESS) return fail("output setup failed");
      if (cmyk && JxlDecoderSetExtraChannelBuffer(dec, &one, cur.black.data(), cur.black.size(), unsigned(black_index)) != JXL_DEC_SUCCESS) return fail("output setup failed");
      if (frames.size() == 1) {
        for (size_t k = 0; k < kept.size(); k++) {
          JxlExtraChannelInfo ec{};
          JxlDecoderGetExtraChannelInfo(dec, kept[k], &ec);
          extras[k].type = unsigned(ec.type);
          std::string n(ec.name_length, '\0');
          if (ec.name_length) JxlDecoderGetExtraChannelName(dec, kept[k], n.data(), ec.name_length + 1);
          extras[k].name = n;
          JxlDecoderSetExtraChannelBuffer(dec, &one, extras[k].pixels.data(), extras[k].pixels.size(), kept[k]);
        }
      }
    } else if (status == JXL_DEC_FULL_IMAGE) {
      // Keep going for the next frame and the metadata boxes after the image.
    }
  }
  if (frames.empty()) return fail("the JPEG XL file holds no image");

  // CMYK: C, M and Y with K after them (and the alpha last), as ink amounts.
  const unsigned channels = cmyk ? 4 + has_alpha : color + has_alpha;
  if (cmyk) {
    for (Frame &f : frames) {
      size_t px = size_t(f.w) * f.h;
      std::vector<unsigned char> joined;
      try {
        joined.resize(px * channels * sample);
      } catch (...) {
        return fail("out of memory");
      }
      for (size_t i = 0; i < px; i++) {
        unsigned char *d = &joined[i * channels * sample];
        const unsigned char *s = &f.pixels[i * (3 + has_alpha) * sample];
        std::memcpy(d, s, 3 * sample);
        std::memcpy(d + 3 * sample, &f.black[i * sample], sample);
        if (has_alpha) std::memcpy(d + 4 * sample, s + 3 * sample, sample);
        for (unsigned k = 0; k < 4; k++) {  // stored as 0 = full ink
          unsigned char *v = d + k * sample;
          if (sample == 1) {
            *v = 255 - *v;
          } else if (sample == 2) {
            uint16_t x;
            std::memcpy(&x, v, 2);
            x = 65535 - x;
            std::memcpy(v, &x, 2);
          } else {
            float x;
            std::memcpy(&x, v, 4);
            x = 1.0f - x;
            std::memcpy(v, &x, 4);
          }
        }
      }
      f.pixels.swap(joined);
      f.black.clear();
    }
  }

  out->width = info.orientation >= JXL_ORIENT_TRANSPOSE ? info.ysize : info.xsize;
  out->height = info.orientation >= JXL_ORIENT_TRANSPOSE ? info.xsize : info.ysize;
  out->channels = channels;
  out->cmyk = cmyk ? 1 : 0;
  out->bytes = sample;
  out->animation = info.have_animation ? 1 : 0;
  out->loops = info.have_animation ? info.animation.num_loops : 0;
  out->frames = static_cast<PcJxlFrame *>(std::calloc(frames.size(), sizeof(PcJxlFrame)));
  out->extras = extras.empty() ? nullptr : static_cast<PcJxlExtra *>(std::calloc(extras.size(), sizeof(PcJxlExtra)));
  if (!out->frames || (!extras.empty() && !out->extras)) {
    pc_jxl_release(out);
    return fail("out of memory");
  }
  for (const Frame &f : frames) {
    PcJxlFrame &o = out->frames[out->frame_count++];
    o = {copy_out(f.pixels), f.x0, f.y0, f.w, f.h, f.blend, f.duration, copy_str(f.name)};
    if (!o.data || !o.name) {
      pc_jxl_release(out);
      return fail("out of memory");
    }
  }
  for (const Extra &e : extras) {
    PcJxlExtra &o = out->extras[out->extra_count++];
    o = {copy_out(e.pixels), e.type, copy_str(e.name)};
    if (!o.data || !o.name) {
      pc_jxl_release(out);
      return fail("out of memory");
    }
  }
  out->icc = copy_out(icc);
  out->icc_len = out->icc ? icc.size() : 0;
  out->exif = copy_out(exif);
  out->exif_len = out->exif ? exif.size() : 0;
  out->xmp = copy_out(xmp);
  out->xmp_len = out->xmp ? xmp.size() : 0;
  return 0;
}

// 0 on success; otherwise 1 with a message in `error`. `max_pixels` caps width × height (and the
// sum over frames). Layers stay apart when that is exact, else the image comes composited; a lossy
// file whose original colour space the decoder can't convert to comes in its default space.
int pc_jxl_decode(const void *data, size_t len, unsigned long long max_pixels, PcJxl *out, char *error, size_t error_len) {
  for (bool layers : {true, false}) {
    for (bool original : {true, false}) {
      bool exact = true;
      int rc = decode_once(data, len, max_pixels, out, error, error_len, layers, original, &exact);
      if (rc == 0) return 0;
      if (!exact) break;  // composite instead
    }
  }
  return 1;
}

struct PcJxlLayer {
  const void *pixels;  // w * h * channels samples
  unsigned int x0, y0, w, h;
  const char *name;
};

struct PcJxlChannel {
  const void *pixels;  // width * height samples of the image's `bytes`
  const char *name;
};

struct PcJxlEncode {
  const void *pixels;  // width * height * channels samples of `bytes` each, native order
  const PcJxlChannel *extras;  // named extra channels (a document's alpha channels), whole image only
  unsigned int extra_count;
  const PcJxlLayer *layers;  // when `layer_count` > 0: these, blended in order, instead of `pixels`
  unsigned int layer_count;
  unsigned int width, height;
  unsigned int channels;  // as PcJxl: 1, 2, 3, 4 (RGBA, or CMYK when `cmyk`), 5 (CMYKA)
  unsigned int cmyk;      // the colour is CMYK ink (0 none, 1 full)
  unsigned int bytes;     // 1, 2 or 4 (f32)
  const unsigned char *icc;
  size_t icc_len;
  const unsigned char *exif;  // TIFF structure
  size_t exif_len;
  const unsigned char *xmp;
  size_t xmp_len;
  unsigned int lossless;
  float quality;  // lossy: 0 … 100
  unsigned int effort;  // 1 … 10
};

// 0 on success with the file in `*out` (`*out_len` bytes, freed with pc_jxl_free).
int pc_jxl_encode(const PcJxlEncode *in, unsigned char **out, size_t *out_len, char *error, size_t error_len) {
  auto fail = [&](const char *msg) {
    std::snprintf(error, error_len, "%s", msg);
    return 1;
  };
  const bool cmyk = in->cmyk != 0;
  const unsigned color = cmyk ? 3 : (in->channels <= 2 ? 1 : 3);
  const unsigned alpha = in->channels - color - (cmyk ? 1 : 0);
  if (alpha > 1 || (cmyk && in->icc_len == 0)) return fail("unsupported channel layout");
  const JxlDataType type = in->bytes == 4 ? JXL_TYPE_FLOAT : in->bytes == 2 ? JXL_TYPE_UINT16 : JXL_TYPE_UINT8;
  const size_t sample = in->bytes;

  JxlEncoder *enc = JxlEncoderCreate(nullptr);
  if (!enc) return fail("out of memory");
  void *runner = JxlResizableParallelRunnerCreate(nullptr);
  struct Cleanup {
    JxlEncoder *enc;
    void *runner;
    ~Cleanup() {
      JxlEncoderDestroy(enc);
      if (runner) JxlResizableParallelRunnerDestroy(runner);
    }
  } cleanup{enc, runner};
  if (runner) {
    JxlEncoderSetParallelRunner(enc, JxlResizableParallelRunner, runner);
    JxlResizableParallelRunnerSetThreads(runner, JxlResizableParallelRunnerSuggestThreads(in->width, in->height));
  }
  // Level 10 allows CMYK and more than 16 bits a sample.
  if (cmyk || in->bytes == 4) JxlEncoderSetCodestreamLevel(enc, 10);
  JxlEncoderUseBoxes(enc);

  JxlBasicInfo info;
  JxlEncoderInitBasicInfo(&info);
  info.xsize = in->width;
  info.ysize = in->height;
  info.bits_per_sample = in->bytes == 4 ? 32 : in->bytes * 8;
  info.exponent_bits_per_sample = in->bytes == 4 ? 8 : 0;
  info.num_color_channels = color;
  const unsigned extras = in->layer_count ? 0 : in->extra_count;
  info.num_extra_channels = alpha + (cmyk ? 1 : 0) + extras;
  info.alpha_bits = alpha ? info.bits_per_sample : 0;
  info.alpha_exponent_bits = alpha ? info.exponent_bits_per_sample : 0;
  info.uses_original_profile = in->lossless ? JXL_TRUE : JXL_FALSE;
  if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) return fail("the encoder refused the image header");
  if (cmyk) {
    JxlExtraChannelInfo k;
    JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_BLACK, &k);
    k.bits_per_sample = info.bits_per_sample;
    k.exponent_bits_per_sample = info.exponent_bits_per_sample;
    if (JxlEncoderSetExtraChannelInfo(enc, alpha, &k) != JXL_ENC_SUCCESS) return fail("the encoder refused the black channel");
    JxlEncoderSetExtraChannelName(enc, alpha, "Black", 5);
  }
  // Extra channels after the alpha and black, as selection masks with their names.
  const unsigned first_extra = alpha + (cmyk ? 1 : 0);
  for (unsigned e = 0; e < extras; e++) {
    JxlExtraChannelInfo x;
    JxlEncoderInitExtraChannelInfo(JXL_CHANNEL_SELECTION_MASK, &x);
    x.bits_per_sample = info.bits_per_sample;
    x.exponent_bits_per_sample = info.exponent_bits_per_sample;
    if (JxlEncoderSetExtraChannelInfo(enc, first_extra + e, &x) != JXL_ENC_SUCCESS) return fail("the encoder refused an extra channel");
    const char *n = in->extras[e].name ? in->extras[e].name : "";
    JxlEncoderSetExtraChannelName(enc, first_extra + e, n, std::strlen(n));
  }
  if (in->icc_len) {
    if (JxlEncoderSetICCProfile(enc, in->icc, in->icc_len) != JXL_ENC_SUCCESS) return fail("the encoder refused the colour profile");
  } else {
    JxlColorEncoding c;
    JxlColorEncodingSetToSRGB(&c, color == 1 ? JXL_TRUE : JXL_FALSE);
    JxlEncoderSetColorEncoding(enc, &c);
  }
  if (in->exif_len) {
    std::vector<unsigned char> b(4 + in->exif_len, 0);  // offset 0: the TIFF header comes first
    std::memcpy(b.data() + 4, in->exif, in->exif_len);
    JxlEncoderAddBox(enc, "Exif", b.data(), b.size(), JXL_FALSE);
  }
  if (in->xmp_len) JxlEncoderAddBox(enc, "xml ", in->xmp, in->xmp_len, JXL_FALSE);
  JxlEncoderCloseBoxes(enc);

  JxlEncoderFrameSettings *fs = JxlEncoderFrameSettingsCreate(enc, nullptr);
  JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_EFFORT, in->effort < 1 ? 1 : in->effort > 10 ? 10 : in->effort);
  if (in->lossless) {
    JxlEncoderSetFrameLossless(fs, JXL_TRUE);
  } else {
    JxlEncoderSetFrameDistance(fs, JxlEncoderDistanceFromQuality(in->quality));
  }

  // One frame per layer (or the one image): the colour (and alpha) interleaved, the black apart;
  // CMYK stored as 0 = full ink.
  const unsigned main = color + alpha;
  auto invert = [&](unsigned char *v) {
    if (sample == 1) {
      *v = 255 - *v;
    } else if (sample == 2) {
      uint16_t x;
      std::memcpy(&x, v, 2);
      x = 65535 - x;
      std::memcpy(v, &x, 2);
    } else {
      float x;
      std::memcpy(&x, v, 4);
      x = 1.0f - x;
      std::memcpy(v, &x, 4);
    }
  };
  const PcJxlLayer whole{in->pixels, 0, 0, in->width, in->height, nullptr};
  const unsigned count = in->layer_count ? in->layer_count : 1;
  for (unsigned f = 0; f < count; f++) {
    const PcJxlLayer &l = in->layer_count ? in->layers[f] : whole;
    if (in->layer_count) {
      JxlFrameHeader h;
      JxlEncoderInitFrameHeader(&h);
      h.layer_info.have_crop = JXL_TRUE;
      h.layer_info.crop_x0 = int32_t(l.x0);
      h.layer_info.crop_y0 = int32_t(l.y0);
      h.layer_info.xsize = l.w;
      h.layer_info.ysize = l.h;
      h.layer_info.blend_info.blendmode = f == 0 ? JXL_BLEND_REPLACE : JXL_BLEND_BLEND;
      if (JxlEncoderSetFrameHeader(fs, &h) != JXL_ENC_SUCCESS) return fail("the encoder refused a layer");
      if (l.name) JxlEncoderSetFrameName(fs, l.name);
    }
    const size_t lpx = size_t(l.w) * l.h;
    std::vector<unsigned char> main_px, black;
    try {
      main_px.resize(lpx * main * sample);
      if (cmyk) black.resize(lpx * sample);
    } catch (...) {
      return fail("out of memory");
    }
    const auto *src = static_cast<const unsigned char *>(l.pixels);
    for (size_t i = 0; i < lpx; i++) {
      const unsigned char *s = src + i * in->channels * sample;
      unsigned char *d = &main_px[i * main * sample];
      if (cmyk) {
        std::memcpy(d, s, 3 * sample);
        std::memcpy(&black[i * sample], s + 3 * sample, sample);
        if (alpha) std::memcpy(d + 3 * sample, s + 4 * sample, sample);
        for (unsigned k = 0; k < 3; k++) invert(d + k * sample);
        invert(&black[i * sample]);
      } else {
        std::memcpy(d, s, main * sample);
      }
    }
    const JxlPixelFormat format{main, type, JXL_NATIVE_ENDIAN, 0};
    if (JxlEncoderAddImageFrame(fs, &format, main_px.data(), main_px.size()) != JXL_ENC_SUCCESS) return fail("the encoder refused the pixels");
    const JxlPixelFormat one{1, type, JXL_NATIVE_ENDIAN, 0};
    if (cmyk && JxlEncoderSetExtraChannelBuffer(fs, &one, black.data(), black.size(), alpha) != JXL_ENC_SUCCESS) return fail("the encoder refused the black channel");
    for (unsigned e = 0; e < extras; e++) {
      if (JxlEncoderSetExtraChannelBuffer(fs, &one, in->extras[e].pixels, lpx * sample, first_extra + e) != JXL_ENC_SUCCESS) return fail("the encoder refused an extra channel");
    }
  }
  JxlEncoderCloseInput(enc);

  std::vector<unsigned char> file(1 << 16);
  uint8_t *next = file.data();
  size_t avail = file.size();
  for (;;) {
    JxlEncoderStatus s = JxlEncoderProcessOutput(enc, &next, &avail);
    if (s == JXL_ENC_SUCCESS) break;
    if (s != JXL_ENC_NEED_MORE_OUTPUT) return fail("encoding failed");
    size_t used = next - file.data();
    file.resize(file.size() * 2);
    next = file.data() + used;
    avail = file.size() - used;
  }
  file.resize(next - file.data());
  *out = copy_out(file);
  *out_len = file.size();
  return *out ? 0 : fail("out of memory");
}
}
