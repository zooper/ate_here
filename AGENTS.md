# AGENTS.md

## Project overview

**Ate Here** is a private, local-first iOS app that helps users remember which restaurants they visited.

The app examines the user’s selected photos, groups them into likely restaurant visits, finds nearby restaurants, and suggests the most likely match.

The core product promise is:

> You took the photos. Ate Here remembers the place.

Ate Here is a personal restaurant journal. It is not a restaurant discovery service, review network, calorie tracker, social network, or general-purpose photo organizer.

---

## Core product principles

All implementation decisions must follow these principles:

1. **Local first**

   * User data remains on the device by default.
   * The app must function without a developer-operated backend.
   * Do not introduce servers, hosted databases, API gateways, analytics pipelines, or custom authentication.

2. **Private by design**

   * Photos must not be uploaded to an external service.
   * Photo analysis should happen on-device.
   * Request only the minimum Photos permissions needed.
   * Explain clearly why access is required.

3. **No mandatory account**

   * Users must be able to use the complete core app without creating an account.
   * Do not add email login, Sign in with Apple, or custom user profiles unless a later product requirement explicitly demands it.

4. **Confirmation over false certainty**

   * The app suggests restaurants.
   * The user confirms the final restaurant.
   * Never silently assign a visit when confidence is uncertain.
   * Do not display invented precision such as “94% confidence” unless the scoring system has been properly calibrated.

5. **Apple-native**

   * Prefer first-party Apple frameworks.
   * Follow current iOS design conventions.
   * Prefer SwiftUI, Swift Concurrency, SwiftData, PhotoKit, Vision, Core Location, and MapKit.
   * Avoid third-party dependencies unless they provide substantial value that cannot reasonably be achieved with Apple frameworks.

6. **No variable AI cost**

   * Do not call OpenAI, Anthropic, Google, or another hosted inference API.
   * Do not add functionality that creates a per-use operating expense.
   * Optional intelligence must use Apple-provided on-device capabilities or a bundled Core ML model.

---

## Supported platform

Initial target:

* iPhone
* Portrait-first interface
* Current public iOS SDK
* Swift 6 language mode where practical
* SwiftUI application lifecycle

Do not add iPad, macOS, watchOS, visionOS, widgets, or App Clips during the initial MVP unless required to avoid an architectural dead end.

Set the minimum deployment target based on the APIs actually required by the MVP. Do not increase it solely to use optional Apple Intelligence features.

---

## MVP user experience

The initial user flow should be:

1. User opens Ate Here.
2. User selects photos or grants appropriate limited Photos access.
3. The app reads available metadata:

   * creation date,
   * location,
   * asset identifier,
   * media type.
4. The app groups related photos into possible visits.
5. The app performs coarse on-device food classification.
6. The app searches MapKit for nearby restaurants.
7. The app ranks candidate restaurants using multiple signals.
8. The app presents the best candidates.
9. The user confirms or manually searches for the correct restaurant.
10. The app saves the visit.
11. The visit appears in a chronological journal and on a map.

The confirmation flow should take only a few seconds when the first suggestion is correct.

---

## Explicit non-goals for the MVP

Do not build the following:

* Social feeds
* Public profiles
* Followers or friends
* Public restaurant reviews
* Restaurant reservations
* Food delivery
* Calorie or macro tracking
* Receipt expense accounting
* Exact menu-item recognition
* Automated restaurant reviews
* Hosted generative AI
* Android support
* Web application
* Developer-operated backend
* Custom restaurant directory
* Gamification
* Advertising
* Subscription infrastructure before the product has demonstrated value

Avoid speculative abstractions for these features.

---

## Architecture

Use a modular architecture with clearly separated responsibilities.

Suggested modules or logical components:

```text
AteHereApp
├── Features
│   ├── Onboarding
│   ├── PhotoImport
│   ├── VisitDetection
│   ├── RestaurantMatching
│   ├── VisitConfirmation
│   ├── Journal
│   ├── VisitDetail
│   ├── Map
│   └── Settings
├── Services
│   ├── PhotoLibraryService
│   ├── PhotoAnalysisService
│   ├── VisitClusteringService
│   ├── PlaceSearchService
│   ├── RestaurantRankingService
│   └── LocationService
├── Models
├── Persistence
└── SharedUI
```

Do not create a separate package for every small component. Keep the repository understandable for one developer.

Use dependency injection through protocols and initializers where it improves testing. Avoid a heavyweight dependency-injection framework.

---

## Data ownership boundaries

Ate Here stores two categories of data.

### User-owned data

The app may persist:

* Visit date and time
* Photo asset identifiers
* Original photo coordinates, when available
* User rating
* User notes
* User-created tags
* User-selected favorite dishes
* User confirmation state
* Coarse food categories produced on-device
* Custom restaurant title entered by the user
* Apple Maps Place ID
* App-generated matching diagnostics when useful for debugging

### Apple Maps data

Treat MapKit restaurant data as externally sourced map data.

Persist the Apple Maps Place ID as the durable reference.

Do not build a permanent replicated restaurant directory containing copied MapKit records such as:

* complete addresses,
* opening hours,
* phone numbers,
* websites,
* cuisine metadata,
* map imagery,
* reviews,
* photos,
* large sets of coordinates.

Resolve current place information through MapKit when displaying it.

A small disposable cache may be used for performance if permitted by current Apple terms. Cached values must not become the authoritative restaurant database.

Before implementing persistent caching of MapKit-provided names or other attributes, verify the current Apple Maps and MapKit terms.

---

## Suggested persistence models

Use SwiftData unless current SDK limitations make it unsuitable.

A possible initial model:

```swift
@Model
final class Visit {
    @Attribute(.unique)
    var id: UUID

    var visitedAt: Date
    var confirmedAt: Date?

    var latitude: Double?
    var longitude: Double?

    var applePlaceID: String?
    var userDefinedPlaceName: String?

    var rating: Int?
    var notes: String
    var foodCategories: [String]

    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade)
    var photos: [VisitPhoto]

    init(
        id: UUID = UUID(),
        visitedAt: Date,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.visitedAt = visitedAt
        self.latitude = latitude
        self.longitude = longitude
        self.notes = ""
        self.foodCategories = []
        self.createdAt = .now
        self.updatedAt = .now
        self.photos = []
    }
}
```

```swift
@Model
final class VisitPhoto {
    @Attribute(.unique)
    var assetLocalIdentifier: String

    var capturedAt: Date?
    var latitude: Double?
    var longitude: Double?

    var classificationLabels: [String]
    var isPrimary: Bool

    init(assetLocalIdentifier: String) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.classificationLabels = []
        self.isPrimary = false
    }
}
```

Do not copy original photo files into the app container unless there is a specific requirement. Prefer storing PhotoKit asset identifiers and requesting the asset when needed.

Handle deleted or unavailable PhotoKit assets gracefully.

---

## Photo access

Prefer the least invasive access model that can support the intended experience.

The application must support limited Photos access.

Photo permissions must never be requested on first launch without context. First explain:

* what the app examines,
* that processing happens locally,
* that photos are not uploaded,
* that the user controls which photos are available.

Do not block the entire app when the user denies broad library access. Provide manual photo selection where practical.

Do not retain image pixel data after analysis unless needed for a visible user feature.

---

## Visit clustering

A visit is a group of photos that were probably taken during the same restaurant outing.

Initial clustering may use:

* time difference,
* geographic distance,
* continuity between photos,
* whether photos contain food, drinks, menus, receipts, or restaurant interiors.

Start with deterministic heuristics.

Example initial rules:

* Photos less than 90 minutes apart are candidates for the same visit.
* Photos within roughly 100 metres strengthen the same-visit hypothesis.
* A long time gap should split clusters.
* A major location change should split clusters.
* Missing location metadata should not automatically exclude a photo.
* Screenshots and obviously unrelated images should be ignored.

Keep thresholds configurable in one location.

Do not introduce machine learning for clustering until deterministic rules have been tested with real photo libraries.

---

## Food classification

The classifier only needs broad categories.

Useful examples:

* pizza,
* burger,
* steak,
* sushi,
* ramen,
* pasta,
* tacos,
* Indian food,
* Chinese food,
* seafood,
* salad,
* coffee,
* pastry,
* dessert,
* cocktails,
* beer,
* wine,
* menu,
* receipt,
* restaurant interior.

Exact dish recognition is not required.

The output must be represented as ranked labels rather than a guaranteed answer.

Example:

```swift
struct FoodClassification: Sendable {
    let category: FoodCategory
    let confidence: Double
}
```

Use Vision, Core ML, or supported Apple on-device model capabilities.

Apple Intelligence must be treated as optional enhancement functionality. The core app must still work on devices where it is unavailable, disabled, unsupported, or unable to process the input.

Do not send photos to hosted AI services.

---

## Restaurant candidate search

Search for nearby points of interest using MapKit.

Candidate retrieval should consider:

* cluster centroid,
* GPS accuracy when available,
* search radius,
* restaurant and café point-of-interest categories,
* visit timestamp,
* candidate distance.

Use a radius that accounts for imperfect indoor GPS. Start conservatively and measure results.

Do not assume the geographically closest business is always correct. Dense urban areas may contain several restaurants at nearly identical coordinates.

The user must also be able to:

