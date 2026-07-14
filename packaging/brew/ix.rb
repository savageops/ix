# P30: Package manager manifest — Homebrew (macOS/Linux)
class Ix < Formula
  desc "A search engine that knows what to ignore"
  homepage "https://github.com/savageops/ix-zig"
  url "https://github.com/savageops/ix-zig/archive/refs/tags/v2.0.0.tar.gz"
  sha256 ""
  license "MIT"
  head "https://github.com/savageops/ix-zig.git", branch: "master"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseFast"
    bin.install "zig-out/bin/ix-zig" => "ix"
  end

  test do
    assert_match "ix 2.0.0", shell_output("#{bin}/ix --version")
  end
end
