# Personal builds

`PersonalBuild.xcconfig` opts into local feature access for this private build:

```sh
xcodebuild -workspace Delta.xcworkspace -scheme Delta -configuration Release \
  -xcconfig Config/PersonalBuild.xcconfig \
  -destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=18.0 build
```

In Xcode, add `DELTA_PERSONAL_BUILD` to the Delta app target's **Active Compilation
Conditions** for your local configuration instead, if preferred.

The flag unlocks experimental features and alternate icons, hides the Patreon
settings section and supporter badges, and skips automatic Patreon account and
purchase-provider initialization. It does not change the account's membership
state or claim a paid subscription. Ordinary builds retain the existing behavior.
The tvOS app has no Patreon feature gates and needs no such flag.

The personal configuration passed a full Release build for the arm64 iOS
simulator with Xcode 27, using `IPHONEOS_DEPLOYMENT_TARGET=18.0` and disabled
code signing. This verifies compilation, not installation on an iOS device.
