import Cocoa
import os

let launchSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)
let launchSignpostState = launchSignposter.beginInterval("launch-to-paint")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
