//! A document view any toolkit can host: the composite lives on the GPU as mipmapped tiles
//! (premultiplied `Rgba8Unorm`) and is drawn with zoom, pan and rotation into a render target.

use photocraft_compose::Buffer;
use photocraft_doc::{DocId, Document};
use photocraft_geom::Rect;

use crate::{Compositor, Stats, Unsupported};

pub const CANVAS_WGSL: &str = include_str!("canvas.wgsl");
pub const ENCODE_WGSL: &str = include_str!("canvas_encode.wgsl");
pub const MIP_WGSL: &str = include_str!("canvas_mip.wgsl");

const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
const VIEW_FLOATS: usize = 32;
const VIEW_UNIFORM_SIZE: u64 = (VIEW_FLOATS * 4) as u64;
/// Largest tile side (smaller when the device's limit is).
const MAX_TILE: u32 = 8192;

/// Where the document sits on screen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct View {
    /// Target size in pixels.
    pub screen: [u32; 2],
    /// Screen pixels per document pixel.
    pub zoom: f32,
    /// Document point shown at the centre of the screen.
    pub center: [f32; 2],
    /// Radians, clockwise.
    pub rotation: f32,
    /// Screen pixels per point: sizes the checkerboard and the shadow.
    pub pixels_per_point: f32,
}

impl View {
    /// Screen position of document point `d`.
    pub fn doc_to_screen(&self, d: [f32; 2]) -> [f32; 2] {
        let (cos, sin) = self.cos_sin();
        let (x, y) = (d[0] - self.center[0], d[1] - self.center[1]);
        let [ox, oy] = self.origin();
        [ox + self.center[0] * self.zoom + (x * cos - y * sin) * self.zoom, oy + self.center[1] * self.zoom + (x * sin + y * cos) * self.zoom]
    }

    /// Document point under screen position `p`.
    pub fn screen_to_doc(&self, p: [f32; 2]) -> [f32; 2] {
        let (cos, sin) = self.cos_sin();
        let [ox, oy] = self.origin();
        let zoom = if self.zoom > 0.0 { self.zoom } else { 1.0 };
        let (x, y) = ((p[0] - ox - self.center[0] * zoom) / zoom, (p[1] - oy - self.center[1] * zoom) / zoom);
        [x * cos + y * sin + self.center[0], -x * sin + y * cos + self.center[1]]
    }

    /// Screen position of document (0, 0) before rotation, snapped to whole pixels.
    fn origin(&self) -> [f32; 2] {
        [(self.screen[0] as f32 * 0.5 - self.center[0] * self.zoom).round(), (self.screen[1] as f32 * 0.5 - self.center[1] * self.zoom).round()]
    }

    fn cos_sin(&self) -> (f32, f32) {
        let r = if self.rotation.is_finite() { self.rotation } else { 0.0 };
        if r.abs() < 1e-8 { (1.0, 0.0) } else { (r.cos(), r.sin()) }
    }
}

struct Tile {
    rect: [u32; 4],
    texture: wgpu::Texture,
    levels: Vec<wgpu::TextureView>,
    bind_group: wgpu::BindGroup,
}

struct DocTiles {
    id: DocId,
    size: [u32; 2],
    tiles: Vec<Tile>,
}

pub struct Viewport {
    device: wgpu::Device,
    queue: wgpu::Queue,
    compositor: Compositor,
    tile_side: u32,
    out_linear: bool,
    view_buffer: wgpu::Buffer,
    view_bind_group: wgpu::BindGroup,
    tile_bgl: wgpu::BindGroupLayout,
    tile_pipeline: wgpu::RenderPipeline,
    shadow_pipeline: wgpu::RenderPipeline,
    mip_bgl: wgpu::BindGroupLayout,
    mip_pipeline: wgpu::RenderPipeline,
    mip_sampler: wgpu::Sampler,
    encode_bgl: wgpu::BindGroupLayout,
    encode_pipeline: wgpu::RenderPipeline,
    lut_bgl: wgpu::BindGroupLayout,
    lut: wgpu::BindGroup,
    lut_on: bool,
    doc: Option<DocTiles>,
}

