# MPE Pitch Bend Mode

Pitch Bend mode for MIDI Razor Edits displays and edits pitch bend events as breakpoint curves overlaid on the piano roll. Designed for MPE (MIDI Polyphonic Expression) workflows with per-channel pitch bend support.

## Overview

- PB events displayed as curves relative to note pitch rows
- PB center (8192) = note's written pitch
- PB offset maps to semitones (default ±48 semitones, MPE standard)
- Per-channel curves for true MPE editing
- Optional channel filtering to focus on single voice
- Microtonal support via Scala (.scl) files

------

Key commands are given with macOS equivalent (`Cmd`, `Opt`) first, Win/Lin (`Ctrl`, `Alt`) second. That's just how I roll. **`Super`**, btw, refers to the **Windows** key in Windows/Linux (where it's apparently called "Super"), and the **`Ctrl`** key in macOS. On Windows, I recommend disabling the Start Menu from whatever side you want to use... (apparently this can be done via AHK or Registry).

## Entry Points

| Script | Description |
|--------|-------------|
| Press `P` in main MRE | Toggle PB mode on/off |
| `sockmonkey72_MIDIRazorEdits_PitchBend.lua` | Launch directly into PB mode |

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `P` | Exit PB mode (return to main MRE or exit PB script if launched directly) |
| `C` | Set curve type for selected points (opens menu) |
| `Q` | Snap selected points to nearest semi-/microtone |
| `M` | Toggle microtonal grid lines (when .scl loaded) |
| `H` | Channel selection menu |
| `B` | Project bend/tuning config dialog |
| `Delete` / `Backspace` | Delete selected points |
| `Cmd/Ctrl+C` | Copy selected points |
| `Cmd/Ctrl+V` | Paste points |
| `Cmd/Ctrl+A` | Select all points |
| `Esc` | End script |

## Modifier Keys

### Drawing & Editing

| Modifier | Action |
|----------|--------|
| `Cmd/Ctrl`+drag | Draw mode: create new PB events at grid intervals |
| `Cmd/Ctrl+Shift`+drag | Smooth draw (grid disabled) |
| `Ctrl/Super`+drag | Compress/expand mode (scale vibrato intensity, see below) |
| `Opt/Alt` (while dragging) | Disable snap to semitone/microtone |
| `Shift`+click | Multi-select points |
| drag | Drag-select points |

### Compress/Expand Mode

1. Hold `Ctrl/Super` - center line appears, follows mouse Y
2. `Ctrl/Super`**`+Opt`** - disable semi-/microtone snap for center line positioning
3. Click to lock center position
4. Drag up/down to expand/compress around center
5. Release to commit

## Mouse Operations

| Action | Result |
|--------|--------|
| Click point | Select point (deselects others); click on background deselects all |
| `Shift`+click | Add/remove from selection |
| Drag point | Move selected points (X=time, Y=pitch), `+Opt/Alt`: toggle grid snapping |
| Double-click | Insert new point at mouse position |
| Right-click point | Delete hovered point |
| `Cmd/Ctrl`+right-click | Adopt active/visible channel from nearest note (this will also change the channel for "next event" in the MIDI Editor, if possible) |
| `Opt/Alt`+drag | When hovering over bezier curves, change curve tension. If multiple points with bezier are selected, change curve tension for all. |

## Channel Filtering

By default, PB curves for all channels are displayed. To focus on a single channel:

1. Press `H` to open channel menu
2. Select a channel (1-16) or "All"
3. When filtered, tooltip shows "Ch N (h=menu)" in ruler area

Channel is auto-adopted when:
- Drawing new events (adopts channel of nearest note)
- `Cmd/Ctrl`+right-click on a note

Active channel persists per-project.

## Curve Types

Press `C` with points selected to choose curve type:

| Type | Description |
|------|-------------|
| Square | Step/hold - instant transition |
| Linear | Straight line interpolation |
| Slow Start/End | Ease in/out |
| Fast Start | Quick attack |
| Fast End | Quick release |
| Bezier | Smooth S-curve |

## Microtonal Support

Load Scala (.scl) tuning files for microtonal pitch snapping:

1. Default Scala (.scl) file directory is `~/Documents/scl`; change this in the Settings as desired
2. Press `B` for project config, or use Settings dialog to change default .scl for new Projects
3. Select a .scl file from your tuning directory
4. Press `M` to toggle microtonal grid lines
5. Points snap to scale degrees when dragging (hold `opt/alt` to disable snap)
6. `q` shortcut will snap selected points (or all if none selected) to closest scale degree

System default tuning can be set in MRE Settings ("Even More Settings" tab).

## Configuration

### Project Settings (B key)

- **Bend Up/Down**: Semitone range (default 48)
- **Tuning File**: Project-specific .scl override
- **Clear**: Revert to system defaults

### System Settings (MRE Settings dialog)

- Default bend range
- Default tuning file
- SCL directory path

## Tips

- Curves are drawn relative to the sounding note - PB at center (0 semitones) sits on the note row
- When notes overlap on same channel, curve associates with nearest note by time
- Use channel filtering for complex MPE arrangements
- Compress/expand is great for adjusting vibrato depth after recording
- Draw mode respects grid snapping for X position
