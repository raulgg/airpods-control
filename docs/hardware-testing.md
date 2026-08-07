# Hardware testing

Use this guide to verify private-API behavior across an AirPods placement change. Record the macOS version and device in the pull request, and update the [device compatibility matrix](compatibility.md) when a check changes a device or capability status.

## One-earbud AVRouting regression check

The private-audio unit tests can model an AirPods endpoint whose listening-mode capabilities disappear or whose plural routing list omits the current device. Only connected hardware can verify private-API behavior across an earbud placement change. Run this check on the same Mac and AirPods before merging a discovery change.

1. Build once with `make`, wear both earbuds, and confirm the AirPods are the selected macOS input and output devices.
2. Create an owner-only capture directory, then capture a capability baseline. Run all commands in the same shell and replace `My AirPods` if the customized name differs:

   ```sh
   capture_parent="${TMPDIR:-/tmp}"
   capture_previous_umask="$(umask)"
   umask 077
   capture_dir="$(mktemp -d "${capture_parent%/}/airpods-control.XXXXXX")" || exit 1
   chmod 700 "$capture_dir"
   printf 'Private capture directory: %s\n' "$capture_dir"

   build/airpods-control --device "My AirPods" listening-mode get --json --debug \
     >"$capture_dir/both-listening-mode.json" \
     2>"$capture_dir/both.debug.log"
   build/airpods-control --device "My AirPods" listening-mode list --json --debug \
     >"$capture_dir/both-listening-modes.json" \
     2>>"$capture_dir/both.debug.log"
   build/airpods-control --device "My AirPods" conversation-awareness get --json --debug \
     >"$capture_dir/both-conversation-awareness.json" \
     2>>"$capture_dir/both.debug.log"
   ```

3. Remove one earbud without putting it in the case. Verify in System Settings that the AirPods remain both the selected input and selected output, then run:

   ```sh
   build/airpods-control --device "My AirPods" listening-mode get --json --debug \
     >"$capture_dir/one-listening-mode.json" \
     2>"$capture_dir/one.debug.log"
   build/airpods-control --device "My AirPods" listening-mode list --json --debug \
     >"$capture_dir/one-listening-modes.json" \
     2>>"$capture_dir/one.debug.log"
   build/airpods-control --device "My AirPods" conversation-awareness get --json --debug \
     >"$capture_dir/one-conversation-awareness.json" \
     2>>"$capture_dir/one.debug.log"
   umask "$capture_previous_umask"
   ```

   If you stop before completing this block, restore the saved mask with `umask "$capture_previous_umask"`.

4. Compare the matching JSON files and these debug keys in `both.debug.log` and `one.debug.log`:

   - `discovery.context_plural_count`
   - `discovery.context_singular_present`
   - `discovery.candidate_*_sources`
   - `device.*.available_modes`
   - `device.*.transient_empty_modes`

5. If the one-earbud run selects the device, test only settings macOS currently permits. Toggle Conversation Awareness away from its initial value and back. Switch to Transparency and restore the initial listening mode. Test Noise Cancellation last: unless **Noise Cancellation with One AirPod** is enabled in Accessibility settings, a rejected or unverified ANC write is expected.

The regression check passes when the plural or singular system-audio context retains the endpoint and the CLI can apply and read back every setting that System Settings permits in the same state. Do not add another discovery backend or make `--debug` change which devices are discovered.

The debug logs can contain the customized device name and source-build or home paths. Review and redact the capture before sharing it, then delete the private capture directory when the comparison is complete.
