ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# Автономная безопасная загрузка локальных переменных из файла .env
if File.exist?(File.expand_path("../.env", __dir__))
  File.foreach(File.expand_path("../.env", __dir__)) do |line|
    next if line.strip.empty? || line.start_with?("#")
    key, value = line.strip.split("=", 2)
    ENV[key] = value if key && value
  end
end
