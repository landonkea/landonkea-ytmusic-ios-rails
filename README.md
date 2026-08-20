# landonkea-ytmusic-ios-rails

This is a small backend server for the [landonkea-ytmusic-ios](https://github.com/landonkea/landonkea-ytmusic-ios) app. If you've never worked with a Rails app before, or with backend servers at all, this file walks through what's actually going on here.

## What problem does this solve?

The iOS/macOS app is a YouTube Music player you build and run yourself. Right now, it talks directly to Google's servers, specifically to an internal API called "InnerTube" that the real YouTube Music website and apps use behind the scenes. There's no official public API for YouTube Music, so the app pretends to be one of Google's own clients (the website, or the iPhone YouTube app) and speaks that private protocol directly.

That works, but it means every request YouTube's servers expect, the exact headers, the "we are pretending to be Firefox on Windows" fingerprint, the encoded search filters, all of that logic lives inside the iPhone app itself.

This project moves that logic here instead. Rather than the iPhone app building InnerTube requests and calling Google directly, it can call this Rails server, and this server does the InnerTube legwork and hands back plain, simple JSON: a list of songs, an album's track list, an artist's page. The iPhone app doesn't need to know anything about InnerTube's internals anymore, it just asks this server for what it wants.

Think of it as a translator standing between the iOS app and Google. The app speaks a simple language ("give me search results for 'bohemian rhapsody'"), and this server translates that into whatever contorted request format Google's real servers expect today, then translates the answer back into something clean.

## How the pieces fit together

There are three layers here, and each one has exactly one job:

**Routes** (`config/routes.rb`) decide which URL goes to which piece of code. A request to `/search?q=queen` gets routed to the search controller, `/albums/MPREb_abc123` gets routed to the albums controller, and so on.

**Controllers** (`app/controllers/`) are thin. Each one reads the incoming request's parameters, asks the InnerTube client to go fetch the actual data, and renders the result as JSON. `SearchController`, `PlayerController`, `BrowseController`, `ArtistsController`, `AlbumsController`, and `RelatedController` cover the app's core features: searching, resolving a playable audio stream, browsing the home/charts/explore pages, and loading full artist or album pages.

**The InnerTube client** (`app/services/innertube/client.rb`) is where almost all the real work happens. This one file builds the requests Google's servers expect (the right headers, the right "client" identity, the right encoded filter parameters), sends them, and then digs through Google's deeply nested JSON response to pull out just the handful of fields the app actually needs. If you want to understand how this whole thing works, this is the file to read, it's heavily commented line by line.

A few endpoints (search, browse pages, artist/album pages) get cached in `Rails.cache` for 10 minutes to an hour, so searching for the same thing twice in a row doesn't hit Google's servers twice. The `/player` endpoint (which resolves a playable stream URL) is never cached, since those URLs expire after a few hours and caching one would just hand out a broken link.

## A note on how solid this is

InnerTube isn't a documented, stable API, it's Google's own internal API that the YouTube Music website and apps happen to use, and it can change shape without warning. While building this, several of the response formats had already shifted since the iOS app's original code was written (months, not years, apart): search results moved from one JSON layout to another, the "related songs" endpoint restructured itself behind an extra tab layer, and album pages switched to an entirely different two-column layout with a new header format. This server's parsing code checks for both the older and newer shapes where that was practical, so it keeps working against the live API rather than just matching whatever the iOS app's Swift code happened to assume. If Google changes things again, some endpoint here may need another look, that's the nature of building on top of a private API instead of a documented one.

One specific limitation worth knowing about: the `/player` endpoint (which resolves the actual playable audio URL for a song) can get blocked by Google's bot-detection with a "Sign in to confirm you're not a bot" response when this server runs from a cloud/datacenter IP address rather than a home internet connection. This is a known, widespread issue affecting basically every unofficial YouTube client (yt-dlp included) when run from cloud infrastructure, it isn't a bug in this code. Running the server from a home connection, or expect this endpoint to need extra handling (cookies, proxies) if you deploy it somewhere with a datacenter IP.

## The endpoints

All of these return JSON. None of them require you to log in or provide any credentials, just like using YouTube Music's search box without an account.

| Endpoint | What it does |
|---|---|
| `GET /search?q=...&filter=songs` | Search for songs/videos/albums/artists. `filter` is optional (`songs`, `videos`, `albums`, or `artists`). |
| `GET /search/suggestions?q=...` | Autocomplete suggestions as someone types. |
| `GET /player/:video_id?quality=high` | Resolves a playable audio stream URL for one video ID. `quality` can be `low`, `medium`, `high`, or `auto`. |
| `GET /home` | The YouTube Music home feed. |
| `GET /charts` | The charts/trending page. |
| `GET /explore` | The explore tab (new releases, moods, genres). |
| `GET /new_releases` | Just the new-releases section. |
| `GET /moods` | The list of mood/genre categories. |
| `GET /moods/playlists?params=...` | Playlists inside one specific mood/genre (the `params` value comes from a moods item). |
| `GET /browse/:browse_id` | A generic fallback for browsing any other page by its ID. |
| `GET /artists/:channel_id` | A full artist page: name, photo, top songs, albums, related artists. |
| `GET /albums/:browse_id` | A full album page: title, artist, year, and the complete track list. |
| `GET /related/:video_id` | Songs related to/recommended after a given video. |
| `GET /up` | Health check. Returns 200 if the app is running. Used by hosting platforms to know the server is alive. |

## Running it yourself

You'll need Ruby installed (this was built against Ruby 3.4.9 and Rails 8.1.3.1, check `.ruby-version` for the exact version this repo expects).

```bash
bundle install
bin/rails server
```

Then visit `http://localhost:3000/search?q=queen` in a browser or with `curl`, you should get back real search results from YouTube Music.

### Configuration

There's a `.env.example` file documenting the one setting this app cares about: `INNERTUBE_API_KEY`. You almost certainly don't need to touch it. It's not a personal API key you'd sign up for, it's the same public "InnerTube WEB_REMIX client" identifier that YouTube Music's own website ships in its own JavaScript, and the app already has a working value baked in as a fallback. The environment variable exists only so the value could be swapped out without a code change, if Google ever rotates it.

If you do want to set it explicitly, copy the example file and fill it in:

```bash
cp .env.example .env
```

### Running the tests

```bash
bin/rails test
```

Every test stubs out the network call to YouTube (using WebMock) with a realistic saved JSON response, so the test suite never actually reaches out to the internet, and it's fast and reliable to run repeatedly. Test fixtures live in `test/fixtures/files/innertube/`, and cover both the search/browse/player/album-page shapes and the newer layouts YouTube has since switched to.

### Running it with Docker

```bash
docker build -t landonkea-ytmusic-ios-rails .
docker run -p 3000:80 -e RAILS_MASTER_KEY=$(cat config/master.key) landonkea-ytmusic-ios-rails
```

This uses the Dockerfile Rails 8 generates by default: a multi-stage build that compiles gems in one stage and copies just the finished app into a lean final image, running as a non-root user.

## Connecting the iOS app to this server

The iOS app currently calls `music.youtube.com` directly from `InnerTubeClient.swift`. Pointing it at this server instead means swapping that base URL for wherever this Rails app is running, and adjusting the response parsing to read this server's simpler JSON shapes (which were deliberately kept close to what the app's existing `SearchResult`, `PlayerInfo`, `BrowseSection`, `ArtistInfo`, and `AlbumInfo` models already expect) instead of InnerTube's raw nested format. That wiring wasn't part of this project, this repo is just the backend half.
