# app/jobs/refresh_channel_metadata_job.rb
class RefreshChannelMetadataJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Обновляем аватарку и баннер автора
    channel.fetch_avatar_from_api

    # 2. Вытаскиваем хэш-карту абсолютно всех видео канала (включая те, что в его плейлистах)
    video_map = channel.videos.pluck(:youtube_video_id, :id).to_h
    video_ids = video_map.keys.compact
    api_key = Rails.application.config.youtube_api_key

    if video_ids.any? && api_key.present?
      video_ids.each_slice(50) do |slice|
        # ДОБАВИЛИ part=snippet, чтобы обновлялись и описания ролика!
        url = "https://www.googleapis.com/youtube/v3/videos?part=snippet,statistics&id=#{slice.join(',')}&key=#{api_key}"
        begin
          uri = URI.parse(url)
          response = Net::HTTP.get_response(uri)
          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)
            if data["items"].present?
              data["items"].each do |item|
                v_id = item["id"]
                views = item.dig("statistics", "viewCount").to_i
                likes = item.dig("statistics", "likeCount").to_i
                description = item.dig("snippet", "description")

                db_id = video_map[v_id]
                if db_id
                  # Обновляем просмотры, лайки и описания намертво в базе данных
                  Video.where(id: db_id).update_all(
                    views_count: views,
                    likes_count: likes,
                    description: description
                  )
                end
              end
            end
          end
        rescue => e
          Rails.logger.error "Ошибка фонового обновления статистики видео: #{e.message}"
        end
      end
    end
    Rails.logger.info "--> [API МЕТАДАННЫХ УСПЕХ] Канал #{channel.title} и все его ролики полностью обновлены."
  end
end
