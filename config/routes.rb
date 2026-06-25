Rails.application.routes.draw do
  # Устанавливаем VideosController и его метод index в качестве главной страницы сайта
  root "videos#index"

  # Маршрут для отправки формы добавления канала
  post "add_channel" => "videos#create_channel", as: :add_channel

  # Новый маршрут для страницы конкретного канала
  get "channels/:id" => "videos#show_channel", as: :channel_page

  # Новый маршрут для просмотра конкретного видео
  get "videos/:id" => "videos#show", as: :watch_video
  post "videos/:id/save_progress" => "videos#save_progress"

  # Маршрут для импорта файла подписок
  post "import_subscriptions" => "videos#import_subscriptions", as: :import_subscriptions

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
