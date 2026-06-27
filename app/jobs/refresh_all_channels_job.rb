class RefreshAllChannelsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "=== [РОБОТ-ПЛАНИРОВЩИК] Начинаю плановое обновление всех каналов... ==="

    # Берем каждый канал и отправляем воркеру задачу на скачивание видео
    Channel.find_each do |channel|
      FetchChannelVideosJob.perform_later(channel.id)
    end

    Rails.logger.info "=== [РОБОТ-ПЛАНИРОВЩИК] Все задачи на обновление успешно добавлены в очередь! ==="
  end
end
