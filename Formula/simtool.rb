class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/platacard/SimTool"
  url "https://github.com/platacard/SimTool/releases/download/v1.1.1/simtool-v1.1.1-macos-arm64.tar.gz"
  version "1.1.1"
  sha256 "09492f8f7c97294b64e431d179354f5d619e38f2d7071878da9e97ab4b3a3fc0"

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
