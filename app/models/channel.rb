require "net/http"
require "rexml/document"

class Channel < ApplicationRecord
  has_many :videos, dependent: :destroy

  # Метод для создания/обновления канала по его ID
  def self.create_by_id(youtube_id)
    rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_id}"

    # Используем метод с редиректами
    response = fetch_with_redirects(rss_url)
    return nil if response.nil? || !response.is_a?(Net::HTTPSuccess)

    doc = REXML::Document.new(response.body)

    title_node = doc.elements["feed/title"]
    channel_title = title_node ? title_node.text : "Неизвестный канал"

    channel = find_or_initialize_by(youtube_channel_id: youtube_id)
    channel.title = channel_title
    channel.rss_url = rss_url
    channel.save
    channel
  end

  # Метод для скачивания видеороликов конкретного канала
  def fetch_videos
    puts "=== [РОБОТ] Начинаю скачивать видео для канала: #{title} (ID: #{youtube_channel_id}) ==="

    correct_rss_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{youtube_channel_id}"

    response = Channel.fetch_with_redirects(correct_rss_url)

    if response.nil? || !response.is_a?(Net::HTTPSuccess)
      puts "=== [РОБОТ ОШИБКА] Не удалось скачать фид для канала #{title} ==="
      return false
    end

    doc = REXML::Document.new(response.body)
    puts "=== [РОБОТ] XML успешно скачан. Начинаю парсить ролики... ==="

    doc.each_element("feed/entry") do |entry|
      video_id = entry.elements["yt:videoId"]&.text
      title = entry.elements["title"]&.text
      published_at = entry.elements["published"]&.text

      thumb_element = entry.elements["media:group/media:thumbnail"]
      thumbnail_url = thumb_element ? thumb_element.attributes["url"] : nil

      description = entry.elements["media:group/media:description"]&.text

      next if video_id.nil?

      video = videos.find_or_initialize_by(youtube_video_id: video_id)
      video.title = title
      video.published_at = published_at
      video.thumbnail_url = thumbnail_url
      video.description = description
      video.save
    end

    true
  end

  # Метод для скачивания оригинальной аватарки через ОФИЦИАЛЬНЫЙ YouTube API v3
  def fetch_avatar_from_api
    api_key = Rails.application.config.youtube_api_key
    return if api_key.blank? || youtube_channel_id.blank?

    # Стучимся в Google API v3 за метаданными канала
    url = "https://www.googleapis.com/youtube/v3/channels?part=snippet&id=#{youtube_channel_id}&key=#{api_key}"

    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      if response.is_a?(Net::HTTPSuccess)
        data = JSON.parse(response.body)

        # Безопасно вытаскиваем аватарку самого высокого разрешения (high или medium)
        avatar_url_from_api = data.dig("items", 0, "snippet", "thumbnails", "high", "url") ||
                              data.dig("items", 0, "snippet", "thumbnails", "medium", "url") ||
                              data.dig("items", 0, "snippet", "thumbnails", "default", "url")

        if avatar_url_from_api.present?
          # Жестко пишем её в нашу свежую колонку базы данных PostgreSQL!
          self.update_columns(avatar_url: avatar_url_from_api)
          puts "--> [API GOOGLE] Успешно загружен оригинал для: #{self.title}"
          return true
        end
      end
    rescue => e
      Rails.logger.error "Ошибка сбора аватарки через YouTube API: #{e.message}"
    end
    false
  end
end
