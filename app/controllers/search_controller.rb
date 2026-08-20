# Handles searching YouTube Music and search-as-you-type suggestions.
class SearchController < ApplicationController
  # GET /search?q=bohemian+rhapsody&filter=songs
  def index
    query = params[:q].to_s.strip # the text someone typed in, with stray whitespace trimmed off
    if query.blank?
      # Nothing to search for, no point calling YouTube at all.
      render json: { error: "q parameter is required" }, status: :bad_request
      return
    end

    filter = params[:filter].presence # "songs" / "videos" / "albums" / "artists", or nil for everything
    cache_key = "search/#{filter}/#{query.downcase}" # one cache entry per distinct query+filter combo

    # Search results don't change second to second, so we cache each
    # distinct query for a few minutes to avoid hammering YouTube with the
    # exact same search over and over (e.g. someone refreshing the app).
    results = Rails.cache.fetch(cache_key, expires_in: 10.minutes) do
      Innertube::Client.new.search(query: query, filter: filter)
    end

    render json: { results: results }
  end

  # GET /search/suggestions?q=quee
  def suggestions
    query = params[:q].to_s.strip
    if query.blank?
      render json: { suggestions: [] } # empty input just gets an empty list back, not an error
      return
    end

    # Suggestions are cheap and change less often than actual results
    # change, but still worth a short cache since the same partial query
    # gets hit on almost every keystroke while typing.
    suggestions = Rails.cache.fetch("search/suggestions/#{query.downcase}", expires_in: 10.minutes) do
      Innertube::Client.new.search_suggestions(query: query)
    end

    render json: { suggestions: suggestions }
  end
end
