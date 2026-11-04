import Foundation

/// What Omega knows about. Omega makes cases for every engine command by itself; this holds what
/// it can't work out: commands it leaves out (and why), settings to always pass, and the app's own
/// lists. `OmegaCatalogTests` fails when something new appears that isn't here.
enum OmegaCatalog {
    /// Commands Omega doesn't run, with why.
    static let skipped: [String: String] = [
        "document.fingerprint": "Omega's own check",
    ]

    /// Commands that move through history themselves: "Undo brings it back" doesn't apply.
    static let historyCommands: Set<String> = [
        "edit.undo", "edit.redo", "edit.toggleLastState",
        "history.undo", "history.redo", "history.selectState", "history.selectSnapshot", "history.deleteState",
    ]

    /// Changes that aren't history steps on purpose, with why.
    static let notUndoable: [String: String] = [
        "layer.setExpanded": "opening or closing a group in the Layers panel",
        "animation.selectFrame": "going to another frame", "timeline.setFrame": "going to another frame",
        "timeline.nextFrame": "going to another frame", "timeline.previousFrame": "going to another frame",
    ]

    /// A param that lets a command run while its menu item is greyed out, with why.
    static let runsWhenGreyed: [String: (param: String, why: String)] = [
        "layer.new.layerFromBackground": ("ifPresent", "an action's step that does nothing without a Background"),
    ]

    /// Commands after which a flat export (PNG, PSD) rightly looks different from the document's
    /// own numbers, with why.
    /// Why these look different at 32 bits: the numbers are linear light, or the look isn't kept.
    static let differsAt32Bits: [String: String] = [
        "image.adjustments.invert": "inverts linear light",
        "layer.newAdjustmentLayer.invert": "inverts linear light",
        "file.scripts.browse": "the script inverts",
        "actions.delete": "the action inverts",
        "image.autoColor": "measured on linear light",
        "filter.render.clouds": "made in linear light",
        "filter.render.fibers": "made in linear light",
        "gradient.fill.create": "fill colours are used as stored",
        "gradient.presets.apply": "fill colours are used as stored",
        "paint.gradient": "blends in linear light",
        "layer.fill.pattern.set": "fill colours are used as stored",
        "edit.assignProfile": "swaps the linear profile for the working one",
        "image.mode.colorTable": "the palette is 8-bit",
        "image.mode.multichannel": "no profile to show the numbers through",
        "file.newFromClipboard": "the fixture's clipboard copy differs",
    ]

    static let flatExportDiffers: [String: String] = [
        "file.automate.mergeToHdrPro": "the file clips the light above white",
        "layer.fill.pattern.set": "a CMYK pattern's preview rounds through RGB",
        "image.mode.duotone": "the file shows the inks; the document's numbers are its one gray channel",
        "image.mode.indexedColor": "the file has the palette's colours",
        "image.mode.bitmap": "the file is black and white dots",
        "image.mode.duotoneInks": "the file shows the inks; the document's numbers are its one gray channel",
    ]

    /// The plug-in in Samples/formats.
    private static let omegaPlugin = "net.photowagon.omega.invert"

