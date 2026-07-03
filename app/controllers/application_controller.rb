class ApplicationController < ActionController::Base
  # Запускаем метод load_sidebar_channels перед любым действием на сайте
  before_action :load_sidebar_channels

  private

  # Метод для загрузки каналов в сайдбаре
  def load_sidebar_channels
    # МАГИЯ АЛГОРИТМА v2: Безопасный подзапрос (Subquery).
    # Считает сумму watched_seconds для каждого канала отдельно, не ломая структуру массива.
    # Самые просматриваемые летят наверх, остальные идут ниже строго по алфавиту.
    @sidebar_channels = Channel.select("channels.*, COALESCE((SELECT SUM(videos.watched_seconds) FROM videos WHERE videos.channel_id = channels.id), 0) AS total_watch_time")
                               .order("total_watch_time DESC, channels.title ASC")
                               .to_a
  end
end
