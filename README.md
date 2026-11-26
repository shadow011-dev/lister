# Lister

A Mac app for a 3D-printed microscope that uses a phone as its camera.

- Live view of what the microscope sees
- One-click capture, saved to your computer
- Voice control: say "capture" to take a photo, "live" for live view
- Flash mode: LEDs switch on while capturing and off afterwards
- Measure (length, angle, box, oval, count), adjust and analyse samples
- Open single pictures or whole folders
- Light and dark mode

## Requirements
- macOS 14 or newer
- A phone running the IP Webcam app on the same network
- Optional: an Arduino for the LED lights (sketch in `Arduino/`)

## Build from source
```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Lister.xcodeproj -scheme Lister -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" build
open build/Build/Products/Release/Lister.app
```

## License
MIT

## Hardware
The 3D model of the microscope is in [`hardware/microscope_assembled_v15.stl`](hardware/microscope_assembled_v15.stl). GitHub shows it in a 3D viewer.
