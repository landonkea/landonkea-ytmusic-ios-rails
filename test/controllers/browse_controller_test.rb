require "test_helper"

# Integration tests for the browse-related endpoints: home, charts,
# explore, new releases, moods, and the generic /browse/:browse_id route.
class BrowseControllerTest < ActionDispatch::IntegrationTest
  test "GET /home returns parsed sections" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
      .to_return(status: 200, body: innertube_fixture("browse_home"), headers: { "Content-Type" => "application/json" })

    get "/home"

    assert_response :success
    sections = JSON.parse(response.body)["sections"]
    assert_equal 2, sections.length
    assert_equal "Quick picks", sections.first["title"]
  end

  test "GET /charts reuses the same browse+parse pipeline as home" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
      .to_return(status: 200, body: innertube_fixture("browse_home"), headers: { "Content-Type" => "application/json" })

    get "/charts"

    assert_response :success
    assert_equal 2, JSON.parse(response.body)["sections"].length
  end

  test "GET /browse/:browse_id works for an arbitrary browse ID" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/browse})
      .to_return(status: 200, body: innertube_fixture("browse_home"), headers: { "Content-Type" => "application/json" })

    get "/browse/FEmusic_explore"

    assert_response :success
    assert_equal 2, JSON.parse(response.body)["sections"].length
  end

  test "GET /moods/playlists without a params query parameter returns a 400" do
    get "/moods/playlists"

    assert_response :bad_request
  end
end
