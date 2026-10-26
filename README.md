# MapMe

MapMe is a private, family-only location sharing app for Apple platforms. A family member's iPhone or Apple Watch records where it has been, and the people they trust can follow along on an iPhone, iPad, Mac, or Apple TV. There is no server and no account to create. Everything travels through the family's own iCloud using CloudKit sharing, so location history never leaves Apple's infrastructure or lands on a third-party backend.

## How it works

Every device picks one of two roles on first launch.

- **Minor** is the device being tracked. It records GPS fixes in the background, stores them locally with Core Data, and mirrors them to the owner's private CloudKit database. The Minor creates a `CKShare` invitation and sends it through Messages, Mail, or AirDrop.
- **Guardian** is a device that accepts one or more of those invitations. Shared records arrive in the Guardian's CloudKit shared database and appear on a dashboard map. A Guardian can follow several Minors at once.

Tracking on a Minor stays blocked until a Guardian accepts the share and grants consent. Until then the Minor sees a "waiting for approval" screen and writes nothing.

Besides people, a Guardian can also add **pet** and **device** trackers. These have no device of their own to pair. Instead, a Shortcuts automation or a Siri request calls the "Log Tracker Location" App Intent to record a position for them, which makes it possible to fold a pet collar or a standalone GPS unit into the same family map.

## Features

### Guardian dashboards

- Dedicated layouts for iPhone, iPad, Mac, and Apple TV, each built around a full-screen map with device cards.
- Three view modes. **Day** shows a single calendar day with a time-of-day scrubber. **Week** overlays seven days with one polyline per device. **Live** shows a rolling 24-hour window that refreshes the moment new fixes arrive via silent push.
- Smooth live-marker interpolation so markers glide between fixes instead of jumping.
- Trails snapped to roads with MapKit directions, rate-limited app-wide to stay under Apple's throttle.
- Journey detection. Round trips that leave an anchor and return are numbered within the day and pinned at their turnaround point.
- Spoken alerts when a tracked device starts moving or arrives somewhere, with a trip log per profile.
- A fresh dashboard centres on the Guardian's own location before any shared records arrive.

### Minor tracking

- Background location on iOS with significant-change monitoring, visit monitoring, and Core Motion activity detection to wake tracking when the user starts moving.
- A hybrid approach on watchOS. Periodic background refreshes take a single fix roughly every fifteen minutes, and the user can start a live session with an extended runtime session for continuous updates.
- Power profiles that trade battery life against fix granularity. GPS stays the primary source in every profile. The profile only changes how often fixes are sampled and written.
- Adaptive sampling that varies the write interval by speed, so a stationary device writes rarely while a device in a car writes often enough to avoid gaps in the trail.
- A teleport guard that rejects implausible fixes before they are persisted.
- Daily launch reminders via a local notification so tracking resumes if the app was closed.

### Privacy and security

- All data stays within the family's iCloud account. MapMe runs no backend.
- Explicit consent flow. A Minor cannot record until a Guardian approves the pairing.
- App lock with a passcode and Face ID or Touch ID where available. The watch can borrow the paired iPhone's unlocked state for a few minutes instead of asking for its own PIN.
- Trusted device management. Every device that has launched MapMe under the account is listed in a family-wide register, and a Guardian can revoke one to force it back through approval. Revocation is a soft delete and can be undone.
- Automatic archiving. Raw fixes are summarised into per-day archives and the fine-grained detail is deleted after a retention window, so history does not grow forever.

### Siri and Shortcuts

- App Intents on iOS and watchOS to start and stop live tracking and to log a tracker position.
- Siri tips on the main screens that teach the available phrases and remember when they have been dismissed.

### Apple Watch

- A standalone watch app that tracks on its own, with a complication and widget showing current tracking status.
- The watch hands share links to the iPhone so invitations can be sent with the phone's full share sheet.

## Platforms

| Target | Minimum OS | Role |
| --- | --- | --- |
| MapMe-iOS (iPhone and iPad) | iOS 17 | Minor or Guardian |
| MapMe-macOS | macOS 14 | Guardian |
| MapMe-tvOS | tvOS 17 | Guardian |
| MapMe-Watch | watchOS 10 | Minor |
| MapMeWatchWidgets | watchOS 10 | Status complication |

## Architecture

The app is SwiftUI throughout, with one shared source tree for iOS, macOS, and tvOS and a separate tree for watchOS.

- **Persistence.** `NSPersistentCloudKitContainer` with two stores. The private store mirrors the user's own records to their private CloudKit database. The shared store mirrors records from accepted shares. Core Data entities are `MinorProfile`, `LocationRecord`, `DayArchive`, and `TrustedDevice`.
- **Sharing.** The Minor shares its single `MinorProfile` row. Core Data moves the profile and its related records into a shared zone, and new child records follow automatically.
- **Sync.** Guardians subscribe to shared-database changes so a silent push wakes the app when a Minor writes new fixes.
- **Services.** Location, sharing, sync, archiving, snap-to-roads, motion monitoring, audio alerts, trusted devices, and launch reminders each live in their own service type under `MapMe/Services`.
- **Logging.** Services log to the unified logging system under the app's subsystem with per-feature categories such as `pairing`, `sharing`, and `guardian-alerts`, so Console.app can be filtered to a single flow.

## Project layout

```
MapMe/                 Shared iOS, macOS, and tvOS app
  Models/              Roles, power profiles, adaptive sampling, tracker kinds
  Persistence/         Core Data model and CloudKit container setup
  Services/            Location, sharing, sync, archiving, intents, alerts
  Views/               Dashboards, pairing, settings, lock screens
  Resources/           Per-platform Info.plist and entitlements
MapMeWatch/            Standalone watchOS app
MapMeWatchWidgets/     watchOS complication and widget
Tools/                 Icon generator script and previews
project.yml            XcodeGen project definition
```

## Building

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing targets or source lists, regenerate it.

```sh
brew install xcodegen
xcodegen generate
open MapMe.xcodeproj
```

All targets derive their bundle identifiers from a single `IOS_APP_BUNDLE_ID` build setting, so changing the app identity means editing that one value. Each target needs the iCloud capability with CloudKit enabled, background location, and remote notifications. The CloudKit container must be shared across all targets so the watch and the phone write into the same private database.

To regenerate the app icons after editing the generator:

```sh
swift Tools/generate_icons.swift
```

## Pairing a family

1. On the child's or family member's device, choose **Minor** and generate an invitation.
2. Send the link through Messages, Mail, or AirDrop to the Guardian.
3. On the Guardian's device, choose **Guardian** and open the link. Accepting the share grants consent.
4. The Minor begins recording, and its trail appears on the Guardian dashboard within a few seconds of each new fix.

Repeat for each additional Minor. One Guardian can follow the whole family, and the same person can be a Guardian on a Mac or Apple TV while their own iPhone acts as a Minor.