impl Viewport {
    /// A view drawing into `target` textures, with a compositor on `device`.
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue, adapter: &wgpu::Adapter, target: wgpu::TextureFormat) -> Result<Self, Unsupported> {
        let compositor = Compositor::try_new_with_format(device, Compositor::preferred_acc_format(adapter))?;
        let vis = wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT;
        let module = shader(device, "pc_canvas", CANVAS_WGSL);
        let view_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("pc_canvas_view"),
            entries: &[uniform_entry(0, VIEW_UNIFORM_SIZE, vis), sampler_entry(1)],
        });
        let tile_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("pc_canvas_tile"),
            entries: &[texture_entry(0, true), uniform_entry(1, 16, vis)],
        });
        let lut_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("pc_display_lut"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    multisampled: false,
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D3,
                },
                count: None,
            }],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("pc_canvas"),
            bind_group_layouts: &[Some(&view_bgl), Some(&tile_bgl), Some(&lut_bgl)],
            immediate_size: 0,
        });
        let shadow_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("pc_canvas_shadow"),
            bind_group_layouts: &[Some(&view_bgl)],
            immediate_size: 0,
        });
        let over = wgpu::BlendState {
            color: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::One,
                dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                operation: wgpu::BlendOperation::Add,
            },
            alpha: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::OneMinusDstAlpha,
                dst_factor: wgpu::BlendFactor::One,
                operation: wgpu::BlendOperation::Add,
            },
        };
        let shadow_pipeline = pipeline(device, "pc_canvas_shadow", &shadow_layout, &module, ("vs_shadow", "fs_shadow"), target, Some(over));
        let tile_pipeline = pipeline(device, "pc_canvas_tile", &layout, &module, ("vs_tile", "fs_tile"), target, Some(over));
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("pc_canvas_trilinear"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            ..Default::default()
        });
        let view_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("pc_canvas_view"),
            size: VIEW_UNIFORM_SIZE,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let view_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("pc_canvas_view"),
            layout: &view_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: view_buffer.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&sampler) },
            ],
        });

        let mip_module = shader(device, "pc_mip", MIP_WGSL);
        let mip_bgl =
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: Some("pc_mip"), entries: &[texture_entry(0, true), sampler_entry(1)] });
        let mip_layout =
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: Some("pc_mip"), bind_group_layouts: &[Some(&mip_bgl)], immediate_size: 0 });
        let mip_pipeline = pipeline(device, "pc_mip", &mip_layout, &mip_module, ("vs", "fs"), FORMAT, None);
        let mip_sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("pc_mip"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let encode_module = shader(device, "pc_encode", ENCODE_WGSL);
        let encode_bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("pc_encode"),
            entries: &[texture_entry(0, false), uniform_entry(1, 16, wgpu::ShaderStages::FRAGMENT)],
        });
        let encode_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("pc_encode"),
            bind_group_layouts: &[Some(&encode_bgl)],
            immediate_size: 0,
        });
        let encode_pipeline = pipeline(device, "pc_encode", &encode_layout, &encode_module, ("vs", "fs"), FORMAT, None);

        let lut = lut_bind_group(device, queue, &lut_bgl, 2, &[0; 32]);
        Ok(Self {
            device: device.clone(),
            queue: queue.clone(),
            compositor,
            tile_side: device.limits().max_texture_dimension_2d.clamp(1, MAX_TILE),
            out_linear: target.is_srgb(),
            view_buffer,
            view_bind_group,
            tile_bgl,
            tile_pipeline,
            shadow_pipeline,
            mip_bgl,
            mip_pipeline,
            mip_sampler,
            encode_bgl,
            encode_pipeline,
            lut_bgl,
            lut,
            lut_on: false,
            doc: None,
        })
    }

    pub fn compositor_mut(&mut self) -> &mut Compositor {
        &mut self.compositor
    }

    /// The display colour transform as an RGBA8 `size`³ LUT (red fastest), or `None` when the
    /// texture values go to the screen as they are.
    pub fn set_display_lut(&mut self, lut: Option<(u32, &[u8])>) {
        match lut {
            Some((size, bytes)) if size >= 2 && bytes.len() as u64 == u64::from(size).pow(3) * 4 => {
                self.lut = lut_bind_group(&self.device, &self.queue, &self.lut_bgl, size, bytes);
                self.lut_on = true;
            }
            _ => self.lut_on = false,
        }
    }

    /// Whether the textures hold `doc` (same document and size), so a damage refresh is enough.
    pub fn holds(&self, doc: &Document) -> bool {
        self.doc.as_ref().is_some_and(|d| d.id == doc.id && d.size == [doc.size.width, doc.size.height])
    }

    /// Composite `damage` (everything when `None` or when the textures hold another document)
    /// on the GPU. `encode_srgb` stores the sRGB encoding of a linear composite.
    pub fn refresh(&mut self, doc: &Document, damage: Option<Rect>, encode_srgb: bool) -> Result<Stats, Unsupported> {
        let fresh = self.prepare(doc)?;
        let region = match damage {
            Some(r) if !fresh => r.intersect(&doc.bounds()),
            _ => doc.bounds(),
        };
        if region.is_empty() {
            return Ok(Stats::default());
        }
        if fresh {
            self.compositor.supports(doc)?;
        }
        let Some(d) = &self.doc else { return Err(Unsupported("no canvas texture".into())) };
        let (device, pipe, bgl) = (&self.device, &self.encode_pipeline, &self.encode_bgl);
        let comp = &mut self.compositor;
        // A wgpu panic (a device lost mid-refresh) must not take the app down.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            comp.render(device, &self.queue, doc, region, |enc, out| {
                for t in &d.tiles {
                    let [tx, ty, tw, th] = t.rect;
                    let r = out.rect.intersect(&Rect::from_xywh(tx as i32, ty as i32, tw, th));
                    if r.is_empty() {
                        continue;
                    }
                    let offset = [out.rect.x0 - tx as i32, out.rect.y0 - ty as i32, i32::from(encode_srgb), 0];
                    let ubuf = init_buffer(device, "pc_encode", &offset.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<u8>>());
                    let bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("pc_encode"),
                        layout: bgl,
                        entries: &[
                            wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(out.view) },
                            wgpu::BindGroupEntry { binding: 1, resource: ubuf.as_entire_binding() },
                        ],
                    });
                    let Some(level0) = t.levels.first() else { continue };
                    let mut pass = begin_pass(enc, "pc_encode", level0, wgpu::LoadOp::Load);
                    pass.set_pipeline(pipe);
                    pass.set_bind_group(0, &bg, &[]);
                    pass.set_scissor_rect(r.x0 as u32 - tx, r.y0 as u32 - ty, r.width(), r.height());
                    pass.draw(0..3, 0..1);
                }
            })
        }));
        let Ok(result) = result else {
            self.doc = None;
            return Err(Unsupported("the GPU compositor stopped (internal error)".into()));
        };
        match &result {
            Ok(_) => self.regenerate_mips(region),
            Err(_) if fresh => self.doc = None,
            Err(_) => {}
        }
        result
    }

    /// Put a CPU composite `buf` (straight alpha, already in the texture's encoding, document
    /// pixels) into the textures: the fallback when [`Self::refresh`] can't composite `doc`.
    pub fn upload(&mut self, doc: &Document, buf: &Buffer) -> Result<(), Unsupported> {
        self.prepare(doc)?;
        let r = buf.rect.intersect(&doc.bounds());
        let Some(d) = &self.doc else { return Ok(()) };
        if r.is_empty() || buf.px.len() != buf.rect.width() as usize * buf.rect.height() as usize {
            return Ok(());
        }
        let texels = premultiply(&buf.px);
        let stride = buf.rect.width();
        for t in &d.tiles {
            let [tx, ty, tw, th] = t.rect;
            let i = r.intersect(&Rect::from_xywh(tx as i32, ty as i32, tw, th));
            if i.is_empty() {
                continue;
            }
            let offset = ((i.y0 - buf.rect.y0) as u64 * u64::from(stride) + (i.x0 - buf.rect.x0) as u64) * 4;
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &t.texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d { x: i.x0 as u32 - tx, y: i.y0 as u32 - ty, z: 0 },
                    aspect: wgpu::TextureAspect::All,
                },
                &texels,
                wgpu::TexelCopyBufferLayout { offset, bytes_per_row: Some(stride * 4), rows_per_image: Some(i.height()) },
                wgpu::Extent3d { width: i.width(), height: i.height(), depth_or_array_layers: 1 },
            );
        }
        self.regenerate_mips(r);
        Ok(())
    }

    /// Draw the view into `target`: `background` (linear when the target is sRGB), the drop
    /// shadow, the checkerboard and the document.
    pub fn draw(&mut self, target: &wgpu::TextureView, view: &View, background: wgpu::Color) {
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("pc_view") });
        let size = self.doc.as_ref().map_or([0, 0], |d| d.size);
        self.queue.write_buffer(&self.view_buffer, 0, &f32_bytes(&self.uniforms(view, size)));
        {
            let mut pass = begin_pass(&mut encoder, "pc_view", target, wgpu::LoadOp::Clear(background));
            if let Some(d) = &self.doc
                && view.screen[0] > 0
                && view.screen[1] > 0
            {
                pass.set_bind_group(0, &self.view_bind_group, &[]);
                pass.set_pipeline(&self.shadow_pipeline);
                pass.draw(0..6, 0..1);
                pass.set_pipeline(&self.tile_pipeline);
                pass.set_bind_group(2, &self.lut, &[]);
                for t in &d.tiles {
                    pass.set_bind_group(1, &t.bind_group, &[]);
                    pass.draw(0..6, 0..1);
                }
            }
        }
        self.queue.submit([encoder.finish()]);
    }

    /// Make the tiles fit `doc`; `true` when they were (re)created.
    fn prepare(&mut self, doc: &Document) -> Result<bool, Unsupported> {
        if self.holds(doc) {
            return Ok(false);
        }
        let size = [doc.size.width, doc.size.height];
        if size[0] == 0 || size[1] == 0 {
            return Err(Unsupported("empty document".into()));
        }
        let side = self.tile_side;
        let mut tiles = Vec::new();
        for ty in (0..size[1]).step_by(side as usize) {
            for tx in (0..size[0]).step_by(side as usize) {
                tiles.push(self.tile([tx, ty, side.min(size[0] - tx), side.min(size[1] - ty)]));
            }
        }
        self.doc = Some(DocTiles { id: doc.id, size, tiles });
        Ok(true)
    }

    fn tile(&self, rect: [u32; 4]) -> Tile {
        let [tx, ty, w, h] = rect;
        let levels_n = 32 - w.max(h).max(1).leading_zeros();
        let texture = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("pc_canvas_tile"),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: levels_n,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST | wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let levels = (0..levels_n)
            .map(|l| texture.create_view(&wgpu::TextureViewDescriptor { base_mip_level: l, mip_level_count: Some(1), ..Default::default() }))
            .collect();
        let full = texture.create_view(&wgpu::TextureViewDescriptor::default());
        let uniform = init_buffer(&self.device, "pc_canvas_tile", &f32_bytes(&[tx as f32, ty as f32, w as f32, h as f32]));
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("pc_canvas_tile"),
            layout: &self.tile_bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&full) },
                wgpu::BindGroupEntry { binding: 1, resource: uniform.as_entire_binding() },
            ],
        });
        Tile { rect, texture, levels, bind_group }
    }

    /// Rebuild the mip chain inside `r` (document pixels) with 2×2 box filtering.
    fn regenerate_mips(&self, r: Rect) {
        let Some(d) = &self.doc else { return };
        let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("pc_mips") });
        for t in &d.tiles {
            let [tx, ty, tw, th] = t.rect;
            let i = r.intersect(&Rect::from_xywh(tx as i32, ty as i32, tw, th));
            if i.is_empty() {
                continue;
            }
            let (mut x0, mut y0, mut x1, mut y1) = (i.x0 as u32 - tx, i.y0 as u32 - ty, i.x1 as u32 - tx, i.y1 as u32 - ty);
            for level in 1..t.levels.len() {
                let (lw, lh) = ((tw >> level).max(1), (th >> level).max(1));
                // Padded by one texel for odd-size rounding.
                (x0, y0) = ((x0 / 2).saturating_sub(1), (y0 / 2).saturating_sub(1));
                (x1, y1) = ((x1.div_ceil(2) + 1).min(lw), (y1.div_ceil(2) + 1).min(lh));
                let (Some(src), Some(dst)) = (t.levels.get(level - 1), t.levels.get(level)) else { break };
                let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("pc_mip"),
                    layout: &self.mip_bgl,
                    entries: &[
                        wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(src) },
                        wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&self.mip_sampler) },
                    ],
                });
                let mut pass = begin_pass(&mut encoder, "pc_mip", dst, wgpu::LoadOp::Load);
                pass.set_pipeline(&self.mip_pipeline);
                pass.set_bind_group(0, &bg, &[]);
                pass.set_scissor_rect(x0, y0, x1 - x0, y1 - y0);
                pass.draw(0..3, 0..1);
            }
        }
        self.queue.submit([encoder.finish()]);
    }

    /// The canvas shader's `View` uniform (see canvas.wgsl).
    fn uniforms(&self, v: &View, doc_size: [u32; 2]) -> [f32; VIEW_FLOATS] {
        let scale = if v.zoom.is_finite() && v.zoom > 0.0 { v.zoom } else { 1.0 };
        let (mode, lod) = if scale < 0.999 {
            (0.0, (-scale.log2()).max(0.0))
        } else if (scale - scale.round()).abs() < 1e-3 || scale >= 2.0 {
            (2.0, 0.0)
        } else {
            (1.0, 0.0)
        };
        let ppp = if v.pixels_per_point.is_finite() && v.pixels_per_point > 0.0 { v.pixels_per_point } else { 1.0 };
        let origin = v.origin();
        let (cos, sin) = v.cos_sin();
        let display = if self.lut_on { 1.0 } else { 0.0 };
        let out_linear = if self.out_linear { 1.0 } else { 0.0 };
        #[rustfmt::skip]
        let u = [
            v.screen[0] as f32, v.screen[1] as f32, scale, ppp,
            origin[0], origin[1], doc_size[0] as f32, doc_size[1] as f32,
            mode, lod, 0.0, (8.0 * ppp).round(),
            0.0, 0.0, display, out_linear,
            1.0, 1.0, 1.0, 1.0,
            0.8, 0.8, 0.8, 0.0,
            0.5, 0.5, 0.5, 1.0,
            cos, sin, v.center[0], v.center[1],
        ];
        u
    }
}

