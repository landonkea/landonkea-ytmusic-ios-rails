# A full artist page: name, photo, top songs, albums, and related artists.
class ArtistsController < ApplicationController
  # GET /artists/:channel_id
  def show
    channel_id = params[:channel_id]
    # Artist pages don't change often, half an hour of caching keeps
    # repeated visits (or several people looking up the same artist) fast.
    info = Rails.cache.fetch("artist/#{channel_id}", expires_in: 30.minutes) do
      Innertube::Client.new.artist(channel_id: channel_id)
    end
    render json: info
  end
end
