require "test_helper"

# Integration-style tests for the /search endpoints, hitting them as an
# actual HTTP request and checking the JSON that comes back, with the
# InnerTube call itself stubbed out via WebMock.
class SearchControllerTest < ActionDispatch::IntegrationTest
  test "GET /search returns parsed results for a query" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/search})
      .to_return(status: 200, body: innertube_fixture("search"), headers: { "Content-Type" => "application/json" })

    get "/search", params: { q: "bohemian rhapsody" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["results"].length
    assert_equal "Bohemian Rhapsody", body["results"].first["title"]
  end

  test "GET /search without a q parameter returns a 400" do
    get "/search"

    assert_response :bad_request
  end

  test "GET /search/suggestions returns a suggestions array" do
    stub_request(:post, %r{music\.youtube\.com/youtubei/v1/music/get_search_suggestions})
      .to_return(status: 200, body: innertube_fixture("search_suggestions"), headers: { "Content-Type" => "application/json" })

    get "/search/suggestions", params: { q: "quee" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "queen", "queen bohemian rhapsody" ], body["suggestions"]
  end

  test "GET /search/suggestions with a blank q returns an empty array without calling out" do
    get "/search/suggestions", params: { q: "" }

    assert_response :success
    assert_equal [], JSON.parse(response.body)["suggestions"]
    assert_not_requested :post, %r{music\.youtube\.com} # never even tried to call YouTube
  end
end
