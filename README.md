# XPFixes

Experimental fixes for the stats and experience reset bug.
The mutator is fully server-side so clients do not have to download it.

Install notes:

- Put the compiled `.u` package into `ROGame\BrewedPCServer`.
- Put `ROMutator_XPFixes.ini` and `ROMutator_XPFixes_Config.ini` into `ROGame\Config`.
- Enable the mutator with `?mutator=XPFixesMutator.XPFixesMutator`.

```
?mutator=XPFixesMutator.XPFixesMutator
```

Current protections:

- Early stats initialization for likely Epic clients to reduce uninitialized stats reads.
- Forces players who connect after `bMatchIsOver` into spectator so they do not get swept into the map-end After Action Report path with uninitialized honor values.
- Optional Epic stats lifecycle logging so you can see when a likely Epic client is detected, when the stats reader attaches, and when honor/level data finishes loading.

Config:

- `ROMutator_XPFixes.ini` is mutator metadata for WebAdmin/listing.
- `ROMutator_XPFixes_Config.ini` contains the runtime settings under `[XPFixesMutator.XPFixesMutator]`.

Optional config in `ROMutator_XPFixes_Config.ini`:

```ini
[XPFixesMutator.XPFixesMutator]
bEarlyInitEpicStats=true
bSpectateLateJoinersAfterMatchEnd=true
bDebugEpicStatsLifecycle=false
DebugEpicStatsPollInterval=1.0
```
