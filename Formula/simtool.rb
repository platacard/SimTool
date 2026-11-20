class Simtool < Formula
  desc "Stream and automate Apple Simulators"
  homepage "https://github.com/platacard/SimTool"
  url "https://github.com/platacard/SimTool/releases/download/v1.2.1/simtool-v1.2.1-macos-arm64.tar.gz"
  version "1.2.1"
  sha256 "951d6124c2967e26c3c6a34c45c3989ee3ade748038c88235509f36e8d91d20c"

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
