# LetsMove (vendored)

Source: https://github.com/potionfactory/LetsMove, tag v1.25

Files: PFMoveApplication.h, PFMoveApplication.m

License: public domain (per dedication stated in PFMoveApplication.m header).
LetsMove has no Package.swift and no formal LICENSE file; the author's
dedication text at the top of the .m file grants the code to the public domain.

Vendored rather than SPM because this project uses only
`PFMoveToApplicationsFolderIfNecessary()` (called from AppDelegate), exposed to
Swift via Waypoint-Bridging-Header.h.
