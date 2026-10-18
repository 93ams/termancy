# Regenerates the JPEG test images and their reference pixels (image.zig's JPEG tests):
#   uv run --python 3.12 --with pillow --with opencv-python-headless python make.py
# OpenCV (libjpeg-turbo) encodes the sampling, restart, and progressive variants; Pillow
# the CMYK and EXIF ones. Pillow (libjpeg-turbo, default fancy upsampling and islow IDCT)
# decodes every file to `<name>.rgb`: raw 8-bit RGB, rows top to bottom, EXIF applied.
import os, cv2, numpy as np
from PIL import Image, ImageOps

here = os.path.dirname(os.path.abspath(__file__))


def pattern(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    r = 255 * x / max(1, w - 1)
    g = 255 * y / max(1, h - 1)
    b = 128 + 100 * np.sin(x / 3) * np.cos(y / 4)
    disc = (x - w * 0.6) ** 2 + (y - h * 0.4) ** 2 < (min(w, h) * 0.3) ** 2
    r[disc], g[disc], b[disc] = 230, 40, 200
    rgb = np.clip(np.stack([r, g, b], -1), 0, 255).astype(np.uint8)
    return rgb


def cv(name, w, h, *params, gray=False):
    rgb = pattern(w, h)
    img = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY) if gray else rgb[:, :, ::-1]
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 90, *params])
    assert ok
    open(os.path.join(here, name + ".jpg"), "wb").write(buf.tobytes())


S = cv2.IMWRITE_JPEG_SAMPLING_FACTOR
cv("rgb_16x16_420", 16, 16, S, cv2.IMWRITE_JPEG_SAMPLING_FACTOR_420)
for f in ["444", "422", "420", "411", "440"]:
    cv("rgb_33x17_" + f, 33, 17, S, getattr(cv2, "IMWRITE_JPEG_SAMPLING_FACTOR_" + f))
cv("gray_33x17", 33, 17, gray=True)
cv("prog_33x17_420", 33, 17, S, cv2.IMWRITE_JPEG_SAMPLING_FACTOR_420,
   cv2.IMWRITE_JPEG_PROGRESSIVE, 1)
cv("rst_33x17_420", 33, 17, S, cv2.IMWRITE_JPEG_SAMPLING_FACTOR_420,
   cv2.IMWRITE_JPEG_RST_INTERVAL, 2)
cv("prog_rst_33x17_444", 33, 17, S, cv2.IMWRITE_JPEG_SAMPLING_FACTOR_444,
   cv2.IMWRITE_JPEG_PROGRESSIVE, 1, cv2.IMWRITE_JPEG_RST_INTERVAL, 1)
Image.fromarray(pattern(16, 16)).convert("CMYK").save(
    os.path.join(here, "cmyk_16x16.jpg"), quality=90)
exif = Image.Exif()
exif[0x0112] = 6  # orientation: rotate 90 degrees clockwise to show
Image.fromarray(pattern(16, 8)).save(
    os.path.join(here, "exif6_16x8.jpg"), quality=90, exif=exif)

for f in sorted(os.listdir(here)):
    if f.endswith(".jpg"):
        img = ImageOps.exif_transpose(Image.open(os.path.join(here, f))).convert("RGB")
        open(os.path.join(here, f[:-4] + ".rgb"), "wb").write(img.tobytes())
        print(f, img.size)
