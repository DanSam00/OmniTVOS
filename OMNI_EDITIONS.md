# Omni and Omni X

One codebase, two apps.

| | **Omni** (public, App Store) | **Omni X** (the original app) |
| --- | --- | --- |
| Compilation condition | none | `OMNI_X` |
| macOS scheme / target | `Omni` (`com.saminaden.omnistore.mac`, sandboxed) | `Omni X` (`com.saminaden.omni.mac`) |
| iOS / tvOS | not split yet — those targets still build as Omni X | `Omni iOS`, `NuvioTV` |
| What plays | the viewer's own IPTV (Xtream / M3U), Jellyfin, SMB, local downloads | everything, including stream add-ons and debrid |
| Add-ons | fixed in code (`CuratedLibrary`), metadata/catalogs only, never asked for streams | user-installed, as before |
| Collections | defaults from `CuratedLibrary` installed on a new profile; the viewer can enable/disable, edit, create and add community ones | user-managed, as before |

Code that must not exist in Omni is wrapped in `#if OMNI_X`, so it is absent from the Omni binary rather than hidden.
Where shared code needs a symbol from that code, `Core/Streams/PublicEditionStubs.swift` provides an inert stand-in.

## What Omni does not contain

- `Core/Debrid/*`, `Core/Cloud/{Torbox,Premiumize}CloudLibrary`, `Core/Stremio/StremioAccountService` — compiled out.
- Settings → Integrations: Add-ons, Stremio import and Debrid sections. (Collections and Home-row settings are available in Omni.)
- The community-add-on store, `nuvio://addon` installs, Torrentio / Comet / MediaFusion lists, the sports/stream add-on defaults.
- Add Profile's "use primary add-ons / plugins".
- Torrent / debrid / Stremio strings in the language catalog (removed from the built bundle by the "Strip Public Catalog" phase; the source file is untouched).

## How the fixed add-ons and collections work

`Core/Addons/CuratedLibrary.swift` is the one place to edit.

- `catalogAddonURLs` / `kidsCatalogAddonURLs`: catalog and metadata add-ons. `CinemetaCatalogRepository.configuredStreamAddonPreferences` returns these whatever is stored or synced, and `set…` is a no-op. `StreamsRepository` asks no add-on for streams.
- `regularCollections` / `kidsCollections`: nuvio.tv community-collection ids. On a profile's first use `installCollectionsIfNeeded()` adds the three built-in TMDB rows (Streaming Services, Studios & Franchises, Genres) plus these, through the same kids filter as before. Bump `version` to re-install after changing the lists.
- Collections stay on the device in Omni (not synced to the Nuvio account) and the defaults are installed once per `version`; a removed default comes back only if `version` is bumped.
- Sync: Omni never reads or writes add-ons, collections, Home row order or debrid settings on the Nuvio account, so it cannot disturb an Omni X account that shares the login.

## Omni onboarding order

1. Nuvio sign-in or account creation (the login screen; Skip continues as a guest)
2. IPTV setup (Xtream login or M3U link, checked by loading the channels)
3. Collections (signed-in only; the defaults are already added)
4. Favourite teams (fixtures come from `SportsSchedule`, so a team must be in one of its leagues)
5. Passphrase: create for a new account, link/unlock for an existing one (signed-in only)

Then notifications (optional) and done. Omni X keeps its original order. The Home layout step is not part of Omni's onboarding; it stays in Settings.

## Live and on-demand

- IPTV Xtream / M3U (live, films, shows, guide) is unchanged.
- A film or show page lists the IPTV copies of the title (`IPTVVODLibrary`), as before.
- Sports: `Core/Sports/SportsSchedule.swift` loads fixtures from TheSportsDB for the Calendar's Sports filter. A fixture's page offers the viewer's IPTV channels whose names match its teams or competition (event channels first, then competition channels).

## Building

```sh
# Omni (public) — macOS
xcodebuild -workspace tvosApp/NuvioTV.xcworkspace -scheme Omni -configuration Debug build
# Omni X — macOS
xcodebuild -workspace tvosApp/NuvioTV.xcworkspace -scheme "Omni X" -configuration Debug build
```

The Omni target runs `python3 scripts/strip_public_catalog.py` after copying resources (`ENABLE_USER_SCRIPT_SANDBOXING = NO` on that target).
`scripts/add_omni_store_target.py` and `scripts/add_swift_files.py` are the one-off project edits used to create the Omni target and add new Swift files to every target; run `add_swift_files.py` for any new file.

## Verify before submitting

1. Build both macOS schemes. **This change was made without a Swift compiler available — expect to fix a few compile errors on the first build.**
2. In the Omni build: Settings has no Add-ons, Stremio or Debrid sections but does have Collections, and a new profile already has the default collections; Library has no Cloud tab; a title with no IPTV source says "Nothing to play yet".
3. `strings Omni.app/Contents/MacOS/Omni | grep -iE 'torrent|magnet|debrid|premiumize|torbox|real-?debrid'` — remaining hits are the `SettingsKey` names and a few comments in shared code (`infoHash` on `NuvioStream`, `DebridStreamQuality`); remove if a reviewer scan is a concern.
4. With the same Nuvio login on Omni X and Omni, change nothing in Omni and confirm Omni X's add-ons and collections are unchanged afterwards.

## Open items for you

- **Curated lists**: `CuratedLibrary` currently holds Cinemeta + Rotten Tomatoes as add-ons, `Kaptain's Mega Collection` for regular profiles and the existing kids starter set. Replace with the ones you want.
- **API keys**: TheSportsDB free key "3" is for development (set `TheSportsDBKey` in `Info-Store-macOS.plist`); TMDB currently needs a per-user key (a built-in key would make the TMDB-built rows work out of the box).
- **League ids** in `SportsSchedule.leagues` are TheSportsDB ids from memory — confirm them.
- Widgets, Google Cast and Bonjour are not in the Omni Mac target yet (Cast needs the sandbox `network.server` entitlement).
- iOS / tvOS Omni targets, App Store Connect record, privacy policy, age rating, screenshots, and App Review notes (state that Omni ships no content and no content sources; users supply their own IPTV / Jellyfin / SMB).
- **Account deletion**: Omni offers account creation, so App Store guideline 5.1.1(v) requires an in-app way to delete the account. There is none yet, and it needs a delete endpoint on Nuvio's backend (or remove sign-up from Omni again).
- Nuvio sign-in: optional (Skip works). It is still a third-party service; a bundled offline copy of the curated collections would remove Review's dependence on it.
