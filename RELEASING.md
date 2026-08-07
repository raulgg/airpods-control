# Releasing

`airpods-control` publishes signed source releases from this repository. Its Homebrew formula lives in [`raulgg/homebrew-tap`](https://github.com/raulgg/homebrew-tap) and builds each release from source. Do not add a second formula to this repository.

## Prepare the release

1. Update the version in the CLI, contract tests, CI install assertion, and documentation examples. Search for the previous version to catch every reference.
2. Run all local checks:

   ```sh
   make clean
   make test
   lipo -archs build/airpods-control
   lipo -archs build/avbypass.dylib
   codesign --verify --verbose=2 build/airpods-control
   codesign --verify --verbose=2 build/avbypass.dylib
   ```

3. Run `make install` and `make uninstall` with `DESTDIR` set to a temporary staging directory. Confirm the executable, interpose dylib, relative bin symlink, and manpage.
4. Merge the version change through a pull request. Confirm `main` is clean, matches `origin/main`, and has a successful CI run.

## Publish the source release

Replace `VERSION` below with the version number without a leading `v`.

```sh
git tag -s "vVERSION" -m "airpods-control VERSION"
git tag -v "vVERSION"
git push origin "vVERSION"
gh release create "vVERSION" \
  --verify-tag \
  --title "airpods-control VERSION" \
  --generate-notes
```

Never move, delete, or recreate a published tag. If a release contains the wrong source, publish the fix in the next patch version.

Download the tag archive twice and compare the files byte for byte before calculating the formula checksum:

```sh
release_archive_dir=$(mktemp -d /tmp/airpods-control-release.XXXXXX)
curl -L --fail --retry 3 \
  -o "$release_archive_dir/first.tar.gz" \
  "https://github.com/raulgg/airpods-control/archive/refs/tags/vVERSION.tar.gz"
curl -L --fail --retry 3 \
  -o "$release_archive_dir/second.tar.gz" \
  "https://github.com/raulgg/airpods-control/archive/refs/tags/vVERSION.tar.gz"
cmp "$release_archive_dir/first.tar.gz" "$release_archive_dir/second.tar.gz"
shasum -a 256 "$release_archive_dir/first.tar.gz"
```

## Update the Homebrew tap

1. Create `feat/airpods-control-VERSION` from the tap's current `main`.
2. Update `Formula/airpods-control.rb` with the tag archive URL and verified SHA-256. Keep the source build, Apple toolchain overrides, exact read-only version test, and absence of a `bottle` block.
3. Run:

   ```sh
   brew style --formula raulgg/tap/airpods-control
   brew audit --strict --online raulgg/tap/airpods-control
   brew install --build-from-source raulgg/tap/airpods-control
   brew test raulgg/tap/airpods-control
   airpods-control --version
   brew uninstall airpods-control
   ```

4. Open a tap pull request and merge it with squash only after every required `brew test-bot` check passes. Do not use `brew pr-pull`; this tap does not publish bottles.
5. Untap the local checkout. From a fresh clone, run the documented public installation:

   ```sh
   brew install raulgg/tap/airpods-control
   airpods-control --version
   brew test raulgg/tap/airpods-control
   brew uninstall airpods-control
   ```

Packaging tests must remain read-only and must never change AirPods settings. If a broken formula reaches `main`, correct or revert it through another pull request after its checks pass. Do not rewrite the tap history.
