## MIDI Razor Edits

MIDI Razor Edits adds the ability to:

- Select, copy, and manipulate MIDI notes and CC data with the precision of Razor Edits.
- Use workflows similar to REAPER’s native Razor Edits but designed specifically for MIDI editing.
- Stretch, scale, invert, duplicate, copy your MIDI data quickly and conveniently.

**<u>Basic usage</u>**

When enabled, click-drag to create a new *area* around some notes or some CC-lane events. Click-drag on the area to move it. That's it.

Of course, there's more to it. You can cmd/ctrl-click-drag to create multiple areas. You can cmd/ctrl-drag existing areas to copy their contents. You can stretch values in time, or scale them within an area's range. Copy, cut, paste, and plenty of other useful, common and less common operations to apply to the events you've captured inside of areas.

**<u>Performance Tips</u>**

* On Windows, MRE can be flickery and laggy. This is not my fault per se, it's a limitation of the kind of drawing required by the script, and REAPER's handling of such. There's a secret performance settings dialog available if you press ctrl-alt-F10, where you can try to adjust the compositing settings. If you find something which works particularly well, please tell me about it.
* On Mac, I recommend enabling Move throttling in the Advanced UI/system tweaks preference dialog (in the General tab), which will smooth out performance (particularly if you have external, high-DPI input devices and/or multiple displays).

**<u>Key Mapping / Operations</u>**

* **Copy Area**: copy the area bounds and contents to the (private) clipboard of the script. **Copy Area** will copy all areas on the last-clicked or hovered section/lane of the MIDI Editor. Also see **Cut Area** and **Paste Area**. *[o]*
* **Cut Area**: cut the area bounds and contents to the (private) clipboard of the script (area/contents are deleted). **Cut Area** will cut all areas on the last-clicked or hovered section/lane of the MIDI Editor. Also see **Copy Area** and **Paste Area**. *[o]*
* **Paste Area**: paste the area bounds and contents from the (private) clipboard of the script, replacing anything found at the target location. The area(s) is/are pasted at the edit cursor, on the last-clicked or hovered section/lane of the MIDI Editor. See also **Copy Area** and **Cut Area**. *[o]*
* **Delete Area and Contents**: delete the area bounds and contents of the area under the mouse, or all areas if no single area is under the mouse. *[o]*
* **Delete Area, Preserve Contents**: delete only the area bounds of the area under the mouse, or all areas if no single area is under the mouse.
* **Delete Contents**: delete only the contents of the area under the mouse, leaving the area itself in place. If no single area is under the mouse, delete the contents of all areas. *[o]*
* **Invert Contents**: invert the values of the events inside the area, rotating around the value at the center. For instance, a full-lane CC area would change 127 to 0, 96 to 31, 64 to 63, and 63 to 64. *[o]*
* **Reverse Contents**: perform a retrograde transformation of the events, reversing the values and timing. *[o]*
* **Reverse Values, Preserving Position**: perform a retrograde transformation of the events, whereby the timing remains static, but the values are reversed. *[o]*
* **Select Contents**: select the events inside the area (does not split notes at the left/right area boundaries)
* **Unselect Contents**: unselect the events inside the area (does not split notes at the left/right area boundaries)
* **Span Area across CC Lanes**: given an area inside the piano roll (a note area), create additional full-lane areas across all visible CC lanes for the same time span.
* **Set Full Lane**: if the area under the mouse does not encompass the full range of values of its lane (or piano roll), force its boundaries to the maximum height.
* **Toggle Insert Mode**: when insert mode is enabled (a **⨁** symbol is displayed within the area bounds), no deletion of source or target regions is attempted. In this mode, a copy of the contents is always made (whether or not the **Copy** modifier is active).
* **Toggle Horizontal Lock Mode**: when horizontal lock mode is enabled (a **<span style="font-size:125%;">⇔</span>** symbol is displayed within the area bounds), the area can only be moved left and right.
* **Toggle Vertical Lock Mode**: when vertical lock mode is enabled (a **<span style="font-size:175%;">⇕</span>** symbol is displayed within the area bounds), the area can only be moved left and right.
* **Toggle Widget Mode**: enable, or disable, widget mode (when enabled, the widget controls will be visible) for linear control over value ramps. Double-clicking on an area will also enter/exit widget mode.
* **Exit MRE**: Exit the script.

[o] = respects the **Preserve Overlaps** modifier (notes only), see below.

**<u>Modifiers</u>**

* **Toggle Snap**: invert the current snap preference for the MIDI Editor.
* [click] **Set Cursor**: if active: when clicking in the MIDI Editor, the edit cursor will be moved to the clicked location. This can be practical when using the **Copy**/**Cut**/**Paste** operations.
* [move] **Copy**: if active: when moving an area or multiple areas, make a copy of the underlying contents (the default is to move the contents without making a copy)
* [move] **Single Area**: if active: when dragging areas, only the area under the mouse will be moved.
* [new] **Preserve Existing**: if active: when creating a new area, do not delete any existing areas (the default is to delete existing areas).
* [new] **Toggle Full-Lane**: if active: when creating a new area in the *piano roll* (for notes), a full-lane area will be created (the default is non-full-lane areas in the piano roll); when creating a new area in a CC lane, a full-lane area will *not* be created (the default is full-lane areas in CC lanes).
* [process] **Preserve Overlaps (notes)**: notes which intersect the area bounds will be included in any moving/processing when this modifer is active. Otherwise, the notes will be split at the area bounds and only the portion of the notes inside the bounds will be moved/processed.
* [stretch] **Stretch Area**: if active: when dragging on an area edge, stretch the contents (the default is to resize the area). LIMITATIONS: in the piano roll, only left/right stretching is supported; in velocity/release velocity lanes, only top/bottom stretching is supported. The default stretch mode is determined by the **Value Stretch Mode** preference.
* [move] **Move Area Only**: if active: when dragging areas, only the area bounds will be moved; the events in the MIDI Editor remain unchanged.

**<u>Widget Mode Modifiers</u>**

Enter **Widget Mode** by double-clicking on an area or by using the **Toggle Widget Mode** keyboard shortcut. A bar with two control handles will appear, and can be used to modify the values of events within the area, using the algorithms below.

* **Push/Pull**: when the bar is at the top of the area, all values are pushed up to the maximum determined by the area's upper bound. When the bar is at the bottom of the area, all values are pulled down to the minimum determined by the area's lower bound. In the middle, no change is made to the original values.
* **Offset**: values are offset (preserving relative distance between values) as the bar is raised and lowered. When the bar is at the top of the area, all values are at the maximum; when the bar is at the bottom of the area, all values are at the minimum.
* **Comp/Exp Middle**: when the bar is at the top of the area, all values are expanded away from the center value of the area to fill the entire area bounds; when the bar is at the bottom of the area, all values are compressed to the center value of the area.
* **Comp/Exp**: values are linearly compressed (bar toward the bottom) or expanded (bar toward the top) to fit the space of the area. The relative distance between values may change in this mode.

**<u>Misc</u>**

* **Add Control Points**: (CC lanes only) when moving/processing area contents, generate new points at the left/right area edges to prevent any side effects outside of the area bounds.

* **Value Stretch Mode**: (CC lanes only) when stretching the top/bottom edges, which algorithm will be used:

  * **Comp/Exp**: values are linearly compressed or expanded to fit the space of the area. The relative distance between values may change in this mode.
  * **Offset**: values are offset to follow changes in the height of the area. The relative distance between values remains constant in this mode.

  Note that **Widget Mode** provides additional value stretching modes.

* **Use Right Mouse Button** (experimental): 