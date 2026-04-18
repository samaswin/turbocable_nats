# frozen_string_literal: true

require_relative "lib/turbocable/version"

Gem::Specification.new do |spec|
  spec.name = "turbocable"
  spec.version = Turbocable::VERSION
  spec.authors = ["samaswin"]
  spec.email = ["samaswin@users.noreply.github.com"]

  spec.summary = "Pure-Ruby publisher for the TurboCable fan-out pipeline."
  spec.description = <<~DESC
    Turbocable publishes messages to NATS JetStream on the TURBOCABLE.* subject
    tree, for fan-out by turbocable-server to WebSocket subscribers. It targets
    Rails and any pure-Ruby process that needs to broadcast without owning the
    delivery path.
  DESC
  spec.homepage = "https://github.com/samaswin/turbocable"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/samaswin/turbocable"
  spec.metadata["changelog_uri"] = "https://github.com/samaswin/turbocable/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/samaswin/turbocable/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    Dir[
      "lib/**/*.rb",
      "docs/**/*.md",
      "README.md",
      "CHANGELOG.md",
      "LICENSE",
      "turbocable.gemspec"
    ]
  end
  spec.require_paths = ["lib"]

  # Phase 1: core publish path
  spec.add_dependency "nats-pure", "~> 2.4"

  # Phase 3: JWT minting & public key publishing
  spec.add_dependency "jwt", ">= 2.8", "< 4.0"
end
