class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает свежие видео из RSS
    channel.fetch_videos

    # 2. АВТОПИЛОТ ВРЕМЕНИ ЧЕРЕЗ GOOGLE API v3:
    # Находим ролики этого канала, у которых ещё нет длительности
    api_key = Rails.application.config.youtube_api_key
    videos_to_update = channel.videos.where(duration_seconds: nil).limit(20)

    if api_key.present? && videos_to_update.any?
      video_ids = videos_to_update.map(&:youtube_video_id).join(",")
      url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=#{video_ids}&key=#{api_key}"

      begin
        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)

          if data["items"].present?
            data["items"].each do |item|
              v_id = item["id"]
              iso_duration = item.dig("contentDetails", "duration") # Строка вида "PT14M23S" или "PT1H5M"

              if iso_duration.present?
                # Парсим ISO 8601 длительность в чистые секунды
                seconds = 0
                match = iso_duration.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/)
                if match
                  hours = match[1].to_i
                  minutes = match[2].to_i
                  secs = match[3].to_i
                  seconds = (hours * 3600) + (minutes * 60) + secs
                end

                if seconds > 0
                  video = channel.videos.find_by(youtube_video_id: v_id)
                  video.update_columns(duration_seconds: seconds) if video
                  Rails.logger.info "--> [API ВРЕМЯ] Успешно записано #{seconds} сек для: #{v_id}"
                end
              end
            end
          end
        end
      rescue => e
        Rails.logger.error "!!! Ошибка сбора времени через API: #{e.message}"
      end
    end

    # 3. Автопилот аватарок: подтягиваем фото автора
    channel.fetch_avatar_from_api
  end
end
