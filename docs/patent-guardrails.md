# Patent guardrails

Design choices that keep PhotoWagon outside Adobe patents that are still in force. Not legal advice.

- **Read this** before you add or change a feature in an area listed below, and before you implement a method from a paper.
- **If a change would cross a line:** stop. Pick another method or leave the feature out. Then add it to the [README's Patents table](../README.md#patents) and to this file.
- **Already removed:** see [README.md › Patents](../README.md#patents).
- Only Adobe's US patents were checked (review of 2026-10-20). Expiry dates are estimates: treat them as "no later than".

## Lines we don't cross

Each line: the rule, the patent, when it ends, and the code it concerns.

### Fill, remove and heal

- Don't carry source positions (an offset map) from a small copy up to full size. Search sources again at full size; use the small copy only for guide colours. [US9305329](https://patents.google.com/patent/US9305329) until 2034-10, [US9396530](https://patents.google.com/patent/US9396530) until 2034-10, [US11449974](https://patents.google.com/patent/US11449974) until 2040-04, [US12373915](https://patents.google.com/patent/US12373915) until 2043-12 (`crates/algo/src/exemplar.rs`)
- Don't add PatchMatch: no propagating neighbours' matches plus a random search. Keep windowed or exhaustive search. [US8285055](https://patents.google.com/patent/US8285055) until 2031-07, [US8571328](https://patents.google.com/patent/US8571328) until 2031-10
- Keep the patch search translation-only. Don't add rotation, scale, flip or gain/bias to the search while also using Poisson blending. [US8861868](https://patents.google.com/patent/US8861868) until 2032-10 (`crates/algo/src/exemplar.rs`)
- Each finer level picks its own best patch. Don't repair invalid pixels by copying a nearby pixel's patch assignment, and don't add a validity mask for carried-over assignments. [US10134108](https://patents.google.com/patent/US10134108) until 2036-10, [US10719913](https://patents.google.com/patent/US10719913) until 2038-10 (`crates/algo/src/exemplar.rs`)
- Keep rotated, scaled or mirrored sources as pre-built copies of the window, checked with an exact summed-area table. Don't build transformed patches one by one and test one pixel, a dilated hole or per-pixel lookups. [US10586311](https://patents.google.com/patent/US10586311) until 2038-06 (`crates/algo/src/exemplar.rs`, `content_aware.rs`)
- Don't let users choose the sampling area for Fill from Surroundings (no Sampling Brush, user area or alpha channel area). Keep the automatic and rectangular windows only. [US10706509](https://patents.google.com/patent/US10706509) until 2038-09 (`crates/algo/src/content_aware.rs`)
- Don't build the sampling area by clustering the ring around the hole and growing the clusters. Never add pixel position to clustering features or run a segmentation per cluster. [US11042969](https://patents.google.com/patent/US11042969) until 2039-07, [US12136199](https://patents.google.com/patent/US12136199) until 2041-10 (`crates/algo/src/content_aware.rs`)
- Apply any sampling limit to the whole fill. Don't let a user stroke tie part of the hole to part of the surroundings. [US9330476](https://patents.google.com/patent/US9330476) until 2032-06 (`crates/algo/src/content_aware.rs`)
- Don't preview a fill by showing a coarse level of the multi-scale fill. Use a separate fast approximation or show only the finished fill. [US11200645](https://patents.google.com/patent/US11200645) until 2040-05 (`crates/algo/src/exemplar.rs`)
- Don't seed the fill (or any heal) with a smooth colour estimate from the hole's border. The membrane fill is a last fallback only, never a starting image. [US9911201](https://patents.google.com/patent/US9911201) until 2036-06 (`crates/algo/src/poisson.rs`)
- Keep Poisson solves as relaxation (SOR multigrid, coarse levels only as a first guess). Don't fill holes with a pull-push pyramid (shrink until no holes, then grow and paste back). [US10049435](https://patents.google.com/patent/US10049435) until 2036-08, [US10915991](https://patents.google.com/patent/US10915991) until 2039-07, [US9036909](https://patents.google.com/patent/US9036909) until 2033-01 (`crates/algo/src/poisson.rs`). US9036909's claim 2 is broad on any seamless paste: check the claims first before a new seamless-clone feature.
- Keep healing as Poisson seamless cloning. Don't add gradient-field texture synthesis that samples gradient patches and integrates them. [US8041140](https://patents.google.com/patent/US8041140) until 2029-07 (`crates/algo/src/poisson.rs`, `crates/engine/src/retouch_cmds.rs`)
- Don't search around a spot for one source region to copy (Proximity Match). Use a user-picked source or per-pixel resynthesis. [US7471417](https://patents.google.com/patent/US7471417) until 2027-02 (`crates/algo/src/inpaint.rs`, `resynth.rs`)
- Move and Fill on iOS: fill only after the drop. Don't refill the vacated spot while the finger is down, and don't port the desktop live preview. Keep the final fill exemplar-based. [US10332291](https://patents.google.com/patent/US10332291) until 2037-03, [US9575641](https://patents.google.com/patent/US9575641) until 2033-10 (`ios/PhotoWagon/ToolGestures.swift`, `crates/ui-egui/src/cam_preview.rs`)
- Don't pick the fill method automatically from local structure or hole size, and don't add an artifact score that retries with another method. [US12700150](https://patents.google.com/patent/US12700150) until 2043-06 (`crates/algo/src/remove.rs`)
- Keep removal manual: the user picks the object, then fills. No one-tap distraction detection with a learned classifier, no automatic shadow detection. [US12395722](https://patents.google.com/patent/US12395722) until 2043-02
- Segment and fill only after the user acts. Don't precompute masks for the whole image on open or pre-fill hidden backgrounds. [US12288279](https://patents.google.com/patent/US12288279) until 2043-03 (`ios/PhotoWagon/ObjectFinder.swift`)

### Selection and masks

- Don't combine two soft selections where both are soft at the same pixel. Cut each at 50% there first. [US7701470](https://patents.google.com/patent/US7701470) until 2028-08 (`crates/algo/src/selection.rs`)
- Don't soften selection edges with a local least-squares colour fit (the guided filter run on the mask). We smooth the mask itself with an edge-aware filter. [US8264500](https://patents.google.com/patent/US8264500) until 2031-09 (`crates/algo/src/matting.rs`, `segment/sky.rs`, `segment/focus.rs`)
- Check the claims first: the edge-aware mask smoothing (`matting::edge_aware_smooth`) is close to the published domain-transform filter (Gastal and Oliveira, 2011). No patent on it was found, but none was searched for. (`crates/algo/src/matting.rs`)
- Don't add a refine brush that marks areas and then sorts pixels using foreground and background colours sampled along the mask. [US8406566](https://patents.google.com/patent/US8406566) until 2031-07
- If a refine brush comes back: the user paints the unknown band by hand. No automatic boundary-finding ring, and no cursor whose ring snaps hard edges and mattes soft ones while its core forces select. [US10068361](https://patents.google.com/patent/US10068361) until 2037-08, [US9786078](https://patents.google.com/patent/US9786078) until 2035-11
- Don't add a smoothness term on output opacity or a closed-form (Levin-style) matting solve, and don't update the mask live during a stroke with such a model. [US8013870](https://patents.google.com/patent/US8013870) until 2028-01 (`crates/algo/src/matting.rs`)
- Don't estimate both a foreground and a background colour for each edge pixel and solve opacity from them. [US9786055](https://patents.google.com/patent/US9786055) until 2036-03 (`crates/algo/src/matting.rs`)
- Don't build a background colour histogram from the background band minus an uncertain area and score edge pixels against it. [US11461880](https://patents.google.com/patent/US11461880) until 2041-01 (`crates/algo/src/matting.rs`)
- Quick Selection: don't weight stroke pixels (add or subtract) by distance from and colour difference to a centre pixel. Keep hard footprint seeds. [US10055107](https://patents.google.com/patent/US10055107) until 2036-05, [US10241661](https://patents.google.com/patent/US10241661) until 2038-07 (`crates/algo/src/segment/quick.rs`)
- Quick Selection: keep one global cut seeded by the brush. Don't run edge detection only in a ring around the brush. [US9547410](https://patents.google.com/patent/US9547410) until 2035-05, [US10254913](https://patents.google.com/patent/US10254913) until 2037-06 (`crates/algo/src/segment/quick.rs`)
- Quick Selection: keep the area cost per selected pixel plus edge weights. Don't add constant foreground, background and bias costs, or refresh the selection live during a stroke with them. [US8050498](https://patents.google.com/patent/US8050498) until 2029-11, [US8200014](https://patents.google.com/patent/US8200014) until 2031-10 (`crates/algo/src/segment/quick.rs`)
- Don't show a lower-resolution preview of the selection while the finger or Pencil is down. Update after the stroke lifts. [US8542923](https://patents.google.com/patent/US8542923) until 2032-06 (`crates/algo/src/segment/quick.rs`, `ios/PhotoWagon/EditorModel.swift`)
- Don't add "select all matching objects" from a scribble by texture or pattern. Select Similar stays a colour-tolerance grow. [US9753625](https://patents.google.com/patent/US9753625) until 2035-10 (`crates/engine/src/selection_cmds.rs`)
- Don't train a three-way (in, out, unsure) classifier from user-marked samples. Keep GrabCut's binary result. [US8437573](https://patents.google.com/patent/US8437573) until 2031-07 (`crates/algo/src/segment/grabcut.rs`)
- Keep the Magnetic Lasso a least-cost path between fastening points. Don't match each point of the freehand path to scored edge candidates, or apply that to brush strokes. [US8565532](https://patents.google.com/patent/US8565532) until 2031-09 (`crates/algo/src/magnetic.rs`)
- Keep conversions between selections, masks and paths as explicit commands. Don't convert silently so a command can run. [US7831108](https://patents.google.com/patent/US7831108) until 2029-09
- Don't show every found object as its own mask at once for the user to pick, or a gallery of masks with one-tap copy to layer. Use one combined highlight, or one object at a time. Check the claims first if you change how Show All Objects draws. [US10977844](https://patents.google.com/patent/US10977844) until 2037-11, [US11468614](https://patents.google.com/patent/US11468614) until 2041-03 (`ios/PhotoWagon/EditorModel.swift`, `ObjectFinder.swift`)
- Compute object masks on demand, per object. No all-objects pre-pass, and no second, slower neural refinement on select. [US12731259](https://patents.google.com/patent/US12731259) until 2042-01
- Don't feed an on-object click and an off-object click to a trained network. Use a box or single point, or non-neural methods. [US11314982](https://patents.google.com/patent/US11314982) until 2040-02 (`crates/engine/src/smartselect_cmds.rs`)
- Don't chain our own learned detector into a segmenter prompted by its boxes or points. Keep Apple Vision or user taps as prompts. [US20260170654A1](https://patents.google.com/patent/US20260170654A1) pending (`ios/PhotoWagon/ObjectFinder.swift`)

### Blur, sharpen and noise

- Don't give Field Blur pins that each carry a blur amount. The blur amount comes from a selection or alpha channel. [US9019310](https://patents.google.com/patent/US9019310) until 2033-03 (`crates/algo/src/gallery.rs`)
- Check the claims first: Surface Blur's ranked path slides its window a column at a time, adding and removing pixels in a value-indexed tree (never merging column histograms). Compare with [US7920741](https://patents.google.com/patent/US7920741) (until 2030-02) before relying on it. (`crates/algo/src/blur.rs`)
- Keep each Blur Effects filter separate. Don't merge field, iris and tilt-shift into one shared blur mask. [US8831371](https://patents.google.com/patent/US8831371) until 2032-12 (`crates/algo/src/gallery.rs`)
- Path Blur: no Taper (exposure fading along the path), no curved kernel shape and no kernel position options. [US9723204](https://patents.google.com/patent/US9723204) until 2035-04 (`crates/algo/src/params_ext.rs`)
- Path Blur: compute each pixel's direction straight from the nearest path segment. No mesh of kernel parameters, no flash effect at points along the path. [US9779484](https://patents.google.com/patent/US9779484) until 2035-08, [US9955065](https://patents.google.com/patent/US9955065) until 2035-05 (`crates/algo/src/gallery.rs`)
- Surface Blur: don't slide a histogram along a row a column at a time. [US7920741](https://patents.google.com/patent/US7920741) until 2030-02 (`crates/algo/src/blur.rs`)
- In any histogram filter, keep every window pixel in the histogram and only limit which bins are read. Don't drop out-of-range pixels. [US7783121](https://patents.google.com/patent/US7783121) until 2029-06 (`crates/algo/src/blur.rs`)
- Keep sliding box cascades and row prefix sums. Don't build tables or pyramids of block results reused across kernels. [US7675524](https://patents.google.com/patent/US7675524) until 2028-08 (`crates/algo/src/blur.rs`, `blur2.rs`)
- Lens Blur: radius comes from distance to the focal value and a user radius. No depth-of-field value combined with a focus plane, and gather rather than scatter by a per-pixel test. Claim is broad: check the claims first. [US7623726](https://patents.google.com/patent/US7623726) until 2027-12 (`crates/algo/src/blur2.rs`)
- Lens Blur: one focal distance. No control that sets a min and max in-focus depth range. [US20260170618A1](https://patents.google.com/patent/US20260170618A1) pending (`crates/algo/src/blur2.rs`)
- Lens Blur highlights: one threshold. No second upper threshold or range-limited boost. [US8824793](https://patents.google.com/patent/US8824793) until 2032-12 (`crates/algo/src/blur2.rs`)
- Blur noise: a uniform user-set amount. Don't scale noise by local blur radius or aim for a target noise level. [US9536337](https://patents.google.com/patent/US9536337) until 2035-10 (`crates/algo/src/blur2.rs`, `gallery.rs`)
- Reduce Noise: no variance-stabilising transform (Anscombe, square root) before filtering, and no hard detail/non-detail split. [US7983511](https://patents.google.com/patent/US7983511) until 2030-11 (`crates/algo/src/denoise.rs`)
- Reduce Noise: no non-local-means or BM3D-style aggregation of overlapping patch estimates run as per-pixel threads. [US9396522](https://patents.google.com/patent/US9396522) until 2034-07 (`crates/algo/src/denoise.rs`)
- Dehaze: stay with the dark channel method. Don't add a lower bound that scales the image by an image-derived fraction to set transmission. [US9508126](https://patents.google.com/patent/US9508126) until 2035-03 (`crates/algo/src/camera_raw.rs`)
- Dehaze: no halo or noise suppression driven by the image gradient. Use a fixed transmission floor or a plain amount blend. [US9508129](https://patents.google.com/patent/US9508129) until 2035-11, [US9646364](https://patents.google.com/patent/US9646364) until 2036-10
- Shake reduction (if added): one global or user-set kernel. Don't place a second region's kernel from the first, or choose regions by edge-orientation counts. [US10032258](https://patents.google.com/patent/US10032258) until 2037-03
- Shake reduction: don't combine two automatic kernel size estimates into a suggested size. Use a slider or a single estimator. [US9299132](https://patents.google.com/patent/US9299132) until 2034-07
- Shake reduction: no classic coarse-to-fine blind kernel estimation. Use a user-set kernel, non-blind sharpening or a neural model. [US9619870](https://patents.google.com/patent/US9619870) until 2036-07

### Tone and colour

- Shadows/Highlights: one shared neighbourhood drives both sides. Don't give shadows and highlights separate neighbourhoods that each set their own weight. [US7853096](https://patents.google.com/patent/US7853096) until 2029-01 (`crates/algo/src/tone/shadows_highlights.rs`)
- An Auto button in Develop must be a fixed or statistical computation, not a learned or fitted model feeding editable sliders. [US11930303](https://patents.google.com/patent/US11930303) until 2042-10 (`ios/PhotoWagon/CameraRaw.swift`)
- Keep the Color Mixer as fixed per-band sliders. No per-band colour histogram with two-axis drag. [US20260147464A1](https://patents.google.com/patent/US20260147464A1) pending (`crates/algo/src/camera_raw.rs`)
- Keep parameters on separate controls. Don't let one gesture surface drive two parameters (such as pivot and contrast) over a live histogram. [US20260147463A1](https://patents.google.com/patent/US20260147463A1) pending
- Keep sliders as plain amount sliders. No remove/boost slider for an effect already in the photo (reflection, flare, haze) where the middle means "as is". [US20260161274A1](https://patents.google.com/patent/US20260161274A1) pending (`ios/PhotoWagon/CameraRaw.swift`)
- Clipping or HDR warnings: use histogram marks or outlines with fixed thresholds. Don't recolour image pixels by luminance range, and don't base the display on the device's HDR headroom. [US12602841](https://patents.google.com/patent/US12602841) until 2043-10, [US20260212550A1](https://patents.google.com/patent/US20260212550A1) pending (`crates/algo/src/histogram.rs`)
- Keep lens correction on a manual or generic profile. No automatic lookup in a lens profile database keyed on EXIF lens make or model. [US8194993](https://patents.google.com/patent/US8194993) until 2031-04 (`crates/algo/src/lens.rs`)

### Transform and warp

- Content-Preserving Scale scales the whole layer. Don't resize a selected region by its energy and leave the rest. [US8160398](https://patents.google.com/patent/US8160398) until 2031-02 (`crates/engine/src/edit_menu_cmds.rs`, `crates/algo/src/retarget.rs`)
- Keep the warp on straight whole columns and rows, with protection as per-column importance. Never add seam finding (connected low-energy paths). [US8218900](https://patents.google.com/patent/US8218900) until 2031-05, [US8290300](https://patents.google.com/patent/US8290300) until 2031-05, MERL [US7477800](https://patents.google.com/patent/US7477800) until about 2027-03 (`crates/algo/src/retarget.rs`)
- Don't bring back content-preserving wide-angle correction (a salience-weighted system that remaps the image). Use a lens profile or a manual warp. [US8525871](https://patents.google.com/patent/US8525871) until 2031-08, [US9742994](https://patents.google.com/patent/US9742994) until 2036-06
- Don't bring back Guided Upright (straightening from lines the user draws). [US9519954](https://patents.google.com/patent/US9519954) until 2035-07, [US9729787](https://patents.google.com/patent/US9729787) until 2036-11, [US10652472](https://patents.google.com/patent/US10652472) until 2038-08
- Warp one surface through a single mesh. Don't split the image into patches that deform separately and get stitched. [US10832376](https://patents.google.com/patent/US10832376) until 2039-02 (`crates/algo/src/warp.rs`, `crates/geom/src/warp.rs`)
- Mesh warp: single-point drags only. No multi-select of anchors with a box to transform them as a group. [US10878641](https://patents.google.com/patent/US10878641) until 2039-06 (`crates/geom/src/warp.rs`, `crates/ui-egui/src/transform_tool.rs`)
- Fluid Warp: no water reflection mode mirroring across a frozen boundary, and no path-vector-times-matrix update. Claim 1 is broad: check the claims and term first. [US7567263](https://patents.google.com/patent/US7567263) until 2027-06 (`crates/algo/src/liquify.rs`)
- Perspective Warp: no pinned or locked sub-areas with an indicator. [US9117253](https://patents.google.com/patent/US9117253) until 2033-06 (`crates/algo/src/perspective.rs`)
- Perspective Warp: fix shared edges with a direct continuity correction. Don't compute an explicit 3D consistency error. [US9196096](https://patents.google.com/patent/US9196096) until 2033-11 (`crates/algo/src/perspective.rs`)
- Perspective Planes: planes are user-drawn. Don't detect planes from an edge map and line crossings. [US10430920](https://patents.google.com/patent/US10430920) until 2036-11 (`crates/algo/src/vanishing.rs`)
- Perspective Planes: don't constrain drags along vanishing-point rays, or clone from one plane into another derived from it. [US7808502](https://patents.google.com/patent/US7808502) until 2028-08 (`crates/algo/src/vanishing.rs`, `crates/engine/src/vp_cmds.rs`)

### Crop and canvas size

- Crop's Fill option: a plain toggle or setting. No picker with preview thumbnails of both outcomes after the frame is placed. [US9478006](https://patents.google.com/patent/US9478006) until 2035-01 (`crates/engine/src/image_cmds.rs`, `ios/PhotoWagon/EditorModel.swift`)
- Fill crop gaps with the exemplar fill, not PatchMatch-style overlapping voting. If unsure, crop to the largest clean rectangle. [US10109093](https://patents.google.com/patent/US10109093) until 2036-10 (`crates/engine/src/crop_fill.rs`)
- A crop loupe is a plain magnifier. Don't draw the crop rectangle and the outside area in a loupe at a different zoom. [US11354027](https://patents.google.com/patent/US11354027) until 2041-01
- Keep canvas resize and crop fill non-ML. Don't split out the subject and regenerate the background with a model. [US20250225609A1](https://patents.google.com/patent/US20250225609A1) pending (`crates/engine/src/crop_fill.rs`)

### Panorama, HDR and merge

- Panorama: blend overlaps with soft weights only. No hard seams where one image masks part of another. [US7646932](https://patents.google.com/patent/US7646932) until 2028-05 (`crates/algo/src/panorama.rs`, `crates/engine/src/photo_cmds.rs`)
- Panorama: bake exposure gains into pixels. Don't output per-photo exposure adjustment layers with masks. [US8368720](https://patents.google.com/patent/US8368720) until 2030-02 (`crates/engine/src/photo_cmds.rs`)
- If blend methods are auto-suggested, choose by image count, EXIF or user choice, not by aligned overlap area. [US8160392](https://patents.google.com/patent/US8160392) until 2030-12 (`crates/engine/src/photo_cmds.rs`)
- Fit-to-frame: crop, fill the gaps or use a global projection. Don't warp a boundary-sampled mesh to a rectangle. [US9978120](https://patents.google.com/patent/US9978120) until 2036-11 (`crates/algo/src/warp.rs`)
- Merge to HDR runs once on the chosen files. No live preview that recomputes as images are added or removed. [US8027538](https://patents.google.com/patent/US8027538) until 2030-02 (`crates/algo/src/hdr.rs`)

### Layers, snapping and compositing

- Snap moved layers to the canvas edges and centre only. No snapping to other layers with smart guides, no edge-to-centre indicators, no equal-spacing snap with distance labels or gap markers, no arrow-key distribution snap. [US10331319](https://patents.google.com/patent/US10331319) until 2037-05, [US10782861](https://patents.google.com/patent/US10782861) until 2039-05 (`ios/PhotoWagon/ToolGestures.swift`)
- Equal-spacing guides: never compare a horizontal distance with a vertical one. Single axis or none. [US10846878](https://patents.google.com/patent/US10846878) until 2039-04 (`crates/engine/src/snap.rs`)
- Snap to bounding-box edges and centres, guides, grid and canvas. Don't derive anchors from an object's real outline and rank them. [US11907515](https://patents.google.com/patent/US11907515) until 2042-08 (`crates/engine/src/snap.rs`)
- Snap the whole moving box's edges and centres. Don't pick the snapping point by distance from the first touch. [US10061496](https://patents.google.com/patent/US10061496) until 2037-01 (`crates/engine/src/snap.rs`)
- Groups with styles: composite the group isolated, apply the style, then composite onto the backdrop. No per-layer blend-in, blend, factor-out loop. [US8948509](https://patents.google.com/patent/US8948509) until 2033-04 (`crates/compose/src/native.rs`, `crates/engine/src/layer_style.rs`)
- Plain back-to-front coverage compositing may read on this. Don't group objects that share edges. Unclear: check the claims first. [US7733354](https://patents.google.com/patent/US7733354) until 2028-09 (`crates/compose/src/lib.rs`, `crates/vector/src/lib.rs`)
- New artboard size comes from the selected artboard, a preset or a default, never from which one was edited last. [US8667406](https://patents.google.com/patent/US8667406) until 2031-02 (`crates/engine/src/artboard_cmds.rs`)

### Canvas display

- Let the GPU sampler pick the mip level. Don't read the zoom from the view matrix to pick a stored lower-resolution copy. [US9135885](https://patents.google.com/patent/US9135885) until 2032-02 (`crates/gpu/src/viewport.rs`)
- If stale tiles ever stand in during rendering, pick them by one fixed rule. Don't rank by completeness first and scale second. [US9235873](https://patents.google.com/patent/US9235873) until 2034-03 (`crates/gpu/src/viewport.rs`)
- Pasted or moved objects: no low-resolution preview followed by a full-resolution refine. Show the final result. [US9058699](https://patents.google.com/patent/US9058699) until 2033-01 (`crates/compose/src/proxy.rs`)

### Paths and vectors

- Add Anchor is a tap on the segment. No off-path drag that slides a preview point along the path. [US10572026](https://patents.google.com/patent/US10572026) until 2038-11 (`ios/PhotoWagon/ToolGestures.swift`)
- Delete Anchor uses a simple join. No refit that samples the path and solves tangent lengths. [US11615562](https://patents.google.com/patent/US11615562) until 2041-12 (`crates/vector/src/edit.rs`)

### Type

- Keep line breaking greedy. No Knuth-Plass style whole-paragraph optimisation; use first-fit or a few lines of look-ahead. [US7797624](https://patents.google.com/patent/US7797624) until 2029-07 (`crates/text/src/layout.rs`)
- Leave font fallback to the shaping library. No per-character glyph-coverage search over a safe-font set, no "preferred font per character" model. [US7982737](https://patents.google.com/patent/US7982737) until 2030-04 (`crates/text/src/fonts.rs`)
- Font suggestions: rank by name, metrics or classification. Don't render every candidate and sort by pixel similarity. [US12608966](https://patents.google.com/patent/US12608966) until 2043-09 (`crates/engine/src/type_extra_cmds.rs`)

### Brushes and painting

- Keep flow as a fraction of the remaining headroom. No fixed per-dab increment (max times flow), no separate max-deposit cap or per-stroke deposit setting, and don't mix colour by a factor from the increment. [US10891760](https://patents.google.com/patent/US10891760) until 2038-12, [US11704842](https://patents.google.com/patent/US11704842) until 2040-12, [US12106400](https://patents.google.com/patent/US12106400) until 2043-05 (`crates/paint/src/render.rs`)
- Size follows pressure (with the minimum). Don't use the previous dab's size for the next one. [US9459790](https://patents.google.com/patent/US9459790) until 2032-03 (`crates/paint/src/dynamics.rs`)
- Pressure to size is a plain curve. No pen-lift cutoff that rescales pressure onto a minimum-width floor. [US9720537](https://patents.google.com/patent/US9720537) until 2036-01 (`crates/paint/src/dynamics.rs`)
- Pressure is a freely edited curve per dynamic. No "default value plus sensitivity" control. [US9740310](https://patents.google.com/patent/US9740310) until 2035-08 (`crates/paint/src/curve.rs`)
- No gesture where a held finger changes brush size, hardness or colour while another paints. Two-finger touches are navigation. [US9003334](https://patents.google.com/patent/US9003334) until 2033-03
- Symmetry mirrors stroke points. Don't build repeat or radial copies as a list of affine matrices on a base shape. [US11461874](https://patents.google.com/patent/US11461874) until 2040-04 (`crates/engine/src/symmetry_cmds.rs`)
- Local adjustments: each is its own adjustment layer with a mask. No list of brush adjustments to pick and re-edit by area or value. [US10481774](https://patents.google.com/patent/US10481774) until 2036-10 (`crates/engine/src/adjust_cmds.rs`)

### Faces and portraits

- Red eye stays tap-driven. If automatic, don't chain face, eye and red-ellipse search with a predicted second eye. [US7623707](https://patents.google.com/patent/US7623707) until 2027-07 (`crates/algo/src/redeye.rs`)
- Face retouch stays manual. Don't auto-find dark areas from landmarks and skin colour, or size smoothing from a detected wrinkle. [US11574388](https://patents.google.com/patent/US11574388) until 2041-04 (`crates/algo/src/faces.rs`)
- Face-aware warp: a plain displacement field from sliders and landmark positions. No landmark mesh with combined per-feature fields, and no mesh shown or edited in a modal control. [US10223767](https://patents.google.com/patent/US10223767) until 2037-05, [US9646195](https://patents.google.com/patent/US9646195) until 2035-11 (`crates/algo/src/liquify.rs`, `crates/engine/src/face_cmds.rs`)

### Sky replacement

- Don't segment the replacement sky, or auto-split into a foreground layer plus a movable sky layer. Skip a CNN probability map, bounding-box coverage check and adjustment layer. [US11042990](https://patents.google.com/patent/US11042990) until 2039-05 (`crates/algo/src/segment/sky.rs`)
- Sky library: load previews and full images by separate paths. Don't store a per-preset low-res record with region info from the user's photo. [US11645788](https://patents.google.com/patent/US11645788) until 2041-04
- Don't build a defringe layer from a soft mask times the grey replacement sky, or take both masks from one network. [US11776184](https://patents.google.com/patent/US11776184) until 2041-08 (`crates/engine/src/select_extra_cmds.rs`)

### AI features and caching

- Don't keep a cache of AI model results (Apple Vision) that is checked before running the model. Run it again, or tie the result to one operation. [US12579596](https://patents.google.com/patent/US12579596) until 2042-01 (`ios/PhotoWagon/ObjectFinder.swift`, `EditorModel.swift`)
- AI Remove (`crates/engine/src/retouch_cmds/remove.rs`, `ios/PhotoWagon/AIRemove.swift`): the area is what the user painted or selected plus a fixed 128-pixel margin, never derived from the model. If that fits the model's square it runs at full size; if not, it is scaled down uniformly (keeping its shape, padded to the square), then scaled back up and faded in over the outer half of the margin the hole grew by (never past the hole). Match Colour shifts the fill's levels to the statistics of a ring round the hole and clones it in seamlessly against the hole's own outer pixels; it never estimates a pixel's colour from border pixels in opposite directions ([US9911201](https://patents.google.com/patent/US9911201)). The user picks AI Remove or Quick Fill (no automatic choice). The owner judged this outside [US20250363689A1](https://patents.google.com/patent/US20250363689A1) (pending), whose claims derive the bounds from the model's parameters (2026-10-22). Recheck if it is granted, and don't reshape the area to fit the model or grow it by a factor.
- AI fill: don't upsample the result by learned patch matching with coordinate scaling. Use a plain edge-aware upsample. [US11948281](https://patents.google.com/patent/US11948281) until 2040-11
- AI fill from a low-res model: no second learned refiner that sharpens only the filled area. [US12602755](https://patents.google.com/patent/US12602755) until 2043-08
- AI fill: don't post-process the output with a patch search guided by it. [US20250139748A1](https://patents.google.com/patent/US20250139748A1) pending
- AI fill: don't blend the output back through an expanded copy of the mask. [US20260154796A1](https://patents.google.com/patent/US20260154796A1) pending
- AI fill context: the whole image, a fixed-size crop, or the user's area plus a fixed margin. Don't derive the bounds from the model, reshape them to its aspect ratio, or grow them by a factor. [US20250363689A1](https://patents.google.com/patent/US20250363689A1) pending
- No generative expand (with an auto mask or a model's fixed ratios). Fill extensions with the exemplar fill. [US12626423](https://patents.google.com/patent/US12626423) until 2044-03, [US20250124626A1](https://patents.google.com/patent/US20250124626A1) pending (`crates/engine/src/crop_fill.rs`)
- No ControlNet-style side network added to the noise prediction. Any control-conditioned diffusion needs a licence check first. [US12462348](https://patents.google.com/patent/US12462348) until 2044-02
- Generated layers: don't auto-detect a subject mask on the output and attach it to the new layer. [US12462456](https://patents.google.com/patent/US12462456) until 2044-03
- No per-brush or per-pixel preservation slider tied to the prompt weight. One global strength or none. [US12646231](https://patents.google.com/patent/US12646231) until 2043-11
- Don't deliver a generated result plus its source as a two-layer stack. [US20250117991A1](https://patents.google.com/patent/US20250117991A1) pending
- Build prompts from document layers, not the screen. Don't show output next to screen pixels in a separate window. [US20260087700A1](https://patents.google.com/patent/US20260087700A1) pending
- No text-instructed attribute edits with a generative model. Use manual adjustments. [US20260105661A1](https://patents.google.com/patent/US20260105661A1) pending
- Any text-conditioned generative edit may read on this broad claim. Check the claims first and get counsel review before adding one. [US20250078200A1](https://patents.google.com/patent/US20250078200A1) pending

### Touch UI and workflow

- Sliders: no precision zones by vertical or off-slider finger distance. Use steppers, a fine toggle, long-press or typed values. [US10496265](https://patents.google.com/patent/US10496265) until 2037-11 (`ios/PhotoWagon/Panels.swift`)
- History is a text list of step names. No preview thumbnail per step; thumbnails stay with named Snapshots. [US11003467](https://patents.google.com/patent/US11003467) until 2037-03 (`ios/PhotoWagon/Panels.swift`)

### File formats

- Don't read or write gain maps with per-channel gamma and min/max metadata (Ultra HDR / Adobe style), or scale one by an ambient light sensor. Export plain PQ/HLG or use the system codecs. [US12666158](https://patents.google.com/patent/US12666158) until 2043-01
- PSD import of unsupported layers: import as editable, drop with a warning, or keep as hidden data. No locked stand-in layer showing the flattened look. [US11087515](https://patents.google.com/patent/US11087515) until 2040-02 (`crates/io/src/psd_import.rs`)
- Reading and writing PSD itself is fine: the 2026-10-20 review found no Adobe patent on the format, and its compression (PackBits, ZIP) is patent-free. The other rules for Adobe's formats are in [trademark-guardrails.md › Adobe's file formats](trademark-guardrails.md#adobes-file-formats).

## Comes back when the patent ends

Features removed or weakened for a patent. Check the real expiry (continuations, terminal disclaimers, unpaid fees) and any other patent above before bringing one back.

| Feature | Patent | Could return |
|---|---|---|
| Spot Repair's Proximity Match (one source searched around the spot) | US7471417 | 2027-02 |
| Seam carving for Content-Aware Scale | MERL US7477800 | about 2027-03 |
| Panorama hard seams | US7646932 | 2028-05 |
| Combining soft selections where both are soft | US7701470 | 2028-08 |
| Shadows/Highlights with separate shadow and highlight radii | US7853096 | 2029-01 |
| Surface Blur's 8-bit sliding histogram | US7920741 | 2030-02 |
| Content-Aware Scale on a selection only | US8160398 | 2031-02 |
| Refine Edge Brush for hair and fur | US8406566 (and see US10068361, US9786078) | 2031-07 |
| Refine Edge's guided-filter colour fit | US8264500 | 2031-09 |
| Field Blur pins with a blur amount | US9019310 | 2033-03 |
| PatchMatch fill | US8285055, US8571328, US8861868, US9396530; US8811749 (not in our data, check) | 2034-10 at the earliest |
| Path Blur Taper | US9723204 | 2035-04 |
| Adaptive Wide Angle | US8525871, US9742994 | 2036-06 |
| Guided Upright | US9519954, US9729787, US10652472 | 2038-08 |
| Custom sampling area for Fill from Surroundings | US10706509 | 2038-09 |
| Snapping to other layers with smart guides | US10331319, US10782861 | 2039-05 |
| Exemplar fill's coarse-to-fine source map | US9305329, US9396530, US11449974 (and see US12373915, to 2043-12) | 2040-04 |
| Automatic sampling area by clustering | US11042969, US12136199 | 2041-10 |
| Keeping Apple Vision results between operations | US12579596 | 2042-01 |

## Keeping this current

- Re-run the patent review once a year, and before adding a big feature.
- When a patent expires, remove its line here (and its row in the table above once the feature is back).
- Record new findings here in the same change that acts on them.
