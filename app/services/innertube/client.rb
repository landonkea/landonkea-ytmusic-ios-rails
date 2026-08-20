# frozen_string_literal: true

require "faraday" # the HTTP library this file uses to actually talk to Google's servers

# This is the heart of the whole app. It's the Ruby version of the iOS app's
# InnerTubeClient.swift, everything here exists so our Rails controllers
# never have to know the messy details of how YouTube Music's private API
# works. A controller just calls something like `Innertube::Client.new.search(query: "queen")`
# and gets back a plain, simple Ruby hash/array, all the InnertTube request
# building and response digging happens in here.
module Innertube
  class Client
    # This is YouTube Music's own base address for every InnerTube call.
    # The trailing slash matters: Faraday/URI joins a base URL and a
    # relative path the same way a browser does, so without it, the last
    # path segment ("v1") would get replaced instead of built upon.
    BASE_URL = "https://music.youtube.com/youtubei/v1/"

    # This is the "InnerTube WEB_REMIX client" API key. It's genuinely
    # public, YouTube Music's own website ships this exact same value in
    # its own JavaScript, and every open-source YouTube client (yt-dlp,
    # ytmusicapi, the Metrolist project this iOS app was inspired by, and
    # the iOS app itself) uses it too. It's a client-type identifier, not a
    # billed or account-linked secret. Even so, to match this project's
    # existing policy (see the iOS app's InnerTubeClient.swift) of never
    # hardcoding anything key-shaped, we read it from an environment
    # variable, with the well-known public value as the fallback so the
    # app works out of the box without forcing a beginner to hunt for a key.
    API_KEY = ENV.fetch("INNERTUBE_API_KEY", "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30")

    # All the different ways a call out to InnerTube can go wrong, nested
    # right here inside Client (rather than their own file) so Rails'
    # autoloader, which expects one file to define one matching constant,
    # doesn't get confused by a file defining several error classes at once.

    # Base class every error below inherits from, so a caller that just
    # wants to catch "anything InnerTube-related went wrong" can rescue
    # this one class and cover every case beneath it.
    class Error < StandardError; end

    # Raised when YouTube's server responds with a non-2xx HTTP status
    # (rate limiting, a 500 on their end, and so on).
    class HttpError < Error
      attr_reader :status # the HTTP status code YouTube sent back

      def initialize(status)
        @status = status
        super("InnerTube request failed with HTTP status #{status}")
      end
    end

    # Raised when we asked for a stream and YouTube says the video can't
    # be played (region-locked, removed, private, etc).
    class VideoUnplayableError < Error
      def initialize(reason)
        super("Video is unplayable: #{reason}")
      end
    end

    # Raised when a player response is missing the `videoDetails` block we
    # need, usually meaning YouTube changed its response shape or the
    # video ID was bad.
    class MissingVideoDetailsError < Error
      def initialize
        super("YouTube's response had no video details")
      end
    end

    # Raised when a player response has no `streamingData` at all, so
    # there's nothing to actually play.
    class MissingStreamingDataError < Error
      def initialize
        super("YouTube's response had no streaming data")
      end
    end

    # Raised when streamingData exists but none of its formats are
    # audio-only (which is all this app cares about for a music player).
    class NoAudioStreamError < Error
      def initialize
        super("No audio-only stream was found for this video")
      end
    end

    # The three "pretend clients" this app impersonates, nested here for
    # the same Zeitwerk-autoloading reason the error classes above are:
    # one file can only be relied on to autoload the single constant its
    # path implies (Innertube::ClientConfig, from client_config.rb), so
    # anything else defined alongside it needs to live somewhere Ruby will
    # actually load it before it's referenced. Living inside Client, which
    # gets loaded the moment anyone calls Innertube::Client.new, is the
    # simplest way to guarantee that.

    # WEB_REMIX is the YouTube Music website's own client identity. We use
    # it for everything except getting the actual playable audio URL:
    # search, browsing the home page, artist pages, album pages, related
    # songs, and search-as-you-type suggestions.
    WEB_REMIX = Innertube::ClientConfig.new(
      client_name: "WEB_REMIX",
      client_version: "1.20260114.03.00",
      client_id: "67",
      user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0",
      os_version: nil
    ).freeze

    # IOS pretends to be the real YouTube app for iPhone. Google's servers
    # hand out better (less throttled, less likely to need extra decoding
    # tricks) audio stream URLs to the IOS client than to the web client,
    # so this is what we use first when resolving a playable stream.
    IOS = Innertube::ClientConfig.new(
      client_name: "IOS",
      client_version: "21.03.1",
      client_id: "5",
      user_agent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
      os_version: "18.2.22C152"
    ).freeze

    # TVHTML5 pretends to be a smart TV app. It's our fallback for
    # fetching playable stream URLs, if the IOS client's request fails
    # for some reason (Google changes its rules often), we retry with
    # this one instead.
    TVHTML5 = Innertube::ClientConfig.new(
      client_name: "TVHTML5",
      client_version: "7.20260114.12.00",
      client_id: "7",
      user_agent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
      os_version: nil
    ).freeze

    # Base64-encoded protobuf values YouTube expects in the `params` field
    # to narrow a search down to just one kind of result. These exact
    # strings come straight from the iOS app, they're not something we can
    # derive, they're just what YouTube's own site sends.
    SEARCH_FILTER_PARAMS = {
      "songs" => "EgIQAw==",
      "videos" => "EgIQBA==",
      "albums" => "EgIQAg==",
      "artists" => "EgIIAQ=="
    }.freeze

    # `connection` lets tests (or anything else) inject a fake Faraday
    # connection instead of hitting the network. If nothing is passed in,
    # we build a real one pointed at YouTube Music.
    def initialize(connection: nil)
      @connection = connection || build_connection
    end

    # SEARCH ------------------------------------------------------------

    # Searches YouTube Music for songs/videos/albums/artists.
    # `filter` can be "songs", "videos", "albums", "artists", or nil for
    # everything mixed together, exactly like the iOS app's search method.
    def search(query:, filter: nil)
      body = {
        context: WEB_REMIX.to_context, # who we're pretending to be
        query: query, # what the user typed
        params: SEARCH_FILTER_PARAMS[filter] # the encoded filter, or nil for "all"
      }
      response = post("/search", client: WEB_REMIX, body: body) # actually call YouTube
      parse_search_results(response) # turn the giant nested JSON into a clean array
    end

    # Returns autocomplete suggestions for a partially-typed search, the
    # same dropdown you'd see typing into YouTube Music's search box.
    def search_suggestions(query:)
      body = {
        context: WEB_REMIX.to_context,
        input: query
      }
      response = post("/music/get_search_suggestions", client: WEB_REMIX, body: body)
      # Suggestions live several layers deep, and any layer might be missing
      # if there simply aren't any suggestions yet, so we dig defensively.
      sections = response.dig(:contents) || []
      sections.flat_map do |section|
        items = section.dig(:searchSuggestionsSectionRenderer, :contents) || []
        items.filter_map { |item| text_from(item.dig(:searchSuggestionRenderer, :suggestion)) }
      end
    end

    # PLAYER --------------------------------------------------------------

    # Resolves a playable audio stream URL for a given video ID. Tries the
    # IOS client first (Google tends to hand it better audio streams), and
    # falls back to the TV client if that fails for any reason.
    def player(video_id:, quality: "high")
      player_with_client(video_id: video_id, client: IOS, quality: quality)
    rescue Error
      player_with_client(video_id: video_id, client: TVHTML5, quality: quality)
    end

    # BROWSE ----------------------------------------------------------------

    # Generic "browse a page" call, this is what home, charts, artist
    # pages, album pages, and mood/genre pages all boil down to underneath.
    def browse(browse_id:, params: nil)
      body = {
        context: WEB_REMIX.to_context,
        browseId: browse_id,
        params: params
      }
      post("/browse", client: WEB_REMIX, body: body)
    end

    # Same as `browse`, but already parsed into the simple sections shape.
    # This is what the generic /browse/:browse_id controller route uses
    # for any browse ID that doesn't have its own dedicated method above.
    def browse_sections(browse_id:, params: nil)
      parse_browse_sections(browse(browse_id: browse_id, params: params))
    end

    # The YouTube Music home page: quick picks, recently played, etc.
    def home
      parse_browse_sections(browse(browse_id: "FEmusic_home"))
    end

    # The charts/trending page.
    def charts
      parse_browse_sections(browse(browse_id: "FEmusic_charts"))
    end

    # Songs/videos related to (recommended after) a given video, the same
    # list you'd see under "Related" on the now-playing screen.
    def related(video_id:)
      body = {
        context: WEB_REMIX.to_context,
        videoId: video_id
      }
      response = post("/next", client: WEB_REMIX, body: body)
      # The "up next" queue always starts with the song you just asked
      # about, filter that one back out since a "related songs" list
      # shouldn't include the song itself.
      parse_related_content(response).reject { |item| item[:id] == video_id }
    end

    # Full artist page: name, photo, top songs, albums, related artists.
    def artist(channel_id:)
      response = browse(browse_id: channel_id) # one browse call gives us both the header and the sections
      sections = parse_browse_sections(response)
      header = extract_artist_header(response)

      top_songs = [] # songs collected from whichever section looks like "top songs"
      albums = [] # albums/singles collected from whichever section looks like a release list
      related_artists = [] # artists collected from a "related"/"fans also like" section

      sections.each do |section|
        title = section[:title].to_s.downcase # lowercase so matching below is case-insensitive
        if title.include?("top") || title.include?("popular")
          top_songs.concat(section[:items].map { |item| song_from_browse_item(item) })
        elsif title.include?("album") || title.include?("single") || title.include?("release")
          albums.concat(section[:items].map { |item| album_from_browse_item(item) })
        elsif title.include?("related") || title.include?("similar") || title.include?("fans")
          related_artists.concat(section[:items].map { |item| artist_from_browse_item(item) })
        else
          # Unlabeled/unknown sections: treat songs as top songs and
          # everything else (playlists, albums) as albums, same fallback
          # the iOS app uses.
          section[:items].each do |item|
            if item[:type] == :song
              top_songs << song_from_browse_item(item)
            else
              albums << album_from_browse_item(item)
            end
          end
        end
      end

      {
        id: channel_id,
        name: header[:name],
        thumbnail_url: header[:thumbnail_url],
        subscriber_count: header[:subscriber_count],
        description: header[:description],
        top_songs: top_songs,
        albums: albums,
        related_artists: related_artists
      }
    end

    # Full album/EP page: title, artist, year, and the complete track list.
    def album(browse_id:)
      response = browse(browse_id: browse_id)
      sections = parse_browse_sections(response)
      header = extract_album_header(response)

      # The track list is always the first section on an album page,
      # anything after it (carousels for "more from this artist" and
      # similar albums) isn't part of the album, so we only look at that
      # first section rather than flattening every section together.
      tracks = (sections.first&.dig(:items) || []).map { |item| song_from_browse_item(item) }

      {
        id: browse_id,
        title: header[:title],
        artist: header[:artist],
        year: header[:year],
        thumbnail_url: header[:thumbnail_url],
        track_count: tracks.empty? ? header[:track_count] : tracks.length,
        tracks: tracks
      }
    end

    # The "Explore" tab: new releases, moods & genres, charts, etc, all
    # bundled together as categorized sections.
    def explore
      parse_browse_sections(browse(browse_id: "FEmusic_explore"))
    end

    # Just the new-releases part of Explore.
    def new_releases
      parse_browse_sections(browse(browse_id: "FEmusic_new_releases"))
    end

    # Just the moods & genres category list (not the playlists inside one).
    def mood_categories
      parse_browse_sections(browse(browse_id: "FEmusic_moods_and_genres"))
    end

    # The playlists that belong to one specific mood/genre, `params` is the
    # opaque token that came from one of the items in `mood_categories`.
    def mood_playlists(params:)
      sections = parse_browse_sections(browse(browse_id: "FEmusic_moods_and_genres", params: params))
      sections.flat_map { |section| section[:items] } # flatten every section into one item list
    end

    private

    # Builds the real Faraday connection used for live requests, pointed
    # at YouTube Music with the API key baked into every request's URL.
    def build_connection
      Faraday.new(url: BASE_URL) do |f|
        f.request :json # automatically encode request bodies as JSON
        f.options.timeout = 15 # give up on a single attempt after 15 seconds
        f.options.open_timeout = 10 # give up trying to even connect after 10 seconds
      end
    end

    # Fetches a player response using one specific pretend-client, and
    # turns it into our simple PlayerInfo-shaped hash.
    def player_with_client(video_id:, client:, quality:)
      body = {
        context: client.to_context,
        videoId: video_id
      }
      response = post("/player", client: client, body: body)
      parse_player_info(response, quality: quality)
    end

    # Sends one POST request to an InnerTube endpoint and returns the
    # parsed JSON body (as a Hash you can `dig` into with symbols or
    # strings). Retries a couple of times on server-side/network failures,
    # but gives up immediately on 4xx errors since retrying won't fix a
    # bad request.
    def post(endpoint, client:, body:)
      with_retry do
        # Faraday's base `url:` (which already has "/youtubei/v1" baked in)
        # only gets combined with a RELATIVE path, a leading "/" here would
        # be treated as "start over from the site root" and silently drop
        # that base path, so we strip any leading slash the caller passed.
        response = @connection.post(endpoint.delete_prefix("/")) do |req|
          req.params["key"] = API_KEY # the API key goes in the query string, not the body
          req.params["prettyPrint"] = "false" # ask for compact JSON, smaller and faster to parse
          req.headers["Content-Type"] = "application/json"
          req.headers["User-Agent"] = client.user_agent
          req.headers["X-Goog-Api-Format-Version"] = "1" # required by InnerTube on every request
          req.headers["X-YouTube-Client-Name"] = client.client_id
          req.headers["X-YouTube-Client-Version"] = client.client_version
          req.headers["X-Origin"] = "https://music.youtube.com"
          req.headers["Referer"] = "https://music.youtube.com/"
          req.body = body
        end

        raise HttpError, response.status unless response.success?

        # `response.body` is already a Ruby Hash here because the `:json`
        # Faraday middleware (added below in build_connection) parses it
        # for us, `with_indifferent_access` lets every parser below use
        # either symbol or string keys interchangeably.
        parsed = response.body.is_a?(String) ? JSON.parse(response.body) : response.body
        parsed.with_indifferent_access
      end
    end

    # Retries the given block up to 3 times with exponential backoff
    # (0.5s, then 1s), matching the iOS app's retry behavior. 4xx errors
    # are treated as permanent and re-raised immediately without retrying.
    def with_retry(max_attempts: 3, initial_delay: 0.5)
      delay = initial_delay
      attempts = 0

      begin
        attempts += 1
        yield
      rescue HttpError => e
        raise if (400..499).cover?(e.status) # our fault, not worth retrying
        raise if attempts >= max_attempts
        sleep(delay)
        delay *= 2
        retry
      rescue Faraday::Error
        raise if attempts >= max_attempts
        sleep(delay)
        delay *= 2
        retry
      end
    end

    # RESPONSE PARSING ------------------------------------------------------
    # Everything below digs through YouTube's deeply-nested JSON shape and
    # pulls out just the handful of fields we actually care about. These
    # mirror the private parse* methods in the iOS app's InnerTubeClient.swift.

    # Turns a raw /search response into an array of simple song/video hashes.
    #
    # NOTE ON WHY THIS CHECKS TWO SHAPES: InnerTube is Google's own
    # internal, undocumented API, it isn't a stable public contract, and
    # it has visibly changed shape even since the iOS app (this app's
    # source of truth) was last updated. Older/simpler responses group
    # results under `musicShelfRenderer`; what YouTube Music actually
    # sends back today instead wraps each result in its own
    # `itemSectionRenderer`. We check for both so search keeps working
    # either way, rather than silently returning nothing the day Google
    # tweaks this again.
    def parse_search_results(response)
      tabs = response.dig(:contents, :tabbedSearchResultsRenderer, :tabs) || []
      tab_contents = tabs.dig(0, :tabRenderer, :content, :sectionListRenderer, :contents) || []

      results = []
      tab_contents.each do |section|
        items = section.dig(:musicShelfRenderer, :contents) ||
                section.dig(:itemSectionRenderer, :contents) ||
                []
        items.each do |item|
          renderer = item[:musicResponsiveListItemRenderer]
          next unless renderer
          parsed = parse_search_item(renderer)
          results << parsed if parsed
        end
      end
      results
    end

    # Pulls id/title/artist/thumbnail/duration out of one music list item.
    # Returns nil when there's no playable video ID (e.g. a header row).
    def parse_search_item(renderer)
      # The video ID usually lives on the item's own navigationEndpoint,
      # but newer result cards only put it inside `playlistItemData`
      # instead, so we check there too before giving up on this item.
      video_id = renderer.dig(:navigationEndpoint, :watchEndpoint, :videoId) ||
                 renderer.dig(:playlistItemData, :videoId)
      return nil unless video_id

      flex_columns = renderer[:flexColumns] || []
      title = text_from(flex_columns.dig(0, :musicResponsiveListItemFlexColumnRenderer, :text)) || "Unknown"
      artist = artist_label(flex_columns.dig(1, :musicResponsiveListItemFlexColumnRenderer, :text)) || "Unknown Artist"
      thumbnail_url = last_thumbnail_url(thumbnails_from(renderer[:thumbnail]))
      # Duration mostly shows up as a little badge over the thumbnail, but
      # on album/playlist track rows (which don't have a per-row
      # thumbnail) it's a plain fixed-width column at the end of the row
      # instead, so we check both spots.
      duration = text_from(
        renderer.dig(:overlay, :musicItemThumbnailOverlayRenderer, :content, :musicResponsiveListItemOverlayLayout, :musicDurationText)
      ) || text_from(renderer.dig(:fixedColumns, 0, :musicResponsiveListItemFixedColumnRenderer, :text))

      { id: video_id, title: title, artist: artist, thumbnail_url: thumbnail_url, duration: duration }
    end

    # The "artist" flex column is sometimes plain text ("Queen") and
    # sometimes a whole "Song • Queen • 2.9B plays"-style string built
    # out of several text runs. When it's the latter, only the run(s)
    # that actually link somewhere (an artist/album page) are the real
    # artist name, the rest is just a "Song" label and bullet
    # separators, so we prefer those linked runs when they exist.
    def artist_label(text_run)
      return nil unless text_run
      runs = text_run[:runs]
      if runs
        linked = runs.select { |run| run[:navigationEndpoint] }
        return linked.map { |run| run[:text] }.join(", ") if linked.any?
      end
      text_from(text_run)
    end

    # Turns a raw /player response into our PlayerInfo-shaped hash,
    # choosing which audio format to hand back based on `quality`.
    def parse_player_info(response, quality:)
      status = response.dig(:playabilityStatus, :status)
      if status && status != "OK"
        raise VideoUnplayableError, response.dig(:playabilityStatus, :reason) || "Unknown reason"
      end

      details = response[:videoDetails]
      raise MissingVideoDetailsError unless details

      streaming = response[:streamingData]
      raise MissingStreamingDataError unless streaming

      audio_streams = (streaming[:adaptiveFormats] || []).select { |f| f[:mimeType].to_s.include?("audio") }
      raise NoAudioStreamError if audio_streams.empty?

      selected = select_audio_stream(audio_streams, quality)
      thumbnail_url = last_thumbnail_url(details.dig(:thumbnail, :thumbnails))

      {
        video_id: details[:videoId],
        title: details[:title],
        artist: details[:author],
        thumbnail_url: thumbnail_url,
        duration: details[:lengthSeconds].to_i,
        audio_url: selected[:url],
        audio_quality: audio_quality_label(selected[:bitrate].to_i),
        view_count: details[:viewCount]
      }
    end

    # Picks one audio format out of the available list based on the
    # requested quality tier, same rules as the iOS app.
    def select_audio_stream(audio_streams, quality)
      case quality
      when "low"
        # Prefer something at least 48kbps so it's not painfully lossy,
        # but fall back to the overall lowest if nothing clears that bar.
        audio_streams.select { |f| f[:bitrate].to_i >= 48_000 }.min_by { |f| f[:bitrate].to_i } ||
          audio_streams.min_by { |f| f[:bitrate].to_i }
      when "medium"
        audio_streams.min_by { |f| (f[:bitrate].to_i - 128_000).abs } # whichever is closest to 128kbps
      else # "high", "auto", or anything unrecognized: go for the best available
        audio_streams.max_by { |f| f[:bitrate].to_i }
      end
    end

    # Same High/Medium/Low bucketing the iOS app uses for display purposes.
    def audio_quality_label(bitrate)
      return "High" if bitrate >= 256_000
      return "Medium" if bitrate >= 128_000
      "Low"
    end

    # Turns a raw /next response into a flat array of related song hashes.
    def parse_related_content(response)
      # YouTube has moved the "up next" queue behind an extra layer of
      # tabs since this project's InnerTube models were first written
      # (there's now a "Lyrics"/"Related"/"Comments" tab strip alongside
      # "Up next"), so we check that newer path first...
      queue_items = response.dig(
        :contents, :singleColumnMusicWatchNextResultsRenderer, :tabbedRenderer,
        :watchNextTabbedResultsRenderer, :tabs, 0, :tabRenderer, :content,
        :musicQueueRenderer, :content, :playlistPanelRenderer, :contents
      )
      return parse_queue_items(queue_items) if queue_items

      # ...and fall back to the older, flatter shape if the newer one
      # isn't there, so this keeps working either way.
      legacy_contents = response.dig(
        :contents, :singleColumnMusicWatchNextResultsRenderer, :results, :results, :contents
      ) || []

      results = []
      legacy_contents.each do |content|
        if (renderer = content[:musicResponsiveListItemRenderer])
          parsed = parse_search_item(renderer)
          results << parsed if parsed
        end

        if (renderer = content[:musicTwoRowItemRenderer])
          title = text_from(renderer[:title])
          subtitle = text_from(renderer[:subtitle])
          next if title.blank? # skip anything without even a title, nothing useful to show
          video_id = renderer.dig(:navigationEndpoint, :watchEndpoint, :videoId) || ""
          thumbnail_url = first_thumbnail_url(thumbnails_from(renderer[:thumbnailRenderer]))
          results << { id: video_id, title: title, artist: subtitle, thumbnail_url: thumbnail_url, duration: nil }
        end
      end
      results
    end

    # Parses the "up next" queue shape YouTube currently sends: a list of
    # `playlistPanelVideoRenderer` entries (one per queued song), plus an
    # `automixPreviewVideoRenderer` entry at the end that just marks where
    # autoplay would continue, not a real song, so we skip that one.
    def parse_queue_items(queue_items)
      queue_items.filter_map do |item|
        renderer = item[:playlistPanelVideoRenderer]
        next unless renderer # skips the automixPreviewVideoRenderer entry

        {
          id: renderer[:videoId],
          title: text_from(renderer[:title]) || "Unknown",
          artist: text_from(renderer[:shortBylineText]) || "Unknown Artist",
          thumbnail_url: last_thumbnail_url(renderer.dig(:thumbnail, :thumbnails)),
          duration: text_from(renderer[:lengthText])
        }
      end
    end

    # Turns a raw /browse response into an array of { title:, items: [...] }
    # sections, covering both horizontal carousels and vertical shelves.
    def parse_browse_sections(response)
      # Most browse pages (home, charts, artist pages) lay everything out
      # in one column, but album/EP/playlist pages now use a two-column
      # layout instead, with the actual content list living under
      # `secondaryContents` rather than inside the tab itself, so we try
      # both layouts here.
      section_list = response.dig(
        :contents, :singleColumnBrowseResultsRenderer, :tabs, 0, :tabRenderer, :content, :sectionListRenderer
      ) || response.dig(:contents, :twoColumnBrowseResultsRenderer, :secondaryContents, :sectionListRenderer)
      section_contents = section_list&.dig(:contents) || []

      section_contents.filter_map do |section|
        if (carousel = section[:musicCarouselShelfRenderer])
          title = text_from(carousel.dig(:header, :musicCarouselShelfBasicHeaderRenderer, :title)) || "Untitled"
          items = (carousel[:contents] || []).flat_map { |item| browse_items_from_carousel_item(item) }
          { title: title, items: items }
        elsif (shelf = section[:musicShelfRenderer])
          title = text_from(shelf[:title]) || "Untitled"
          items = (shelf[:contents] || []).filter_map do |item|
            renderer = item[:musicResponsiveListItemRenderer]
            next unless renderer
            result = parse_search_item(renderer)
            next unless result
            { id: result[:id], title: result[:title], subtitle: result[:artist], thumbnail_url: result[:thumbnail_url], type: :song }
          end
          { title: title, items: items }
        end
      end
    end

    # A single carousel entry can be a two-row card (album/playlist/artist)
    # or a list-item row (song), this normalizes either into a browse item.
    # Returns an array (0 or 1 items) so callers can flat_map it directly.
    def browse_items_from_carousel_item(item)
      if (two_row = item[:musicTwoRowItemRenderer])
        title = text_from(two_row[:title])
        subtitle = text_from(two_row[:subtitle])
        thumbnail_url = last_thumbnail_url(thumbnails_from(two_row[:thumbnailRenderer]))
        browse_id = two_row.dig(:navigationEndpoint, :browseEndpoint, :browseId)
        video_id = two_row.dig(:navigationEndpoint, :watchEndpoint, :videoId)
        return [ { id: browse_id || video_id || "", title: title, subtitle: subtitle, thumbnail_url: thumbnail_url, type: browse_id ? :playlist : :song } ]
      end

      if (renderer = item[:musicResponsiveListItemRenderer])
        result = parse_search_item(renderer)
        return [] unless result
        return [ { id: result[:id], title: result[:title], subtitle: result[:artist], thumbnail_url: result[:thumbnail_url], type: :song } ]
      end

      [] # neither shape matched (a divider or ad slot, most likely), skip it
    end

    # Pulls artist name/photo/subscriber-count/description out of a
    # /browse response's header block, whichever header shape is present.
    def extract_artist_header(response)
      header = response[:header]

      if (immersive = header&.dig(:musicImmersiveHeaderRenderer))
        {
          name: text_from(immersive[:title]) || "Unknown Artist",
          thumbnail_url: last_thumbnail_url(thumbnails_from(immersive[:thumbnail])),
          subscriber_count: text_from(immersive[:subtitle]),
          description: text_from(immersive[:description])
        }
      elsif (visual = header&.dig(:musicVisualHeaderRenderer))
        {
          name: text_from(visual[:title]) || "Unknown Artist",
          thumbnail_url: last_thumbnail_url(thumbnails_from(visual[:thumbnail])),
          subscriber_count: nil,
          description: nil
        }
      else
        { name: "Unknown Artist", thumbnail_url: "", subscriber_count: nil, description: nil }
      end
    end

    # Pulls album title/artist/year/track-count out of a /browse response's
    # header block, whichever header shape YouTube happened to send.
    def extract_album_header(response)
      header = response[:header]

      # Album pages moved to the two-column layout (see parse_browse_sections
      # above), which keeps its header as a musicResponsiveHeaderRenderer
      # inside the primary tab instead of the top-level "header" key, so we
      # check that spot first.
      if (responsive_header = response.dig(
            :contents, :twoColumnBrowseResultsRenderer, :tabs, 0, :tabRenderer,
            :content, :sectionListRenderer, :contents, 0, :musicResponsiveHeaderRenderer
          ))
        title = text_from(responsive_header[:title]) || "Unknown Album"
        artist = text_from(responsive_header[:straplineTextOne]) || "Unknown Artist"

        # subtitle reads like "Album • 1975", the year is whatever's after
        # the last bullet.
        subtitle_parts = text_from(responsive_header[:subtitle]).to_s.split("•").map(&:strip)
        year = subtitle_parts.last&.to_i
        year = nil if year.nil? || year.zero?

        # secondSubtitle reads like "18 songs • 1 hour, 2 minutes", we just
        # want the first number in it.
        track_count = text_from(responsive_header[:secondSubtitle]).to_s[/\d+/]&.to_i

        {
          title: title,
          artist: artist,
          year: year,
          track_count: track_count,
          thumbnail_url: last_thumbnail_url(thumbnails_from(responsive_header[:thumbnail]))
        }
      elsif (playlist_header = header&.dig(:musicEditablePlaylistDetailHeaderRenderer, :header))
        title = text_from(playlist_header[:title]) || "Unknown Album"
        # The subtitle is a "Artist • Year • Track Count" string, so we
        # split on the bullet character to pull the pieces back apart.
        parts = text_from(playlist_header[:subtitle]).to_s.split("•").map(&:strip)
        artist = parts[0].presence || "Unknown Artist"
        year = parts[1]&.strip&.to_i
        year = nil if year&.zero?
        track_count = parts[2]&.strip&.to_i
        track_count = nil if track_count&.zero?

        # If there's an explicit song-count field, trust it over the
        # subtitle parsing above, it's more reliable.
        if (count_text = text_from(playlist_header[:songCount]))
          digits = count_text.gsub(/\D/, "")
          track_count = digits.presence&.to_i
        end

        {
          title: title,
          artist: artist,
          year: year,
          track_count: track_count,
          thumbnail_url: last_thumbnail_url(thumbnails_from(playlist_header[:thumbnail]))
        }
      elsif (detail_header = header&.dig(:musicDetailHeaderRenderer))
        {
          title: text_from(detail_header[:title]) || "Unknown Album",
          artist: text_from(detail_header[:subtitle]) || "Unknown Artist",
          year: nil,
          track_count: nil,
          thumbnail_url: last_thumbnail_url(thumbnails_from(detail_header[:thumbnail]))
        }
      else
        { title: "Unknown Album", artist: "Unknown Artist", year: nil, track_count: nil, thumbnail_url: "" }
      end
    end

    # Converts one browse item hash into the SearchResult shape (used for
    # an artist's top songs and an album's track list).
    def song_from_browse_item(item)
      { id: item[:id], title: item[:title], artist: item[:subtitle], thumbnail_url: item[:thumbnail_url], duration: nil }
    end

    # Converts one browse item hash into the AlbumInfo shape (used for an
    # artist's albums/singles section).
    def album_from_browse_item(item)
      { id: item[:id], title: item[:title], artist: item[:subtitle], year: nil, thumbnail_url: item[:thumbnail_url], track_count: nil, tracks: nil }
    end

    # Converts one browse item hash into a minimal ArtistInfo shape (used
    # for a "related artists" section, we don't have their full page yet).
    def artist_from_browse_item(item)
      { id: item[:id], name: item[:title], thumbnail_url: item[:thumbnail_url], subscriber_count: nil, description: nil, top_songs: [], albums: [], related_artists: [] }
    end

    # YouTube represents "a bit of text" two different ways: either a flat
    # `simpleText` string, or an array of `runs` (segments) to join
    # together. This handles both and returns nil if there's no text at all.
    def text_from(text_run)
      return nil unless text_run
      return text_run[:simpleText] if text_run[:simpleText]
      runs = text_run[:runs]
      return nil unless runs
      runs.map { |run| run[:text] }.join
    end

    # Thumbnail arrays are ordered smallest to largest, so "last" is the
    # highest resolution image available.
    def last_thumbnail_url(thumbnails)
      thumbnails&.last&.dig(:url) || ""
    end

    # Some places in YouTube's response want the smallest/first thumbnail
    # instead (matches what the iOS app does for related-content cards).
    def first_thumbnail_url(thumbnails)
      thumbnails&.first&.dig(:url) || ""
    end

    # Pulls the actual array of { url:, width:, height: } thumbnails out of
    # a "thumbnail" field. This exists because YouTube added an extra layer
    # of nesting here at some point, older responses have the array
    # directly at musicThumbnailRenderer.thumbnails, newer ones bury it one
    # level deeper at musicThumbnailRenderer.thumbnail.thumbnails, we check
    # both so thumbnail URLs don't just quietly go missing.
    def thumbnails_from(thumbnail_field)
      renderer = thumbnail_field&.dig(:musicThumbnailRenderer)
      return [] unless renderer
      renderer[:thumbnails] || renderer.dig(:thumbnail, :thumbnails) || []
    end
  end
end
