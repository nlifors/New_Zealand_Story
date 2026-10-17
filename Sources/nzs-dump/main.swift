// nzs-dump: decode assets straight from the ADF and write PNG/WAV for inspection.
// Usage: nzs-dump <adf> <outdir>
import Foundation
import NZSCore

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: nzs-dump <adf> <outdir>"); exit(1) }
let out = args[2]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let disk = try DiskImage(contentsOf: URL(fileURLWithPath: args[1]))
let data = try GameData(disk: disk)

// Level graphics sets: tile sheets (16 tiles per row)
var doneSets = Set<Int>()
for (i, lv) in data.image.levels.enumerated() {
    let gs = try data.graphicsSet(level: i)
    if !doneSets.contains(lv.graphicsTrack) {
        doneSets.insert(lv.graphicsTrack)
        let n = gs.tileCapacity, cols = 16, rows = (n + cols - 1) / cols
        let w = cols * 17, h = rows * 17
        var px = [UInt32](repeating: 0x404040, count: w * h)
        let pal = gs.palette.rgb
        for t in 0..<n {
            let tile = gs.tile(t)
            let ox = (t % cols) * 17, oy = (t / cols) * 17
            for y in 0..<16 { for x in 0..<16 { px[(oy + y) * w + ox + x] = pal[Int(tile[y * 16 + x])] } }
        }
        try ImageFile.writePNG("\(out)/tiles_track\(lv.graphicsTrack).png", width: w, height: h, pixels: px, scale: 2)
        print("graphics set track \(lv.graphicsTrack): \(gs.raw.count) bytes, header count \(gs.headerTileCount), capacity \(n) tiles, palette \(gs.palette.amiga.map { String(format: "%03x", $0) }.joined(separator: " "))")
    }
    let map = try data.map(level: i)
    let pal = gs.palette.rgb
    let w = map.width * 16, h = map.height * 16
    var px = [UInt32](repeating: 0, count: w * h)
    var tileCache = [Int: [UInt8]]()
    for my in 0..<map.height {
        for mx in 0..<map.width {
            let t = Int(map.tile(mx, my))
            let tile = tileCache[t] ?? gs.tile(t); tileCache[t] = tile
            for y in 0..<16 { for x in 0..<16 { px[(my * 16 + y) * w + mx * 16 + x] = pal[Int(tile[y * 16 + x])] } }
        }
    }
    try ImageFile.writePNG("\(out)/map_level\(String(format: "%02d", i)).png", width: w, height: h, pixels: px)
    print("level \(i): map \(map.width)x\(map.height) (track \(lv.mapTrack)), gfx track \(lv.graphicsTrack), attr $\(String(lv.attributeTable, radix: 16)) p2 $\(String(lv.pointer2, radix: 16)) p3 $\(String(lv.pointer3, radix: 16))")
}

// Sprite banks: sheets with a grey checker behind transparent pixels
let spritePalette = try data.graphicsSet(level: 0).palette.rgb   // ASSUMPTION: sprites use the level palette
let banks = SpriteBank.known.map { SpriteBank(image: data.image, name: $0.0, dataBase: $0.1, tableBase: $0.2) } + [data.track144Sprites()] + (0..<5).compactMap { data.bossSprites(world: $0) }
for bank in banks {
    let name = bank.name
    let cell = bank.entries.map { max($0.words * 16, $0.lines) }.max()! + 2, cols = max(1, min(16, 1100 / cell))
    let rows = (bank.entries.count + cols - 1) / cols
    let w = cols * cell, h = rows * cell
    var px = [UInt32](repeating: 0x303030, count: w * h)
    for i in 0..<bank.entries.count {
        let (sw, sh, d) = bank.pixels(i)
        let ox = (i % cols) * cell, oy = (i / cols) * cell
        for y in 0..<min(sh, cell - 1) { for x in 0..<min(sw, cell - 1) {
            let v = d[y * sw + x]
            px[(oy + y) * w + ox + x] = v == 0xff ? (((x / 4 + y / 4) & 1) == 0 ? 0x505050 : 0x606060) : spritePalette[Int(v)]
        } }
    }
    try ImageFile.writePNG("\(out)/sprites_\(name).png", width: w, height: h, pixels: px, scale: 2)
    print("sprite bank \(name): \(bank.entries.count) images")
}

// Samples (8SVX) at their VHDR rate; the game sets its own periods when playing
for (i, smp) in Sample8SVX.scan(data.image).enumerated() {
    let pcm = smp.body.map { Int16($0) << 8 }
    let safe = smp.name.replacingOccurrences(of: ".iff", with: "").replacingOccurrences(of: "/", with: "_")
    try WAVFile.write("\(out)/sample_\(String(format: "%02d", i))_\(safe).wav", rate: smp.rate, left: pcm, right: pcm)
    print(String(format: "sample %2d $%05X %-14@ %5d bytes oneShot %5d repeat %5d rate %5d", i, smp.address, smp.name as NSString, smp.body.count, smp.oneShot, smp.repeatLength, smp.rate))
}

for (name, pic) in try data.pictures() {
    try ImageFile.writePNG("\(out)/picture_\(name).png", width: 320, height: 200, pixels: pic.rgb, scale: 2)
    print("picture \(name): palette \(pic.palette.amiga.map { String(format: "%03x", $0) }.joined(separator: " "))")
}

// Font sheet: 16 x 6 characters ($20..$7F)
let font = Font8x8(image: data.image)
var fpx = [UInt32](repeating: 0x202040, count: 16 * 9 * 6 * 9)
for c in 0..<96 { for y in 0..<8 { for x in 0..<8 where font.glyphs[c][y] & (0x80 >> UInt8(x)) != 0 {
    fpx[((c / 16) * 9 + y) * 144 + (c % 16) * 9 + x] = 0xffffff
} } }
try ImageFile.writePNG("\(out)/font.png", width: 144, height: 54, pixels: fpx, scale: 4)
print("font: 96 glyphs at $DA66")
