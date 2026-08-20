require "test_helper"

# Tests for the service object that does all the actual InnerTube request
# building/calling/parsing. Every outbound HTTP call is stubbed with
# WebMock using realistic (trimmed-down) sample responses saved in
# test/fixtures/files/innertube, no test here ever touches the real network.
module Innertube
  class ClientTest < ActiveSupport::TestCase
    setup do
      @client = Innertube::Client.new # a fresh client for each test, no shared state between them
    end

    test "search parses song results out of a search response" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/search})
        .to_return(status: 200, body: innertube_fixture("search"), headers: { "Content-Type" => "application/json" })

      results = @client.search(query: "bohemian rhapsody")

      assert_equal 1, results.length
      song = results.first
      assert_equal "fJ9rUzIMcZQ", song[:id]
      assert_equal "Bohemian Rhapsody", song[:title]
      assert_equal "Queen", song[:artist]
      assert_equal "5:55", song[:duration]
      assert_equal "https://i.ytimg.com/vi/fJ9rUzIMcZQ/large.jpg", song[:thumbnail_url] # picks the LAST (largest) thumbnail
    end

    test "search sends the matching filter params for a given filter name" do
      stub = stub_request(:post, %r{music\.youtube\.com/youtubei/v1/search})
        .with(body: ->(body) { JSON.parse(body)["params"] == "EgIQAw==" }) # "songs" filter's protobuf value
        .to_return(status: 200, body: innertube_fixture("search"), headers: { "Content-Type" => "application/json" })

      @client.search(query: "queen", filter: "songs")

      assert_requested stub
    end

    test "search_suggestions returns a flat array of suggestion strings" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/music/get_search_suggestions})
        .to_return(status: 200, body: innertube_fixture("search_suggestions"), headers: { "Content-Type" => "application/json" })

      suggestions = @client.search_suggestions(query: "quee")

      assert_equal [ "queen", "queen bohemian rhapsody" ], suggestions
    end

    test "player picks the highest-bitrate audio stream for quality high" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
        .to_return(status: 200, body: innertube_fixture("player"), headers: { "Content-Type" => "application/json" })

      info = @client.player(video_id: "fJ9rUzIMcZQ", quality: "high")

      assert_equal "fJ9rUzIMcZQ", info[:video_id]
      assert_equal "Bohemian Rhapsody", info[:title]
      assert_equal "Queen", info[:artist]
      assert_equal 355, info[:duration]
      assert_equal "https://example.com/audio-256.webm", info[:audio_url] # 256kbps beats 128kbps and 64kbps
      assert_equal "High", info[:audio_quality]
    end

    test "player picks the stream closest to 128kbps for quality medium" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
        .to_return(status: 200, body: innertube_fixture("player"), headers: { "Content-Type" => "application/json" })

      info = @client.player(video_id: "fJ9rUzIMcZQ", quality: "medium")

      assert_equal "https://example.com/audio-128.mp4", info[:audio_url]
    end

    test "player falls back to the TV client when the IOS client's request fails" do
      # First request (IOS client) fails outright, second (TV client) succeeds.
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
        .with(headers: { "X-YouTube-Client-Name" => "5" }) # "5" = IOS client's ID
        .to_return(status: 500)
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
        .with(headers: { "X-YouTube-Client-Name" => "7" }) # "7" = TVHTML5 client's ID
        .to_return(status: 200, body: innertube_fixture("player"), headers: { "Content-Type" => "application/json" })

      info = @client.player(video_id: "fJ9rUzIMcZQ")

      assert_equal "fJ9rUzIMcZQ", info[:video_id]
    end

    test "player raises VideoUnplayableError when the video can't be played" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
        .to_return(status: 200, body: innertube_fixture("player_unplayable"), headers: { "Content-Type" => "application/json" })

      error = assert_raises(Innertube::Client::VideoUnplayableError) do
        @client.player(video_id: "private123")
      end
      assert_match "This video is private", error.message
    end

    test "browse_sections parses both a carousel and a shelf into sections" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
        .to_return(status: 200, body: innertube_fixture("browse_home"), headers: { "Content-Type" => "application/json" })

      sections = @client.browse_sections(browse_id: "FEmusic_home")

      assert_equal 2, sections.length
      assert_equal "Quick picks", sections[0][:title]
      assert_equal :playlist, sections[0][:items].first[:type] # carousel item has a browseId, so it's a playlist/album
      assert_equal "Recently played", sections[1][:title]
      assert_equal :song, sections[1][:items].first[:type]
    end

    test "related returns songs and albums/playlists from the next response" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/next})
        .to_return(status: 200, body: innertube_fixture("next"), headers: { "Content-Type" => "application/json" })

      results = @client.related(video_id: "fJ9rUzIMcZQ")

      assert_equal 2, results.length
      assert_equal "HgzGwKwLmgM", results[0][:id]
      assert_equal "Don't Stop Me Now", results[0][:title]
      assert_equal "Greatest Hits", results[1][:title]
    end

    test "related parses the current 'up next' queue shape and filters out the song you asked about" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/next})
        .to_return(status: 200, body: innertube_fixture("next_queue"), headers: { "Content-Type" => "application/json" })

      results = @client.related(video_id: "fJ9rUzIMcZQ") # this is the "current" song in the fixture's queue

      assert_equal 1, results.length # the current song itself is filtered out, only the next queued song remains
      assert_equal "HgzGwKwLmgM", results.first[:id]
      assert_equal "Don't Stop Me Now", results.first[:title]
      assert_equal "Queen", results.first[:artist]
      assert_equal "3:29", results.first[:duration]
    end

    test "artist parses header info and buckets sections into songs/albums" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
        .to_return(status: 200, body: innertube_fixture("artist"), headers: { "Content-Type" => "application/json" })

      info = @client.artist(channel_id: "UCiMhD4jzUqG-IgPzUmmytRQ")

      assert_equal "Queen", info[:name]
      assert_equal "18.2M subscribers", info[:subscriber_count]
      assert_equal 1, info[:top_songs].length
      assert_equal "Bohemian Rhapsody", info[:top_songs].first[:title]
      assert_equal 1, info[:albums].length
      assert_equal "A Night at the Opera", info[:albums].first[:title]
    end

    test "album parses header info (title/artist/year/track count) and the track list" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
        .to_return(status: 200, body: innertube_fixture("album"), headers: { "Content-Type" => "application/json" })

      info = @client.album(browse_id: "MPREb_night123")

      assert_equal "A Night at the Opera", info[:title]
      assert_equal "Queen", info[:artist]
      assert_equal 1975, info[:year]
      assert_equal 2, info[:tracks].length
      assert_equal "Death on Two Legs", info[:tracks].first[:title]
      assert_equal 2, info[:track_count] # actual parsed track count wins over the header's own count
    end

    test "raises HttpError when YouTube responds with a server error" do
      stub_request(:post, %r{music\.youtube\.com/youtubei/v1/search})
        .to_return(status: 500)

      assert_raises(Innertube::Client::HttpError) do
        @client.search(query: "anything")
      end
    end
  end
end
