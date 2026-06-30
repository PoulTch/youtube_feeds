class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает свежие видео из RSS
    channel.fetch_videos

    # 2. АВТОМАТИЧЕСКИЙ ДЕСАНТ: Если у канала ещё нет аватарки — генерируем её на лету!
    if channel.avatar_url.nil?
      begin
        avatar_seed = CGI.escape(channel.title)
        real_avatar = "https://api.dicebear.com/7.x/initials/svg?seed=#{avatar_seed}&radius=50&backgroundType=solid"

        # update_columns обновляет базу мгновенно и без лишних проверок в фоне
        channel.update_columns(avatar_url: real_avatar)
      rescue => e
        Rails.logger.error "!!! Ошибка генерации аватарки для #{channel.title}: #{e.message}"
      end
    end
  end
end
