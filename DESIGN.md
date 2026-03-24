# GetOverHere / ComeOverHere — UI/UX Design Spec

**Version:** 1.0
**Date:** 2026-03-23
**Source of Truth:** SPEC.md v1.0

---

## 1. Screen Architecture

### 1.1 Single-View, Channel-Based

The entire app is one view: **channel list + channel detail**. No tabs. No separate screens for chat, files, or walkie-talkie. Everything lives inside a channel.

### 1.2 Navigation by Platform

| Platform | Layout | Channel List | Channel Detail |
|----------|--------|-------------|----------------|
| **iPhone** | NavigationStack | Sheet/drawer, swipe-right from left edge to reveal | Full screen, always visible |
| **iPad** | NavigationSplitView | Persistent sidebar (320pt) | Detail pane fills remaining width |
| **Android Phone** | Scaffold + DrawerLayout | Navigation drawer, swipe from left edge | Full screen |
| **Android Tablet** | Scaffold + permanent drawer | Persistent sidebar (320dp) | Detail pane fills remaining width |

**iPhone flow:** App launches → Townsquare detail fills screen → swipe right or tap hamburger to reveal channel list as a sliding sheet → tap channel → sheet dismisses, detail updates.

**iPad flow:** App launches → sidebar visible with channel list → Townsquare selected → detail pane shows Townsquare content.

### 1.3 View Hierarchy (iOS)

```
ChannelRootView
├── ChannelSidebar                          // NavigationSplitView sidebar / sheet on iPhone
│   ├── BridgeStatusBanner                  // Only visible when bridge active
│   ├── TownsquareRow (pinned)             // Always first, not sortable
│   ├── ChannelRow[] (sorted by name)      // User-created channels
│   └── CreateChannelButton                 // "+" at bottom of list
├── ChannelDetailView                       // Main content area
│   ├── ChannelHeader                       // Channel name, member count, PTT state
│   ├── MessageList                         // ScrollView, bottom-anchored
│   │   ├── TextBubble                      // Text messages
│   │   ├── PhotoBubble                     // Inline image thumbnail
│   │   ├── FileBubble                      // File attachment card
│   │   └── AudioIndicator                  // "🎙 Alice is speaking"
│   └── ComposeBar                          // Input area
│       ├── AttachButton                    // Photo/file picker
│       ├── TextField                       // Message input
│       ├── SendButton                      // Arrow-up circle
│       └── PTTButton                       // Full-width push-to-talk
└── StatusBar                               // Bottom bar
    ├── PeerCount                           // "3 peers connected"
    └── BridgeToggle                        // Enable/disable bridge
```

### 1.4 View Hierarchy (Android)

```
ChannelActivity (single-activity)
├── Scaffold
│   ├── TopAppBar                           // Channel name, hamburger, member count
│   ├── DrawerContent (ModalNavigationDrawer)
│   │   ├── BridgeStatusBanner
│   │   ├── TownsquareRow (pinned)
│   │   ├── ChannelRow[] (sorted by name)
│   │   └── CreateChannelFAB
│   ├── ChannelDetailContent                // Main content
│   │   ├── MessageList (LazyColumn)
│   │   │   ├── TextBubble
│   │   │   ├── PhotoBubble
│   │   │   ├── FileBubble
│   │   │   └── AudioIndicator
│   │   └── ComposeBar
│   │       ├── AttachButton
│   │       ├── TextField
│   │       ├── SendButton
│   │       └── PTTButton
│   └── BottomBar
│       ├── PeerCount
│       └── BridgeToggle
```

---

## 2. Channel List

### 2.1 Layout

The channel list is a vertical scrollable list with these sections:

1. **Bridge status banner** (conditional — only when bridge is active)
2. **Townsquare** (pinned at top, never moves)
3. **User-created channels** (alphabetically sorted by name)
4. **Create channel button** (fixed at bottom of list)

### 2.2 Channel Row Anatomy

```
┌─────────────────────────────────────────┐
│ #  Channel Name                    (3)  │
│    Last message preview...        ● 2   │
└─────────────────────────────────────────┘
  ↑  ↑                              ↑  ↑
  │  │                              │  └─ Unread count badge (blue circle)
  │  │                              └──── Member count (gray, parenthesized)
  │  └────────────────────────────────── Channel name (bold, primary)
  └───────────────────────────────────── Hash icon (SF Symbol: number.circle.fill)
```

**Row states:**
- **Default:** Hash icon in `secondaryLabel` color
- **Selected/Active:** Background highlight (`systemFill`), hash icon in accent color
- **Unread:** Blue dot badge with unread count on the right
- **Townsquare:** Uses `star.circle.fill` instead of hash icon. Row is non-reorderable, non-deletable

