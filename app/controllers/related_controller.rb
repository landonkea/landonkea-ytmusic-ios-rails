# Related/recommended songs for whatever's currently playing, backs the
# "Related" list on the now-playing screen in the iOS app.
class RelatedController < ApplicationController
  # GET /related/:video_id
  def show
    video_id = params[:video_id]
    results = Rails.cache.fetch("related/#{video_id}", expires_in: 30.minutes) do
      Innertube::Client.new.related(video_id: video_id)
    end
    render json: { results: results }
  end
end
