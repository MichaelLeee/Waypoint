# Global Shortcuts

Waypoint supports global shortcuts through AppleScript, invoked via the
system Automator app.

Supported actions:

1. Toggle system proxy on/off
2. Switch outbound mode

## Creating a global shortcut with Automator

1. Open **Automator** and create a new *Quick Action*.
2. Add a *Run Shell Script* action.
3. Paste one of the commands below.
4. Save it, then assign a keyboard shortcut in
   **System Settings → Keyboard → Keyboard Shortcuts → Services**.

## Available AppleScript commands

Toggle system proxy:

```
tell application "Waypoint" to toggleProxy
```

Switch outbound mode to global:

```
tell application "Waypoint" to proxyMode 'global'
```

Switch outbound mode to direct:

```
tell application "Waypoint" to proxyMode 'direct'
```

Switch outbound mode to rule:

```
tell application "Waypoint" to proxyMode 'rule'
```

## Known limitations

1. Shortcuts will not fire from the desktop itself — focus any application
   window first for the service shortcut to run.
2. The first time a shortcut runs in any application, confirm the
   authorization prompt once to allow it.