### 2.3 Channel Row — Detailed Fields

| Element | Font | Color | Max Lines |
|---------|------|-------|-----------|
| Channel name | `.body.bold()` | `.primary` | 1, truncate tail |
| Last message preview | `.subheadline` | `.secondary` | 1, truncate tail |
| Member count | `.caption` | `.tertiary` | 1 |
| Unread badge | `.caption2.bold()` | `.white` on blue circle | 1 |

### 2.4 Create Channel Button

- **iOS:** Row at bottom of list with `plus.circle` SF Symbol + "New Channel" text. Tapping triggers an `.alert` with a text field (channel name, 1-32 chars).
- **Android:** FAB at bottom-right of drawer with Material `Add` icon. Tapping triggers an `AlertDialog` with `OutlinedTextField`.

### 2.5 Empty State (no user-created channels)

Only Townsquare visible. Below Townsquare, a soft prompt:

```
┌─────────────────────────────────┐
│  ⭐  Townsquare            (2)  │
│      Hey everyone!              │
├─────────────────────────────────┤
│                                 │
│   📢  Create a channel          │
│   Organize your conversations   │
│   by topic.                     │
│                                 │
│   [ + New Channel ]             │
│                                 │
└─────────────────────────────────┘
```

---

## 3. Channel Detail View

This is where users spend 95% of their time. It must feel fast, responsive, and uncluttered.

### 3.1 Channel Header

Fixed at the top of the detail view.

```
┌─────────────────────────────────────────────────┐
│ ☰  # Townsquare                    👥 3  ···   │
└─────────────────────────────────────────────────┘
  ↑  ↑                                ↑     ↑
  │  │                                │     └── Overflow menu (member list)
  │  │                                └──────── Member count, tappable → member sheet
  │  └───────────────────────────────────────── Channel name
  └──────────────────────────────────────────── Hamburger (iPhone only, reveals sidebar)
```

**iOS iPhone:** `☰` hamburger in leading toolbar position. Tapping it presents the channel list sheet.
**iOS iPad:** No hamburger — sidebar is always visible.
**Android:** Standard hamburger for drawer toggle.

**When someone is speaking (PTT active):**
```
┌─────────────────────────────────────────────────┐
│ ☰  # Townsquare                    👥 3  ···   │
│ 🎙 Alice is speaking...                        │
└─────────────────────────────────────────────────┘
```

The speaking banner is a secondary row below the header, colored with `accent/orange` background at 15% opacity, with the mic icon pulsing.

### 3.2 Message List

Scrollable, bottom-anchored (newest messages at bottom, auto-scrolls on new message unless user has scrolled up).

**Message grouping rules:**
1. Consecutive messages from the same sender within 2 minutes → grouped (no repeated sender name/avatar)
2. Timestamp separator shown every 5 minutes or on sender change
3. Date separator for messages on different days

### 3.3 Text Bubble

**My messages (right-aligned):**
```
                              ┌──────────────────┐
                              │ Hey everyone!     │
                              │ What's the plan?  │
                              └──────────────────┘
                                          12:34 PM
```

**Other's messages (left-aligned):**
```
  Alice
  ┌──────────────────┐
  │ Let's meet at the │
  │ trailhead at 9am  │
  └──────────────────┘
  12:35 PM
```

**Bubble spec:**

| Property | My Messages | Others' Messages |
|----------|-------------|-----------------|
| Alignment | Trailing | Leading |
| Background | `accentColor` (blue) | `systemGray5` (iOS) / `surfaceVariant` (Android) |
| Text color | `.white` | `.primary` |
| Corner radius | 16pt, bottom-trailing corner 4pt | 16pt, bottom-leading corner 4pt |
| Max width | 75% of available width | 75% of available width |
| Sender name | Hidden | Shown above bubble, `.caption2`, `.secondary` |
| Timestamp | Below bubble, trailing, `.caption2`, `.tertiary` | Below bubble, leading, `.caption2`, `.tertiary` |
| Horizontal padding | 12pt | 12pt |
| Vertical padding | 8pt | 8pt |

### 3.4 Photo Bubble (Inline Image)

Images display inline as thumbnails within message bubbles.

```
  Alice
  ┌──────────────────────┐
  │ ┌──────────────────┐ │
  │ │                  │ │
  │ │  [photo thumb]   │ │
  │ │   240 x 180pt    │ │
  │ │                  │ │
  │ └──────────────────┘ │
  │ Check out this view! │
  └──────────────────────┘
  12:36 PM
```

