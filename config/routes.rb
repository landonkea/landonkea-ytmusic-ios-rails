Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Searching for songs/videos/albums/artists, e.g. GET /search?q=queen&filter=songs
  get "search" => "search#index"
  # Autocomplete suggestions as someone types, e.g. GET /search/suggestions?q=quee
  get "search/suggestions" => "search#suggestions"

  # Resolves a playable audio stream URL for one video ID.
  get "player/:video_id" => "player#show", as: :player

  # The handful of built-in YouTube Music pages the iOS app's browse() helper covers.
  get "home" => "browse#home"
  get "charts" => "browse#charts"
  get "explore" => "browse#explore"
  get "new_releases" => "browse#new_releases"
  get "moods" => "browse#moods"
  get "moods/playlists" => "browse#mood_playlists"
  # A generic catch-all for any other browse ID the app wants directly.
  get "browse/:browse_id" => "browse#show", as: :browse, constraints: { browse_id: /.+/ }

  # Full artist and album pages.
  get "artists/:channel_id" => "artists#show", as: :artist
  get "albums/:browse_id" => "albums#show", as: :album, constraints: { browse_id: /.+/ }

  # Related/recommended songs for a given video ID.
  get "related/:video_id" => "related#show", as: :related

  # Defines the root path route ("/")
  # root "posts#index"
end
