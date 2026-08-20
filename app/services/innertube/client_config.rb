# This file describes the shape of a "pretend client" our Rails app can
# impersonate when it talks to YouTube's InnerTube API. YouTube doesn't have
# a public API for this stuff, so every request has to look like it's coming
# from one of YouTube's own real apps (the website, the iOS app, a smart TV
# app, etc). The actual named configurations (WEB_REMIX, IOS, TVHTML5) live
# in Client itself (see client.rb), this file just defines the reusable
# struct they're built from.
#
# This mirrors YouTubeClient in the iOS app's InnerTubeClient.swift, so if
# you're comparing the two side by side, they should look almost identical.
module Innertube
  # One frozen little bundle of "who are we pretending to be" values.
  # `Struct.new` with keyword_init: true gives us a simple immutable object
  # with named fields, without having to hand-write a whole class for it.
  ClientConfig = Struct.new(
    :client_name,    # YouTube's internal name for this client, e.g. "WEB_REMIX"
    :client_version,  # version string that client reports itself as
    :client_id,       # numeric ID YouTube uses for this client in headers
    :user_agent,      # the User-Agent header this client sends
    :os_version,      # OS version string this client reports (nil if not needed)
    keyword_init: true
  ) do
    # Turns this client config into the nested "context" hash that InnerTube
    # expects inside every request body. `visitor_data` is an optional token
    # YouTube hands back on earlier responses, we don't track it across
    # requests (this app is stateless request-in request-out), so it's
    # always nil here, but the field stays so the shape matches what
    # YouTube expects.
    def to_context(visitor_data: nil)
      {
        client: {
          clientName: client_name,
          clientVersion: client_version,
          deviceMake: "Apple",
          deviceModel: "iPhone16,2",
          hl: "en",
          gl: "US",
          osName: "iPhone",
          osVersion: os_version || "18.2.0",
          userAgent: user_agent,
          visitorData: visitor_data
        }.compact
      }
    end
  end
end
