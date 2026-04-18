# frozen_string_literal: true

require "simplecov"
require "tempfile"

SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch
  # Phase 1 real code is in place — enforce 90% floor.
  minimum_coverage 90
end

require "turbocable_nats"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed

  # Reset global Turbocable state between examples that modify it
  config.after do
    Turbocable.reset! if Turbocable.instance_variable_defined?(:@config)
  end
end
