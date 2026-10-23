// C wrapper over LibRaw for libraw.rs: develops a raw file to 16-bit ProPhoto RGB.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

#include "libraw/libraw.h"

extern "C" {

struct PcRaw {
  unsigned short *rgb; // width * height * 3, freed with pc_libraw_free
  unsigned int width;
  unsigned int height;
  char make[64];
  char model[64];
};

// 0 on success; otherwise a LibRaw error code with its message in `error`.
int pc_libraw_develop(const void *data, size_t len, PcRaw *out, char *error, size_t error_len) {
  int rc = LIBRAW_UNSPECIFIED_ERROR;
  LibRaw *raw = new (std::nothrow) LibRaw();
  if (!raw) {
    std::snprintf(error, error_len, "out of memory");
    return rc;
  }
  try {
    libraw_output_params_t &p = raw->imgdata.params;
    p.output_bps = 16;
    p.output_color = 4; // ProPhoto
    p.gamm[0] = 1 / 1.8; // ProPhoto's gamma 1.8, no linear toe
    p.gamm[1] = 0;
    p.use_camera_wb = 1;
    rc = raw->open_buffer(data, len);
    if (rc == LIBRAW_SUCCESS) rc = raw->unpack();
    // X-Trans: one demosaic pass, not three (about half the time).
    if (rc == LIBRAW_SUCCESS && raw->imgdata.idata.filters == 9) p.user_qual = 2;
    if (rc == LIBRAW_SUCCESS) rc = raw->dcraw_process();
    libraw_processed_image_t *img = nullptr;
    if (rc == LIBRAW_SUCCESS) img = raw->dcraw_make_mem_image(&rc);
    if (img && (img->type != LIBRAW_IMAGE_BITMAP || img->colors != 3 || img->bits != 16)) {
      rc = LIBRAW_UNSPECIFIED_ERROR;
    }
    if (rc == LIBRAW_SUCCESS && img) {
      size_t n = size_t(img->width) * img->height * 3;
      out->rgb = static_cast<unsigned short *>(std::malloc(n * sizeof(unsigned short)));
      if (!out->rgb) {
        rc = LIBRAW_UNSUFFICIENT_MEMORY;
      } else {
        std::memcpy(out->rgb, img->data, n * sizeof(unsigned short));
        out->width = img->width;
        out->height = img->height;
        std::snprintf(out->make, sizeof out->make, "%s", raw->imgdata.idata.make);
        std::snprintf(out->model, sizeof out->model, "%s", raw->imgdata.idata.model);
      }
    }
    if (img) LibRaw::dcraw_clear_mem(img);
  } catch (...) {
    rc = LIBRAW_UNSPECIFIED_ERROR;
  }
  if (rc != LIBRAW_SUCCESS) std::snprintf(error, error_len, "%s", LibRaw::strerror(rc));
  delete raw;
  return rc;
}

struct PcRawData {
  unsigned short *data; // width * height * channels, freed with pc_libraw_free
  unsigned int width;   // the stored (raw) size, margins included
  unsigned int height;
  unsigned int channels; // 1 for a mosaic, 3 or 4 for linear raws
  unsigned int black;
  unsigned int maximum;
};

// The unpacked sensor values (no processing), for comparing decoders. 0 on success.
int pc_libraw_raw(const void *data, size_t len, PcRawData *out, char *error, size_t error_len) {
  int rc = LIBRAW_UNSPECIFIED_ERROR;
  LibRaw *raw = new (std::nothrow) LibRaw();
  if (!raw) {
    std::snprintf(error, error_len, "out of memory");
    return rc;
  }
  try {
    rc = raw->open_buffer(data, len);
    if (rc == LIBRAW_SUCCESS) rc = raw->unpack();
    if (rc == LIBRAW_SUCCESS) {
      libraw_rawdata_t &rd = raw->imgdata.rawdata;
      unsigned w = raw->imgdata.sizes.raw_width, h = raw->imgdata.sizes.raw_height;
      unsigned ch = rd.raw_image ? 1 : rd.color3_image ? 3 : rd.color4_image ? 4 : 0;
      size_t pitch = raw->imgdata.sizes.raw_pitch / sizeof(unsigned short);
      if (!ch) {
        rc = LIBRAW_UNSPECIFIED_ERROR;
        std::snprintf(error, error_len, "no integer raw data (floating point?)");
        delete raw;
        return rc;
      }
      out->data = static_cast<unsigned short *>(std::malloc(size_t(w) * h * ch * sizeof(unsigned short)));
      if (!out->data) {
        rc = LIBRAW_UNSUFFICIENT_MEMORY;
      } else {
        const unsigned short *src = rd.raw_image ? rd.raw_image : rd.color3_image ? &rd.color3_image[0][0] : &rd.color4_image[0][0];
        for (unsigned y = 0; y < h; y++) std::memcpy(out->data + size_t(y) * w * ch, src + y * pitch, size_t(w) * ch * sizeof(unsigned short));
        out->width = w;
        out->height = h;
        out->channels = ch;
        out->black = raw->imgdata.color.black;
        out->maximum = raw->imgdata.color.maximum;
      }
    }
  } catch (...) {
    rc = LIBRAW_UNSPECIFIED_ERROR;
  }
  if (rc != LIBRAW_SUCCESS) std::snprintf(error, error_len, "%s", LibRaw::strerror(rc));
  delete raw;
  return rc;
}

void pc_libraw_free(unsigned short *rgb) { std::free(rgb); }
}
