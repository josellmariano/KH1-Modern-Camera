# KH1 Modern Camera

Makes the KH1 camera feel like a modern game. Right-stick camera movement is
reworked to be smooth and responsive, with no camera inertia and no automatic
re-centering. Speed and sensitivity can be changed in a config file. The
lock-on camera isn't affected, so it works alongside mods like KH2 Style
Camera.

## Requirements

- Kingdom Hearts Final Mix, Steam version
- LuaBackend, installed through OpenKH Mods Manager
- A controller

## Settings

Start the game once with the mod and `KH1_Modern_Camera_Config.lua` appears
in the game folder, next to `KINGDOM HEARTS FINAL MIX.exe`. Open it in a text
editor, change a value, save, and restart the game. Every setting is
explained in the file, and mod updates never overwrite it.

| Setting | Default | What it does |
| --- | --- | --- |
| `CameraSpeed` | `1.4` | How fast the camera turns, compared to vanilla. |
| `PitchSpeed` | `0.85` | Up/down turn speed, compared to left/right. |
| `ResponseCurve` | `1.5` | `1` is linear. Higher values give finer control on small stick tilts. |
| `Deadzone` | `0.2` | How far the stick moves before the camera does. Raise it if the camera drifts. |
| `InvertX` / `InvertY` | `false` | Flip left/right or up/down. |
| `HoldPitch` | `true` | `false` brings back the automatic re-centering. |

## Compatibility

- Don't use it with CameraSpeedSlider. Both mods change the same values.
- The in-game camera invert options have no effect with this mod. Use
  `InvertX` and `InvertY` in the config file instead.

## License

MIT. See [LICENSE](LICENSE).
