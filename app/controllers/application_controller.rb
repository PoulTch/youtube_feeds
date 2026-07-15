class ApplicationController < ActionController::Base
  include Pagy::Method

  # 1. СТРОГО НА ПЕРВОМ МЕСТЕ: Сначала проверяем, вошел ли пользователь
  before_action :check_login

  # 2. НА ВТОРОМ МЕСТЕ: Загружаем сайдбар только для тех, кто успешно прошел проверку
  before_action :load_sidebar_channels

  private

  # Метод проверки авторизации
  def check_login
    unless current_user
      redirect_to login_path
    end
  end

  # Хелпер-метод для поиска текущего вошедшего пользователя
  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end
  helper_method :current_user

  def load_sidebar_channels
    # Кэшируем сайдбар на 5 минут. Rails посчитает его один раз, а потом будет отдавать мгновенно!
    @sidebar_channels = Rails.cache.fetch("sidebar_channels_user_#{session[:user_id]}", expires_in: 5.minutes) do
      Channel.select("channels.*, COALESCE((SELECT SUM(videos.watched_seconds) FROM videos WHERE videos.channel_id = channels.id), 0) AS total_watch_time")
            .order("total_watch_time DESC, channels.title ASC")
            .to_a
    end
  end
end
