# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin Ajax requests.

# Read more: https://github.com/cyu/rack-cors

# This API's real client is a native iOS/macOS app, not a web page, so
# browser CORS rules don't actually apply to it. We still turn this on
# (wide open, GET/HEAD only since every endpoint here is read-only) so
# the API is also easy to poke at from a browser or a web-based tool
# during development, without that costing us anything security-wise,
# there's nothing here that requires a login or writes any data.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*" # any site can call this read-only proxy

    resource "*",
      headers: :any,
      methods: [ :get, :head, :options ]
  end
end
