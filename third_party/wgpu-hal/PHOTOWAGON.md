# wgpu-hal 30.0.1, patched

From crates.io (MIT OR Apache-2.0, licence files kept). One change, in `src/metal/adapter.rs`:
the Metal backend asks for Metal Shading Language 4.0 only when the GPU is in the Metal 4 family,
not on every device running iOS 26 or later. Older GPUs get 3.2. Drop this copy when upstream does
the same.
