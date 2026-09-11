# Waypoint

An individual study project for macOS. Built to explore modern Apple-platform
engineering end to end:

- Swift 6 strict concurrency (`Sendable`, actors, structured tasks)
- SwiftUI interface targeting macOS Tahoe 26.0+
- Subprocess management and a REST/WebSocket control plane
- Privileged helper (SMJobBless) and XPC
- System configuration, event monitoring, and background services
- Asset pipelines and packaging

Requires macOS 26+ and Xcode 26+. Not maintained, not for distribution —
published here only as a coding exercise.

## Building

Three assets the app bundle needs are not built from source: the mihomo core,
a GeoIP database, and the web dashboard.

```sh
brew install go            # only needed to build the core from source
./install_dependency.sh    # fetch and verify all three
open Waypoint.xcodeproj    # build and run the Waypoint scheme
```

Every download is checked against a pin — `Waypoint/goWaypoint/mihomo.sha256`
for the core (built from a pinned source tag by default), `assets.sha256` for
the rest. The GeoIP database comes from a rolling upstream release that is
replaced roughly daily, so its pin is expected to fail once upstream
republishes: audit the new database, then run `./install_dependency.sh --update`
to re-pin it.

The two Swift packages carry their own tests:

```sh
(cd WaypointCore && swift test)
(cd WaypointNetworking && swift test)
```
