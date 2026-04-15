# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.2"
  gem "rspec", "~> 3.13"
  gem "simplecov", "~> 0.22", require: false
  gem "standard", "~> 1.40"
  gem "rubocop-rspec", "~> 3.0"
  # Optional runtime dep for :msgpack codec; included here so specs can exercise it
  gem "msgpack", "~> 1.7"
end
