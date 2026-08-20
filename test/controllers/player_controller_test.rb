require "test_helper"

# Integration tests for the /player endpoint, checking both the happy path
# and how an unplayable video gets turned into a proper error response.
class PlayerControllerTest < ActionDispatch::IntegrationTest
  test "GET /player/:video_id returns stream info" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
      .to_return(status: 200, body: innertube_fixture("player"), headers: { "Content-Type" => "application/json" })

    get "/player/fJ9rUzIMcZQ"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "fJ9rUzIMcZQ", body["video_id"]
    assert_equal "https://example.com/audio-256.webm", body["audio_url"]
  end

  test "GET /player/:video_id for an unplayable video returns a 422 with the reason" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/player})
      .to_return(status: 200, body: innertube_fixture("player_unplayable"), headers: { "Content-Type" => "application/json" })

    get "/player/private123"

    assert_response :unprocessable_content
    assert_match "This video is private", JSON.parse(response.body)["error"]
  end
end
