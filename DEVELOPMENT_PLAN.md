# PushUp Local App Development Plan

## Goal
Build an iOS SwiftUI app that runs entirely on-device with no server dependency. The bundled `data.json` is the source of truth for the 6-week push-up routine, while user-specific state is persisted locally.

## Data Strategy
- Keep the workout program as a bundled JSON resource.
- Use SwiftData for local persistence because the project targets modern iOS and does not need Core Data's lower-level API surface.
- Store only user state in SwiftData:
  - selected training range
  - current week/day pointer
  - completed workout history
  - completed reps snapshot as a compact string
- Do not sync, upload, or depend on remote APIs.

## App Flow
1. On launch, load `data.json` from the app bundle.
2. Create a singleton local `AppState` row if one does not already exist.
3. Show the current workout session.
4. Let the user choose the available range for that session.
5. Show five set targets and rest time.
6. Persist completion locally and advance to the next available session.
7. Show recent completion history.

## First Implementation Scope
- SwiftData model container setup.
- JSON decoding for mixed integer and `"N+"` set values.
- Main SwiftUI dashboard.
- Range picker per workout day.
- Completion persistence and next-session navigation.
- Bundled copy of the current `data.json`.

## Implemented After First Commit
- Per-set checkoff and actual reps input.
- Rest countdown timer between sets.

## Later Enhancements
- Retest flow between phase changes.
- Calendar/streak view.
- Reset and export local history.
- Better empty-state and error handling.
