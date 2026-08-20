require "test_helper"

# Integration test for the full album page endpoint.
class AlbumsControllerTest < ActionDispatch::IntegrationTest
  test "GET /albums/:browse_id returns the album's info and track list" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
      .to_return(status: 200, body: innertube_fixture("album"), headers: { "Content-Type" => "application/json" })

    get "/albums/MPREb_night123"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "A Night at the Opera", body["title"]
    assert_equal "Queen", body["artist"]
    assert_equal 2, body["tracks"].length
  end
end
