---
status: accepted
---

# Cache AV-derived Allow Off availability for HAL commands

The BTAudio HAL `lsms` property describes the supported non-Off listening
modes, but it does not expose the separate user-configured Allow Off setting.
The active AV provider does expose Off in its available-mode inventory when
Allow Off is enabled. A device can later remain connected and controllable
through HAL after it stops being the selected audio output, so the CLI can
reuse a recent AV observation without changing the route or starting audio.

This is deliberately a weak cache. A positive record means only that the exact
output endpoint recently advertised Off through AV. A negative tombstone means
that a newer eligible read did not advertise Off. Neither record is a current
read of the AirPods setting, a device-level capability, a durable device
identity, or a protocol acknowledgement.

## Decision

The route-aware coordinator may cache a positive AV observation of Allow Off
and consume it only for HAL-backed listening-mode commands. The transport
selection and stickiness rules in
[ADR 0001](0001-route-aware-listening-mode-control.md) remain unchanged.

### Evidence and updates

An active AV availability read is cache-eligible only when that read is
already required for:

- `listening-mode list`;
- `listening-mode set off`; or
- an explicit `listening-mode cycle --modes ...` set that contains Off.

A successful eligible availability read that advertises Off writes or
refreshes the positive record. A successful eligible read that omits Off
removes the positive record and writes a negative tombstone. The latest
observation time wins, and a negative observation wins ties so an older
in-flight positive read cannot restore stale evidence. A selector failure, read
failure, or unavailable AV endpoint leaves the record unchanged.

An AV-backed `listening-mode get` may also write or refresh the positive record
when its result is Off. A non-Off current-mode result is not an availability
observation and does not delete the record. Incidental current-mode reads made
by other operations do not warm the cache. The coordinator never performs an
extra AV read solely to warm or refresh it, and a HAL current-mode observation
never updates it. Fresh, successful AV evidence takes precedence over cached
evidence in the same command.

An accepted Off write backed by positive AV-derived evidence can disprove that
positive even when AV still advertises Off. If the full bounded readback ends in
a known non-Off mode, the coordinator removes the exact positive record that
authorized the attempt, whether that record was refreshed by the same AV command
or consumed later by HAL. This invalidation does not create a negative
tombstone: the write mismatch is evidence that the positive is unsafe to reuse,
not a successful availability observation that Off is absent. A rejected setter,
timeout, failed read, or unknown final state leaves the record unchanged.

### Correlation and privacy

The cache key is the full SHA-256 digest of a random per-cache salt followed by
the exact, case-sensitive public Core Audio UID of the joined output endpoint.
The cache persists the salt, digest, and observation time. The raw UID exists in
memory only long enough to correlate the already-selected AV and HAL
representations and derive the digest, and is never persisted. The CLI never
prints or logs the raw UID, digest, or salt.

This correlation is downstream of target selection. It must never select a
device, merge records, disambiguate names, or change AV/HAL routing. If the
selected target cannot be correlated to exactly one output endpoint, the
lookup is a silent cache miss and the command follows its ordinary HAL
behavior.

### Storage and lifetime

Positive records and negative tombstones are stored in:

```text
~/Library/Caches/io.github.raulgg.airpods-control/allow-off-v1.json
```

Each positive record expires seven days after its AV observation. The lifetime
is non-sliding: consuming a record does not refresh it. Negative tombstones are
used only to order observations and never authorize Off. A new eligible
observation replaces the older state for that endpoint; macOS version changes
do not extend or invalidate a positive record. Missing, expired, unreadable, or
malformed cache data is a miss. The file is disposable cache data and should be
excluded from backups; deleting it safely restores the pre-cache behavior. The
cache directory and files are restricted to the current user, and updates use
atomic replacement so an interrupted write becomes a miss rather than partial
trusted evidence. If a negative update cannot obtain the bounded shared mutation
lock, it appends a digest-keyed deny marker beside the cache; lookups honor that
marker before using positive evidence. A failed negative write while holding the
lock removes the disposable cache instead of retaining stale positive evidence.

### HAL behavior

When a valid positive record is consumed for the exact HAL target:

- `listening-mode list` adds Off to the modes derived from `lsms`;
- `listening-mode set off` may attempt the normal HAL write; and
- an explicit cycle set containing Off may include it.

The default cycle continues to exclude Off, even on a cache hit. A miss does
not weaken the existing fail-closed behavior: HAL `list` omits Off, `set off`
is unsupported, and Off is removed from an explicit cycle set before the
minimum-size check.

Provider stickiness, deadlines, readback, and the prohibition on route changes
or raw AACP access are unaffected. An accepted cache-authorized Off write must
still complete the normal bounded HAL readback. If the definitive final state
is a known non-Off mode, the command reports the existing `no-op` result with
that actual state, deletes the positive record, and does not retry through AV,
fall back to an inferred Transparency state, or choose another cycle target.

### Output and diagnostics

Plain output is unchanged. JSON adds cache provenance only when cached evidence
was actually consumed:

```json
{
  "allowOffAvailability": {
    "expiresAt": "2030-01-08T12:00:00.000Z",
    "observedAt": "2030-01-01T12:00:00.000Z",
    "source": "cached-av-observation"
  }
}
```

Live AV evidence and cache misses do not add this object. Debug diagnostics may
report only the bounded cache outcome (`hit` or `miss`) and record age. They do
not expose the UID, digest, salt, cache key, or cache contents. `support-report`
does not access the cache or include its data.

## Consequences

HAL-backed commands can honor a recently observed Allow Off setting while the
AirPods are connected but not selected as the macOS output. The evidence can be
stale during the interval after the setting changes and before another eligible
AV observation or a definitive HAL write mismatch corrects it. Therefore a
cache hit is always described as cached AV-derived availability, never as a
live device query.

This decision supersedes only ADR 0001's interim Off limitation. It does not
change target selection, provider routing, transport stickiness, or the meaning
of a matching macOS readback. The stale gap can end through a newer AV
availability observation or an accepted Off write with definitive non-Off
readback; only the former can create a negative tombstone.
