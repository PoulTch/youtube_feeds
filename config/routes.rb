Rails.application.routes.draw do
  # НАШИ НОВЫЕ МАРШРУТЫ БЕЗОПАСНОСТИ
  get  "/login",  to: "sessions#new",     as: :login
  post "/login",  to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  # Устанавливаем VideosController и его метод index в качестве главной страницы сайта
  root "videos#index"

  # Маршрут для отправки формы добавления канала
  post "add_channel" => "videos#create_channel", as: :add_channel

  # Новый маршрут для страницы конкретного канала
  get "channels/:id" => "videos#show_channel", as: :channel_page
  delete "channels/:id", to: "videos#destroy", as: :delete_channel

  # Маршрут для запуска сканирования полного архива канала через yt-dlp
  post "channels/:id/fetch_archive" => "videos#fetch_channel_archive", as: :fetch_channel_archive

  # Новый маршрут для просмотра конкретного видео
  get "videos/:id" => "videos#show", as: :watch_video
  post "videos/:id/save_progress" => "videos#save_progress"

  # ДОБАВЛЕНО: Автономный маршрут для просмотра содержимого плейлиста внутри MyChannels!
  get "playlists/:id" => "videos#show_playlist", as: :playlist_page

  # Маршрут для импорта файла подписок
  post "import_subscriptions" => "videos#import_subscriptions", as: :import_subscriptions

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check
end
