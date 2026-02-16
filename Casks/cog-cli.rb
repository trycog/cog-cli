cask "cog-cli" do
  version "0.1.0"

  on_arm do
    sha256 "REPLACE_WITH_ARM64_SHA256"
    url "https://github.com/bcardarella/cog-cli/releases/download/v#{version}/cog-darwin-arm64.tar.gz"
  end

  on_intel do
    sha256 "REPLACE_WITH_X86_64_SHA256"
    url "https://github.com/bcardarella/cog-cli/releases/download/v#{version}/cog-darwin-x86_64.tar.gz"
  end

  name "Cog CLI"
  desc "Native CLI for Cog associative memory"
  homepage "https://trycog.ai"

  binary "cog"

  postflight do
    system_command "#{staged_path}/cog", args: ["debug/sign"]
  end
end
