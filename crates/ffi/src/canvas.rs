//! The GPU canvas on the app's `CAMetalLayer`: a wgpu surface, the document composited by
//! `photocraft_gpu` (the CPU compositor when the GPU can't) and drawn with the view.

use photocraft_doc::Document;
use photocraft_engine::Session;
use photocraft_geom::Rect;
use photocraft_gpu::viewport::{View, Viewport};

/// Display LUT size (per axis).
const LUT_SIZE: usize = 33;
/// GPU memory the compositor may keep for layer pages.
const COMPOSITOR_BUDGET: u64 = 768 << 20;
/// Default pasteboard colour around the document.
const BACKGROUND: wgpu::Color = wgpu::Color { r: 0.09, g: 0.09, b: 0.1, a: 1.0 };

pub struct Canvas {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    viewport: Viewport,
    /// The display signature the LUT was made for.
    display: Option<u64>,
    /// Pasteboard colour around the document.
    pub background: wgpu::Color,
}

impl Canvas {
    /// A canvas drawing into the `CAMetalLayer` at `layer`.
    ///
    /// The caller keeps the layer alive until [`Canvas`] is dropped.
    #[allow(unsafe_code)]
    pub fn new(layer: u64, width: u32, height: u32) -> Result<Self, String> {
        if layer == 0 {
            return Err("no Metal layer".into());
        }
        let instance =
            wgpu::Instance::new(wgpu::InstanceDescriptor { backends: wgpu::Backends::METAL, ..wgpu::InstanceDescriptor::new_without_display_handle() });
        // SAFETY: `layer` is a live CAMetalLayer the Swift view owns and keeps until it detaches
        // the canvas (which drops this surface first).
        let surface = unsafe { instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer as usize as *mut std::ffi::c_void)) }
            .map_err(|e| format!("can't draw on this view: {e}"))?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            ..Default::default()
        }))
        .map_err(|e| format!("no GPU: {e}"))?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("photocraft ios"),
            required_limits: adapter.limits(),
            ..Default::default()
        }))
        .map_err(|e| format!("the GPU didn't start: {e}"))?;
        let caps = surface.get_capabilities(&adapter);
        let format = [wgpu::TextureFormat::Bgra8Unorm, wgpu::TextureFormat::Rgba8Unorm]
            .into_iter()
            .find(|f| caps.formats.contains(f))
            .or_else(|| caps.formats.first().copied())
            .ok_or("the view has no drawable format")?;
        let mut config = surface.get_default_config(&adapter, width.max(1), height.max(1)).ok_or("the view can't be drawn on with this GPU")?;
        config.format = format;
        config.present_mode = wgpu::PresentMode::Fifo;
        config.alpha_mode = wgpu::CompositeAlphaMode::Opaque;
        config.desired_maximum_frame_latency = 2;
        surface.configure(&device, &config);
        let mut viewport = Viewport::new(&device, &queue, &adapter, format).map_err(|e| e.to_string())?;
        viewport.compositor_mut().set_memory_budget(COMPOSITOR_BUDGET);
        Ok(Self { surface, device, queue, config, viewport, display: None, background: BACKGROUND })
    }

    pub fn resize(&mut self, width: u32, height: u32) {
        let (w, h) = (width.max(1), height.max(1));
        if (w, h) != (self.config.width, self.config.height) {
            (self.config.width, self.config.height) = (w, h);
            self.surface.configure(&self.device, &self.config);
        }
    }

    pub fn holds(&self, doc: &Document) -> bool {
        self.viewport.holds(doc)
    }

    /// Bring the canvas up to date with `doc` inside `damage` (everything when `None`).
    pub fn refresh(&mut self, session: &Session, doc: &Document, damage: Option<Rect>) {
        let signature = session.color.display_signature(doc);
        let display = session.color.canvas_display(doc).ok();
        let damage = if self.display == Some(signature) { damage } else { None };
        if self.display != Some(signature) {
            let lut = session.color.gpu_canvas_lut(doc, LUT_SIZE).ok().flatten();
            self.viewport.set_display_lut(lut.as_deref().map(|b| (LUT_SIZE as u32, b)));
            self.display = Some(signature);
        }
        let encode_srgb = display.as_ref().is_some_and(|d| d.encode_srgb);
        if let Err(e) = self.viewport.refresh(doc, damage, encode_srgb) {
            log::warn!("GPU composite failed ({e}); using the CPU compositor");
            let rect = damage.map_or(doc.bounds(), |r| r.intersect(&doc.bounds()));
            let buf = photocraft_compose::render(doc, rect);
            let buf = match &display {
                Some(d) => d.texture_buffer(&buf).into_owned(),
                None => buf,
            };
            if let Err(e) = self.viewport.upload(doc, &buf) {
                log::warn!("canvas upload failed: {e}");
            }
        }
    }

    pub fn draw(&mut self, view: &View) {
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config);
                return;
            }
            _ => return,
        };
        let target = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let view = View { screen: [self.config.width, self.config.height], ..*view };
        self.viewport.draw(&target, &view, self.background);
        self.queue.present(frame);
    }
}
