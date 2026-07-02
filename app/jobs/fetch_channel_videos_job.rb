class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает новые видео из RSS
    channel.fetch_videos

    # 2. АВТОПИЛОТ РЕАЛЬНЫХ ДАТ И ВРЕМЕНИ ЧЕРЕЗ GOOGLE API v3
    api_key = Rails.application.config.youtube_api_key
    # Ищем ролики, у которых нет длительности (или если нужно принудительно обновить даты)
    videos_to_update = channel.videos.where(duration_seconds: nil).limit(30)

    if api_key.present? && videos_to_update.any?
      video_ids = videos_to_update.map(&:youtube_video_id).join(",")
      # Добавляем в part секцию snippet, чтобы забрать реальную дату публикации!
      url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,snippet&id=#{video_ids}&key=#{api_key}"

      begin
        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)

          if data["items"].present?
            data["items"].each do |item|
              v_id = item["id"]

              # 1. Вытаскиваем реальную дату публикации с YouTube
              real_date_str = item.dig("snippet", "publishedAt") # Например: "2026-06-30T15:30:00Z"

              # 2. Вытаскиваем длительность ролика
              iso_duration = item.dig("contentDetails", "duration")

              seconds = 0
              if iso_duration.present?
                match = iso_duration.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/)
                if match
                  hours   = match[1].to_i
                  minutes = match[2].to_i
                  secs    = match[3].to_i
                  seconds = (hours * 3600) + (minutes * 60) + secs
                end
              end

              video = channel.videos.find_by(youtube_video_id: v_id)
              if video
                # Обновляем в базе данных PostgreSQL и секунды, и настоящую дату публикации!
                updates = {}
                updates[:duration_seconds] = seconds if seconds > 0
                updates[:published_at] = Time.parse(real_date_str) if real_date_str.present?

                video.update_columns(updates) if updates.any?
                Rails.logger.info "--> [API УСПЕХ] Синхронизированы дата и время для: #{v_id}"
              end
            end
          end
        end
      rescue => e
        Rails.logger.error "!!! Ошибка синхронизации дат через API: #{e.message}"
      end
    end

    # 3. Автопилот аватарок и баннеров
    channel.fetch_avatar_from_api
  end
end