**Photo thumbnail spec:**
- Max size: 240 x 180 pt (aspect-fill, clipped to rounded rect)
- Corner radius: 12pt
- Tap action: Full-screen image viewer (`.fullScreenCover` on iOS, new Activity on Android)
- Loading state: Gray placeholder with `photo` SF Symbol centered
- Transfer progress: Circular progress indicator overlaid on placeholder

**Image-only message** (no text): Bubble has minimal padding (4pt), image fills bubble.

### 3.5 File Bubble (Attachment Card)

Non-image files display as cards:

```
  Bob
  ┌─────────────────────────────┐
  │  📄  trip-itinerary.pdf     │
  │      245 KB                 │
  │      ██████████░░░ 78%      │
  └─────────────────────────────┘
  12:37 PM
```

**File card spec:**

| Element | Description |
|---------|-------------|
| Icon | SF Symbol based on MIME type (see §5.5) |
| Filename | `.subheadline.bold()`, 1 line, truncate middle |
| File size | `.caption`, `.secondary`, formatted (KB/MB) |
| Progress bar | Linear, shown only during transfer. `accentColor` |
| Tap action (complete) | iOS: share sheet. Android: open with system intent |
| Tap action (in-progress) | No action |
| Background | Same as text bubble for sender alignment |
| Width | Min 200pt, max 280pt |

### 3.6 Audio Indicator (In-Message)

When someone is speaking via PTT, an inline indicator appears at the bottom of the message list:

```
  ┌─────────────────────────────────────┐
  │  🎙  ≋≋≋≋≋≋≋  Alice is speaking... │
  └─────────────────────────────────────┘
```

- Full-width, centered
- Background: `orange.opacity(0.1)`
- Text: `.subheadline`, `orange`
- Animated waveform icon (3 bars, pulsing)
- Appears/disappears with animation (`.transition(.opacity)`)

### 3.7 Timestamp Separator

```
            ─── 12:30 PM ───
```

- Centered, `.caption`, `.tertiary`
- Horizontal rules on each side, `Divider` or `.separator` color
- Appears every 5 minutes or on sender change

### 3.8 Date Separator

```
        ─── Today, March 23 ───
```

- Same style as timestamp separator but uses relative date formatting
- Appears when messages cross day boundaries

### 3.9 Member List

Accessible via tapping the member count in the header, or the `···` overflow menu.

**Presentation:** `.sheet` (iOS) / `BottomSheetDialog` (Android)

```
┌─────────────────────────────────┐
│  Members (3)              Done  │
├─────────────────────────────────┤
│  🟢  Alice's iPhone      (you) │
│  🟢  Bob's Pixel                │
│  🟢  Charlie's iPad             │
└─────────────────────────────────┘
```

- Green dot = connected
- "(you)" label for local device
- No actions on members (no kick, no DM — broadcast only)

---

## 4. Compose Bar

The compose bar is fixed at the bottom of the channel detail view, above the safe area.

### 4.1 Layout

```
┌─────────────────────────────────────────────────┐
│  [📎]  [  Type a message...          ]  [➤]    │
│  [ 🎙 Push to Talk                          ]   │
└─────────────────────────────────────────────────┘
```

### 4.2 Component Spec

| Component | iOS | Android | Behavior |
|-----------|-----|---------|----------|
| Attach button | `paperclip` SF Symbol, 24pt | Material `AttachFile` icon | Tap → action sheet: "Photo Library" / "Choose File" |
| Text field | `.roundedBorder` style, 1-5 lines auto-expand | `OutlinedTextField`, same expansion | Placeholder: "Type a message..." |
| Send button | `arrow.up.circle.fill`, 28pt | Material `Send` icon, filled | Disabled (gray) when text is empty. Blue when active. Tap → send + clear field |
| PTT button | Full-width rounded rect below text row | Same | See §4.3 |

### 4.3 Push-to-Talk Button

The PTT button is a full-width bar below the text input row, always visible.

**States:**

| State | Appearance | Label | Action |
|-------|-----------|-------|--------|
| **Idle** | Blue background, mic icon | "Push to Talk" | Tap → request floor |
| **Requesting** | Blue background, spinner | "Requesting..." | Tap → cancel request |
| **Broadcasting** | Red background, pulsing | "Tap to Stop • Recording" | Tap → release floor |
| **Listening** | Gray background, disabled | "🎙 {name} speaking" | No action (disabled) |

