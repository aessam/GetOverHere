# GetOverHere Product Design

**Status:** Current summary. Functional authority remains [TourGuideProductSpec.md](TourGuideProductSpec.md).

## Information architecture

The first screen has two actions: create a tour as guide or join a discovered tour as guest. There is no transport-configuration screen in the production flow.

### Guide session

```text
Tour header
├── live microphone state
├── validated listener count
├── per-tour join code
└── end tour

Tour tools
├── Slides: import, reorder, remove, show, hide, next, previous
├── Map: import offline pack, drop/move/label/clear one target
└── Pointer: share/update/clear a magnetic sightline bearing
```

### Guest session

```text
Tour header
├── connection/reconnect state
├── private receiver/headset output (default)
├── warned speaker override
└── leave tour

Tour content
├── automatically presented slide, locally minimizable
├── offline map with shared pin and optional local guidance
└── local-heading-relative pointer
```

## Visual priority

The guide-selected Slides, Map, or Pointer tool is the shared guest screen. Selecting Map or Pointer replaces a visible slide without clearing that slide, pin, or bearing state. Guests may browse another tool locally, but the next guide screen change or presentation action restores the guide's selection. Minimizing a slide is local guest state and does not modify shared presentation state.

## State and failure design

- Product state is authoritative and versioned; button events alone are not synchronization state.
- Guests receive a complete snapshot after joining or reconnecting.
- Missing map content, denied location, unavailable compass, poor compass accuracy, transfer failure, and reconnecting are distinct visible states.
- Audio remains active while visual tools are open and while the display is locked, subject to platform-supported background audio lifecycle.
- Transport counters and Wi-Fi Aware diagnostics remain outside the production tour flow.

## Privacy

Only the guide-selected target coordinate crosses the network. Every device's position, heading samples, accuracy, path, and derived movement remain local. Slides and credentials are not logged. No cloud service or analytics SDK participates in a tour.
