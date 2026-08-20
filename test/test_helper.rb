ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest" # blocks every real HTTP call made during tests

# Fails loudly (instead of silently trying the real network) if any test
# forgets to stub an HTTP call it makes, that's exactly what we want, this
# whole app's job is calling an external API, so nothing here should ever
# hit the real music.youtube.com during a test run.
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # Reads one of our saved sample InnerTube JSON responses from
    # test/fixtures/files and parses it, so tests can stub WebMock with
    # realistic response bodies instead of hand-typing giant JSON blobs
    # inline in every test.
    def innertube_fixture(name)
      File.read(Rails.root.join("test/fixtures/files/innertube/#{name}.json"))
    end
  end
end