**PTT button spec:**
- Height: 44pt
- Corner radius: 10pt
- Font: `.subheadline.bold()`
- Text color: `.white`
- Icon: `mic.fill` (broadcasting), `mic` (idle), `speaker.wave.3.fill` (listening)
- Animation: Scale 1.0 → 1.02 on press (broadcasting), pulse on red background

**Toggle behavior:** Tap to start, tap to stop. NOT press-and-hold. This matches the existing WalkieTalkieView behavior and is easier on mobile.

### 4.4 Attach Flow

**Tap attach button → Action sheet:**

```
┌─────────────────────────────┐
│  Photo Library              │
│  Choose File                │
│  ─────────────────────────  │
│  Cancel                     │
└─────────────────────────────┘
```

- **Photo Library:** `PhotosPicker` (iOS 17+) / `ActivityResultContracts.PickVisualMedia` (Android)
- **Choose File:** `.fileImporter` (iOS) / `ActivityResultContracts.OpenDocument` (Android)
- Selected item → immediately starts file transfer (fileHeader + fileChunk broadcast)
- Message appears in channel with progress indicator

---

## 5. Visual Design

### 5.1 Color Palette

| Token | Light Mode | Dark Mode | Usage |
|-------|-----------|-----------|-------|
| `accent` | `#007AFF` (systemBlue) | `#0A84FF` | Send button, my bubbles, unread badge, links |
| `channelIcon` | `#8E8E93` (systemGray) | `#8E8E93` | Default channel hash icon |
| `channelActive` | `#007AFF` | `#0A84FF` | Selected channel hash icon |
| `pttIdle` | `#007AFF` | `#0A84FF` | PTT button idle state |
| `pttBroadcasting` | `#FF3B30` (systemRed) | `#FF453A` | PTT button recording |
| `pttListening` | `#FF9500` (systemOrange) | `#FF9F0A` | Speaking indicator, audio banner |
| `bridgeActive` | `#34C759` (systemGreen) | `#30D158` | Bridge status indicator |
| `bridgeOff` | `#8E8E93` | `#8E8E93` | Bridge toggle off state |
| `otherBubble` | `systemGray5` | `systemGray4` | Other people's message bubbles |
| `myBubble` | `accent` | `accent` | My message bubbles |
| `error` | `#FF3B30` | `#FF453A` | Transfer failures, errors |
| `surface` | `systemBackground` | `systemBackground` | Main background |
| `surfaceSecondary` | `secondarySystemBackground` | `secondarySystemBackground` | Sidebar/list background |

**Android mapping:** Use Material 3 dynamic color where possible. Map `accent` → `primary`, `otherBubble` → `surfaceVariant`, `myBubble` → `primary`.

### 5.2 Bubble Styles

**My messages:**
```swift
RoundedRectangle(cornerRadius: 16)
    // Bottom-trailing corner tighter for "tail" effect
    .background(Color.accentColor)
    .foregroundStyle(.white)
```

Corner radii: `UnevenRoundedRectangle(topLeading: 16, bottomLeading: 16, bottomTrailing: 4, topTrailing: 16)`

**Others' messages:**
```swift
UnevenRoundedRectangle(topLeading: 16, bottomLeading: 4, bottomTrailing: 16, topTrailing: 16)
    .background(Color(.systemGray5))
    .foregroundStyle(.primary)
```

### 5.3 Typography Scale

| Element | iOS | Android |
|---------|-----|---------|
| Channel name (header) | `.headline` | `titleMedium` |
| Channel name (sidebar row) | `.body.bold()` | `bodyLarge` (bold) |
| Message text | `.body` | `bodyLarge` |
| Sender name | `.caption2` | `labelSmall` |
| Timestamp | `.caption2` | `labelSmall` |
| File name | `.subheadline.bold()` | `bodyMedium` (bold) |
| File size | `.caption` | `labelMedium` |
| PTT button label | `.subheadline.bold()` | `labelLarge` |
| Status bar text | `.caption` | `labelMedium` |
| Unread badge | `.caption2.bold()` | `labelSmall` (bold) |
| Empty state title | `.headline` | `titleMedium` |
| Empty state body | `.subheadline` | `bodyMedium` |

### 5.4 SF Symbols (iOS) / Material Icons (Android)