* search manually,
* choose none of the suggestions,
* enter a custom place,
* correct a previously confirmed visit.

---

## Candidate ranking

Restaurant matching is a ranking problem, not a binary classifier.

Initial signals should include:

1. Distance from the photo cluster
2. Food-category compatibility
3. Business category
4. Visit timing
5. Number of consistent photo coordinates
6. Previous user confirmations at the same place
7. Negative evidence

Negative evidence is important.

Examples:

* A steak photo should strongly penalize a pharmacy.
* Pizza should boost pizzerias and relevant Italian restaurants.
* Coffee and pastry should boost cafés and bakeries.
* Sushi should penalize unrelated retail businesses.
* Food classification should not automatically eliminate a general restaurant that could plausibly serve the food.

Implement scoring as a pure, testable function.

Example:

```swift
struct RestaurantCandidateScore: Sendable {
    let placeID: String
    let distanceScore: Double
    let foodCompatibilityScore: Double
    let categoryScore: Double
    let timingScore: Double
    let historyScore: Double
    let totalScore: Double
}
```

Do not present raw scores to users during the MVP.

User-facing confidence labels may be:

* Very likely
* Likely
* Possible

The thresholds must be centralized and testable.

---

## Matching behavior

If there is one clearly plausible result, show it prominently.

If several candidates are plausible, show the top three to five.

If no candidate is plausible:

* say that no confident match was found,
* offer manual search,
* allow a custom place,
* do not manufacture a match.

Always preserve the user’s ability to override the ranking.

Every correction should be stored in a way that could improve future local ranking without requiring a backend.

---

## Search and journal

The journal should support:

* chronological visits,
* restaurant name,
* visit date,
* rating,
* notes,
* selected photos,
* food tags,
* favorites,
* map view.

Initial search should be deterministic and local.

Searchable fields may include:

* user-defined restaurant name,
* currently resolved place name,
* notes,
* tags,
* food categories,
* city or locality when available for display,
* visit date.

Do not add natural-language generative search to the MVP.

---

## Cloud synchronization

Cloud synchronization is optional and must not block the first release.

If introduced, use the user’s private iCloud database through Apple-supported persistence mechanisms.

Cloud sync must not require the developer to operate a service.

Do not sync full-resolution copies of photos. Store references and app-owned visit metadata unless a future design explicitly introduces app-managed photo copies.

The app must remain usable when:

* iCloud is disabled,
* the user is signed out,
* the device is offline,
* synchronization is delayed,
* records conflict.

Local data is primary for the immediate user experience.

---

## Monetization

Do not implement monetization until the core import and matching flow works reliably.

Likely future model:

* free trial or limited free tier,
* one-time purchase or modest annual premium,
* no advertising,
* no sale of user data.

Potential premium features may include:

* unlimited visit history,
* iCloud synchronization,
* map history,
* advanced filters,
* exports,
* shared journals,
* richer on-device analysis.

Do not lock the user’s existing personal data behind a paywall after it has been created.

Export and deletion must remain available.

---

## Privacy

Ate Here handles sensitive personal information, including location history and photos.

Required rules:

* Never log image contents.
* Never log precise coordinates in production analytics.
* Never transmit photo metadata to third parties.
* Never use user photos for model training.
* Never collect a central restaurant-visit history.
* Do not add tracking SDKs.
* Avoid analytics for the MVP.
* Use local structured logging for development where needed.
* Remove or redact sensitive logging in release builds.

The privacy policy must accurately state what the shipping app does, not what the project intends to do later.

---

## Accessibility

All primary functionality must support:

* VoiceOver,
* Dynamic Type,
* sufficient contrast,
* reduced motion,
* clear button labels,
* non-color-only confidence indicators.

Do not make photo thumbnails the only way to identify a visit.

---

## UI direction

The interface should feel calm, personal, and native.

Prefer:

* large photography,
* simple typography,
* restrained use of controls,
* clear confirmation actions,
* familiar Apple navigation,
* content-first visit pages.

Avoid:

* dashboard-heavy screens,
* excessive cards,
* social-media styling,
* technical confidence charts,
* chatbot interfaces,
* gradients used without purpose,
* dense restaurant metadata.

The user should feel that the app is a photo journal, not a mapping utility.

---

## Error handling

Every Apple framework call can fail or return incomplete information.

Handle at least:

* denied Photos access,
* limited Photos access,
* missing photo location,
* missing creation date,
* unavailable PhotoKit asset,
* MapKit search failure,
* no nearby restaurants,
* missing Place ID,
* place no longer resolvable,
* unsupported on-device model,
* Apple Intelligence disabled,
* offline state,
* SwiftData save failure.

Errors must produce an understandable recovery action.

Never crash because optional metadata is missing.

