# Uhm Swift Example

A tiny SwiftUI app for trying Uhm on Apple platforms: pick an audio file and it lists every detected filler ("uh", "um", "hmm") with timestamps and confidence.

## Run

Open `UhmExample.xcodeproj` in Xcode, choose a simulator or device, and press Run.

The first analysis downloads the Core ML model (~45 MB) to the app cache. Later runs use the cached model offline.