    /// Settings passed to a command in every case, where the engine can't run it without them.
    /// Filled in per case: "@x:0.5" and "@y:0.5" are positions as fractions of the document,
    /// "$LAYER" the active layer's id, "$OTHER" another layer's, "$IMAGE" a PNG, "$PSD" a PSD,
    /// "$GBR" a brush file, "$JPGS" a folder of two JPEGs, "$PHOTO" a photo, "$OVERLAP" a folder of two overlapping
    /// photos, "$PRESETS" a presets file, "$OUT" an empty folder, "$RESULT:key" that key of what the
    /// last setup step answered; "$ATN", "$ABR",
    /// "$GRD", "$ACO", "$NOTES" (a PSD with notes), "$CSV", "$GIF", "$FRAMES" (a folder of PNGs),
    /// "$WASM" and "$FORMATS" (their folder) from Samples/formats.
    static let fixedParams: [String: [String: Any]] = {
        var p: [String: [String: Any]] = [
            // Never reach a printer.
            "file.print": ["dryRun": true],
            "file.printOneCopy": ["dryRun": true],
        ]
        let stroke: [[String]] = [["@x:0.2", "@y:0.3"], ["@x:0.5", "@y:0.5"], ["@x:0.8", "@y:0.7"]]
        for id in ["paint.stroke", "paint.pencil", "paint.mixerBrush", "paint.colorReplacement", "paint.backgroundEraser",
                   "paint.cloneStamp", "paint.patternStamp", "paint.healingBrush", "paint.spotHealing", "paint.dodge",
                   "paint.burn", "paint.sponge", "paint.blur", "paint.sharpen", "paint.smudge", "paint.historyBrush"] {
            p[id] = ["points": stroke]
        }
        let at: [String: Any] = ["x": "@x:0.4", "y": "@y:0.5"]
        let box: [String: Any] = ["x": "@x:0.2", "y": "@y:0.2", "width": "@x:0.5", "height": "@y:0.5"]
        let quad: [[String]] = [["@x:0.1", "@y:0.1"], ["@x:0.9", "@y:0.15"], ["@x:0.85", "@y:0.9"], ["@x:0.15", "@y:0.85"]]
        let corners: [[String]] = [["@x:0", "@y:0"], ["@x:1", "@y:0"], ["@x:1", "@y:1"], ["@x:0", "@y:1"]]
        let triangle: [[String]] = [["@x:0.2", "@y:0.2"], ["@x:0.8", "@y:0.3"], ["@x:0.5", "@y:0.8"]]
        let steps: [[Any]] = [["image.adjustments.invert", [String: Any]()]]
        for id in ["paint.redEye", "paint.magicEraser", "document.sampleColor", "view.setRulerOrigin", "view.colorSamplers.add",
                   "count.add", "notes.add", "type.hitTest", "layer.pickAt"] { p[id] = at }
        for id in ["select.rect", "layer.selectInRect", "layer.new.frame"] { p[id] = box }
        p["paint.patch"] = ["offset": [3, 2]]
        p["paint.contentAwareMove"] = ["offset": [3, 2]]
        p["paint.gradient"] = ["from": ["@x:0.1", "@y:0.5"], "to": ["@x:0.9", "@y:0.5"]]
        p["gradient.fill.create"] = ["from": ["@x:0.1", "@y:0.5"], "to": ["@x:0.9", "@y:0.5"]]
        p["select.lasso"] = ["points": triangle]
        p["select.magneticLasso"] = ["points": triangle]
        p["select.quick"] = ["points": stroke]
        p["select.object"] = ["point": ["@x:0.4", "@y:0.4"]]
        p["select.objectPreview"] = ["point": ["@x:0.4", "@y:0.4"]]
        p["select.loadSelection"] = ["channel": "transparency"]
        p["layer.select"] = ["layer": "$OTHER"]
        p["layer.moveTo"] = ["target": "$OTHER"]
        p["layer.layerMask.copyTo"] = ["to": "$OTHER"]
        p["layer.layerStyle.transferEffects"] = ["from": "$LAYER", "to": "$OTHER"]
        p["layer.smartFilter.transfer"] = ["from": "$OTHER", "to": "$LAYER"]
        p["layer.layerStyle.replace"] = ["layer": "$LAYER", "effects": [["kind": "dropShadow", "params": [String: Any]()]]]
        p["layer.layerStyle.makeDefault"] = ["kind": "dropShadow", "params": [String: Any]()]
        p["layer.layerStyle.defaultFor"] = ["kind": "dropShadow"]
        p["shape.create"] = ["rect": ["@x:0.2", "@y:0.2", "@x:0.5", "@y:0.5"]]
        p["path.set"] = ["path": ["subpaths": [["closed": true, "knots": triangle]]]]
        p["path.rename"] = ["to": "Omega"]
        p["path.transform"] = ["translateX": 2]
        p["path.addAnchor"] = ["subpath": 0, "knot": 0]
        p["path.deleteAnchor"] = ["subpath": 0, "knot": 0]
        p["path.convertPoint"] = ["subpath": 0, "knot": 0]
        p["path.moveHandle"] = ["subpath": 0, "knot": 0, "handle": "out", "to": ["@x:0.6", "@y:0.4"]]
        p["path.bendSegment"] = ["subpath": 0, "knot": 0, "move": [2, 2]]
        p["path.moveAnchors"] = ["anchors": [[0, 0]], "move": [2, 2]]
        p["path.clippingPath.set"] = ["name": "Omega"]
        p["view.newGuideLayout"] = ["columns": 3]
        p["view.colorSamplers.move"] = ["index": 0, "x": "@x:0.6", "y": "@y:0.6"]
        p["view.colorSamplers.delete"] = ["index": 0]
        for id in ["view.moveGuide", "view.editGuide", "view.deleteGuide"] { p[id] = ["orientation": "horizontal", "index": 0, "position": "@y:0.3"] }
        p["document.activate"] = ["document": 0]
        p["document.move"] = ["to": 0]
        p["image.perspectiveCrop"] = ["corners": quad]
        p["image.adjustmentEyedropper"] = ["kind": "levels", "params": [String: Any](), "eyedropper": ["point": "black", "at": ["@x:0.3", "@y:0.3"]]]
        p["edit.transform"] = ["scaleX": 50, "scaleY": 50]
        p["edit.transform.warpGrid"] = ["size": 3]
        p["edit.perspectiveWarp"] = ["planes": [["src": corners, "dst": quad]]]
        p["layer.smartObjects.perspectiveWarp"] = ["planes": [["src": corners, "dst": quad]]]
        p["filter.vanishingPoint"] = ["planes": [["corners": quad]]]
        p["filter.distort.displace"] = ["mapPath": "$IMAGE"]
        p["count.remove"] = ["index": 0]
        p["count.move"] = ["index": 0, "to": ["@x:0.6", "@y:0.6"]]
        p["count.clear"] = ["group": "all"]
        p["notes.set"] = ["index": 0, "text": "Changed"]
        p["notes.delete"] = ["index": 0]
        p["measurementLog.export"] = ["path": "$OUT/log.csv"]
        p["animation.selectFrame"] = ["frame": 0]
        p["animation.setDelay"] = ["delay": 0.5]
        p["animation.setLoops"] = ["loops": 2]
        p["timeline.setFrame"] = ["frame": 1]
        for id in ["channel.duplicate", "channel.delete", "channel.setVisible", "channel.options"] { p[id] = ["channel": "Omega"] }
        p["channel.rename"] = ["channel": "Omega", "name": "Renamed"]
        p["channel.move"] = ["channel": "Omega", "to": 0]
        for id in ["layerComp.apply", "layerComp.delete", "layerComp.duplicate", "layerComp.update", "layerComp.setOptions"] { p[id] = ["comp": "Omega"] }
        p["layerComp.rename"] = ["comp": "Omega", "name": "Renamed"]
        p["layerComp.setComment"] = ["comp": "Omega", "comment": "A comment"]
        for id in ["slice.set", "slice.promote", "slice.delete"] { p[id] = ["number": 1] }
        p["slice.divide"] = ["number": 1, "horizontal": 2, "vertical": 2]
        p["type.caret"] = ["index": 0]
        p["type.navigate"] = ["index": 0, "move": "wordNext"]
        p["layer.exportAs"] = ["path": "$OUT/layer.png"]
        p["layer.quickExportAsPng"] = ["path": "$OUT/layer.png"]
        p["file.saveACopy"] = ["path": "$OUT/copy.png"]
        p["file.export.quickExport"] = ["path": "$OUT/quick.png"]
        for id in ["file.openAs", "file.placeEmbedded", "file.placeLinked", "layer.smartObjects.replaceContents", "layer.smartObjects.relinkToFile"] { p[id] = ["path": "$IMAGE"] }
        p["layer.smartObjects.exportContents"] = ["path": "$OUT/contents.png"]
        p["layer.smartObjects.convertToLinked"] = ["path": "$OUT/linked.pcraft"]
        p["file.import.notes"] = ["path": "$NOTES"]
        p["file.import.variableDataSets"] = ["path": "$CSV"]
        p["actions.load"] = ["path": "$ATN"]
        p["brush.presets.importAbr"] = ["path": "$ABR", "group": "Omega"]
        p["gradient.presets.importGrd"] = ["path": "$GRD", "group": "Omega"]
        p["swatches.import"] = ["path": "$ACO", "group": "Omega"]
        p["layer.videoLayers.newVideoLayerFromFile"] = ["path": "$GIF"]
        p["layer.videoLayers.replaceFootage"] = ["path": "$GIF"]
        p["file.import.videoFramesToLayers"] = ["path": "$FRAMES"]
        p["plugin.install"] = ["path": "$WASM"]
        p["plugin.reload"] = ["path": "$FORMATS"]
        p["plugin.remove"] = ["id": omegaPlugin]
        p["plugin.run"] = ["id": omegaPlugin]
        p["file.scripts.loadFilesIntoStack"] = ["paths": "$JPGS"]
        p["file.scripts.statistics"] = ["input": "$JPGS"]
        p["file.scripts.imageProcessor"] = ["input": "$JPGS", "output": "$OUT"]
        p["file.automate.contactSheetII"] = ["input": "$JPGS"]
        p["file.automate.lensCorrection"] = ["input": "$JPGS", "output": "$OUT"]
        p["file.automate.batch"] = ["steps": steps, "input": "$JPGS", "output": "$OUT"]
        p["file.automate.photomerge"] = ["paths": "$OVERLAP"]
        p["file.automate.mergeToHdrPro"] = ["paths": "$OVERLAP", "exposures": [0, 2]]
        p["file.automate.runDroplet"] = ["droplet": "$OUT/omega.pcdroplet", "input": ["$JPGS"], "output": "$OUT"]
        p["edit.presets.migratePresets"] = ["path": "$PRESETS"]
        p["file.automate.createDroplet"] = ["path": "$OUT/omega.pcdroplet", "steps": steps]
        p["file.scripts.browse"] = ["steps": steps]
        p["file.package"] = ["dir": "$OUT"]
        for id in ["file.export.layersToFiles", "file.export.artboardsToFiles", "file.export.layerCompsToFiles", "file.export.dataSetsAsFiles"] { p[id] = ["dir": "$OUT"] }
        p["file.export.artboardsToPdf"] = ["path": "$OUT/boards.pdf"]
        p["file.export.colorLookupTables"] = ["path": "$OUT/look.cube"]
        p["file.export.pathsToIllustrator"] = ["path": "$OUT/paths.ai"]
        p["brush.presets.importFile"] = ["path": "$GBR"]
        p["brush.presets.importImage"] = ["path": "$IMAGE"]
        p["pattern.export"] = ["path": "$OUT/omega.pat"]
        p["pattern.import"] = ["path": "$OUT/omega.pat"]
        for id in ["swatches.delete", "swatches.use", "swatches.move"] { p[id] = ["index": 0] }
        p["swatches.rename"] = ["index": 0, "name": "Renamed"]
        for id in ["actions.play", "actions.get", "actions.delete", "actions.toggle", "actions.dialog", "actions.assignSet"] { p[id] = ["action": "Omega"] }
        p["actions.rename"] = ["action": "Omega", "name": "Renamed"]
        p["actions.setColor"] = ["action": "Omega", "color": "red"]
        p["actions.move"] = ["action": "Omega", "to": 0]
        p["actions.insert"] = ["action": "Omega", "id": "image.adjustments.invert"]
        p["actions.record"] = ["name": "Omega"]
        p["actions.conditional"] = ["if": "always", "then": NSNull(), "else": NSNull()]
        for id in ["document.presets.get", "document.presets.delete", "file.export.presets.get", "file.export.presets.delete"] { p[id] = ["name": "Omega"] }
        p["document.presets.save"] = ["name": "Omega", "settings": ["width": 10, "height": 10]]
        p["document.recent.add"] = ["settings": ["width": 10, "height": 10]]
        p["file.export.presets.save"] = ["name": "Omega", "settings": ["format": "png"]]
        p["tool.presets.new"] = ["name": "Omega", "tool": "brush"]
        p["tool.presets.select"] = ["preset": "Omega"]
        p["tool.presets.edit"] = ["action": "rename", "preset": "Omega", "name": "Renamed"]
        p["history.selectState"] = ["state": 0]
        p["layer.copyToDocument"] = ["document": 1]
        p["image.variables.define"] = ["defs": [["name": "v", "layer": "$LAYER", "type": "visibility"]]]
        p["image.variables.dataSets"] = ["dataSets": [["name": "d", "values": [["variable": "v", "kind": "visibility", "value": true]]]]]
        p["image.applyDataSet"] = ["name": "d"]
        p["gradient.fill.stop"] = ["action": "add", "location": 0.5]
        p["image.imageSize"] = ["width": 20, "height": 15]
        p["select.fromMask"] = ["width": 1, "height": 1, "data": "/w=="]
        p["select.findLayers"] = ["name": "Layer"]
        p["shape.edit"] = ["kind": "rect"]
        p["shape.presets.place"] = ["preset": "Omega"]
        p["slice.new"] = ["rect": ["@x:0.1", "@y:0.1", "@x:0.4", "@y:0.4"]]
        p["prefs.set"] = ["path": "general.autoShowHomeScreen", "value": true]
        p["image.mode.colorTable"] = ["table": "web"]
        p["file.export.renderVideo"] = ["dir": "$OUT"]
        p["file.revealInFinder"] = ["dryRun": true]
        p["layer.layerStyle.scaleEffects"] = ["scale": 50]
        p["layer.frame.at"] = at
        p["layer.frame.fill"] = ["frame": "$RESULT:layer", "layer": "$OTHER"]
        p["measurementLog.delete"] = ["all": true]
        p["paint.cloneStamp"] = ["points": stroke, "offset": [3, 2]]
        p["paint.healingBrush"] = ["points": stroke, "offset": [3, 2]]
        p["layer.smartFilter.blendingOptions"] = ["opacity": 0.5, "blend": "normal"]
        p["layer.smartFilter.setParams"] = ["params": ["radius": 2]]
        p["layer.smartFilter.move"] = ["index": 1, "to": 0]
                for id in ["brush.presets.delete", "brush.presets.setCurrent", "brush.presets.update"] { p[id] = ["name": "Omega"] }
        p["brush.presets.rename"] = ["name": "Omega", "newName": "Renamed"]
        p["brush.presets.move"] = ["name": "Omega", "group": ""]
        p["brush.presets.deleteGroup"] = ["group": "OmegaGroup"]
        p["brush.presets.moveGroup"] = ["group": "OmegaGroup", "index": 0]
        p["brush.presets.renameGroup"] = ["group": "OmegaGroup", "newName": "Renamed"]
        p["brush.presets.importFile"] = ["path": "$GBR", "fileName": "speckle.gbr", "group": "Omega"]
        p["pattern.delete"] = ["pattern": "Omega"]
        p["pattern.rename"] = ["pattern": "Omega", "name": "Renamed"]
        p["layer.fill.pattern.set"] = ["scale": 50]
        p["swatches.deleteGroup"] = ["group": "Omega"]
        p["swatches.renameGroup"] = ["group": "Omega", "name": "Renamed"]
        p["style.presets.apply"] = ["preset": "Omega"]
        for id in ["history.selectSnapshot", "history.deleteSnapshot"] { p[id] = ["snapshot": "$RESULT:snapshot"] }
        p["history.renameSnapshot"] = ["snapshot": "$RESULT:snapshot", "name": "Renamed"]
        for style in ["characterStyle", "paragraphStyle"] {
            for id in ["duplicate", "delete"] { p["type.\(style).\(id)"] = ["id": "$RESULT:id"] }
            p["type.\(style).rename"] = ["id": "$RESULT:id", "name": "Renamed"]
            p["type.\(style).set"] = ["id": "$RESULT:id", "name": "Renamed", "attrs": ["size": 12]]
        }
        p["type.characterStyle.redefine"] = ["id": "$RESULT:id"]
        return p
    }()