/// Straight-alpha f32 RGBA → premultiplied RGBA8.
fn premultiply(px: &[[f32; 4]]) -> Vec<u8> {
    let q = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
    px.iter()
        .flat_map(|p| {
            let a = if p[3].is_finite() { p[3].clamp(0.0, 1.0) } else { 0.0 };
            let c = |v: f32| if v.is_finite() { v * a } else { 0.0 };
            [q(c(p[0])), q(c(p[1])), q(c(p[2])), q(a)]
        })
        .collect()
}

fn shader(device: &wgpu::Device, label: &str, src: &str) -> wgpu::ShaderModule {
    device.create_shader_module(wgpu::ShaderModuleDescriptor { label: Some(label), source: wgpu::ShaderSource::Wgsl(src.into()) })
}

/// A render pass drawing into `view`.
fn begin_pass<'e>(encoder: &'e mut wgpu::CommandEncoder, label: &str, view: &wgpu::TextureView, load: wgpu::LoadOp<wgpu::Color>) -> wgpu::RenderPass<'e> {
    encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some(label),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view,
            resolve_target: None,
            depth_slice: None,
            ops: wgpu::Operations { load, store: wgpu::StoreOp::Store },
        })],
        depth_stencil_attachment: None,
        timestamp_writes: None,
        occlusion_query_set: None,
        multiview_mask: None,
    })
}

