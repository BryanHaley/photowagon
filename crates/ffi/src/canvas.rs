//! The GPU canvas on the app's `CAMetalLayer`: a wgpu surface, the document composited by
//! `photocraft_gpu` (the CPU compositor when the GPU can't) and drawn with the view.

use photocraft_doc::Document;
use photocraft_engine::Session;
use photocraft_geom::Rect;
use photocraft_gpu::DeviceHealth;
use photocraft_gpu::viewport::{View, Viewport};

/// Display LUT size (per axis).
const LUT_SIZE: usize = 33;
/// GPU memory the compositor may keep for layer pages.
const COMPOSITOR_BUDGET: u64 = 768 << 20;
/// Default pasteboard colour around the document.
const BACKGROUND: wgpu::Color = wgpu::Color { r: 0.09, g: 0.09, b: 0.1, a: 1.0 };

pub struct Canvas {
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    /// The view's layer (its address) and the surface on it; `None` between views.
    surface: Option<(u64, wgpu::Surface<'static>)>,
    config: wgpu::SurfaceConfiguration,
    /// Whether `surface` has been configured: that sets the layer's properties, so it waits for
    /// the main thread ([`Canvas::resize`]).
    configured: bool,
    viewport: Viewport,
    /// GPU errors and a lost device mark this instead of panicking.
    health: DeviceHealth,
    /// The display signature the LUT was made for.
    display: Option<u64>,
    /// Pasteboard colour around the document.
    pub background: wgpu::Color,
}

impl Canvas {
    /// A canvas for the `CAMetalLayer` at `layer`: the GPU device and every pipeline, which takes
    /// a while (each shader is compiled), so callers build it off the main thread. The surface
    /// is configured later, on the main thread, by [`Canvas::resize`].
    ///
    /// The caller keeps the layer alive until it calls [`Canvas::release`] or drops this.
    pub fn new(layer: u64, width: u32, height: u32) -> Result<Self, String> {
        let instance =
            wgpu::Instance::new(wgpu::InstanceDescriptor { backends: wgpu::Backends::METAL, ..wgpu::InstanceDescriptor::new_without_display_handle() });
        let surface = Self::surface(&instance, layer)?;
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
        let health = DeviceHealth::watch(&device);
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
        let mut viewport = Viewport::new(&device, &queue, &adapter, format).map_err(|e| e.to_string())?;
        viewport.compositor_mut().set_memory_budget(COMPOSITOR_BUDGET);
        viewport.compositor_mut().set_health(health.clone());
        if let Some(fault) = health.fault() {
            return Err(format!("the GPU reported a problem while starting: {fault:?}"));
        }
        Ok(Self {
            instance,
            adapter,
            device,
            queue,
            surface: Some((layer, surface)),
            config,
            configured: false,
            viewport,
            health,
            display: None,
            background: BACKGROUND,
        })
    }

    #[allow(unsafe_code)]
    fn surface(instance: &wgpu::Instance, layer: u64) -> Result<wgpu::Surface<'static>, String> {
        if layer == 0 {
            return Err("no Metal layer".into());
        }
        // SAFETY: `layer` is a live CAMetalLayer the Swift view owns and keeps until it releases
        // the canvas (which drops this surface first). Making the surface only retains it.
        unsafe { instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer as usize as *mut std::ffi::c_void)) }
            .map_err(|e| format!("can't draw on this view: {e}"))
    }

    /// Draw on another view's layer, keeping the device and pipelines (a view rebuilt for a new
    /// layout doesn't compile everything again).
    pub fn retarget(&mut self, layer: u64, width: u32, height: u32) -> Result<(), String> {
        if self.surface.as_ref().is_some_and(|(l, _)| *l == layer) {
            return Ok(());
        }
        self.surface = None;
        let surface = Self::surface(&self.instance, layer)?;
        if !surface.get_capabilities(&self.adapter).formats.contains(&self.config.format) {
            return Err("the view can't be drawn on with this GPU".into());
        }
        self.surface = Some((layer, surface));
        (self.config.width, self.config.height) = (width.max(1), height.max(1));
        self.configured = false;
        Ok(())
    }

    /// The view at `layer` is going away: stop drawing on it. Another view's surface stays.
    pub fn release(&mut self, layer: u64) {
        if self.surface.as_ref().is_some_and(|(l, _)| *l == layer) {
            self.surface = None;
            self.configured = false;
        }
    }

    /// Size the surface (and configure it the first time). On the main thread: it sets the
    /// layer's properties.
    pub fn resize(&mut self, width: u32, height: u32) {
        let (w, h) = (width.max(1), height.max(1));
        let Some((_, surface)) = &self.surface else { return };
        if !self.configured || (w, h) != (self.config.width, self.config.height) {
            (self.config.width, self.config.height) = (w, h);
            surface.configure(&self.device, &self.config);
            self.configured = true;
        }
    }

    /// The GPU hasn't reported a fault or been lost.
    pub fn healthy(&self) -> bool {
        self.health.is_ok()
    }

    /// Whether frames can be drawn: a configured surface and a GPU without faults.
    pub fn ready(&self) -> bool {
        self.configured && self.surface.is_some() && self.health.is_ok()
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
        if !self.ready() {
            return;
        }
        let Some((_, surface)) = &self.surface else { return };
        let frame = match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                surface.configure(&self.device, &self.config);
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
