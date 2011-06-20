# encoding: utf-8

source :rubygems

# Use local clones if possible.
# If you want to use your local copy, just symlink it to vendor.
def custom_gem(name, options = Hash.new)
  local_path = File.expand_path("../vendor/#{name}", __FILE__)
  if File.exist?(local_path)
    gem name, options.merge(:path => local_path).delete_if { |key, _| [:git, :branch].include?(key) }
  else
    gem name, options
  end
end

custom_gem "eventmachine"
# cool.io uses iobuffer that won't compile on JRuby
# (and, probably, Windows)
gem "cool.io", :platform => :ruby
custom_gem "amq-protocol", :git => "git://github.com/ruby-amqp/amq-protocol.git", :branch => "master"

group :development do
  gem "yard"
  # yard tags this buddy along
  gem "RedCloth", :platform => :mri

  gem "nake",          :platform => :ruby_19
  gem "contributors",  :platform => :ruby_19

  # excludes Windows and JRuby
  gem "perftools.rb",  :platform => :mri
end

group :test do
  gem "cool.io", :platform => :ruby
  gem "rspec", ">=2.0.0"
  gem "autotest"
  custom_gem "evented-spec", :git => "git://github.com/ruby-amqp/evented-spec.git", :branch => "master"
end
