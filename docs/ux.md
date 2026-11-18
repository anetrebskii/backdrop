# Backdrop UX

Backdrop replaces the background behind the person in a camera feed and publishes the result as a camera called Backdrop Camera, which any video app can select. It exists for cameras macOS does not offer its own Background effect for, such as an iPhone XR used as a Continuity Camera.

## Entry points

- Menu bar icon. Backdrop has no Dock icon and no main window. Clicking the icon opens the panel.
- Settings window: from the panel's gear button, or Cmd+, while the panel is open.

## Menu bar icon

- `person.and.background.dotted` while the background effect is on.
- `person.crop.rectangle` while it is off.

## Panel (320 pt wide)

From top to bottom:

1. Title row: "Replace background" and its switch. The switch is the primary action. Off passes the camera through unchanged.
2. Preview, 16:9, rounded 8 pt. Shows exactly what Backdrop Camera sends.
   - Starting: "Starting camera..."
   - No camera: "No camera found. Connect your iPhone or a camera."
   - Permission denied: "Backdrop needs camera access." and button "Open Privacy Settings".
   - The overlay at bottom left shows frame rate and segmentation time when the effect is on.
3. Background row: label "Background" and a segmented control "Blur" / "Image".
4. When Image is selected, a row of background thumbnails, 4 per row, then a "+" tile.
   - Clicking a thumbnail selects it; the selection has an accent ring and the preview changes on the next frame.
   - "+" opens a file panel for images; the chosen file is copied into Backdrop's library and selected.
   - Right-click a thumbnail: "Remove". The file goes to the Trash, so it can be restored.
   - Empty library: only the "+" tile, with the caption "Add a background image".
5. Footer: status of Backdrop Camera, and the gear and Quit buttons.
   - Installed: green dot, "Backdrop Camera is ready" and "Choose it as the camera in your video app."
   - Not installed: grey dot, "Backdrop Camera is not installed" and an "Install" button.
   - Waiting for approval: "Approve Backdrop Camera", "Allow Backdrop in System Settings > General > Login Items & Extensions." and an "Open" button.

## Settings window

Standard macOS Settings with three tabs.

- General: Camera picker; "Open at login" switch.
- Effect: Quality (Fast, Balanced, Accurate; default Accurate) with the caption "Accurate gives the cleanest hair and edges and uses the most power."; Edge softness slider (Sharp to Soft); Blur strength slider (Light to Strong).
- Camera: Backdrop Camera status, Install or Uninstall. Uninstall asks for confirmation: "Uninstall Backdrop Camera? Video apps using it will lose the picture." with the buttons "Uninstall" (destructive) and "Cancel" (default).

## Persistence

All choices persist across launches: switch, style, selected image, camera, quality, softness and blur strength.

## Permissions

The camera permission is requested when Backdrop first starts the camera, with the reason "Backdrop reads your camera to replace the background and publish it as Backdrop Camera."

## Apple design check

- Direct manipulation: backgrounds are chosen by clicking the image itself.
- Immediate feedback: every control changes the preview on the next frame.
- Forgiveness: Remove goes to the Trash; Uninstall is confirmed, with Cancel as default.
- Visible next step: each camera and extension state names its next action.
- No surprises: settings persist; the panel never opens on its own.
- Ask late: camera permission only when the camera starts.
- Quiet notifications: Backdrop sends none.
- Plain wording: messages name Backdrop Camera and the action to take.