| Usage | iOS SF Symbol | Android Material Icon |
|-------|---------------|----------------------|
| Channel (default) | `number.circle.fill` | `Tag` |
| Townsquare | `star.circle.fill` | `Stars` |
| Send message | `arrow.up.circle.fill` | `Send` (filled) |
| Attach file | `paperclip` | `AttachFile` |
| Photo library | `photo.on.rectangle` | `Photo` |
| File browser | `doc` | `InsertDriveFile` |
| Microphone (idle) | `mic` | `Mic` |
| Microphone (active) | `mic.fill` | `Mic` (filled) |
| Speaker | `speaker.wave.3.fill` | `VolumeUp` |
| Member list | `person.2.fill` | `Group` |
| Connected peer | `person.crop.circle.badge.checkmark` | `CheckCircle` |
| Bridge active | `antenna.radiowaves.left.and.right.circle.fill` | `SettingsInputAntenna` |
| Bridge off | `antenna.radiowaves.left.and.right.circle` | `SettingsInputAntenna` (outlined) |
| Create channel | `plus.circle` | `AddCircle` |
| Unread dot | Circle shape (8pt) | Circle shape (8dp) |
| Menu/hamburger | `line.3.horizontal` | `Menu` |
| Overflow | `ellipsis.circle` | `MoreVert` |
| Error | `exclamationmark.triangle.fill` | `Warning` |
| Image file | `photo` | `Image` |
| PDF file | `doc.richtext` | `PictureAsPdf` |
| Audio file | `waveform` | `AudioFile` |
| Generic file | `doc.fill` | `InsertDriveFile` |
| Close/dismiss | `xmark` | `Close` |

### 5.5 File Type Icon Mapping

| MIME Type Pattern | iOS SF Symbol | Color |
|-------------------|---------------|-------|
| `image/*` | `photo` | `.blue` |
| `application/pdf` | `doc.richtext` | `.red` |
| `audio/*` | `waveform` | `.orange` |
| `video/*` | `film` | `.purple` |
| `text/*` | `doc.text` | `.gray` |
| `application/zip`, `application/x-tar` | `doc.zipper` | `.yellow` |
| Everything else | `doc.fill` | `.secondary` |

### 5.6 Empty States

**No peers connected (channel detail):**
```
┌─────────────────────────────────┐
│                                 │
│        📡                       │
│                                 │
│    Waiting for peers            │
│                                 │
│    Other devices running        │
│    GetOverHere nearby will      │
│    appear automatically.        │
│                                 │
└─────────────────────────────────┘
```
- Icon: `antenna.radiowaves.left.and.right` SF Symbol, 48pt, `.secondary`
- Title: `.headline`, `.primary`
- Body: `.subheadline`, `.secondary`, multiline centered

**Empty channel (has peers, no messages yet):**
```
┌─────────────────────────────────┐
│                                 │
│        💬                       │
│                                 │
│    No messages yet              │
│                                 │
│    Be the first to say          │
│    something in #Townsquare     │
│                                 │
└─────────────────────────────────┘
```
- Icon: `bubble.left.and.bubble.right` SF Symbol, 48pt, `.secondary`
- Uses `ContentUnavailableView` on iOS 17+

**No channels besides Townsquare (sidebar):**
See §2.5 above.

---

## 6. Bridge Mode UX

### 6.1 Toggle Location

The bridge toggle lives in the **bottom status bar**, always visible regardless of which channel is active.

### 6.2 Status Bar Layout

```
┌─────────────────────────────────────────────────┐
│  🟢 3 peers connected        [🔘 Bridge: OFF]  │
└─────────────────────────────────────────────────┘
```

When bridge is enabled:
```
┌─────────────────────────────────────────────────┐
│  🟢 5 peers connected    [📡 Bridge: ON ✓]     │
└─────────────────────────────────────────────────┘
```

### 6.3 Bridge Toggle Spec

| State | Icon | Label | Tint | Background |
|-------|------|-------|------|------------|
| OFF | `antenna.radiowaves.left.and.right.circle` | "Bridge" | `.secondary` | None |
| ON | `antenna.radiowaves.left.and.right.circle.fill` | "Bridge" | `.green` | `.green.opacity(0.15)` |

- Toggle is a `Button` styled as a capsule/chip
- Tap toggles `CompositeTransport.isBridgeEnabled`
- Haptic feedback on toggle (`.impact(.medium)`)

### 6.4 Bridge Active Banner (Sidebar)

When bridge is active, a banner appears at the top of the channel sidebar:

```
┌─────────────────────────────────┐
│  📡 Bridging                    │
│  2 Android devices connected    │
└─────────────────────────────────┘
```

- Background: `green.opacity(0.1)`
- Border: `green.opacity(0.3)`, 1pt
- Corner radius: 8pt
- "N Android devices" comes from peers discovered via BLE transport
- If no BLE peers: "Listening for Android devices..."

### 6.5 Bridge State Transitions

