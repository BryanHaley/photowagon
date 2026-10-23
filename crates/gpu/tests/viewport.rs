//! The toolkit-free view (`viewport`): a composited document drawn at a zoom, by the GPU and by
//! the CPU fallback upload.

use photocraft_color::{Color, ColorMode, SampleType};
use photocraft_doc::{Document, Layer, Size};
use photocraft_geom::Rect;
use photocraft_gpu::viewport::{View, Viewport};

const TARGET: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;

fn gpu() -> Option<(wgpu::Adapter, wgpu::Device, wgpu::Queue)> {
    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default())).ok()?;
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default())).ok()?;
    Some((adapter, device, queue))
}

/// White document with a red 8×8 square at (8, 8).
fn doc() -> Document {
    let mut d = Document::with_background("v", Size::new(32, 32), ColorMode::Rgb, SampleType::U8, Color::WHITE);
    let fmt = d.pixel_format();
    let mut l = Layer::raster("red", fmt);
    l.surface_mut().unwrap().fill_rect(Rect::new(8, 8, 16, 16), &photocraft_raster::from_rgba(&fmt, [1.0, 0.0, 0.0, 1.0]));
    d.layers.push(l);
    d
}

/// Draw `view` into a 64×64 texture and read it back as RGBA8.
fn draw(device: &wgpu::Device, queue: &wgpu::Queue, vp: &mut Viewport, view: &View) -> Vec<u8> {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: None,
        size: wgpu::Extent3d { width: 64, height: 64, depth_or_array_layers: 1 },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: TARGET,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    vp.draw(&tex.create_view(&Default::default()), view, wgpu::Color::BLACK);
    let buf = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: 256 * 64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut enc = device.create_command_encoder(&Default::default());
    enc.copy_texture_to_buffer(
        tex.as_image_copy(),
        wgpu::TexelCopyBufferInfo { buffer: &buf, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(256), rows_per_image: Some(64) } },
        wgpu::Extent3d { width: 64, height: 64, depth_or_array_layers: 1 },
    );
    queue.submit([enc.finish()]);
    buf.slice(..).map_async(wgpu::MapMode::Read, |_| {});
    device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
    buf.slice(..).get_mapped_range().unwrap().to_vec()
}

fn px(img: &[u8], x: usize, y: usize) -> [u8; 3] {
    let i = y * 256 + x * 4;
    [img[i], img[i + 1], img[i + 2]]
}

#[test]
fn a_document_is_drawn_at_the_view_zoom() {
    let Some((adapter, device, queue)) = gpu() else { return };
    let mut vp = Viewport::new(&device, &queue, &adapter, TARGET).unwrap();
    let d = doc();
    // 2× zoom centred on the document: doc (x, y) lands at screen (2x, 2y).
    let view = View { screen: [64, 64], zoom: 2.0, center: [16.0, 16.0], rotation: 0.0, pixels_per_point: 1.0 };
    // Where the compositor can run with full-float targets it must; elsewhere the CPU fallback
    // fills the same textures.
    match vp.refresh(&d, None, false) {
        Ok(_) => {}
        Err(e) if photocraft_gpu::Compositor::preferred_acc_format(&adapter) == wgpu::TextureFormat::Rgba32Float => panic!("{e}"),
        Err(_) => vp.upload(&d, &photocraft_compose::render(&d, d.bounds())).unwrap(),
    }
    let img = draw(&device, &queue, &mut vp, &view);
    assert_eq!(px(&img, 24, 24), [255, 0, 0], "inside the square");
    assert_eq!(px(&img, 8, 40), [255, 255, 255], "outside it");
    // A damage refresh after a change updates only that area.
    let mut d2 = d.clone();
    let fmt = d2.pixel_format();
    d2.layers[1].surface_mut().unwrap().fill_rect(Rect::new(20, 20, 24, 24), &photocraft_raster::from_rgba(&fmt, [0.0, 0.0, 1.0, 1.0]));
    vp.upload(&d2, &photocraft_compose::render(&d2, Rect::new(20, 20, 24, 24))).unwrap();
    let img = draw(&device, &queue, &mut vp, &view);
    assert_eq!(px(&img, 44, 44), [0, 0, 255]);
    assert_eq!(px(&img, 24, 24), [255, 0, 0]);
}
