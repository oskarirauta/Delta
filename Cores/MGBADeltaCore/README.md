# mGBA integration

This core uses upstream mGBA 0.10.5, pinned at
`26b7884bc25a5933960f3cdcd98bac1ae14d42e2`, for GBA games on iOS and tvOS.
Select it in the GBA core settings; the existing VBA core remains available.

The cores have separate save states because their state formats are not
interchangeable. Legacy GBA states without a core identifier belong to VBA.
On tvOS, mGBA states use the `mgba` filename namespace. Automatic saves are
written to a temporary file and published only after a nonempty write succeeds.

mGBA uses `.mgba.sav` battery saves. On first use, an existing VBA `.sav` is
copied if the mGBA save does not exist. Subsequent progress is independent in
each core; switching cores does not continuously synchronize battery saves.

iOS motion controls require the motion permission declared by the app. tvOS
supplies neutral motion values. Physical-controller testing and broader game
compatibility testing remain necessary; successful compilation does not prove
compatibility with every game.
