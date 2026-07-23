# airpods-control builds from source: it needs Swift (Command Line Tools or
# Xcode) to compile. It reaches a PRIVATE, undocumented Apple audio API and, to
# do so, forges exactly one audio entitlement inside its own process via a tiny
# DYLD interpose library (see native/bypass.c). Read that source before tapping.
# No prebuilt binary is shipped — the ad-hoc-signed build cannot be notarized.
class AirpodsControl < Formula
  desc "Control AirPods listening mode and Conversation Awareness from the CLI"
  homepage "https://github.com/raulgg/airpods-control-cli"
  url "https://github.com/raulgg/airpods-control-cli/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER" # fill in on release: shasum -a 256 of the release tarball
  license "MIT"

  depends_on :macos

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    # Read-only smoke test: never sets a mode. Just confirm the binary runs and
    # reports a version.
    assert_match(/\d+\.\d+/, shell_output("#{bin}/airpods-control --version"))
  end
end