---

## Concurrency

Use Swift Concurrency.

Rules:

* UI-facing state changes occur on `MainActor`.
* Photo analysis and scoring must not block the main thread.
* Long-running import work should be cancellable.
* Avoid unstructured `Task` usage when structured concurrency is possible.
* Respect task cancellation during photo imports.
* Use bounded concurrency when processing many photos.
* Do not load large numbers of full-resolution images simultaneously.

---

## Testing expectations

At minimum, provide unit tests for:

* time-based photo clustering,
* distance-based photo clustering,
* cluster splitting,
* food-category compatibility,
* negative evidence,
* candidate score ordering,
* confidence-label thresholds,
* handling missing coordinates,
* handling missing food classifications,
* repeated visits to the same place.

Use fixtures representing difficult real-world cases:

* several restaurants in one building,
* a restaurant next to Starbucks,
* food court,
* hotel restaurant,
* photos without GPS,
* photos taken after leaving the restaurant,
* screenshots mixed into the photo sequence,
* multiple restaurants visited on the same evening,
* home-cooked food near restaurants,
* takeaway food photographed at home.

Do not make tests depend on live MapKit results. Wrap MapKit behind a protocol and use deterministic test candidates.

---

## Coding standards

* Use clear names over abbreviations.
* Prefer small focused types.
* Avoid massive observable view models.
* Keep business logic out of SwiftUI views.
* Use value types where appropriate.
* Use protocols at external framework boundaries.
* Do not add abstractions without a current use.
* Do not use force unwraps in production code.
* Avoid global mutable state.
* Document non-obvious scoring and privacy decisions.
* Keep constants such as clustering thresholds and ranking weights centralized.
* Format code consistently using the repository’s chosen formatter.
* Keep warnings at zero.

---

## Dependency policy

Do not add a third-party package without documenting:

* why Apple frameworks are insufficient,
* maintenance status,
* privacy impact,
* binary-size impact,
* licensing,
* whether the dependency introduces networking.

Default answer: do not add the dependency.

Never add:

* hosted analytics SDKs,
* advertising SDKs,
* generic networking layers,
* third-party authentication,
* cloud AI SDKs.

---

## Implementation order

Work in this order unless an issue explicitly changes the priority:

### Phase 1: Manual journal

* SwiftData models
* Manual restaurant search
* Save a visit
* Attach selected photos
* Journal list
* Visit detail
* Edit and delete

### Phase 2: Metadata matching

* Read photo dates and coordinates
* Group photos into visits
* Search nearby restaurants
* Rank primarily by distance
* Confirmation interface

### Phase 3: Food-assisted ranking

* Coarse food classification
* Cuisine compatibility mapping
* Negative evidence
* Improved candidate ordering
* Test against real-world photo sets

### Phase 4: Polish

* Map view
* Search and filters
* Permissions onboarding
* Empty states
* Accessibility
* Import performance
* Privacy documentation

### Phase 5: Optional enhancements

* iCloud synchronization
* On-device Apple Intelligence enhancements
* Export
* Shared journal
* Monetization

Do not begin Phase 5 while the core matching experience is unreliable.

---

## Definition of done for the MVP

The MVP is complete when a user can:

1. Select a group of restaurant photos.
2. Have them grouped into a likely visit.
3. Receive nearby restaurant suggestions.
4. See obviously incompatible businesses ranked lower.
5. Confirm or correct the restaurant.
6. Add a rating and note.
7. Reopen the visit later.
8. View the visit’s photos without them being uploaded anywhere.
9. Delete the visit and its app-owned metadata.
10. Use the app without creating an account or connecting to a developer-operated backend.

The MVP does not require perfect food recognition.

It requires restaurant suggestions that are meaningfully better than choosing the nearest point of interest alone.

---

## Instructions for coding agents

Before changing code:

1. Read this file.
2. Inspect the existing project structure.
3. Identify which MVP phase the task belongs to.
4. Preserve the local-first and backend-free architecture.
5. Verify uncertain Apple API behavior against current official Apple documentation.
6. State any privacy, MapKit-data, or deployment-target implications in the change summary.

When implementing a task:

* Make the smallest coherent change that completes it.
* Include or update tests for business logic.
* Do not silently add product scope.
* Do not introduce a network service merely because it is easier.
* Do not use hosted AI.
* Do not persist copied Apple Maps records as a restaurant database.
* Do not assume Apple Intelligence is available.
* Do not request broader Photos access than necessary.
* Do not claim an uncertain restaurant match as fact.

When finishing:

* Build the project.
* Run relevant tests.
* Report warnings and failures honestly.
* Summarize files changed.
* Describe any manual testing still required.
* Call out assumptions that need validation on a physical iPhone.

