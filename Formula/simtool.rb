class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/platacard/SimTool"
  url "https://github.com/platacard/SimTool/releases/download/v1.1.0/simtool-v1.1.0-macos-arm64.tar.gz"
  version "1.1.0"
  sha256 "ca08484ba12c6c3cfecc0f43660ad6430bb40215a697a0506a567af6b2b0f958"

  def install
    bin.install "bin/simtool"
    prefix.install "README.md" if File.exist?("README.md")
  end

  def caveats
    <<~EOS
      SimTool requires local Apple simulator tooling.
      Install Xcode or Command Line Tools, select it with xcode-select, and install simulator runtimes.
      AXe is optional and required only for accessibility automation commands.
      Run: simtool doctor
    EOS
  end

  test do
    assert_match "Stream and automate Apple Simulators", shell_output("#{bin}/simtool --help")
  end
end
