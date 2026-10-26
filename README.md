# Facet for Mac

Local Mac app: photos (HEIC/JPG/PNG) → textured 3D model using Apple's Object Capture.
Export: STL, OBJ (with textures), FBX (via Blender), PLY, USDZ.

## Download
Get the latest **Facet.zip** from the [Releases](../../releases) page, unzip it and
drag Facet into your Applications folder.

Requirements: macOS 14 or newer, Apple Silicon Mac (M1 or later).
Blender in /Applications is only needed for FBX export.

**First launch:** macOS will warn that it can't verify the developer. Open
System Settings → Privacy & Security, scroll down and click **Open Anyway**.

## Export formats
- **STL**: for 3D printing
- **OBJ**: for Blender and Rhino
- **FBX**: for animation and games
- **PLY**: for mesh cleanup
- **USDZ**: for AR on iPhone

## Build from source

Download or clone this repository, open Terminal in its folder and run:

    bash build.sh

Requires Xcode or the Command Line Tools (`xcode-select --install`).
The finished app is placed next to the script as `Facet.app`.

## Usage
1. Drop a folder of photos into the window (or use "Choose Folder…").
2. Pick a detail level – "Preview" for a quick test, then "Full".
3. Click "Create 3D Model".
4. Check the scale and enter a real dimension if needed.
5. Choose formats and export.

## Settings
- **Isolate Object**: ignores the background. Keep it on if the object was flipped
  (top and bottom photos in the same folder).
- **Photos in Capture Order**: faster if the photos were taken in sequence around the object.
- **High Sensitivity**: for smooth, single-color surfaces.

## Export notes
- STL, OBJ and PLY are written in the selected unit (default: millimeters, which slicers expect).
- FBX is written in meters with unit info and requires Blender in /Applications.
- USDZ keeps Object Capture's original scale (meters, no calibration applied).

## Photo tips for handheld devices
- Glossy/transparent surfaces, displays: treat with a matte 3D scanning spray or baby powder.
- Soft, even lighting without hard shadows.
- Overlap between neighboring photos.
- Shoot the object standing and lying down, all in one folder. 
- Best is to shoot object on a think stick.
- Capture details (buttons, ports, seams) additionally from close up.