| From | To | Visual Change |
|------|-----|---------------|
| OFF | ON (no BLE peers) | Toggle turns green, sidebar banner says "Listening for Android devices..." |
| ON (no BLE peers) | ON (BLE peers found) | Banner updates to "N Android devices connected" |
| ON | OFF | Toggle goes gray, sidebar banner disappears, BLE peers removed from member lists |

---

## 7. ASCII Wireframes

### 7.1 Channel List — With Channels (iPhone)

```
┌─────────────────────────────────────┐
│ Channels                       [+]  │
├─────────────────────────────────────┤
│ 📡 Bridging: 1 Android device      │
├─────────────────────────────────────┤
│ ⭐ Townsquare               (4)    │
│    Alice: Hey everyone!       ● 3   │
├─────────────────────────────────────┤
│ #  Photos                    (3)    │
│    Bob: Check this out              │
├─────────────────────────────────────┤
│ #  Road Trip                 (2)    │
│    Charlie: ETA 2 hours             │
├─────────────────────────────────────┤
│                                     │
│  [ + New Channel ]                  │
│                                     │
└─────────────────────────────────────┘
```

### 7.2 Channel List — Empty (First Launch)

```
┌─────────────────────────────────────┐
│ Channels                       [+]  │
├─────────────────────────────────────┤
│ ⭐ Townsquare               (1)    │
│    No messages yet                  │
├─────────────────────────────────────┤
│                                     │
│        📢                           │
│   Create a channel                  │
│   Organize your conversations       │
│   by topic.                         │
│                                     │
│  [ + New Channel ]                  │
│                                     │
└─────────────────────────────────────┘
```

### 7.3 Channel Detail — Messages + Photos + Files (iPhone)

```
┌─────────────────────────────────────────┐
│ ☰  # Townsquare              👥 4  ··· │
├─────────────────────────────────────────┤
│                                         │
│           ─── 12:30 PM ───              │
│                                         │
│  Alice                                  │
│  ┌───────────────────┐                  │
│  │ Hey everyone!     │                  │
│  │ Ready for the     │                  │
│  │ trip?             │                  │
│  └───────────────────┘                  │
│  12:30 PM                               │
│                                         │
│             ┌───────────────────┐       │
│             │ Yeah! Let's go!   │       │
│             └───────────────────┘       │
│                         12:31 PM        │
│                                         │
│  Bob                                    │
│  ┌──────────────────────┐               │
│  │ ┌──────────────────┐ │               │
│  │ │                  │ │               │
│  │ │  [sunset.jpg]    │ │               │
│  │ │   thumbnail      │ │               │
│  │ │                  │ │               │
│  │ └──────────────────┘ │               │
│  │ Check out this view! │               │
│  └──────────────────────┘               │
│  12:33 PM                               │
│                                         │
│  Charlie                                │
│  ┌─────────────────────────┐            │
│  │  📄 trip-itinerary.pdf  │            │
│  │     245 KB              │            │
│  └─────────────────────────┘            │
│  12:35 PM                               │
│                                         │
├─────────────────────────────────────────┤
│  [📎] [ Type a message...     ]  [➤]   │
│  [ 🎙 Push to Talk                  ]   │
├─────────────────────────────────────────┤
│  🟢 4 peers              [📡 Bridge]   │
└─────────────────────────────────────────┘
```

### 7.4 Channel Detail — Walkie-Talkie Active (iPhone)

```
┌─────────────────────────────────────────┐
│ ☰  # Townsquare              👥 4  ··· │
│ 🎙 Alice is speaking...                │
├─────────────────────────────────────────┤
│                                         │
│  Alice                                  │
│  ┌───────────────────┐                  │
│  │ Let me explain     │                  │
│  │ the route          │                  │
│  └───────────────────┘                  │
│  12:40 PM                               │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  🎙 ≋≋≋  Alice is speaking...  │    │
│  └─────────────────────────────────┘    │
│                                         │
├─────────────────────────────────────────┤
│  [📎] [ Type a message...     ]  [➤]   │
│  [ 🎙 Alice speaking — listen  ]       │
├─────────────────────────────────────────┤
│  🟢 4 peers              [📡 Bridge]   │
└─────────────────────────────────────────┘
```

PTT button is gray/disabled with the speaker's name.

### 7.5 Channel Detail — I Am Broadcasting (iPhone)

