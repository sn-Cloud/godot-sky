# Sky texture format

The runtime uses a 2D octahedral direction map instead of equirectangular projection,
so the shader avoids per-pixel `atan` and `asin` operations.

The four SVG files are lightweight placeholder assets for validating the renderer and
24-hour blending. Production assets will use denser keyframes and ASTC-compressed
raster textures after the visual direction is approved.