fn uniform_entry(binding: u32, size: u64, visibility: wgpu::ShaderStages) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility,
        ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: std::num::NonZeroU64::new(size) },
        count: None,
    }
}

fn texture_entry(binding: u32, filterable: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            multisampled: false,
            sample_type: wgpu::TextureSampleType::Float { filterable },
            view_dimension: wgpu::TextureViewDimension::D2,
        },
        count: None,
    }
}

fn sampler_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
        count: None,
    }
}

fn pipeline(
    device: &wgpu::Device,
    label: &str,
    layout: &wgpu::PipelineLayout,
    module: &wgpu::ShaderModule,
    (vs, fs): (&str, &str),
    format: wgpu::TextureFormat,
    blend: Option<wgpu::BlendState>,
) -> wgpu::RenderPipeline {
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some(label),
        layout: Some(layout),
        vertex: wgpu::VertexState { module, entry_point: Some(vs), buffers: &[], compilation_options: Default::default() },
        primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleList, ..Default::default() },
        depth_stencil: None,
        multisample: wgpu::MultisampleState { count: 1, mask: !0, alpha_to_coverage_enabled: false },
        fragment: Some(wgpu::FragmentState {
            module,
            entry_point: Some(fs),
            targets: &[Some(wgpu::ColorTargetState { format, blend, write_mask: wgpu::ColorWrites::ALL })],
            compilation_options: Default::default(),
        }),
        multiview_mask: None,
        cache: None,
    })
}

