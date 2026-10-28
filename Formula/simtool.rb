class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/platacard/SimTool"
  url "https://github.com/platacard/SimTool/releases/download/v1.0.0/simtool-v1.0.0-macos-arm64.tar.gz"
  version "1.0.0"
  sha256 "3a105efc390a42b31a7114cb19d1707d2c00f61625bf38b8cefb21364573f9f3"

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
