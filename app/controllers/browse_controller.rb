# Handles all the "browse a built-in YouTube Music page" endpoints: the
# home feed, charts, explore tab, new releases, and mood/genre categories,
# plus a generic fallback for any other browse ID.
class BrowseController < ApplicationController
  # How long a browsed page stays cached before we ask YouTube again.
  # These pages (home, charts, etc) change throughout the day but not
  # minute to minute, so half an hour is a reasonable balance between
  # freshness and not hammering YouTube's servers.
  CACHE_TTL = 30.minutes

  # GET /home
  def home
    render json: { sections: cached("browse/home") { Innertube::Client.new.home } }
  end

  # GET /charts
  def charts
    render json: { sections: cached("browse/charts") { Innertube::Client.new.charts } }
  end

  # GET /explore
  def explore
    render json: { sections: cached("browse/explore") { Innertube::Client.new.explore } }
  end

  # GET /new_releases
  def new_releases
    render json: { sections: cached("browse/new_releases") { Innertube::Client.new.new_releases } }
  end

  # GET /moods
  def moods
    render json: { sections: cached("browse/moods") { Innertube::Client.new.mood_categories } }
  end

  # GET /moods/playlists?params=<opaque token from a moods item>
  def mood_playlists
    token = params[:params].to_s
    if token.blank?
      render json: { error: "params query parameter is required" }, status: :bad_request
      return
    end

    items = cached("browse/moods/#{token}") { Innertube::Client.new.mood_playlists(params: token) }
    render json: { items: items }
  end

  # GET /browse/:browse_id - a catch-all for any browse ID the client
  # already knows about (e.g. one it got back from another response) that
  # doesn't have its own dedicated endpoint above.
  def show
    browse_id = params[:browse_id]
    sections = cached("browse/#{browse_id}") { Innertube::Client.new.browse_sections(browse_id: browse_id) }
    render json: { sections: sections }
  end

  private

  # Small wrapper around Rails.cache.fetch so every action above shares
  # the same TTL instead of repeating `expires_in: 30.minutes` everywhere.
  def cached(key, &block)
    Rails.cache.fetch(key, expires_in: CACHE_TTL, &block)
  end
end
