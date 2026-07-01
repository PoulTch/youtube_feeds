class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает свежие видео из RSS
    channel.fetch_videos

    # 2. ОФИЦИАЛЬНЫЙ АВТОНОМНЫЙ ДЕСАНТ: Качаем оригинальную аватарку из YouTube через yt-dlp!
    # Если аватарки еще нет, или там застряла временная заглушка DiceBear — принудительно тянем оригинал.
    if channel.avatar_url.blank? || channel.avatar_url.include?("dicebear.com")
      channel.fetch_avatar_from_api
    end
  end
end
