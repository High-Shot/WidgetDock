# WidgetDock

A second Dock for macOS with live widgets: clock, weather, next calendar event, apps and folders, system stats (CPU, memory, temperature, battery), now playing, todos and trash. It can replace the system Dock.

## Build

Needs macOS 14 or later on Apple Silicon and the Xcode command line tools.

```bash
./build.sh
```

This builds the app, installs it in `/Applications` and starts it. Click the gear at the right end of the dock for settings.

## Notes

- Weather comes from open-meteo.com, using your location if you allow it.
- Calendar events come from the macOS Calendar app.
- Badges and "keep windows above the dock" need the Accessibility permission.
- Temperature uses private IOKit calls, so it may break on a future macOS.
