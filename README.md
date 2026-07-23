# Ate Here

Ate Here is a private, local-first iPhone journal for remembering restaurants
from personal visits and photos.

The current foundation implements the manual journal and the first Phase 2 import slice:

- create a visit manually;
- attach up to 10 gallery photos while creating or editing a manual visit;
- use a manually selected photo’s capture date, GPS, and on-device food labels to suggest restaurants;
- search Apple Maps and retain only a durable Place ID;
- enter a custom place when Apple Maps has no suitable result;
- save it on device with SwiftData;
- browse visits chronologically;
- add and remove detected or custom tags on each visit;
- browse restaurants grouped by place, filter them by specific food or drink tags, and sort them by recency, visit count, or rating;
- optionally back up journal metadata to the user’s private iCloud database and safely merge it during restore;
- view a live-resolved restaurant address and a non-interactive location map;
- browse an interactive photo map with each geotagged visit photo at its capture location;
- tap a map photo to reopen its visit;
- view, edit, and delete a visit;
- optionally scan the last 30 days of selected Photos access;
- group likely outings using deterministic time and distance rules;
- use on-device Vision labels as coarse food evidence;
- exclude clusters without food or restaurant-related evidence;
- use each photo cluster’s saved GPS location to suggest nearby restaurants;
- rank suggestions using on-device food labels, Apple Maps business type, and distance;
- show a coarse 5-point-step match score when useful food evidence is available;
- review photo groups and confirm a restaurant before saving;
- optionally scan for new food-related photos when the app opens;
- optionally set a private home area that automatic scans ignore;
- keep automatic matches in a private review inbox until they are confirmed or dismissed;
- request occasional iOS background refresh time without automatically creating visits.

Photo scanning is opt-in, supports limited Photos access, and does not upload
photos or retain analyzed image pixels. Foreground scanning runs when the app is
opened; background scanning is opportunistic and scheduled by iOS. A match never
becomes a saved visit without confirmation. Apple Maps names and addresses are
resolved for display and are not copied into the local restaurant database. The
match score is a deterministic photo-and-location heuristic, not a calibrated
statistical confidence. Category-search hints are used only for the current
Apple Maps lookup and are not persisted as restaurant records. The
app has no developer-operated backend, account system, analytics SDK, hosted AI,
or third-party runtime dependencies.

The optional home area stores only a coordinate, radius, and enabled state in
local settings. It is not included in iCloud journal backups. It affects only
automatic suggestions; manually selected photos remain available, and photos
without GPS are not silently excluded.

iCloud journal backup is also opt-in. When enabled, it stores visit metadata,
including dates, notes, tags, ratings, coordinates, durable Apple Place IDs, and
PhotoKit asset references, in the user’s private CloudKit database. It never
uploads original photos. Restoring merges missing and newer backed-up visits
without deleting newer local edits. Photo references that are unavailable in the
current Photos library continue to degrade gracefully.

## Requirements

- Xcode 26 or newer
- iOS 18 or newer

## Development

Open `AteHere.xcodeproj` and run the `AteHere` scheme on an iPhone simulator.
The unit and UI tests are included in the same scheme.

The project uses automatic signing for Apple development team `K6VJLG2HHY`. A
matching Apple account must be signed in under Xcode Settings > Accounts before
Xcode can create a provisioning profile for a physical iPhone.