```
┌─────────────────────────────────────────┐
│ ☰  # Townsquare              👥 4  ··· │
│ 🔴 You are speaking                    │
├─────────────────────────────────────────┤
│                                         │
│  (messages...)                          │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │  🔴 ≋≋≋  You are speaking...   │    │
│  └─────────────────────────────────┘    │
│                                         │
├─────────────────────────────────────────┤
│  [📎] [ Type a message...     ]  [➤]   │
│  [ 🔴 Tap to Stop • Recording     ]    │
├─────────────────────────────────────────┤
│  🟢 4 peers              [📡 Bridge]   │
└─────────────────────────────────────────┘
```

PTT button is red with pulsing animation.

### 7.6 Create Channel Dialog

**iOS (Alert with TextField):**

```
┌─────────────────────────────────┐
│        New Channel              │
│                                 │
│  ┌───────────────────────────┐  │
│  │ Channel name              │  │
│  └───────────────────────────┘  │
│                                 │
│      [ Cancel ]  [ Create ]     │
└─────────────────────────────────┘
```

- TextField: 1-32 characters, auto-focused
- Create button: disabled if empty
- On create: broadcast `channelAnnounce` + auto-switch to new channel

**Android (AlertDialog):**

```
┌─────────────────────────────────┐
│  New Channel                    │
│                                 │
│  ┌───────────────────────────┐  │
│  │ Channel name              │  │
│  │ ─────────────────────────  │  │
│  └───────────────────────────┘  │
│  Max 32 characters              │
│                                 │
│         CANCEL     CREATE       │
└─────────────────────────────────┘
```

### 7.7 iPad Split View

```
┌────────────────┬────────────────────────────────────────────┐
│ Channels  [+]  │  # Townsquare                  👥 4  ···  │
├────────────────┤  🎙 Alice is speaking...                   │
│ 📡 Bridge: 1  ├────────────────────────────────────────────┤
├────────────────┤                                            │
│ ⭐ Townsquare  │  Alice                                     │
│    Hey every.. │  ┌───────────────────┐                     │
├────────────────┤  │ Hey everyone!     │                     │
│ #  Photos      │  └───────────────────┘                     │
│    Bob: Check  │  12:30 PM                                  │
├────────────────┤                                            │
│ #  Road Trip   │            ┌───────────────────┐           │
│    Charlie:..  │            │ Yeah! Let's go!   │           │
├────────────────┤            └───────────────────┘           │
│                │                        12:31 PM            │
│ [+ New Chan.]  │                                            │
│                ├────────────────────────────────────────────┤
│                │  [📎] [ Type a message...       ]  [➤]    │
│                │  [ 🎙 Alice speaking — listen       ]      │
├────────────────┴────────────────────────────────────────────┤
│  🟢 4 peers connected              [📡 Bridge: ON ✓]       │
└─────────────────────────────────────────────────────────────┘
```

### 7.8 Bridge Mode States

**Bridge OFF:**
```
┌─────────────────────────────────────────────────┐
│  🟢 3 peers connected       [ 📡 Bridge ]      │
└─────────────────────────────────────────────────┘
                                  ↑ gray, subtle
```

**Bridge ON, scanning:**
```
┌─────────────────────────────────────────────────┐
│  🟢 3 peers connected     [ 📡 Bridge: ON ✓ ]  │
└─────────────────────────────────────────────────┘
                                ↑ green capsule

Sidebar banner:
┌─────────────────────────────────┐
│  📡 Bridging                    │
│  Listening for Android devices  │
└─────────────────────────────────┘
```

**Bridge ON, Android peers connected:**
```
┌─────────────────────────────────────────────────┐
│  🟢 5 peers connected     [ 📡 Bridge: ON ✓ ]  │
└─────────────────────────────────────────────────┘
                                ↑ green capsule

Sidebar banner:
┌─────────────────────────────────┐
│  📡 Bridging                    │
│  2 Android devices connected    │
└─────────────────────────────────┘
```

---

## 8. Interaction Details

### 8.1 Channel Switching

1. User taps channel in sidebar
2. Set `activeChannelID` on `ChannelService`
3. Filter `messagesByChannel[newChannelID]`
4. Scroll message list to bottom
5. If PTT was active in previous channel → release floor first (send `releaseFloor`)
6. Update header to show new channel name + member count
7. On iPhone: dismiss sidebar sheet

### 8.2 Receiving a Message in Inactive Channel

1. Message arrives for channel X, but user is viewing channel Y
2. Increment unread count for channel X in sidebar
3. Show blue unread badge on channel X row
4. No toast/banner notification (local mesh app, not push-based)

### 8.3 File Transfer Progress

