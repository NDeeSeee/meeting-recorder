// display-asleep — is the Mac's display currently asleep?
//
// Prints "asleep" (exit 1) or "awake" (exit 0). Used by meeting-notify.lua to
// skip the ScreenCaptureKit stream rebuild while the display is asleep: that
// rebuild re-enumerates SCShareableContent behind a plugin semaphore, and macOS
// drops a sleeping display from that list — so the rebuild both cannot succeed
// AND can block the OBS scripting thread indefinitely (see the deadlock comment
// in meeting-notify.lua). CGDisplayIsAsleep reads the real display power state,
// which no dependency-free shell probe reports on Apple Silicon (IODisplayWrangler
// is gone, `pmset -g powerstate` errors out).
//
// Compile: swiftc -O tools/display-asleep.swift -o ~/.local/bin/display-asleep
//
// The Lua caller fails OPEN: if this helper is missing or prints anything else,
// it treats the display as awake and behaves exactly as it did before — this is
// an optimization to dodge a known hang, never a gate the repair depends on.

import CoreGraphics

let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
print(asleep ? "asleep" : "awake")
exit(asleep ? 1 : 0)
