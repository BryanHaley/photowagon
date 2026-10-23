# Trademark guardrails

Names PhotoWagon must not use as its own. Not legal advice.

- **Read this** before you name a feature, tool, menu item, message, preset, file format label or icon.
- **If a name is listed:** pick our own name, similar and meaningful so a Photoshop user recognises it (see AGENTS.md). Then add it to the table of our names below.
- **Naming Adobe's products to say what we work with is fine:** "Photoshop® (PSD)" as a file format, "a Photoshop .atn can't hold this step", and the magic strings file formats require (`Adobe Photoshop Document Data Block`, `8BIM`, `Photoshop 3.0`, `%!PS-Adobe`, `Camera Raw Filter` inside PSD smart filters). Code comments and internal docs can name Photoshop freely.
- Sources: Adobe's [trademark list](https://www.adobe.com/legal/permissions/trademarks.html) (as of 21 May 2026, not complete) and the USPTO register (checked 2026-10-20).

## Rules

- **Never name a feature, tool or setting with an Adobe mark.** The list below has the ones a photo editor could reach for.
- **Mark Photoshop where the UI names it:** "Photoshop® (PSD)", with Adobe's notice nearby: "Adobe and Photoshop are either registered trademarks or trademarks of Adobe in the United States and/or other countries. PhotoWagon isn't affiliated with Adobe." (`ios/PhotoWagon/Documents.swift`). Docs write "Adobe Photoshop" at first mention.
- **Never say or suggest Adobe made our output.** Files we write name PhotoWagon as the writing program (the PSD version info resource, `crates/psd/src/resources.rs`).
- **No Adobe logos or look-alikes:** no two-letter rounded-square app or tool icons in Adobe's style (Adobe registered its "Ps" design), no Adobe PDF, DNG or Creative Cloud logos.
- **Adobe's font names that are everyday words** (Birch, Willow, Poplar, Source, Toolbox, Flood, Graphite, Ultra, Nueva and others) are fine as ordinary words, such as a tree preset or a "Source" setting. Never ship a font or typeface under one of them.

## Adobe's file formats

Reading and writing PSD (and PSB, .atn, .abr, .grd and Adobe's other formats) is fine. Adobe publishes the [PSD specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/) "for 3rd parties to read and write the Photoshop native file format", with no click-through or confidentiality terms. GIMP, Krita, Affinity Photo, Pixelmator Pro, Photopea and Procreate all do it. To keep it that way:

- **Write our own code** from the public spec and permissively licensed readers (psd-tools, ag-psd). Don't copy Adobe's code or the spec's text.
- **Never put Adobe-owned content in the files we save:** no Adobe ICC profiles, fonts, presets, brushes or other assets.
- **Name PhotoWagon as the program that wrote the file**, never Adobe (see Rules).
- **Test files are ours:** the Photoshop-authored oracles in photocraft-corpus were made by us, never taken from Adobe's samples.
- **Patents:** none found on the format itself. Follow the File formats section of [patent-guardrails.md](patent-guardrails.md#file-formats), such as no locked stand-in layers for unsupported PSD layers.

## Adobe marks to avoid as our names

- **Company and products:** Adobe, Photoshop (and Photoshop Elements, Photoshop Express), Lightroom, Camera Raw, Bridge, Illustrator, InDesign, Acrobat, Reader, Fresco, Express, Firefly, Sensei, Creative Cloud (and "CC"), Creative Suite, Behance, Stock, Substance 3D, Premiere, After Effects, Frame.io, Capture, Adobe Color, Adobe Fonts, Dreamweaver, Flash, PostScript.
- **Formats and colour spaces:** Adobe RGB and Adobe RGB (1998), DNG, XMP, Adobe PDF. Fine for naming the format we read or write; not as names for our own things.
- **Feature names Adobe claims:** Content Credentials, Content Authenticity Initiative, Cutout™, Upright™, Lumetri.
- **Photoshop's feature names** (not registered, but our naming rule replaces them): Content-Aware (Fill, Scale, Move, Patch), Smart Object, Smart Filters, Neural Filters, Generative Fill, Generative Expand, Puppet Warp, Liquify, Photomerge, Select and Mask, Refine Edge, Adaptive Wide Angle, Guided Upright, Sky Replacement, Proximity Match.

## Other companies' marks

- **Magic Eraser:** Google's name for its photo feature; P&G's registered mark (for cleaning pads).
- **Liquify:** registered by another company (for hosting services).

## Our names

| Photoshop | PhotoWagon |
|---|---|
| Content-Aware Fill, Fill › Content-Aware | Fill from Surroundings |
| Patch: Content-Aware | Patch (From Surroundings) |
| Content-Aware Scale | Content-Preserving Scale |
| Camera Raw Filter | Develop |
| Smart Objects | Embedded Layers |
| Proximity Match | Match Nearby |
| Filter › Artistic › Cutout | Cut Paper |
| Photoshop as the writer of exported PSDs | PhotoWagon |

## Still to decide

- Photoshop tool names still in the app: Select Subject, Object Selection, Quick Selection, Magic Wand, Magic Eraser, Smart Sharpen, Lens Blur, Perspective Warp, Remove Tool. None is registered for software, so renaming is a naming choice, not a legal need.
- The colour profile "Adobe RGB (1998) compatible" (`crates/cms/src/builtin.rs`, `ios/PhotoWagon/Documents.swift`). Saying "compatible" is normally fine; ArgyllCMS calls the same space "ClayRGB1998" to avoid the name.
