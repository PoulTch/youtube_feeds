class FetchPlaylistVideosJob < ApplicationJob
  queue_as :default

  def perform(playlist_id)
    playlist = Playlist.find_by(id: playlist_id)
    return unless playlist

    channel = playlist.channel
    api_key = Rails.application.config.youtube_api_key
    return if api_key.blank?

    new_video_ids = []
    next_page_token = nil

    begin
      # 1. ЦИКЛ СБОРА СТРУКТУРЫ: СКАНИРУЕМ ВСЕ СТРАНИЦЫ ПЛЕЙЛИСТА У ГУГЛА
      loop do
        token_param = next_page_token.present? ? "&pageToken=#{next_page_token}" : ""
        url = "https://www.googleapis.com/youtube/v3/playlistItems?part=contentDetails,snippet&playlistId=#{playlist.youtube_playlist_id}&maxResults=50&key=#{api_key}#{token_param}"

        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        break unless response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)
        break if data["items"].blank?

        data["items"].each do |item|
          v_id = item.dig("contentDetails", "videoId")
          snippet = item["snippet"]

          if v_id.present? && snippet
            video = channel.videos.find_or_initialize_by(youtube_video_id: v_id)
            video.title = snippet["title"]
            video.published_at = snippet["publishedAt"]
            video.video_type = "video"
            video.playlist_id = playlist.id

            if snippet["thumbnails"].present?
              thumb_data = snippet["thumbnails"]["maxres"] || snippet["thumbnails"]["high"] || snippet["thumbnails"]["medium"] || snippet["thumbnails"]["default"]
              video.thumbnail_url = thumb_data["url"] if thumb_data
            end

            video.save!(validate: false)
            new_video_ids << v_id
          end
        end

        next_page_token = data["nextPageToken"]
        break if next_page_token.blank?
      end

      # 2. ТОТАЛЬНЫЙ СКАНЕР СТАТИСТИКИ (ПРОСМОТРЫ, ЛАЙКИ, ОПИСАНИЯ, ДЛИТЕЛЬНОСТЬ)
      if new_video_ids.any?
        new_video_ids.each_slice(50) do |slice_ids|
          video_ids_str = slice_ids.join(",")
          # Обязательно запрашиваем part=snippet для получения full description!
          stats_url = "https://www.googleapis.com/youtube/v3/videos?part=contentDetails,statistics,snippet&id=#{video_ids_str}&key=#{api_key}"
          stats_res = Net::HTTP.get_response(URI.parse(stats_url))

          if stats_res.is_a?(Net::HTTPSuccess)
            stats_data = JSON.parse(stats_res.body)
            if stats_data["items"].present?
              stats_data["items"].each do |v_item|
                db_v = channel.videos.find_by(youtube_video_id: v_item["id"])
                if db_v
                  iso_dur = v_item.dig("contentDetails", "duration")

                  # Парсим длительность в секунды для кастомного прогресс-бара
                  secs = 0
                  if iso_dur.present?
                    begin
                      secs = ActiveSupport::Duration.parse(iso_dur).to_i
                    rescue
                      secs = 0
                    end
                  end

                  views = v_item.dig("statistics", "viewCount").to_i
                  likes = v_item.dig("statistics", "likeCount").to_i
                  description = v_item.dig("snippet", "description")

                  db_v.update_columns(
                    duration_seconds: secs,
                    views_count: views,
                    likes_count: likes,
                    description: description,
                    video_type: "video" # Перезаписываем "regular" на "video", чтобы автоповорот в плеере отработал корректно!
                  )
                end
              end
            end
          end
        end
        Rails.logger.info "--> [SOLID QUEUE УСПЕХ] Плейлист #{playlist.title} полностью синхронизирован."
      end

    rescue => e
      Rails.logger.error "!!! Ошибка фоновой синхронизации плейлиста: #{e.message}"
    end
  end
end
