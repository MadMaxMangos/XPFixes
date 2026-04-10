# XPFixes

Experimental fixes for the stats and experience reset bug.
The mutator is fully server-side so clients do not have to download it.

```
?mutator=XPFixes.XPFixesMutator
```

Current protections:

- Early stats initialization for likely Epic clients to reduce uninitialized stats reads.
- Forces players who connect after `bMatchIsOver` into spectator so they do not get swept into the map-end After Action Report path with uninitialized honor values.

Optional config in `Mutator_XPFixes.ini`:

```ini
[XPFixes.XPFixesMutator]
bEarlyInitEpicStats=true
bSpectateLateJoinersAfterMatchEnd=true
```