    /// Steps run after the document is built and before the command, where it needs something first.
    static let setup: [String: [(String, [String: Any])]] = {
        var s: [String: [(String, [String: Any])]] = [:]
        let stroke2: [[String]] = [["@x:0.1", "@y:0.1"], ["@x:0.4", "@y:0.4"]]
        let triangle: [[String]] = [["@x:0.2", "@y:0.2"], ["@x:0.8", "@y:0.3"], ["@x:0.5", "@y:0.8"]]
        let threeLayers: [(String, [String: Any])] = [
            ("layer.new.layer", [:]), ("paint.stroke", ["points": [["@x:0.1", "@y:0.1"], ["@x:0.4", "@y:0.4"]], "size": 3]),
            ("layer.new.layer", [:]), ("paint.stroke", ["points": [["@x:0.6", "@y:0.6"], ["@x:0.9", "@y:0.9"]], "size": 3]),
            ("select.allLayers", [:]),
        ]
        for id in ["edit.autoBlendLayers", "layer.linkLayers", "layer.arrange.reverse",
                   "layer.distribute.topEdges", "layer.distribute.verticalCenters", "layer.distribute.bottomEdges",
                   "layer.distribute.leftEdges", "layer.distribute.horizontalCenters", "layer.distribute.rightEdges",
                   "layer.distribute.horizontally", "layer.distribute.vertically"] { s[id] = threeLayers }
        s["layer.selectLinkedLayers"] = threeLayers + [("layer.linkLayers", [:]), ("layer.select", ["layer": "$LAYER"])]
        s["edit.redo"] = [("edit.undo", [:])]
        s["history.redo"] = [("edit.undo", [:])]
        s["edit.transform.again"] = [("edit.transform", ["scaleX": 80, "scaleY": 80])]
        s["edit.transform.againCopy"] = [("edit.transform", ["scaleX": 80, "scaleY": 80])]
        let copied: [(String, [String: Any])] = [("select.all", [:]), ("edit.copy", [:])]
        for id in ["edit.paste", "edit.pasteSpecial.pasteInPlace", "edit.purge.clipboard", "file.newFromClipboard"] { s[id] = copied + [("select.deselect", [:])] }
        for id in ["edit.pasteSpecial.pasteInto", "edit.pasteSpecial.pasteOutside"] { s[id] = copied }
        let saved: [(String, [String: Any])] = [("file.saveACopy", ["path": "$OUT/saved.pcraft"]), ("file.openAs", ["path": "$OUT/saved.pcraft"])]
        s["file.revert"] = saved + [("select.all", [:]), ("edit.fill", ["color": "#00ff00"])]
        s["file.revealInFinder"] = saved
        s["filter.lastFilter"] = [("filter.blur.gaussianBlur", ["radius": 1])]
        s["image.mode.colorTable"] = [("image.mode.indexedColor", [:])]
        s["image.analysis.straightenLayer"] = [("image.analysis.rulerTool", ["start": ["@x:0", "@y:0"], "end": ["@x:0.9", "@y:0.4"]])]
        for id in ["layer.arrange.bringForward", "layer.arrange.bringToFront"] { s[id] = [("layer.new.layer", [:]), ("layer.new.layer", [:]), ("layer.arrange.sendBackward", [:])] }
        let effects: (String, [String: Any]) = ("layer.layerStyle.replace", ["effects": [["kind": "dropShadow", "params": [String: Any]()]]])
        for id in ["layer.layerStyle.createLayer", "layer.layerStyle.scaleEffects", "layer.layerStyle.transferEffects", "layer.rasterize.layerStyle",
                   "layer.setEffectsExpanded", "layer.setEffectsVisible"] { s[id] = [effects] }
        s["layer.layerStyle.pasteLayerStyle"] = [effects, ("layer.layerStyle.copyLayerStyle", [:])]
        let embed: (String, [String: Any]) = ("layer.smartObjects.convertToSmartObject", [:])
        let blur: (String, [String: Any]) = ("filter.blur.gaussianBlur", ["radius": 1])
        for id in ["disableSmartFilters", "clearSmartFilters", "setVisible", "delete", "blendingOptions", "setParams"] { s["layer.smartFilter.\(id)"] = [embed, blur] }
        // A filter run with a selection gets a filter mask.
        for id in ["deleteFilterMask", "disableFilterMask"] { s["layer.smartFilter.\(id)"] = [embed, ("select.all", [:]), blur] }
        s["layer.smartFilter.move"] = [embed, blur, ("filter.blur.gaussianBlur", ["radius": 2])]
        s["layer.smartFilter.transfer"] = [embed, blur, ("layer.smartObjects.newSmartObjectViaCopy", [:])]
        s["layer.smartObjects.convertToEmbedded"] = [("file.placeLinked", ["path": "$IMAGE"])]
        s["layer.smartObjects.updateModifiedContent"] = [("file.placeLinked", ["path": "$IMAGE"])]
        s["layer.smartObjects.saveContents"] = [embed, ("layer.smartObjects.editContents", [:])]
        for id in ["layer.vectorMask.edit", "layer.vectorMask.delete", "layer.vectorMask.enabled", "layer.vectorMask.linked", "layer.rasterize.vectorMask"] {
            s[id] = [("layer.vectorMask.revealAll", [:])]
        }
        let text: (String, [String: Any]) = ("type.create", ["x": "@x:0.1", "y": "@y:0.7", "text": "Omega", "size": 10])
        s["type.convertToPointText"] = [("type.create", ["x": "@x:0.1", "y": "@y:0.1", "text": "Omega", "size": 8, "box": ["@x:0.1", "@y:0.1", "@x:0.8", "@y:0.8"]])]
        s["type.loadDefaultTypeStyles"] = [text, ("type.saveDefaultTypeStyles", [:])]
        for style in ["characterStyle", "paragraphStyle"] {
            for id in ["duplicate", "delete", "rename", "set"] { s["type.\(style).\(id)"] = [("type.\(style).new", ["name": "Omega"])] }
        }
        s["type.characterStyle.redefine"] = [text, ("type.characterStyle.new", ["name": "Omega"])]
        let shapeLayer: (String, [String: Any]) = ("shape.create", ["kind": "rect", "rect": ["@x:0.2", "@y:0.2", "@x:0.5", "@y:0.5"], "fill": "#ff0000", "stroke": ["color": "#0000ff", "width": 2]])
        s["shape.edit"] = [shapeLayer]
        s["path.style.copyStroke"] = [shapeLayer]
        s["path.style.pasteFill"] = [shapeLayer, ("path.style.copyFill", [:])]
        s["path.style.pasteStroke"] = [shapeLayer, ("path.style.copyStroke", [:])]
        let workPath: (String, [String: Any]) = ("path.set", ["path": ["subpaths": [["closed": true, "knots": triangle]]]])
        let namedPath: (String, [String: Any]) = ("path.set", ["name": "Omega", "path": ["subpaths": [["closed": true, "knots": triangle]]]])
        s["type.detachFromPath"] = [text, workPath, ("type.attachToPath", [:])]
        s["shape.presets.place"] = [("shape.presets.new", ["name": "Omega", "path": ["subpaths": [["closed": true, "knots": triangle]]]])]
        s["paint.symmetryDisable"] = [namedPath, ("paint.symmetryFromPath", ["name": "Omega"])]
        s["path.clippingPath.clear"] = [namedPath, ("path.clippingPath.set", ["name": "Omega"])]
        for id in ["delete", "setCurrent", "update", "rename", "move"] { s["brush.presets.\(id)"] = [("brush.presets.save", ["name": "Omega"])] }
        for id in ["deleteGroup", "moveGroup", "renameGroup"] { s["brush.presets.\(id)"] = [("brush.presets.importFile", ["path": "$GBR", "group": "OmegaGroup"])] }
        let pattern: (String, [String: Any]) = ("edit.definePattern", ["name": "Omega"])
        for id in ["pattern.delete", "pattern.rename"] { s[id] = [pattern] }
        s["layer.fill.pattern.set"] = [pattern, ("layer.newFillLayer.pattern", ["pattern": "Omega"])]
        for id in ["swatches.deleteGroup", "swatches.renameGroup"] { s[id] = [("swatches.newGroup", ["name": "Omega"])] }
        s["style.presets.apply"] = [("style.presets.new", ["name": "Omega", "effects": [["dropShadow", [String: Any]()]]])]
        for id in ["history.selectSnapshot", "history.deleteSnapshot", "history.renameSnapshot"] { s[id] = [("history.newSnapshot", ["name": "Omega"])] }
        s["layer.frame.at"] = [("layer.new.frame", ["x": "@x:0.2", "y": "@y:0.2", "width": "@x:0.5", "height": "@y:0.5"])]
        s["layer.frame.fill"] = [("layer.new.layer", [:]), ("paint.stroke", ["points": stroke2, "size": 3]), ("layer.new.frame", ["x": "@x:0.2", "y": "@y:0.2", "width": "@x:0.5", "height": "@y:0.5"])]
        s["channel.merge"] = [("channel.split", [:])]
        s["channel.mergeSpot"] = [("channel.newSpot", ["name": "Omega"])]
        let alphas: [(String, [String: Any])] = (0..<4).map { ("channel.new", ["name": "Omega \($0)"]) }
        s["channel.target.slot8"] = alphas
        s["channel.target.slot9"] = alphas
        s["layerComp.restoreLastDocumentState"] = [("layerComp.new", ["name": "Omega"]), ("layer.new.layer", [:]), ("layerComp.apply", ["comp": "Omega"])]
        s["measurementLog.delete"] = [("select.all", [:]), ("image.analysis.recordMeasurements", ["source": "selection"])]
        s["edit.transform.removeWarpSplit"] = [embed, ("edit.transform.warp", ["style": "custom"]), ("edit.transform.splitWarpCrosswise", [:])]
        s["actions.save"] = [("actions.record", ["name": "Omega"]), ("image.adjustments.invert", [:]), ("actions.stop", [:])]
        s["file.automate.runDroplet"] = [("file.automate.createDroplet", ["path": "$OUT/omega.pcdroplet", "steps": [["image.adjustments.invert", [String: Any]()]]])]
        // Two layers of one photo, one moved.
        s["edit.autoAlignLayers"] = [
            ("file.new", ["width": 300, "height": 240]), ("file.placeEmbedded", ["path": "$PHOTO"]), ("layer.rasterize.smartObject", [:]),
            ("layer.renameLayer", ["name": "A"]), ("layer.duplicate", [:]), ("layer.renameLayer", ["name": "B"]), ("edit.transform", ["dx": 7, "dy": 3]),
            ("layer.select", ["layer": "A"]), ("layer.select", ["layer": "B", "mode": "add"]),
        ]
        let video: (String, [String: Any]) = ("layer.videoLayers.newVideoLayerFromFile", ["path": "$GIF"])
        for id in ["deleteFrame", "duplicateFrame", "insertBlankFrame", "interpretFootage", "rasterize", "reloadFrame", "replaceFootage",
                   "restoreAllFrames", "restoreFrame", "showAlteredVideo"] { s["layer.videoLayers.\(id)"] = [video] }
        s["layer.rasterize.video"] = [video]
        s["file.export.renderVideo"] = [("timeline.create", ["duration": 2, "fps": 24.0])]
        for id in ["view.colorSamplers.move", "view.colorSamplers.delete"] { s[id] = [("view.colorSamplers.add", ["x": "@x:0.3", "y": "@y:0.3"])] }
        for id in ["count.remove", "count.move", "count.clear", "count.deleteGroup", "count.setGroup"] { s[id] = [("count.add", ["x": "@x:0.3", "y": "@y:0.3"])] }
        s["path.clippingPath.set"] = [("path.set", ["name": "Omega", "path": ["subpaths": [["closed": true, "knots": triangle]]]])]
        s["pattern.import"] = [("pattern.export", ["path": "$OUT/omega.pat"])]
        let action: [(String, [String: Any])] = [("actions.record", ["name": "Omega"]), ("image.adjustments.invert", [:]), ("actions.stop", [:])]
        for id in ["actions.play", "actions.get", "actions.delete", "actions.toggle", "actions.dialog", "actions.assignSet",
                   "actions.rename", "actions.setColor", "actions.move", "actions.insert"] { s[id] = action }
        s["actions.stop"] = [("actions.record", ["name": "Omega"])]
        for id in ["document.presets.get", "document.presets.delete"] { s[id] = [("document.presets.save", ["name": "Omega", "settings": ["width": 10, "height": 10]])] }
        for id in ["file.export.presets.get", "file.export.presets.delete"] { s[id] = [("file.export.presets.save", ["name": "Omega", "settings": ["format": "png"]])] }
        for id in ["tool.presets.select", "tool.presets.edit"] { s[id] = [("tool.presets.new", ["name": "Omega", "tool": "brush"])] }
        s["layer.copyToDocument"] = [("file.new", ["width": 10, "height": 10]), ("document.activate", ["document": 0])]
        let define: (String, [String: Any]) = ("image.variables.define", ["defs": [["name": "v", "layer": "$LAYER", "type": "visibility"]]])
        let sets: (String, [String: Any]) = ("image.variables.dataSets", ["dataSets": [["name": "d", "values": [["variable": "v", "kind": "visibility", "value": true]]]]])
        s["image.variables.dataSets"] = [define]
        s["file.import.variableDataSets"] = [define]
        for id in ["plugin.remove", "plugin.run"] { s[id] = [("plugin.install", ["path": "$WASM"])] }
        s["image.applyDataSet"] = [define, sets]
        s["file.export.dataSetsAsFiles"] = [define, sets]
        for id in ["gradient.fill.set", "gradient.fill.stop", "gradient.fill.get"] { s[id] = [("layer.newFillLayer.gradient", [:])] }
        return s
    }()

