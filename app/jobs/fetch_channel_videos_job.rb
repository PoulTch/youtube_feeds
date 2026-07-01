class FetchChannelVideosJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    # 1. Робот скачивает свежие видео из RSS
    channel.fetch_videos

    # 2. АВТОМАТИЧЕСКИЙ СБОР ВРЕМЕНИ ДЛЯ НОВЫХ ВИДЕО
    # Робот находит ролики этого канала, у которых ещё нет длительности, и опрашивает yt-dlp
    channel.videos.where(duration_seconds: nil).limit(5).each do |video|
      powershell_path = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
      ytdlp_path = "C:\\Windows\\System32\\yt-dlp.exe"
      video_url = "https://youtube.com{video.youtube_video_id}"

      cmd = "#{powershell_path} -Command \"& '#{ytdlp_path}' --get-duration '#{video_url}'\""

      begin
        IO.popen(cmd) do |io|
          duration_str = io.read.strip
          if duration_str.present?
            # Парсим строку вида "14:23" или "01:15:30" в чистые секунды
            parts = duration_str.split(":").map(&:to_i)
            seconds = case parts.size
            when 3 then parts[0] * 3600 + parts[1] * 60 + parts[2]
            when 2 then parts[0] * 60 + parts[1]
            else parts[0]
            end
            video.update_columns(duration_seconds: seconds) if seconds > 0
          end
        end
      rescue => e
        Rails.logger.error "Не удалось получить длительность для видео #{video.youtube_video_id}: #{e.message}"
      end
    end

    # 3. АВТОПИЛОТ АВАТАРОК: Обновляем оригинальное фото через Google API
    channel.fetch_avatar_from_api
  end
end