1. User taps attach → picks file
2. `fileHeader` broadcast immediately
3. Message placeholder appears in channel with filename + "0%" progress
4. `fileChunk` messages sent sequentially
5. Progress bar updates as chunks send: `chunksReceived / totalChunks`
6. On completion: progress bar disappears, file card shows final state
7. For images: thumbnail renders inline after all chunks received

### 8.4 Scroll Behavior

- New message arrives + user is at bottom → auto-scroll to new message
- New message arrives + user has scrolled up → show "↓ New messages" pill at bottom, do NOT auto-scroll
- User taps pill → scroll to bottom, dismiss pill
- Pill shows count: "↓ 3 new messages"

### 8.5 Keyboard Handling

- Text field gets focus → keyboard rises → compose bar moves up with keyboard
- Message list also adjusts (`.keyboardAdaptive` / keyboard avoidance)
- PTT button remains visible above keyboard

---

## 9. Cross-Platform Notes

### 9.1 Identical Between iOS and Android

- Channel model, IDs, Townsquare UUID
- Wire format (all JSON messages and audio frames)
- Channel list layout (sidebar/drawer, same row anatomy)
- Message bubble alignment (mine right, others left)
- Compose bar layout (attach, text, send, PTT)
- Bridge toggle location (bottom status bar)
- File type icon mapping (by MIME type)
- Empty state messaging
- PTT toggle behavior (tap-to-talk, tap-to-stop)
- Timestamp/date separator rules

### 9.2 Platform-Adaptive

| Feature | iOS | Android |
|---------|-----|---------|
| Channel list | Sheet on iPhone, NavigationSplitView sidebar on iPad | ModalNavigationDrawer (phone), permanent drawer (tablet) |
| Icons | SF Symbols | Material Icons |
| Colors | System semantic colors (systemBlue, systemGray5, etc.) | Material 3 dynamic color tokens |
| Typography | iOS Dynamic Type | Material 3 type scale |
| Haptics | UIImpactFeedbackGenerator | HapticFeedbackConstants |
| Photo picker | PhotosPicker (SwiftUI) | PickVisualMedia contract |
| File picker | .fileImporter | OpenDocument contract |
| Image viewer | .fullScreenCover | New composable/activity |
| Persistence | SwiftData for messages | In-memory (Room later) |
| Share action | ShareLink | Intent.ACTION_SEND |
| Alert/dialog | .alert modifier | AlertDialog composable |
| Scrolling | ScrollViewReader | LazyListState |

### 9.3 Design Tokens to Share

Both platforms should define these tokens to keep visual consistency:

```
bubbleRadiusOuter = 16
bubbleRadiusTail = 4
bubbleMaxWidthPercent = 0.75
bubblePaddingH = 12
bubblePaddingV = 8
photoMaxWidth = 240
photoMaxHeight = 180
photoRadius = 12
fileCardMinWidth = 200
fileCardMaxWidth = 280
pttHeight = 44
pttRadius = 10
channelRowIconSize = 24
unreadDotSize = 8
statusBarHeight = 44
sidebarWidth = 320  // iPad/tablet only
timestampIntervalSeconds = 300  // 5 minutes
maxChannelNameLength = 32
```

---

## 10. Accessibility

- All interactive elements have accessibility labels
- Message bubbles: "{sender} says {content}, {timestamp}"
- PTT button: "Push to talk, {current state}" with dynamic trait
- Bridge toggle: "Bridge mode, {on/off}"
- Channel rows: "{channel name}, {member count} members, {unread count} unread messages"
- Support Dynamic Type / font scaling on both platforms
- Minimum tap target: 44x44pt (iOS) / 48x48dp (Android)
- PTT state changes announced via `UIAccessibility.post(notification:)` / `LiveRegion`

---

## 11. Animation & Motion

| Interaction | Animation |
|-------------|-----------|
| Channel switch | Cross-fade message list (0.2s ease) |
| New message appears | Slide up from bottom (0.15s ease-out) |
| PTT state change | Scale bounce (1.0 → 1.02 → 1.0, 0.2s spring) |
| PTT broadcasting | Red background pulse (opacity 0.8 → 1.0, repeat) |
| Audio indicator waveform | 3 bars oscillating height (0.3s, staggered, repeat) |
| Sidebar show/hide (iPhone) | Sheet presentation (system default) |
| Unread badge appear | Scale-in (0 → 1, 0.2s spring) |
| File progress | Linear interpolation of progress bar width |
| "New messages" pill | Fade + slide up (0.2s ease) |
| Speaking banner | Slide down from header (0.15s ease) |

---

*This document is the single source of truth for UI implementation. Devs: if something is ambiguous, ask — don't guess.*
