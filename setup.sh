#!/bin/bash
set -euo pipefail

RUBY_VERSION=$(cat .ruby-version)

# System dependencies
sudo apt update
sudo apt install -y build-essential git libssl-dev zlib1g-dev libffi-dev libyaml-dev libreadline-dev rbenv nghttp2-client linux-tools-common linux-tools-generic

# ruby-build (apt version is too old for Ruby 4.x)
git clone https://github.com/rbenv/ruby-build.git "$(rbenv root)/plugins/ruby-build"

echo 'eval "$(rbenv init -)"' >> ~/.bashrc
eval "$(rbenv init -)"

# Ruby
rbenv install "$RUBY_VERSION"
rbenv global "$RUBY_VERSION"

# RubyGems + Bundler
gem update --system
gem install bundler

# Project
bundle install
bundle exec rake
