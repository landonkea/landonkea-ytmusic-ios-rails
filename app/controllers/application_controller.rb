# Every controller in this app inherits from this one, so error handling
# that should apply everywhere (like "InnerTube blew up, don't 500 silently")
# only has to be written once, right here.
class ApplicationController < ActionController::API
  # Catches every InnerTube-related failure our service object can raise
  # and turns it into a proper JSON error response instead of a raw 500
  # crash page (which would be useless to an API client anyway).
  rescue_from Innertube::Client::Error, with: :render_innertube_error

  private

  # Maps each kind of InnerTube failure to a sensible HTTP status code and
  # sends back a small, consistent JSON error body.
  def render_innertube_error(error)
    status =
      case error
      when Innertube::Client::HttpError
        # Pass through YouTube's own status if it's a client error (like a
        # bad video ID), otherwise treat it as an upstream failure (502).
        (400..499).cover?(error.status) ? error.status : :bad_gateway
      when Innertube::Client::VideoUnplayableError
        :unprocessable_content # the request was fine, but that video just can't be played
      else
        :bad_gateway # YouTube's response didn't have the shape we expected
      end

    render json: { error: error.message }, status: status
  end
end
