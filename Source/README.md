# Swift source

App.swift manages the menu, slider and brightness queue. Hardware.swift reads and writes hardware backlight through DisplayServices or DDC/CI. Keys.swift filters brightness key events. ScreenDimming.swift implements the 1% and 5% low-brightness presets and software shading. The remaining files provide the HUD, login launch, recovery shortcut and CLI.

Build from the repository root with `bash build.command`.
