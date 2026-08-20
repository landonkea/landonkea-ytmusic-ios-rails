require "test_helper"

# Integration test for the "related songs" endpoint used on the
# now-playing screen.
class RelatedControllerTest < ActionDispatch::IntegrationTest
  test "GET /related/:video_id returns related songs and albums" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/next})
      .to_return(status: 200, body: innertube_fixture("next"), headers: { "Content-Type" => "application/json" })

    get "/related/fJ9rUzIMcZQ"

    assert_response :success
    results = JSON.parse(response.body)["results"]
    assert_equal 2, results.length
    assert_equal "Don't Stop Me Now", results.first["title"]
  end
end