    /// Tools that never change the document, with why (`Tool` raw values). Any other tool that
    /// changes it in none of Omega's cases is reported.
    static let toolsThatOnlyLook: [String: String] = [
        "sliceSelect": "picks a slice", "hand": "moves the view", "rotateView": "turns the view", "zoomIn": "zooms the view", "zoomOut": "zooms the view",
        "eyedropper": "picks a colour", "colorSampler": "reads colours", "ruler": "measures",
        "aiRemove": "needs the AI model, which tests don't download",
        "pathSelect": "selects a path", "directSelect": "selects anchors",
    ]

    /// Every stored setting the app reads or writes (`UserDefaults` keys and `@AppStorage` names).
    static let settings: Set<String> = [
        "autoOptions", "canvasColor", "canvasCustom", "developFiles", "developPresets", "layerThumbnails",
        "openJPEGInDevelop", "pencilOnly", "pencilSqueeze", "pencilTap", "recentFiles",
        "recoveryMinutes", "snap", "statusInfo", "tutorialDone",
    ]

    /// Keys the completeness check finds that aren't settings, with why.
    static let notSettings: [String: String] = [
        "march": "the marching ants' animation key",
    ]

    /// Launch arguments for tests and screenshots, not settings a person changes.
    static let launchFlags: Set<String> = ["omegaDeviceProbe", "resetRecents", "resetSettings", "seedSamples", "skipTutorial", "uiTestProbe"]
}
