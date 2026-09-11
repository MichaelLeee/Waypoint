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

## Updates

The app bundles Sparkle and starts its updater from `AutoUpgardeManager`; the
"Check Update" menu item is bound to Sparkle's standard updater controller, and
the update channel picker switches between the stable feed and a pre-release feed.

Self-updating needs an EdDSA key pair and a signed appcast, neither of which is
committed:

- `SUPublicEDKey` is deliberately absent from `Waypoint/Info.plist`. Until it is
  set, Sparkle cannot validate a download, so the updater fails to start and the
  app logs that the key is missing.
- `SUFeedURL` points at `https://michaelleee.github.io/Waypoint/appcast.xml`, which
  has to exist before a check can succeed.

To finish on a machine with Sparkle's tools: run `generate_keys` once (from the
Sparkle distribution's `bin/` directory — it prints the public key and stores the
private key in the login keychain), add the printed value to `Waypoint/Info.plist`
as `SUPublicEDKey`, then sign each release and write the feed with
`generate_appcast`. Keep the private key out of the repository.

