# Resolves a playable audio stream URL for a single video ID.
class PlayerController < ApplicationController
  # GET /player/:video_id?quality=high
  def show
    quality = params[:quality].presence || "high" # default matches the iOS app's default

    # Deliberately NOT cached: stream URLs YouTube hands back are
    # time-limited and tied to the request that fetched them, caching one
    # would just hand out a URL that stops working, so every call here
    # goes straight to YouTube.
    info = Innertube::Client.new.player(video_id: params[:video_id], quality: quality)
    render json: info
  end
end
