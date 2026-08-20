require "test_helper"

# Integration test for the full artist page endpoint.
class ArtistsControllerTest < ActionDispatch::IntegrationTest
  test "GET /artists/:channel_id returns the artist's info, top songs, and albums" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
      .to_return(status: 200, body: innertube_fixture("artist"), headers: { "Content-Type" => "application/json" })

    get "/artists/UCiMhD4jzUqG-IgPzUmmytRQ"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Queen", body["name"]
    assert_equal 1, body["top_songs"].length
    assert_equal 1, body["albums"].length
  end
end
