class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает новые видео из RSS
    channel.fetch_videos

    # 2. АВТОПИЛОТ РЕАЛЬНЫХ ДАТ И ВРЕМЕНИ ЧЕРЕЗ GOOGLE API v3 (ИСПРАВЛЕННЫЙ)
    api_key = Rails.application.config.youtube_api_key
    # ДОБАВИЛИ .to_a в конце, чтобы зафиксировать массив из 500 роликов в памяти компьютера
    videos_to_update = channel.videos.where(duration_seconds: nil).or(channel.videos.where(views_count: nil)).limit(500).to_a

    if api_key.present? && videos_to_update.any?
      # .each_slice(50) берет по 50 видео за раз и крутит внутренний цикл
      videos_to_update.each_slice(50) do |batch|
        video_ids = batch.map(&:youtube_video_id).join(",")
        url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,snippet,statistics&id=#{video_ids}&key=#{api_key}"

        begin
          uri = URI.parse(url)
          response = Net::HTTP.get_response(uri)

          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)

            if data["items"].present?
              data["items"].each do |item|
                v_id = item["id"]

                # 1. Вытаскиваем реальную дату публикации с YouTube
                real_date_str = item.dig("snippet", "publishedAt")
                views = item.dig("statistics", "viewCount").to_i
                likes = item.dig("statistics", "likeCount").to_i

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
                  updates = {}
                  updates[:duration_seconds] = seconds if seconds > 0
                  updates[:published_at] = Time.parse(real_date_str) if real_date_str.present?
                  # ИСПРАВЛЕНО: Указали правильные имена колонок из миграции (views_count и likes_count)
                  updates[:views_count] = views if views > 0
                  updates[:likes_count] = likes if likes > 0

                  video.update_columns(updates) if updates.any?
                  Rails.logger.info "--> [API УСПЕХ] Синхронизированы просмотры и лайки для: #{v_id}"
                end
              end
            end
          end
        rescue => e
          Rails.logger.error "!!! Ошибка синхронизации данных через API: #{e.message}"
        end
      end # Конец блока .each_slice
    end

    # 3. Автопилот аватарок и баннеров
    channel.fetch_avatar_from_api
  end
end
