class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает новые видео из RSS
    channel.fetch_videos

    # 2. АВТОПИЛОТ РЕАЛЬНЫХ ДАТ И ВРЕМЕНИ ЧЕРЕЗ GOOGLE API v3 (ИСПРАВЛЕННЫЙ)
    api_key = Rails.application.config.youtube_api_key
    # === УМНЫЙ АВТОПИЛОТ С ОПТИМИЗАЦИЕЙ КВОТ GOOGLE ===
    # 1. Срочно собираем ролики без статистики (duration или views равны nil)
    blank_videos = channel.videos.where(duration_seconds: nil).or(channel.videos.where(views_count: nil))

    # 2. Собираем ГОРЯЧИЕ НОВИНКИ (вышли в последние 3 дня), которые не обновлялись более 3 часов
    hot_news = channel.videos.where("published_at > ?", 3.days.ago).where("updated_at < ?", 3.hours.ago)

    # 3. Собираем СТАРЫЙ АРХИВ, который не обновлялся больше 24 часов (берем понемногу, чтобы не тратить квоту)
    old_archive = channel.videos.where("published_at <= ?", 3.days.ago).where("updated_at < ?", 24.hours.ago).limit(100)

    # Объединяем всё в один фиксированный массив для обработки
    videos_to_update = (blank_videos.to_a + hot_news.to_a + old_archive.to_a).uniq.first(500)

    if api_key.present? && videos_to_update.any?
      # .each_slice(50) берет по 50 видео за раз и крутит внутренний цикл
      videos_to_update.each_slice(50) do |batch|
        video_ids = batch.map(&:youtube_video_id).join(",")
        url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,liveStreamingDetails,snippet,statistics&id=#{video_ids}&key=#{api_key}"

        begin
          uri = URI.parse(url)
          response = Net::HTTP.get_response(uri)

          if response.is_a?(Net::HTTPSuccess)
            data = JSON.parse(response.body)

            if data["items"].present?
              data["items"].each do |item|
                v_id = item["id"]

                snippet = item["snippet"]
                content_details = item["contentDetails"]
                statistics = item["statistics"]
                live_details = item["liveStreamingDetails"]

                real_date_str = snippet ? snippet["publishedAt"] : nil
                views = statistics ? statistics["viewCount"].to_i : 0
                likes = statistics ? statistics["likeCount"].to_i : 0

                # 1. СВЕРХТОЧНОЕ РАСПАРСИВАНИЕ ДЛИТЕЛЬНОСТИ В СЕКУНДЫ
                seconds = 0
                if content_details && content_details["duration"].present?
                  begin
                    seconds = ActiveSupport::Duration.parse(content_details["duration"]).to_i
                  rescue
                    seconds = 0
                  end
                end

                # 2. ЖЕЛЕЗОБЕТОННОЕ ОПРЕДЕЛЕНИЕ ТИПА КОНТЕНТА (НАШ НАДЁЖНЫЙ КРИТЕРИЙ)
                description_text = snippet ? snippet["description"].to_s.downcase : ""

                if live_details.present?
                  # Если у видео физически есть блок liveStreamingDetails — это на 100% СТРИМ!
                  detected_type = "stream"
                elsif description_text.include?("#shorts") || (seconds > 0 && seconds <= 180)
                  # Если есть тег или длительность до 3 минут (180 секунд) — это ШОРТС!
                  detected_type = "shorts"
                else
                  # Во всех остальных случаях — обычное классическое видео
                  detected_type = "video"
                end

                # 3. ЗАПИСЬ ДАННЫХ В ЛОКАЛЬНУЮ БАЗУ
                video = channel.videos.find_by(youtube_video_id: v_id)
                if video
                  updates = {}
                  updates[:duration_seconds] = seconds if seconds > 0
                  updates[:published_at] = Time.parse(real_date_str) if real_date_str.present?
                  updates[:views_count] = views if views > 0
                  updates[:likes_count] = likes if likes > 0
                  updates[:video_type] = detected_type

                  video.update_columns(updates) if updates.any?
                  Rails.logger.info "--> [API АВТОПИЛОТ] Синхронизированы данные и ТИП КОНТЕНТА (#{detected_type}) для: #{v_id}"
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

    # 4. Автопилот плейлистов и карточек плейлистов
    channel.fetch_playlist_cards_from_api
  end
end
