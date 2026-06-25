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

  # Вспомогательный метод: рекурсивно идет по редиректам (код 301, 302) до 5 раз
  def self.fetch_with_redirects(url_value, limit = 5)
    return nil if limit.zero?

    uri = URI.parse(url_value)
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    case response
    when Net::HTTPSuccess
      response
    when Net::HTTPRedirection
      location = response["location"]
      puts "=== [РОБОТ ИНФО] Редирект #{response.code} на адрес: #{location} ==="
      fetch_with_redirects(location, limit - 1)
    else
      response
    end
  end
end