/// A `size`³ RGBA8 3D texture for the canvas shader.
fn lut_bind_group(device: &wgpu::Device, queue: &wgpu::Queue, bgl: &wgpu::BindGroupLayout, size: u32, bytes: &[u8]) -> wgpu::BindGroup {
    let extent = wgpu::Extent3d { width: size, height: size, depth_or_array_layers: size };
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("pc_display_lut"),
        size: extent,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D3,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        wgpu::TexelCopyTextureInfo { texture: &texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        bytes,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(size * 4), rows_per_image: Some(size) },
        extent,
    );
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("pc_display_lut"),
        layout: bgl,
        entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&view) }],
    })
}

fn f32_bytes(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|f| f.to_ne_bytes()).collect()
}

/// A uniform buffer holding `contents` (an invalid buffer, not a panic, on a lost device).
fn init_buffer(device: &wgpu::Device, label: &str, contents: &[u8]) -> wgpu::Buffer {
    let size = (contents.len() as u64).next_multiple_of(wgpu::COPY_BUFFER_ALIGNMENT).max(wgpu::COPY_BUFFER_ALIGNMENT);
    let buffer = device.create_buffer(&wgpu::BufferDescriptor { label: Some(label), size, usage: wgpu::BufferUsages::UNIFORM, mapped_at_creation: true });
    if let Ok(mut view) = buffer.slice(..).get_mapped_range_mut()
        && view.len() >= contents.len()
    {
        view.slice(..contents.len()).copy_from_slice(contents);
    }
    buffer.unmap();
    buffer
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screen_and_document_points_round_trip() {
        let v = View { screen: [400, 800], zoom: 0.37, center: [1200.0, 900.0], rotation: 0.6, pixels_per_point: 3.0 };
        for d in [[0.0, 0.0], [1200.0, 900.0], [3000.0, 17.5]] {
            let back = v.screen_to_doc(v.doc_to_screen(d));
            assert!((back[0] - d[0]).abs() < 1e-2 && (back[1] - d[1]).abs() < 1e-2, "{d:?} -> {back:?}");
        }
        let c = v.doc_to_screen(v.center);
        assert!((c[0] - 200.0).abs() <= 1.0 && (c[1] - 400.0).abs() <= 1.0, "{c:?}");
    }
}
