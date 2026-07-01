#!/bin/bash
# Build a macOS 26 Liquid Glass app icon (AppIcon.icon package) from an Apple SF Symbol.
# The .icon bundle = icon.json (layer/material spec) + Assets/ (layer images). Xcode's
# actool compiles it; the OS renders the glass (specular, refraction, dark/tint variants).
set -euo pipefail
cd "$(dirname "$0")"

ICON="AppIcon.icon"
GLYPH="$(mktemp -t glyph).png"
SWIFT="$(mktemp -t mkglyph).swift"
ICT="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

# 1. Render the SF Symbol as a white glyph on a transparent canvas (the glass layer).
cat > "$SWIFT" <<'SWIFTEOF'
import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let cfg = NSImage.SymbolConfiguration(pointSize: 680, weight: .medium)
let sym = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(cfg)!
let tinted = NSImage(size: sym.size)
tinted.lockFocus()
sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.set()
NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
tinted.unlockFocus()
tinted.draw(in: NSRect(x: (S-sym.size.width)/2, y: (S-sym.size.height)/2,
                       width: sym.size.width, height: sym.size.height))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFTEOF
swift "$SWIFT" "$GLYPH"

# 2. Assemble the .icon package: gradient background fill + one glass glyph layer.
rm -rf "$ICON"
mkdir -p "$ICON/Assets"
cp "$GLYPH" "$ICON/Assets/glyph.png"

cat > "$ICON/icon.json" <<'JSONEOF'
{
  "fill" : {
    "linear-gradient" : [ "srgb:0.34000,0.60000,1.00000,1.00000", "srgb:0.03000,0.24000,0.84000,1.00000" ],
    "orientation" : { "start" : { "x" : 0.5, "y" : 0.0 }, "stop" : { "x" : 0.5, "y" : 1.0 } }
  },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "glyph.png", "name" : "Arrow", "glass" : true }
      ],
      "specular" : true,
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
JSONEOF

rm -f "$SWIFT" "$GLYPH"
echo "Wrote $ICON"

# 3. Optional preview: render the glass result to PNG (needs Icon Composer.app's ictool).
if [ -f "$ICT" ]; then
  "$ICT" "$ICON" --export-image --output-file preview-light.png \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 2>/dev/null && \
    echo "Preview: preview-light.png"
fi
