class RefreshAllChannelsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info "=== [РОБОТ-ПЛАНИРОВЩИК] Начинаю плановое обновление всех каналов... ==="

    # Находим каждый канал в базе и отдаем его роботу-исполнителю (которого ты мне прислал)
    Channel.find_each do |channel|
      FetchChannelVideosJob.perform_later(channel.id)
    end

    Rails.logger.info "=== [РОБОТ-ПЛАНИРОВЩИК] Все задачи на обновление успешно добавлены в очередь! ==="
  end
end
