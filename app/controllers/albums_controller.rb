# A full album/EP page: title, artist, year, and the complete track list.
class AlbumsController < ApplicationController
  # GET /albums/:browse_id
  def show
    browse_id = params[:browse_id]
    # Once released, an album's track list basically never changes, so a
    # longer cache window is safe here and saves a lot of repeat calls.
    info = Rails.cache.fetch("album/#{browse_id}", expires_in: 1.hour) do
      Innertube::Client.new.album(browse_id: browse_id)
    end
    render json: info
  end
end
