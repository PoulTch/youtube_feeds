class FetchChannelVideosJob < ApplicationJob
  # Задаем имя очереди (по умолчанию default)
  queue_as :default

  # Этот метод выполнится в фоновом потоке Linux
  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return if channel.nil?

    # Запускаем наш парсер, который мы написали в модели Channel
    channel.fetch_videos
  end
end
